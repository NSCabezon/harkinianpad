#pragma once

#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, HPEngineState) {
    HPEngineStateIdle = 0,
    HPEngineStateRunning,
    HPEngineStateExited, // SoHEngine_Main returned (it should never return)
    HPEngineStateFailed, // the game thread could not be created
};

/// Posted on the main thread when the engine stops (state Exited or Failed).
FOUNDATION_EXPORT NSNotificationName const HPVisionHostEngineDidStopNotification;

/// Stereo hand-off from the game thread to the main actor (S5, presentation A).
///
/// Game thread (HPPresent, inside the engine's command buffer, no commit):
/// eye 0 acquires a free ring slot (or drops the frame, never blocks), each eye is
/// drawn into ring[slot][eye]; after the last eye the sink encodes
/// `signalEvent(event, value)` and publishes {value, slot, mono}, superseding an
/// older unconsumed frame. Then it schedules one coalesced hop to the main queue.
/// Main actor: `takeLatestFrame` -> encodeWaitForEvent(value) -> LowLevelTexture
/// replace(using:) + blit -> `releaseSlot` from the completion handler.
///
/// Ring textures are BGRA8Unorm_sRGB (the engine output holds sRGB-encoded values
/// in a BGRA8Unorm texture; the game thread writes them through a BGRA8Unorm view).
NS_SWIFT_SENDABLE
@interface HPStereoSink : NSObject

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device width:(NSInteger)width height:(NSInteger)height;
/// `eyes` = 1 for the flat window (keeps only the left eye of a stereo frame), 2 for stereo.
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                  width:(NSInteger)width
                                 height:(NSInteger)height
                                   eyes:(NSInteger)eyes;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) id<MTLSharedEvent> event;
@property (class, nonatomic, readonly) NSInteger slotCount;

- (id<MTLTexture>)textureForSlot:(NSInteger)slot eye:(NSInteger)eye NS_SWIFT_NAME(texture(slot:eye:));

/// Invoked on the main queue after a frame is published (coalesced: at most one
/// pending hop). Set it before attaching the sink.
@property (atomic, nullable, copy) void (^frameReadyHandler)(void);

/// Main thread: the newest published frame, which moves to "presenting".
/// Returns NO if no new frame is pending. `mono` = the engine sent one eye only.
- (BOOL)takeLatestFrameValue:(uint64_t*)value slot:(NSInteger*)slot mono:(BOOL*)mono
    NS_SWIFT_NAME(takeLatestFrame(value:slot:mono:));

/// Main thread, flat window (2D): takes the newest frame and draws it aspect-fit into
/// the layer's next drawable on `queue` (waits for the engine on the GPU, not the CPU).
/// Returns NO if there was no new frame or no drawable.
- (BOOL)presentLatestToLayer:(CAMetalLayer*)layer queue:(id<MTLCommandQueue>)queue
    NS_SWIFT_NAME(presentLatest(to:queue:));

/// Any thread: the main-actor blit out of `slot` completed on the GPU.
- (void)releaseSlot:(NSInteger)slot;

/// Pacing counters (monotonic).
@property (atomic, readonly) uint64_t publishedFrames;  // frames fully encoded by the game thread
@property (atomic, readonly) uint64_t droppedFrames;    // no free slot at eye 0 (ring full)
@property (atomic, readonly) uint64_t supersededFrames; // published but replaced before the main actor took them
@property (atomic, readonly) uint64_t takenFrames;      // frames the main actor presented

@end

/// Host side of gfx_host.h: owns the presenter and the game thread.
@interface HPVisionHost : NSObject

/// Layer the presenter draws into (nil detaches; frames are then skipped).
/// Safe from any thread.
+ (void)attachLayer:(nullable CAMetalLayer*)layer NS_SWIFT_NAME(attach(_:));

/// Routes presents to a stereo sink instead of the layer (nil = back to the layer).
/// Safe from any thread.
+ (void)attachStereoSink:(nullable HPStereoSink*)sink NS_SWIFT_NAME(attachStereo(_:));

/// Detaches `sink` only if it is still the attached one (views may appear before
/// the previous one disappears). Safe from any thread.
+ (void)detachStereoSink:(HPStereoSink*)sink NS_SWIFT_NAME(detachStereo(_:));

/// The sink presents currently go to (FPS meter). Safe from any thread.
@property (class, readonly, nullable) HPStereoSink* attachedStereoSink;

/// Main thread: runs on every display refresh, just before the engine's tick
/// (HP_DisplayTick). The flat window presents from it. nil clears it.
+ (void)setDisplayTickHandler:(nullable void (^)(void))handler;

/// Installs the presenter and starts the game thread once (and the display clock,
/// main thread). Later calls are no-ops.
/// Returns NO if the thread could not be created.
+ (BOOL)startEngine;

@property (class, readonly) HPEngineState engineState;
@property (class, readonly) int engineExitCode;

@end

NS_ASSUME_NONNULL_END
