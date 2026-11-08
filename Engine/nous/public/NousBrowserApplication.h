#import <AppKit/AppKit.h>

#define NOUS_EXPORT __attribute__((visibility("default")))

NS_ASSUME_NONNULL_BEGIN

@class NousBrowserApplication;

/// Mirrors Dia's ArcBrowserApplicationDelegate: the browser process tells the
/// Swift host when it may build its UI and when the user asked to quit.
NOUS_EXPORT
NS_SWIFT_UI_ACTOR
@protocol NousBrowserApplicationDelegate <NSObject>
/// Chromium's browser process, Local State and the default profile are ready.
/// NSApp exists (a BrowserCrApplication) but its run loop has not started yet.
/// Install the app delegate, main menu and restore windows here.
- (void)browserApplicationDidInitialize:(NousBrowserApplication *)application;
@optional
/// -[NSApp terminate:] (⌘Q, Dock, Sparkle, logout). The host runs its own
/// beforeunload/download/session confirmation and calls -quit when approved.
- (void)browserApplicationDidRequestTermination:(NousBrowserApplication *)application;
/// Chromium's main message loop ended; Chromium shutdown follows.
- (void)browserApplicationWillShutDown:(NousBrowserApplication *)application;
@end

NOUS_EXPORT
NS_SWIFT_UI_ACTOR
@interface NousBrowserApplicationConfiguration : NSObject
/// Chromium --user-data-dir. The default profile lives in `Default/`.
@property(nonatomic, copy) NSString *userDataDirectory;
/// Keychain item protecting cookies/passwords (Chromium OSCrypt "Safe Storage").
/// Chromium creates it without UI when missing. nil keeps Chromium's default.
@property(nonatomic, copy, nullable) NSString *keychainServiceName;
@property(nonatomic, copy, nullable) NSString *keychainAccountName;
/// When set, OSCrypt's Safe Storage secret comes from the host instead of the
/// login keychain (no keychain item is read or created). Ad-hoc signed builds
/// use this so every update can open the same profile without a prompt.
@property(nonatomic, copy, nullable) NSString *safeStoragePassword;
/// Extra Chromium switches, e.g. @"--enable-features=Foo".
@property(nonatomic, copy) NSArray<NSString *> *additionalArguments;
@end

/// The Chromium browser process inside NousCore.framework (Dia: ArcBrowserApplication).
/// Chromium (//chrome) owns NSApp and the main run loop; the Swift host only
/// provides UI. There is no CEF layer and no external message pump.
NOUS_EXPORT
NS_SWIFT_UI_ACTOR
@interface NousBrowserApplication : NSObject
+ (instancetype)sharedApplication NS_SWIFT_NAME(shared());
@property(nonatomic, weak, nullable) id<NousBrowserApplicationDelegate> delegate;
@property(nonatomic, readonly, copy) NSString *version;
@property(nonatomic, readonly) BOOL isRunning;
/// Runs ChromeMain in this (browser) process. Blocks until Chromium has shut
/// down and returns its exit code. Call once, from main(), before touching NSApp.
- (int)runWithConfiguration:(NousBrowserApplicationConfiguration *)configuration;
/// Exit after the host approved termination (chrome::AttemptExit()).
- (void)quit;
@end

NS_ASSUME_NONNULL_END
