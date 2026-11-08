#import <AppKit/AppKit.h>
#ifndef NOUS_EXPORT
#define NOUS_EXPORT __attribute__((visibility("default")))
#endif
NS_ASSUME_NONNULL_BEGIN

/// These objects are main-thread only. They never retain the source tab/browser.
NOUS_EXPORT
@interface NBChromiumDownloadJob : NSObject
@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly, copy) NSString *suggestedFilename;
@property(nonatomic, readonly, copy) NSString *mimeType;
@property(nonatomic, readonly, weak, nullable) NSWindow *sourceWindow;
@property(nonatomic, readonly) BOOL hasDurableObservation;
@property(nonatomic, readonly, copy) NSDictionary<NSString *, id> *snapshot;
@property(nonatomic, copy, nullable) void (^updateHandler)(NBChromiumDownloadJob *job);
/// One-shot. nil cancels; a file URL starts writing to the caller's staging file.
- (void)chooseDestination:(nullable NSURL *)url;
- (void)cancel;
@end

NOUS_EXPORT
@interface NBChromiumDownloadCenter : NSObject
+ (instancetype)sharedCenter NS_SWIFT_NAME(shared());
@property(nonatomic, copy, nullable) void (^newDownloadHandler)(NBChromiumDownloadJob *job);
@property(nonatomic, readonly) NSUInteger activeDownloadCount;
/// Call before Chromium shutdown so pending save choices and partial files fail
/// explicitly. Completion callbacks are delivered before this method returns.
- (void)cancelAll;
@end
NS_ASSUME_NONNULL_END
