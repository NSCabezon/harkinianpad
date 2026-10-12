#pragma once

#import <Foundation/Foundation.h>
#import <QuartzCore/CAMetalLayer.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, HPEngineState) {
    HPEngineStateIdle = 0,
    HPEngineStateRunning,
    HPEngineStateExited, // SoHEngine_Main returned (it should never return)
    HPEngineStateFailed, // the game thread could not be created
};

/// Posted on the main thread when the engine stops (state Exited or Failed).
FOUNDATION_EXPORT NSNotificationName const HPVisionHostEngineDidStopNotification;

/// Host side of gfx_host.h: owns the presenter and the game thread.
@interface HPVisionHost : NSObject

/// Layer the presenter draws into (nil detaches; frames are then skipped).
/// Safe from any thread.
+ (void)attachLayer:(nullable CAMetalLayer*)layer NS_SWIFT_NAME(attach(_:));

/// Installs the presenter and starts the game thread once. Later calls are no-ops.
/// Returns NO if the thread could not be created.
+ (BOOL)startEngine;

@property (class, readonly) HPEngineState engineState;
@property (class, readonly) int engineExitCode;

@end

NS_ASSUME_NONNULL_END
