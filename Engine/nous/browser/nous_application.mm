// NousBrowserApplication: runs Chromium's real //chrome browser process inside
// the Nous app, the way Dia's ArcBrowserApplication does. ChromeMain owns the
// process main thread and [NSApp run]; the Swift host is a delegate.

#import "nous/public/NousBrowserApplication.h"
#import "nous/public/NousChromium.h"
#import "nous/public/NBChromiumDownloads.h"

#include <memory>
#include <string>
#include <vector>

#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/strings/sys_string_conversions.h"
#include "base/values.h"
#include "chrome/browser/browser_process.h"
#include "chrome/browser/lifetime/application_lifetime_desktop.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/profiles/profile_manager.h"
#include "components/keep_alive_registry/keep_alive_types.h"
#include "components/os_crypt/common/keychain_password_mac.h"
#include "components/keep_alive_registry/scoped_keep_alive.h"
#include "components/prefs/pref_service.h"
#include "components/version_info/version_info.h"
#include "crypto/apple/keychain_v2.h"
#include "nous/browser/nous_internal.h"
#include "nous/common/nous_embedder.h"
#include "url/gurl.h"

extern "C" int ChromeMain(int argc, const char** argv);

namespace {

// Answers only the Safe Storage lookup with the host's secret; every other
// keychain call (passkeys, Touch ID, certificates) goes to the real keychain.
class NousSafeStorageKeychain : public crypto::apple::KeychainV2 {
 public:
  explicit NousSafeStorageKeychain(std::string password)
      : password_(std::move(password)) {}

  static void Install(std::string password) {
    static NousSafeStorageKeychain* keychain =
        new NousSafeStorageKeychain(std::move(password));
    SetInstanceOverride(keychain);
  }

  OSStatus AddGenericPassword(std::string_view service_name,
                              std::string_view account_name,
                              base::span<const uint8_t> password) override {
    if (IsSafeStorage(service_name, account_name)) return noErr;
    return KeychainV2::AddGenericPassword(service_name, account_name, password);
  }

  base::expected<std::vector<uint8_t>, OSStatus> FindGenericPassword(
      std::string_view service_name,
      std::string_view account_name) override {
    if (IsSafeStorage(service_name, account_name))
      return std::vector<uint8_t>(password_.begin(), password_.end());
    return KeychainV2::FindGenericPassword(service_name, account_name);
  }

 private:
  static bool IsSafeStorage(std::string_view service, std::string_view account) {
    return service == KeychainPassword::GetServiceName() &&
           account == KeychainPassword::GetAccountName();
  }

  const std::string password_;
};

std::unique_ptr<ScopedKeepAlive> g_keep_alive;
dispatch_block_t g_legacy_termination_handler;
bool g_quitting = false;

// Chrome Settings stores these in the profile (Windows-epoch microseconds).
constexpr char kMemorySaverSites[] =
    "performance_tuning.tab_discarding.exceptions_with_time";
constexpr char kManagedMemorySaverSites[] =
    "performance_tuning.tab_discarding.exceptions_managed";

NSError* Failure(NSString* message) {
  return [NSError errorWithDomain:@"NousCore"
                             code:1
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}
}  // namespace

namespace {
raw_ptr<Profile> g_profile = nullptr;
}  // namespace

namespace nous {
Profile* GetProfile() { return g_profile; }
}  // namespace nous

@implementation NousBrowserApplicationConfiguration
- (instancetype)init {
  if ((self = [super init])) {
    _userDataDirectory = @"";
    _additionalArguments = @[];
  }
  return self;
}
@end

@interface NousBrowserApplication ()
- (void)browserStarted;
- (BOOL)terminateRequested;
- (void)mainLoopEnded;
@end

static void BrowserStartedHook() {
  [[NousBrowserApplication sharedApplication] browserStarted];
}
static bool TerminateRequestHook() {
  return [[NousBrowserApplication sharedApplication] terminateRequested];
}
static void MainLoopEndedHook() {
  [[NousBrowserApplication sharedApplication] mainLoopEnded];
}

@implementation NousBrowserApplication {
  BOOL _running;
}

+ (instancetype)sharedApplication {
  static NousBrowserApplication* application;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ application = [[NousBrowserApplication alloc] init]; });
  return application;
}

- (NSString*)version {
  return base::SysUTF8ToNSString(std::string(version_info::GetVersionNumber()));
}

- (BOOL)isRunning { return _running; }

