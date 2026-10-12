#import "HPVisionHost.h"

#import <Metal/Metal.h>
#import <os/lock.h>
#import <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/qos.h>
#include <unistd.h>

#include "gfx_host.h"
#include "SoHEngine.h"

NSNotificationName const HPVisionHostEngineDidStopNotification = @"HPVisionHostEngineDidStop";

// Must match HPPresentUniforms in GamePresent.metal.
typedef struct {
    uint32_t encodeSRGB;
} HPPresentUniforms;

static os_unfair_lock sLock = OS_UNFAIR_LOCK_INIT;
static CAMetalLayer* sLayer;   // guarded by sLock
static _Atomic long sState = HPEngineStateIdle;
static _Atomic int sExitCode = 0;
static atomic_flag sStarted = ATOMIC_FLAG_INIT;

// Presenter GPU state. Only touched on the game thread (present() callback).
static id<MTLDevice> sDevice;
static id<MTLRenderPipelineState> sPipeline;
static MTLPixelFormat sPipelineFormat = MTLPixelFormatInvalid;
static id<MTLSamplerState> sSampler;

static os_log_t HPLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("com.nscabezon.sohvision", "host"); });
    return log;
}

static BOOL IsSRGB(MTLPixelFormat format) {
    switch (format) {
        case MTLPixelFormatBGRA8Unorm_sRGB:
        case MTLPixelFormatRGBA8Unorm_sRGB:
            return YES;
        default:
            return NO;
    }
}

static BOOL PreparePipeline(id<MTLDevice> device, MTLPixelFormat format) {
    if (sPipeline != nil && sDevice == device && sPipelineFormat == format) {
        return YES;
    }
    id<MTLLibrary> library = [device newDefaultLibrary];
    id<MTLFunction> vertexFn = [library newFunctionWithName:@"hp_present_vertex"];
    id<MTLFunction> fragmentFn = [library newFunctionWithName:@"hp_present_fragment"];
    if (vertexFn == nil || fragmentFn == nil) {
        os_log_error(HPLog(), "present: shader functions missing from the default library");
        return NO;
    }
    MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
    desc.label = @"HPPresent";
    desc.vertexFunction = vertexFn;
    desc.fragmentFunction = fragmentFn;
    desc.colorAttachments[0].pixelFormat = format;
    NSError* error = nil;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (pipeline == nil) {
        os_log_error(HPLog(), "present: pipeline creation failed: %{public}@", error);
        return NO;
    }
    MTLSamplerDescriptor* samplerDesc = [MTLSamplerDescriptor new];
    samplerDesc.minFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.sAddressMode = MTLSamplerAddressModeClampToEdge;
    samplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
    sSampler = [device newSamplerStateWithDescriptor:samplerDesc];
    sPipeline = pipeline;
    sDevice = device;
    sPipelineFormat = format;
    return YES;
}

