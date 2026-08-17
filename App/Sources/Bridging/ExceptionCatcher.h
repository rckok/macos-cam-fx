#ifndef CAMERA_EFFECTS_EXCEPTION_CATCHER_H
#define CAMERA_EFFECTS_EXCEPTION_CATCHER_H

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C `@try/@catch`.
///
/// AVFoundation APIs such as `AVCaptureDevice.activeVideoMinFrameDuration`
/// throw `NSException` rather than `NSError`, which Swift `do/catch` cannot handle.
BOOL CECatchException(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END

#endif
