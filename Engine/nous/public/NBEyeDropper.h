#import <AppKit/AppKit.h>
#ifndef NOUS_EXPORT
#define NOUS_EXPORT __attribute__((visibility("default")))
#endif
NS_ASSUME_NONNULL_BEGIN

@class NBChromiumView;

/// One webpage EyeDropper picking request (Web EyeDropper API or color input).
/// Main-thread only. Calling either -selectRed:green:blue: or -cancel finishes
/// the session; afterwards its methods do nothing. If Chromium cancels the
/// request first (navigation, tab close, or AbortController), `cancelHandler`
/// runs so the host can tear down its picker UI.
NOUS_EXPORT
NS_SWIFT_UI_ACTOR
@interface NBEyeDropperSession : NSObject
@property(nonatomic, readonly, weak, nullable) NBChromiumView *sourceView;
@property(nonatomic, readonly, weak, nullable) NSWindow *sourceWindow;
@property(nonatomic, readonly, getter=isFinished) BOOL finished;
@property(nonatomic, copy, nullable) void (^cancelHandler)(void);

/// Captures the requesting page's current composited surface directly from
/// Chromium without requiring macOS Screen Recording permission.
/// `screenRect` is the page view's frame in AppKit global screen coordinates.
- (void)capturePageSnapshot:(void (^)(NSBitmapImageRep * _Nullable bitmap, NSRect screenRect))completion;

/// Finishes the session with an sRGB color (0..255 per channel).
- (void)selectRed:(uint8_t)red green:(uint8_t)green blue:(uint8_t)blue;

/// Finishes the session as canceled.
- (void)cancel;
@end

NOUS_EXPORT
NS_SWIFT_UI_ACTOR
@interface NBEyeDropperCenter : NSObject
+ (instancetype)sharedCenter NS_SWIFT_NAME(shared());
/// Called when a webpage requests the EyeDropper. When nil, Chromium falls back
/// to its built-in macOS NSColorSampler implementation.
@property(nonatomic, copy, nullable) void (^sessionHandler)(NBEyeDropperSession *session);
@end

NS_ASSUME_NONNULL_END