- (int)runWithConfiguration:(NousBrowserApplicationConfiguration*)configuration {
  if (_running) return 1;
  _running = YES;
  nous::SetEmbedded(true);
  nous::SetBrowserStartedHook(&BrowserStartedHook);
  nous::SetTerminateRequestHook(&TerminateRequestHook);
  nous::SetMainLoopEndedHook(&MainLoopEndedHook);

  // Nous' own Safe Storage item instead of Chromium's shared one (Dia uses
  // its own name too); must be set before OSCrypt first reads it.
  if (configuration.keychainServiceName.length)
    KeychainPassword::GetServiceName() = base::SysNSStringToUTF8(configuration.keychainServiceName);
  if (configuration.keychainAccountName.length)
    KeychainPassword::GetAccountName() = base::SysNSStringToUTF8(configuration.keychainAccountName);
  if (configuration.safeStoragePassword.length)
    NousSafeStorageKeychain::Install(base::SysNSStringToUTF8(configuration.safeStoragePassword));

  std::vector<std::string> arguments;
  NSArray<NSString*>* processArguments = NSProcessInfo.processInfo.arguments;
  arguments.push_back(processArguments.firstObject.UTF8String ?: "Nous Browser");
  if (configuration.userDataDirectory.length) {
    arguments.push_back("--user-data-dir=" +
                        base::SysNSStringToUTF8(configuration.userDataDirectory));
  }
  // The host owns windows, session restore, first run and default-browser UI.
  arguments.push_back("--no-startup-window");
  arguments.push_back("--no-first-run");
  arguments.push_back("--no-default-browser-check");
  arguments.push_back("--disable-session-crashed-bubble");
  for (NSString* argument in configuration.additionalArguments)
    arguments.push_back(base::SysNSStringToUTF8(argument));
  // Developer switches given to the app itself (e.g. --enable-logging).
  for (NSUInteger i = 1; i < processArguments.count; ++i) {
    if ([processArguments[i] hasPrefix:@"--"])
      arguments.push_back(base::SysNSStringToUTF8(processArguments[i]));
  }
  std::vector<const char*> argv;
  for (const std::string& argument : arguments) argv.push_back(argument.c_str());
  argv.push_back(nullptr);

  const int code = ChromeMain(static_cast<int>(arguments.size()), argv.data());
  _running = NO;
  return code;
}

- (void)browserStarted {
  // Chrome on macOS keeps running with zero windows only because AppController
  // holds a keep-alive. Nous replaces AppController, so it holds its own.
  g_keep_alive = std::make_unique<ScopedKeepAlive>(
      KeepAliveOrigin::APP_CONTROLLER, KeepAliveRestartOption::DISABLED);
  // With --no-startup-window Chrome need not have loaded a profile yet. Nous
  // always uses the user-data-dir's last-used ("Default") profile.
  ProfileManager* profiles = g_browser_process->profile_manager();
  Profile* profile = ProfileManager::GetLastUsedProfileIfLoaded();
  if (!profile && profiles) profile = profiles->GetProfile(profiles->GetLastUsedProfileDir());
  g_profile = profile;
  LOG_IF(ERROR, !profile) << "Nous: the default Chromium profile could not be loaded.";
  if (profile) nous::InstallDownloadDelegate(profile);
  nous::InstallTabServices();
  [self.delegate browserApplicationDidInitialize:self];
}

- (BOOL)terminateRequested {
  if (getenv("NOUS_TRACE")) fprintf(stderr, "Nous: terminate requested (quitting=%d)\n", g_quitting);
  if (g_quitting) return NO;  // Let Chrome finish its own exit sequence.
  if (g_legacy_termination_handler) {
    g_legacy_termination_handler();
    return YES;
  }
  if ([self.delegate respondsToSelector:@selector(browserApplicationDidRequestTermination:)]) {
    [self.delegate browserApplicationDidRequestTermination:self];
    return YES;
  }
  [self quit];
  return YES;
}

- (void)quit {
  if (g_quitting) return;
  g_quitting = true;
  // Defer so a caller inside an AppKit event or Chromium callback unwinds first.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (getenv("NOUS_TRACE")) fprintf(stderr, "Nous: CloseAllBrowsersAndQuit\n");
    g_keep_alive.reset();
    chrome::OnClosingAllBrowsers(true);
    chrome::CloseAllBrowsersAndQuit();
  });
}