// Draws `source` aspect-fit (letterboxed, black bars) into `target` inside `cmdbuf`.
// Game thread only (uses the shared pipeline state).
static BOOL EncodeFit(id<MTLCommandBuffer> cmdbuf, id<MTLTexture> source, id<MTLTexture> target, BOOL sourceIsSRGB) {
    if (source.width == 0 || source.height == 0 || target.width == 0 || target.height == 0) {
        return NO;
    }
    if (!PreparePipeline(cmdbuf.device, target.pixelFormat)) {
        return NO;
    }

    // Aspect-fit the source into the target.
    double srcAspect = (double)source.width / (double)source.height;
    double dstW = (double)target.width, dstH = (double)target.height;
    double w = dstW, h = dstW / srcAspect;
    if (h > dstH) {
        h = dstH;
        w = dstH * srcAspect;
    }
    MTLViewport viewport = { (dstW - w) * 0.5, (dstH - h) * 0.5, w, h, 0.0, 1.0 };

    MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);

    id<MTLRenderCommandEncoder> encoder = [cmdbuf renderCommandEncoderWithDescriptor:pass];
    encoder.label = @"HPPresent";
    [encoder setRenderPipelineState:sPipeline];
    [encoder setViewport:viewport];
    HPPresentUniforms uniforms = { .encodeSRGB = (sourceIsSRGB && !IsSRGB(target.pixelFormat)) ? 1u : 0u };
    [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
    [encoder setFragmentTexture:source atIndex:0];
    [encoder setFragmentSamplerState:sSampler atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [encoder endEncoding];
    return YES;
}

// ---------------------------------------------------------------------------
// HPStereoSink

enum { HPSlotFree = 0, HPSlotWriting, HPSlotPending, HPSlotPresenting };
#define HP_STEREO_SLOTS 3

@implementation HPStereoSink {
    id<MTLTexture> _ring[HP_STEREO_SLOTS][2];     // BGRA8Unorm_sRGB, read by the main-actor blit
    id<MTLTexture> _ringView[HP_STEREO_SLOTS][2]; // BGRA8Unorm views, render targets on the game thread
    os_unfair_lock _lock;
    int _slotState[HP_STEREO_SLOTS]; // guarded by _lock
    NSInteger _pendingSlot;          // guarded by _lock
    uint64_t _pendingValue;          // guarded by _lock
    BOOL _pendingMono;               // guarded by _lock
    // Game thread only.
    NSInteger _writingSlot;
    uint64_t _writingFrameIndex;
    uint64_t _eventValue;
    _Atomic bool _hopScheduled;
    _Atomic uint64_t _published, _dropped, _superseded, _taken;
}

+ (NSInteger)slotCount {
    return HP_STEREO_SLOTS;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device width:(NSInteger)width height:(NSInteger)height {
    if (width < 1 || height < 1) {
        return nil;
    }
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _width = width;
    _height = height;
    _lock = OS_UNFAIR_LOCK_INIT;
    _pendingSlot = -1;
    _writingSlot = -1;
    _event = [device newSharedEvent];
    if (_event == nil) {
        return nil;
    }
    _event.label = @"HPStereoSink";
    MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                                                    width:(NSUInteger)width
                                                                                   height:(NSUInteger)height
                                                                                mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    for (int slot = 0; slot < HP_STEREO_SLOTS; slot++) {
        for (int eye = 0; eye < 2; eye++) {
            id<MTLTexture> t = [device newTextureWithDescriptor:desc];
            id<MTLTexture> v = [t newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm];
            if (t == nil || v == nil) {
                return nil;
            }
            t.label = [NSString stringWithFormat:@"HPStereoRing %d/%d", slot, eye];
            _ring[slot][eye] = t;
            _ringView[slot][eye] = v;
        }
    }
    return self;
}

- (id<MTLTexture>)textureForSlot:(NSInteger)slot eye:(NSInteger)eye {
    return _ring[slot < 0 ? 0 : slot % HP_STEREO_SLOTS][eye == 0 ? 0 : 1];
}

- (uint64_t)publishedFrames { return atomic_load(&_published); }
- (uint64_t)droppedFrames { return atomic_load(&_dropped); }
- (uint64_t)supersededFrames { return atomic_load(&_superseded); }
- (uint64_t)takenFrames { return atomic_load(&_taken); }

// Game thread, inside the engine's command buffer (the engine commits it).
- (void)encodeEye:(const HPPresentInfo*)info {
    id<MTLTexture> source = (__bridge id<MTLTexture>)info->texture;
    id<MTLCommandBuffer> cmdbuf = (__bridge id<MTLCommandBuffer>)info->commandBuffer;
    int eyeCount = info->eyeCount < 1 ? 1 : (info->eyeCount > 2 ? 2 : info->eyeCount);
    int eye = info->eye < 0 ? 0 : (info->eye > 1 ? 1 : info->eye);

    if (eye == 0) {
        os_unfair_lock_lock(&_lock);
        if (_writingSlot < 0) {
            for (int i = 0; i < HP_STEREO_SLOTS; i++) {
                if (_slotState[i] == HPSlotFree) {
                    _slotState[i] = HPSlotWriting;
                    _writingSlot = i;
                    break;
                }
            }
        }
        // else: the previous frame never reached its last eye; reuse its slot.
        os_unfair_lock_unlock(&_lock);
        if (_writingSlot < 0) {
            atomic_fetch_add(&_dropped, 1); // ring full: drop, never block the game
            return;
        }
        _writingFrameIndex = info->frameIndex;
    } else if (_writingSlot < 0 || _writingFrameIndex != info->frameIndex) {
        return; // eye 0 of this frame was dropped
    }

    if (!EncodeFit(cmdbuf, source, _ringView[_writingSlot][eye], IsSRGB(source.pixelFormat))) {
        return;
    }
    if (eye != eyeCount - 1) {
        return;
    }

    _eventValue++;
    [cmdbuf encodeSignalEvent:_event value:_eventValue];

    os_unfair_lock_lock(&_lock);
    if (_pendingSlot >= 0) {
        // Not taken yet: replace it. Later writes to that slot are ordered after this
        // command buffer on the engine queue, so it can be reused right away.
        _slotState[_pendingSlot] = HPSlotFree;
        atomic_fetch_add(&_superseded, 1);
    }
    _slotState[_writingSlot] = HPSlotPending;
    _pendingSlot = _writingSlot;
    _pendingValue = _eventValue;
    _pendingMono = (eyeCount == 1);
    os_unfair_lock_unlock(&_lock);
    _writingSlot = -1;
    atomic_fetch_add(&_published, 1);

    if (!atomic_exchange(&_hopScheduled, true)) {
        __weak HPStereoSink* weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            HPStereoSink* sink = weakSelf;
            if (sink == nil) {
                return;
            }
            atomic_store(&sink->_hopScheduled, false);
            void (^handler)(void) = sink.frameReadyHandler;
            if (handler != nil) {
                handler();
            }
        });
    }
}

