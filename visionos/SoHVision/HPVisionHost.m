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

// HPPresenter.present: runs on the game thread, before the engine commits `cmdbuf`.
// Draws the eye texture aspect-fit (letterboxed) into the layer's next drawable.
static void HPPresent(void* ctx, const HPPresentInfo* info) {
    (void)ctx;
    if (info == NULL || info->texture == NULL || info->commandBuffer == NULL) {
        return;
    }
    // Phase 1 is mono: only eye 0 reaches the flat window.
    if (info->eye != 0) {
        return;
    }

    os_unfair_lock_lock(&sLock);
    CAMetalLayer* layer = sLayer;
    os_unfair_lock_unlock(&sLock);
    if (layer == nil) {
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
        id<MTLTexture> target = drawable.texture;
        if (target.width == 0 || target.height == 0) {
            return;
        }
        if (!PreparePipeline(cmdbuf.device, target.pixelFormat)) {
            return;
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
        HPPresentUniforms uniforms = { .encodeSRGB = (IsSRGB(source.pixelFormat) && !IsSRGB(target.pixelFormat)) ? 1u : 0u };
        [encoder setFragmentBytes:&uniforms length:sizeof(uniforms) atIndex:0];
        [encoder setFragmentTexture:source atIndex:0];
        [encoder setFragmentSamplerState:sSampler atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [encoder endEncoding];

        [cmdbuf presentDrawable:drawable];
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
