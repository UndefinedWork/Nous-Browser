#import "nous/public/NBChromiumExtensions.h"

#include <memory>
#include <string>

#include "base/functional/bind.h"
#include "base/memory/weak_ptr.h"
#include "base/scoped_observation.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/extensions/extension_action_runner.h"
#include "chrome/browser/extensions/extension_uninstall_dialog.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/extensions/extension_enable_flow.h"
#include "chrome/browser/ui/extensions/extension_enable_flow_delegate.h"
#include "components/sessions/content/session_tab_helper.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/disable_reason.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/image_loader.h"
#include "extensions/browser/management_policy.h"
#include "extensions/browser/uninstall_reason.h"
#include "extensions/common/api/extension_action/action_info.h"
#include "extensions/common/constants.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest.h"
#include "extensions/common/manifest_handlers/options_page_info.h"
#include "nous/browser/nous_internal.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/native_ui_types.h"
#include "url/gurl.h"

#import "nous/public/NousChromium.h"

namespace {

using extensions::Extension;
using extensions::ExtensionRegistry;

bool IsUserExtension(const Extension& extension) {
  return extension.is_extension() &&
         !extensions::Manifest::IsComponentLocation(extension.location());
}

bool HasAction(const Extension& extension) {
  const auto* info = extensions::ActionInfo::GetExtensionActionInfo(&extension);
  return info && !info->synthesized;
}

bool CanModify(Profile* profile, const Extension& extension) {
  auto* system = extensions::ExtensionSystem::Get(profile);
  auto* policy = system ? system->management_policy() : nullptr;
  return policy && policy->UserMayModifySettings(&extension, nullptr) &&
         !policy->MustRemainInstalled(&extension, nullptr);
}

NSString* ExtensionPage(const GURL& url, const Extension& extension) {
  if (!url.is_valid() || !url.SchemeIs(extensions::kExtensionScheme) ||
      url.host() != extension.id()) {
    return nil;
  }
  return base::SysUTF8ToNSString(url.spec());
}

class ExtensionCenter final : public extensions::ExtensionRegistryObserver,
                              public ExtensionEnableFlowDelegate,
                              public extensions::ExtensionUninstallDialog::Delegate {
 public:
  explicit ExtensionCenter(NBChromiumExtensionCenter* owner)
      : owner_(owner), icons_([NSMutableDictionary dictionary]) {}

  bool Available() { return Registry() != nullptr; }

  NSArray<NSDictionary<NSString*, id>*>* InstalledExtensions() {
    auto* registry = Registry();
    if (!registry) return @[];

    auto* profile = nous::GetProfile();
    const auto installed = registry->GenerateInstalledExtensionsSet();
    NSMutableArray<NSDictionary<NSString*, id>*>* records = [NSMutableArray array];
    for (const auto& extension : installed) {
      if (!IsUserExtension(*extension)) continue;
      NSString* identifier = base::SysUTF8ToNSString(extension->id());
      if (!icons_[identifier]) LoadIcon(profile, *extension, identifier);
      NSMutableDictionary<NSString*, id>* record = [@{
          @"id" : identifier,
          @"name" : base::SysUTF8ToNSString(extension->name()),
          @"enabled" : @(registry->enabled_extensions().Contains(extension->id())),
          @"canModify" : @(CanModify(profile, *extension)),
          @"hasAction" : @(HasAction(*extension)),
          @"hasOptions" : @(extensions::OptionsPageInfo::HasOptionsPage(extension.get())),
      } mutableCopy];
      if ([icons_[identifier] isKindOfClass:NSImage.class]) record[@"icon"] = icons_[identifier];
      [records addObject:record];
    }
    return records;
  }

  bool SetEnabled(NSString* identifier, bool enabled) {
    const auto* extension = Find(identifier, ExtensionRegistry::EVERYTHING);
    auto* profile = nous::GetProfile();
    if (!extension || !CanModify(profile, *extension)) return false;

    const std::string id = extension->id();
    auto* registry = Registry();
    if (!enabled) {
      if (registry->enabled_extensions().Contains(id))
        extensions::ExtensionRegistrar::Get(profile)->DisableExtension(
            id, {extensions::disable_reason::DISABLE_USER_ACTION});
      ScheduleUpdate();
      return true;
    }
    if (enable_ || !NSApp.keyWindow ||
        (!registry->disabled_extensions().Contains(id) &&
         !registry->terminated_extensions().Contains(id))) {
      return false;
    }
    // Stock flow confirms newly requested permissions and honors the
    // blocklist, supervision, and policy before enabling the extension.
    enable_ = std::make_unique<ExtensionEnableFlow>(profile, id, this);
    enable_->StartForNativeWindow(gfx::NativeWindow(NSApp.keyWindow));
    return true;
  }

  bool Uninstall(NSString* identifier, NSWindow* window) {
    const auto* extension = Find(identifier, ExtensionRegistry::EVERYTHING);
    auto* profile = nous::GetProfile();
    if (uninstall_ || !window || !extension || !CanModify(profile, *extension))
      return false;
    uninstall_ = extensions::ExtensionUninstallDialog::Create(
        profile, gfx::NativeWindow(window), this);
    uninstall_->ConfirmUninstall(
        extension, extensions::UNINSTALL_REASON_USER_INITIATED,
        extensions::UNINSTALL_SOURCE_CHROME_EXTENSIONS_PAGE);
    return true;
  }

  NSString* Run(NSString* identifier, NBChromiumView* page) {
    const auto* extension = Find(identifier, ExtensionRegistry::ENABLED);
    if (!extension) return nil;

    auto* contents = nous::WebContentsForView(page);
    if (contents && contents->GetBrowserContext() != nous::GetProfile())
      return nil;
    if (!page.window || !contents || !HasAction(*extension)) {
      return ExtensionPage(extensions::OptionsPageInfo::GetOptionsPage(extension),
                           *extension);
    }

    auto* runner = extensions::ExtensionActionRunner::GetForWebContents(contents);
    auto* manager = extensions::ExtensionActionManager::Get(nous::GetProfile());
    auto* action = manager ? manager->GetExtensionAction(*extension) : nullptr;
    if (!runner || !action) return nil;

    const int tab_id = sessions::SessionTabHelper::IdForTab(contents).id();
    const GURL popup = action->GetPopupUrl(tab_id);
    switch (runner->RunAction(extension, /*grant_tab_permissions=*/true)) {
      case extensions::ExtensionAction::ShowAction::kShowPopup:
        return ExtensionPage(popup, *extension);
      case extensions::ExtensionAction::ShowAction::kToggleSidePanel:
        return ExtensionPage(extensions::OptionsPageInfo::GetOptionsPage(extension),
                             *extension);
      case extensions::ExtensionAction::ShowAction::kNone:
        return nil;
    }
    return nil;
  }

 private:
  ExtensionRegistry* Registry() {
    auto* profile = nous::GetProfile();
    if (!profile || shutdown_) return nullptr;
    auto* registry = ExtensionRegistry::Get(profile);
    if (registry && !observation_.IsObserving()) observation_.Observe(registry);
    return registry;
  }

  const Extension* Find(NSString* identifier, int states) {
    auto* registry = Registry();
    if (!registry) return nullptr;
    const auto* extension = registry->GetExtensionById(
        base::SysNSStringToUTF8(identifier), states);
    return extension && IsUserExtension(*extension) ? extension : nullptr;
  }

  void LoadIcon(Profile* profile, const Extension& extension, NSString* identifier) {
    icons_[identifier] = NSNull.null;
    auto* loader = extensions::ImageLoader::Get(profile);
    if (!loader) return;
    loader->LoadImageAtEveryScaleFactorAsync(
        &extension, gfx::Size(24, 24),
        base::BindOnce(&ExtensionCenter::IconLoaded, weak_factory_.GetWeakPtr(),
                       base::SysNSStringToUTF8(identifier), extension.version().GetString()));
  }

  void IconLoaded(std::string id, std::string version, const gfx::Image& image) {
    if (image.IsEmpty()) return;
    NSString* identifier = base::SysUTF8ToNSString(id);
    const auto* current = Find(identifier, ExtensionRegistry::EVERYTHING);
    if (!current || current->version().GetString() != version) return;
    icons_[identifier] = image.AsNSImage();
    ScheduleUpdate();
  }

  void ScheduleUpdate() {
    if (update_scheduled_ || shutdown_) return;
    update_scheduled_ = true;
    auto weak = weak_factory_.GetWeakPtr();
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!weak) return;
      weak->update_scheduled_ = false;
      NBChromiumExtensionCenter* owner = weak->owner_;
      if (owner)
        [NSNotificationCenter.defaultCenter postNotificationName:@"NBChromiumExtensionsDidChange"
                                                          object:owner];
    });
  }

  void OnExtensionLoaded(content::BrowserContext*, const Extension* extension) override {
    if (IsUserExtension(*extension)) ScheduleUpdate();
  }
  void OnExtensionUnloaded(content::BrowserContext*, const Extension* extension,
                           extensions::UnloadedExtensionReason) override {
    if (IsUserExtension(*extension)) ScheduleUpdate();
  }
  void OnExtensionInstalled(content::BrowserContext*, const Extension* extension, bool) override {
    if (!IsUserExtension(*extension)) return;
    [icons_ removeObjectForKey:base::SysUTF8ToNSString(extension->id())];
    ScheduleUpdate();
  }
  void OnExtensionUninstalled(content::BrowserContext*, const Extension* extension,
                              extensions::UninstallReason) override {
    if (!IsUserExtension(*extension)) return;
    [icons_ removeObjectForKey:base::SysUTF8ToNSString(extension->id())];
    ScheduleUpdate();
  }
  void OnShutdown(ExtensionRegistry*) override {
    shutdown_ = true;
    weak_factory_.InvalidateWeakPtrs();
    enable_.reset();
    uninstall_.reset();
    observation_.Reset();
  }
  void ExtensionEnableFlowFinished() override {
    enable_.reset();
    ScheduleUpdate();
  }
  void ExtensionEnableFlowAborted(bool) override {
    enable_.reset();
    ScheduleUpdate();
  }
  void OnExtensionUninstallDialogClosed(bool, const std::u16string&) override {
    uninstall_.reset();
    ScheduleUpdate();
  }

  __weak NBChromiumExtensionCenter* owner_;
  NSMutableDictionary<NSString*, id>* icons_;
  base::ScopedObservation<ExtensionRegistry, extensions::ExtensionRegistryObserver>
      observation_{this};
  std::unique_ptr<ExtensionEnableFlow> enable_;
  std::unique_ptr<extensions::ExtensionUninstallDialog> uninstall_;
  bool update_scheduled_ = false;
  bool shutdown_ = false;
  base::WeakPtrFactory<ExtensionCenter> weak_factory_{this};
};

}  // namespace

@implementation NBChromiumExtensionCenter {
  std::unique_ptr<ExtensionCenter> _center;
}

+ (instancetype)sharedCenter {
  static NBChromiumExtensionCenter* center;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ center = [[self alloc] init]; });
  return center;
}

- (instancetype)init {
  if ((self = [super init])) _center = std::make_unique<ExtensionCenter>(self);
  return self;
}

- (NSNumber*)availability { return @(_center->Available()); }

- (NSArray<NSDictionary<NSString*, id>*>*)installedExtensions {
  return _center->InstalledExtensions();
}

- (NSNumber*)setEnabled:(NSNumber*)enabled forExtension:(NSString*)identifier {
  return @(_center->SetEnabled(identifier, enabled.boolValue));
}

- (NSNumber*)uninstallExtension:(NSString*)identifier fromWindow:(NSWindow*)window {
  return @(_center->Uninstall(identifier, window));
}

- (NSString*)runExtension:(NSString*)identifier inPage:(NBChromiumView*)page {
  return _center->Run(identifier, page);
}

@end
