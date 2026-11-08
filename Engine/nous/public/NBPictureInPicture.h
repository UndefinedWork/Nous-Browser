#import <AppKit/AppKit.h>
#ifndef NOUS_EXPORT
#define NOUS_EXPORT __attribute__((visibility("default")))
#endif
NS_ASSUME_NONNULL_BEGIN

@class NBChromiumView;

/// One video playing in Chromium's Picture-in-Picture window. Chromium draws
/// the video; the host draws the controls. Main-thread only. After
/// `closeHandler` runs the session is inert and its methods do nothing.
NOUS_EXPORT
@interface NBPictureInPictureSession : NSObject
/// The floating window that shows the video.
@property(nonatomic, readonly, weak, nullable) NSWindow *window;
/// The page the video came from.
@property(nonatomic, readonly, weak, nullable) NBChromiumView *sourceView;
@property(nonatomic, readonly, getter=isPlaying) BOOL playing;
@property(nonatomic, readonly, getter=hasEnded) BOOL ended;
/// Seconds. 0 when unknown, +infinity for live streams.
@property(nonatomic, readonly) NSTimeInterval duration;
/// Playback position at `positionDate`; advance it by `playbackRate`.
@property(nonatomic, readonly) NSTimeInterval position;
@property(nonatomic, readonly) double playbackRate;
@property(nonatomic, readonly, copy) NSDate *positionDate;
@property(nonatomic, readonly, getter=isClosed) BOOL closed;
@property(nonatomic, copy, nullable) void (^updateHandler)(NBPictureInPictureSession *session);
@property(nonatomic, copy, nullable) void (^closeHandler)(NBPictureInPictureSession *session);

- (void)togglePlayPause;
- (void)seekTo:(NSTimeInterval)seconds;
/// Closes the window and pauses the video.
- (void)close;
/// Closes the window and keeps the video playing in its page.
- (void)returnToPage;
@end

NOUS_EXPORT
@interface NBPictureInPictureCenter : NSObject
+ (instancetype)sharedCenter NS_SWIFT_NAME(shared());
/// Called each time a video enters Picture-in-Picture.
@property(nonatomic, copy, nullable) void (^sessionHandler)(NBPictureInPictureSession *session);
@end

NS_ASSUME_NONNULL_END