- (BOOL)takeLatestFrameValue:(uint64_t*)value slot:(NSInteger*)slot mono:(BOOL*)mono {
    os_unfair_lock_lock(&_lock);
    NSInteger pending = _pendingSlot;
    if (pending >= 0) {
        _slotState[pending] = HPSlotPresenting;
        *value = _pendingValue;
        *slot = pending;
        *mono = _pendingMono;
        _pendingSlot = -1;
    }
    os_unfair_lock_unlock(&_lock);
    if (pending < 0) {
        return NO;
    }
    atomic_fetch_add(&_taken, 1);
    return YES;
}

- (void)releaseSlot:(NSInteger)slot {
    if (slot < 0 || slot >= HP_STEREO_SLOTS) {
        return;
    }
    os_unfair_lock_lock(&_lock);
    if (_slotState[slot] == HPSlotPresenting) {
        _slotState[slot] = HPSlotFree;
    }
    os_unfair_lock_unlock(&_lock);
}

@end

static HPStereoSink* sStereoSink; // guarded by sLock

// HPPresenter.present: runs on the game thread, before the engine commits `cmdbuf`.
// Stereo sink attached: every eye goes to the sink. Otherwise eye 0 is drawn
// aspect-fit (letterboxed) into the layer's next drawable.
static void HPPresent(void* ctx, const HPPresentInfo* info) {
    (void)ctx;
    if (info == NULL || info->texture == NULL || info->commandBuffer == NULL) {
        return;
    }

    os_unfair_lock_lock(&sLock);
    CAMetalLayer* layer = sLayer;
    HPStereoSink* sink = sStereoSink;
    os_unfair_lock_unlock(&sLock);

    if (sink != nil) {
        @autoreleasepool {
            [sink encodeEye:info];
        }
        return;
    }

    // The flat window shows eye 0 only.
    if (info->eye != 0 || layer == nil) {
        return;
    }
    CGSize drawableSize = layer.drawableSize;
    if (drawableSize.width < 1 || drawableSize.height < 1) {
        return;
    }

    @autoreleasepool {
        id<MTLTexture> source = (__bridge id<MTLTexture>)info->texture;
        id<MTLCommandBuffer> cmdbuf = (__bridge id<MTLCommandBuffer>)info->commandBuffer;
        if (source.width == 0 || source.height == 0) {
            return;
        }
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (drawable == nil) {
            return;
        }
        if (EncodeFit(cmdbuf, source, drawable.texture, IsSRGB(source.pixelFormat))) {
            [cmdbuf presentDrawable:drawable];
        }
    }
}

