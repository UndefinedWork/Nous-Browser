#import <AppKit/AppKit.h>
#ifndef NOUS_EXPORT
#define NOUS_EXPORT __attribute__((visibility("default")))
#endif
#import "NBChromiumDownloads.h"
NS_ASSUME_NONNULL_BEGIN
/// Public Objective-C boundary. Chromium C++ types never cross into Swift.
NOUS_EXPORT
@interface NBChromiumRuntime : NSObject
+ (void)prepareApplication;
+ (BOOL)startWithProfilePath:(NSString *)profilePath error:(NSError * _Nullable * _Nullable)error;
+ (void)shutdown;
+ (NSString *)engineVersion;
+ (BOOL)hasNativeTabLifecycle;
+ (BOOL)hasNativeClosePreflight;
/// True only when the loaded SDK exposes the versioned Chrome source-picker API.
+ (BOOL)hasNativeDisplayPicker;
/// Uses Chromium's own persisted Memory Saver preferences. -1 is unavailable.
+ (NSInteger)memorySaverMode;
+ (BOOL)setMemorySaverMode:(NSInteger)mode;
/// Reads the active Chromium profile's native exceptions and managed rules.
/// `sites` and `managedSites` contain the original Chrome URL-match patterns.
+ (nullable NSDictionary<NSString *, id> *)memorySaverSitesWithError:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(memorySaverSites());
/// New entries accept canonical domain names; Chromium itself matches subdomains.
+ (BOOL)addMemorySaverSite:(NSString *)domain error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(addMemorySaverSite(_:));
/// Removes only the exact user-owned rule, never a managed rule.
+ (BOOL)removeMemorySaverSite:(NSString *)rule error:(NSError * _Nullable * _Nullable)error NS_SWIFT_NAME(removeMemorySaverSite(_:));
/// AppKit's terminateLater loop prevents CEF close tasks from completing.
/// The app requests asynchronous page closure before entering normal terminate.
+ (void)setTerminationHandler:(void (^)(void))handler;
+ (void)completeApplicationTermination;
@end

NOUS_EXPORT
@interface NBChromiumView : NSView
@property(nonatomic, copy, nullable) void (^eventHandler)(NSString *event, NSDictionary<NSString *, id> *payload);
/// Return a retained native host for a user-initiated popup. Chromium retains
/// its opener and navigation state. A background tab must not steal selection.
@property(nonatomic, copy, nullable) NBChromiumView * _Nullable (^popupHandler)(BOOL newWindow, BOOL activate);
/// The owning browser window remains available while this page is detached
/// from the view deck. Setting nil suspends presentation during a transfer or
/// shutdown; it never falls back to the page's former physical parent window.
/// Unmanaged standalone hosts default to their attached NSView window.
@property(nonatomic, weak, nullable) NSWindow *dialogPresentationWindow;
@property(nonatomic, readonly, copy) NSString *pageTitle;
@property(nonatomic, readonly, copy) NSString *URLString;
@property(nonatomic, readonly) BOOL loading;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
@property(nonatomic, readonly) BOOL fullscreen;
@property(nonatomic, readonly) BOOL mediaActive;
@property(nonatomic) double zoomFactor;
- (void)loadURL:(NSString *)URLString;
- (void)reserveForPopup;
- (void)goBack;
- (void)goForward;
- (void)navigationURLBackwards:(BOOL)backwards completion:(void (^)(NSString * _Nullable, NSError * _Nullable))completion;
- (void)reloadBypassingCache:(BOOL)bypass;
- (void)stopLoading;
/// Prints through Chromium's native page printing pipeline and macOS dialog.
- (void)printPage;
/// Exits HTML fullscreen through Chromium. Native window fullscreen is restored
/// only when this page originally requested it.
- (void)exitPageFullscreen;
- (void)closeBrowser;
/// Asks the page to close and preserves it if an unload confirmation is canceled.
- (void)requestCloseWithCompletion:(void (^)(BOOL closed))completion NS_SWIFT_NAME(requestClose(completion:));
/// Native, reversible beforeunload. No page unloads until commitPreparedClose.
- (void)prepareCloseWithCompletion:(void (^)(BOOL approved))completion NS_SWIFT_NAME(prepareClose(completion:));
- (BOOL)validatePreparedClose;
- (void)cancelPreparedClose;
- (void)commitPreparedCloseWithCompletion:(void (^)(BOOL closed))completion NS_SWIFT_NAME(commitPreparedClose(completion:));
- (void)focusBrowser;
- (void)setPageVisible:(BOOL)visible;
/// Supplies window-selected/pinned state to Chromium's own lifecycle policy.
/// This does not override DOM visibility or discard a page on a custom timer.
- (void)setTabActiveInWindow:(BOOL)active pinned:(BOOL)pinned autoDiscardable:(BOOL)autoDiscardable;
/// Executes through an in-process DevTools session; no debugging port is opened.
/// A nonempty worldName is an isolated world. Async results are awaited.
- (void)evaluate:(NSString *)source world:(NSString *)worldName completion:(void (^)(id _Nullable, NSError * _Nullable))completion;
- (void)capturePNG:(void (^)(NSData * _Nullable, NSError * _Nullable))completion;
- (void)findText:(NSString *)text backwards:(BOOL)backwards next:(BOOL)next completion:(void (^)(BOOL))completion;
- (void)stopFinding;
/// Installs isolated document-start code and a named binding. Binding events include
/// the trusted executionContextId and are accepted only from that registered world.
- (void)addScript:(NSString *)source world:(NSString *)worldName binding:(NSString *)bindingName;
@end
NS_ASSUME_NONNULL_END
