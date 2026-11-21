#import <AppKit/AppKit.h>
#ifndef NOUS_EXPORT
#define NOUS_EXPORT __attribute__((visibility("default")))
#endif

@class NBChromiumView;

NS_ASSUME_NONNULL_BEGIN

// The regular Chromium profile's installed extensions. No private profiles
// are exposed through this bridge.
NOUS_EXPORT
@interface NBChromiumExtensionCenter : NSObject
+ (instancetype)sharedCenter;
- (NSNumber*)availability;
- (NSArray<NSDictionary<NSString*, id>*>*)installedExtensions;
- (NSNumber*)setEnabled:(NSNumber*)enabled forExtension:(NSString*)identifier;
- (NSNumber*)uninstallExtension:(NSString*)identifier fromWindow:(NSWindow*)window;
// Returns an extension-owned page to open, if the action has UI.
- (nullable NSString*)runExtension:(NSString*)identifier inPage:(nullable NBChromiumView*)page;
@end

NS_ASSUME_NONNULL_END