- (void)mainLoopEnded {
  if (getenv("NOUS_TRACE")) fprintf(stderr, "Nous: main loop ended\n");
  g_profile = nullptr;
  if ([self.delegate respondsToSelector:@selector(browserApplicationWillShutDown:)])
    [self.delegate browserApplicationWillShutDown:self];
  // Pages must not outlive their Profile; Chromium destroys profiles next.
  nous::CloseAllTabs();
  [[NBChromiumDownloadCenter sharedCenter] cancelAll];
}
@end

// ---------------------------------------------------------------------------
// NBChromiumRuntime: the engine-facing facade the Swift UI already uses.

@implementation NBChromiumRuntime
+ (void)prepareApplication {}
+ (BOOL)startWithProfilePath:(NSString*)profilePath error:(NSError**)error {
  if (nous::GetProfile()) return YES;
  if (error) *error = Failure(@"Chromium has not started.");
  return NO;
}
+ (void)shutdown {}
+ (NSString*)engineVersion { return [NousBrowserApplication sharedApplication].version; }
+ (BOOL)hasNativeTabLifecycle { return NO; }
+ (BOOL)hasNativeClosePreflight { return YES; }
+ (BOOL)hasNativeDisplayPicker { return NO; }
+ (NSInteger)memorySaverMode { return -1; }
+ (BOOL)setMemorySaverMode:(NSInteger)mode { return NO; }

+ (NSDictionary<NSString*, id>*)memorySaverSitesWithError:(NSError**)error {
  Profile* profile = nous::GetProfile();
  if (!profile) {
    if (error) *error = Failure(@"Chromium profile preferences are unavailable.");
    return nil;
  }
  PrefService* prefs = profile->GetPrefs();
  NSMutableArray<NSString*>* sites = [NSMutableArray array];
  for (const auto [key, value] : prefs->GetDict(kMemorySaverSites))
    [sites addObject:base::SysUTF8ToNSString(key)];
  NSMutableArray<NSString*>* managed = [NSMutableArray array];
  for (const base::Value& value : prefs->GetList(kManagedMemorySaverSites))
    if (value.is_string()) [managed addObject:base::SysUTF8ToNSString(value.GetString())];
  [sites sortUsingSelector:@selector(localizedStandardCompare:)];
  [managed sortUsingSelector:@selector(localizedStandardCompare:)];
  return @{@"sites" : sites, @"managedSites" : managed,
           @"canEdit" : @(prefs->IsUserModifiablePreference(kMemorySaverSites))};
}

+ (BOOL)changeMemorySaverSite:(NSString*)rule adding:(BOOL)adding error:(NSError**)error {
  Profile* profile = nous::GetProfile();
  if (!profile) {
    if (error) *error = Failure(@"Chromium profile preferences are unavailable.");
    return NO;
  }
  PrefService* prefs = profile->GetPrefs();
  if (!prefs->IsUserModifiablePreference(kMemorySaverSites)) {
    if (error) *error = Failure(@"Chromium Memory Saver exceptions are read-only.");
    return NO;
  }
  const std::string key = base::SysNSStringToUTF8(rule);
  if (adding) {
    GURL url("https://" + key);
    if (key.empty() || !url.is_valid() || url.host() != key) {
      if (error) *error = Failure(@"Enter a valid domain name.");
      return NO;
    }
  }
  base::DictValue sites = prefs->GetDict(kMemorySaverSites).Clone();
  if (adding) {
    if (sites.contains(key)) return YES;
    const int64_t windowsMicros =
        static_cast<int64_t>(NSDate.date.timeIntervalSince1970 * 1000000) + 11644473600000000LL;
    sites.Set(key, std::to_string(windowsMicros));
  } else {
    if (!sites.Remove(key)) return YES;
  }
  prefs->SetDict(kMemorySaverSites, std::move(sites));
  return YES;
}
+ (BOOL)addMemorySaverSite:(NSString*)domain error:(NSError**)error {
  return [self changeMemorySaverSite:domain adding:YES error:error];
}
+ (BOOL)removeMemorySaverSite:(NSString*)rule error:(NSError**)error {
  return [self changeMemorySaverSite:rule adding:NO error:error];
}
+ (void)setTerminationHandler:(void (^)(void))handler {
  g_legacy_termination_handler = [handler copy];
}
+ (void)completeApplicationTermination {
  [[NousBrowserApplication sharedApplication] quit];
}
@end