static void* EngineThreadMain(void* arg) {
    char* argv0 = (char*)arg;
    pthread_setname_np("SoHEngine");
    os_log(HPLog(), "engine thread started (cwd=%{public}s, HOME=%{public}s)", getcwd(NULL, 0) ?: "?",
           getenv("HOME") ?: "?");

    char* argv[] = { argv0, NULL };
    int rc;
    @autoreleasepool {
        rc = SoHEngine_Main(1, argv);
    }

    os_log_error(HPLog(), "SoHEngine_Main returned %d", rc);
    atomic_store(&sExitCode, rc);
    atomic_store(&sState, HPEngineStateExited);
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:HPVisionHostEngineDidStopNotification object:nil];
    });
    return NULL;
}

@implementation HPVisionHost

+ (void)attachLayer:(CAMetalLayer*)layer {
    os_unfair_lock_lock(&sLock);
    sLayer = layer;
    os_unfair_lock_unlock(&sLock);
}

+ (void)attachStereoSink:(HPStereoSink*)sink {
    os_unfair_lock_lock(&sLock);
    sStereoSink = sink;
    os_unfair_lock_unlock(&sLock);
}

+ (HPEngineState)engineState {
    return (HPEngineState)atomic_load(&sState);
}

+ (int)engineExitCode {
    return atomic_load(&sExitCode);
}

+ (BOOL)startEngine {
    if (atomic_flag_test_and_set(&sStarted)) {
        return atomic_load(&sState) != HPEngineStateFailed;
    }

    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* bundlePath = NSBundle.mainBundle.bundlePath;
    NSString* resourcePath = NSBundle.mainBundle.resourcePath ?: bundlePath;
    NSString* documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];

    // User data lives in Documents (LUS GetAppDirectoryPath on __IOS__ = $HOME/Documents):
    // oot.o2r, saves, config, logs. Make sure mods/ exists so it is visible in Files.
    if (documents != nil) {
        [fm createDirectoryAtPath:[documents stringByAppendingPathComponent:@"mods"]
            withIntermediateDirectories:YES
                             attributes:nil
                                  error:nil];
    }
    // Same as SDL's UIKit main on iOS (HarkinianPad): cwd = bundle resources, so the
    // "./" fallback of LocateFileAcrossAppDirs resolves into the bundle.
    [fm changeCurrentDirectoryPath:resourcePath];

    os_log(HPLog(), "bundle=%{public}@ documents=%{public}@", bundlePath, documents ?: @"?");
    for (NSString* name in @[ @"soh.o2r", @"gamecontrollerdb.txt", @"assets" ]) {
        NSString* path = [resourcePath stringByAppendingPathComponent:name];
        os_log(HPLog(), "resource %{public}@: %{public}s", name, [fm fileExistsAtPath:path] ? "found" : "MISSING");
    }

    HPPresenter presenter = { .ctx = NULL, .present = HPPresent };
    HP_SetPresenter(&presenter);
    HP_SetEyeCount(1);

    NSString* executable = NSBundle.mainBundle.executablePath ?: @"SoHVision";
    char* argv0 = strdup(executable.fileSystemRepresentation);

    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 8 * 1024 * 1024);
    pthread_attr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE, 0);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    int err = pthread_create(&thread, &attr, EngineThreadMain, argv0);
    pthread_attr_destroy(&attr);

    if (err != 0) {
        os_log_error(HPLog(), "pthread_create failed: %{public}s", strerror(err));
        free(argv0);
        atomic_store(&sState, HPEngineStateFailed);
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:HPVisionHostEngineDidStopNotification object:nil];
        });
        return NO;
    }
    atomic_store(&sState, HPEngineStateRunning);
    return YES;
}

@end
