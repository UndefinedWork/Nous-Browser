#!/usr/bin/env python3
"""Apply the Nous Core patch set to a Chromium checkout (idempotent).

These are the only changes //chrome needs for the Dia-style embedding:
  1. chrome/BUILD.gn          build //chrome as NousCore.framework + link //nous,
                              export the Nous/NB Objective-C classes.
  2. chrome/common            framework name constant used for bundle lookup.
  3. chrome_browser_main_mac  no Chrome AppController / main menu when embedded.
  4. app_controller_mac       AppController.sharedController is nil when embedded.
  5. chrome_browser_application_mac
                              -terminate: is routed to the Swift host.
  6. chrome_browser_main.cc   browser-started and main-loop-ended hooks.
  7. ui/tab_helpers.h         let //nous attach Chrome's tab helpers.

Usage: apply_chromium_patches.py /path/to/chromium/src
Each edit is an exact-text replacement; a missing anchor fails loudly so a
Chromium roll surfaces every conflict (Dia rebases weekly the same way).
"""
import pathlib
import sys

SRC = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '.')
EMBEDDER = '#include "nous/common/nous_embedder.h"\n'


def edit(path, old, new):
    file = SRC / path
    text = file.read_text()
    if new in text:
        return
    if old not in text:
        sys.exit(f'Nous patch anchor not found in {path}:\n{old[:200]}')
    file.write_text(text.replace(old, new, 1))
    print(f'patched {path}')


def include_after(path, anchor, line):
    file = SRC / path
    text = file.read_text()
    if line in text:
        return
    if anchor not in text:
        sys.exit(f'Nous include anchor not found in {path}: {anchor}')
    file.write_text(text.replace(anchor, anchor + '\n' + line, 1))
    print(f'patched {path} (include)')


# 1. chrome/BUILD.gn -----------------------------------------------------------
edit('chrome/BUILD.gn', 'import("//v8/gni/v8.gni")\n',
     'import("//v8/gni/v8.gni")\nimport("//nous/nous.gni")\n')
edit('chrome/BUILD.gn',
     '  chrome_framework_name = chrome_product_full_name + " Framework"\n',
     '  chrome_framework_name = chrome_product_full_name + " Framework"\n'
     '  if (nous_core) {\n'
     '    # Dia ships //chrome as ArcCore.framework; Nous ships it as NousCore.\n'
     '    chrome_framework_name = "NousCore"\n'
     '  }\n')
edit('chrome/BUILD.gn', '''  config("chrome_dll_symbol_exports") {
    inputs = [ rebase_path("app/framework.exports") ]
    ldflags = [
      "-Wl,-exported_symbols_list",
      "-Wl," + rebase_path("app/framework.exports", root_build_dir),
    ]
  }''', '''  config("chrome_dll_symbol_exports") {
    inputs = [ rebase_path("app/framework.exports") ]
    ldflags = [
      "-Wl,-exported_symbols_list",
      "-Wl," + rebase_path("app/framework.exports", root_build_dir),
    ]
    if (nous_core) {
      inputs += [ "//nous/nous_framework.exports" ]
      ldflags += [
        "-Wl,-exported_symbols_list",
        "-Wl," + rebase_path("//nous/nous_framework.exports", root_build_dir),
      ]
    }
  }''')
edit('chrome/BUILD.gn', '''      "//third_party/cld_3/src/src:cld_3",
    ]

    if (is_chromeos) {
      deps += [ "//chrome/browser/ash/schedqos" ]
    }''', '''      "//third_party/cld_3/src/src:cld_3",
    ]

    if (nous_core) {
      deps += [
        "//nous:browser",
        "//nous:embedder",
      ]
    }

    if (is_chromeos) {
      deps += [ "//chrome/browser/ash/schedqos" ]
    }''')

# 2. Framework name constant ----------------------------------------------------
gn = SRC / 'chrome/common/BUILD.gn'
if 'import("//nous/nous.gni")' not in gn.read_text():
    text = gn.read_text()
    i = text.index('import(')
    gn.write_text(text[:i] + 'import("//nous/nous.gni")\n' + text[i:])
edit('chrome/common/BUILD.gn', '''static_library("non_code_constants") {
  sources = [''', '''static_library("non_code_constants") {
  if (nous_core) {
    defines = [ "NOUS_CORE_FRAMEWORK" ]
  }
  sources = [''')
edit('chrome/common/chrome_constants.cc', '''#if BUILDFLAG(IS_MAC)
const base::FilePath::CharType kFrameworkName[] =''', '''#if BUILDFLAG(IS_MAC) && defined(NOUS_CORE_FRAMEWORK)
const base::FilePath::CharType kFrameworkName[] = FPL("NousCore.framework");
const base::FilePath::CharType kFrameworkExecutableName[] = FPL("NousCore");
const char kMacHelperSuffixAlerts[] = " (Alerts)";
#elif BUILDFLAG(IS_MAC)
const base::FilePath::CharType kFrameworkName[] =''')

# 3./4./5. Host owns NSApp delegate, menu and termination -------------------------
include_after('chrome/browser/chrome_browser_main_mac.mm',
              '#include "chrome/browser/chrome_browser_main_mac.h"\n', EMBEDDER)
edit('chrome/browser/chrome_browser_main_mac.mm', '''  // Create the app delegate by requesting the shared AppController.
  CHECK_EQ(nil, NSApp.delegate);''', '''  if (nous::IsEmbedded()) {
    // Nous: the Swift host installs its own delegate and main menu.
    return content::RESULT_CODE_NORMAL_EXIT;
  }
  // Create the app delegate by requesting the shared AppController.
  CHECK_EQ(nil, NSApp.delegate);''')
edit('chrome/browser/chrome_browser_main_mac.mm', '''  [AppController.sharedController didEndMainMessageLoop];''',
     '''  if (!nous::IsEmbedded()) {
    [AppController.sharedController didEndMainMessageLoop];
  }''')

include_after('chrome/browser/app_controller_mac.mm',
              '#import "chrome/browser/app_controller_mac.h"\n', EMBEDDER)
edit('chrome/browser/app_controller_mac.mm', '''+ (AppController*)sharedController {
  static AppController* sharedController = [] {''', '''+ (AppController*)sharedController {
  if (nous::IsEmbedded()) {
    // Nous: there is no Chrome AppController; callers are nil-safe sends.
    return nil;
  }
  static AppController* sharedController = [] {''')

include_after('chrome/browser/chrome_browser_application_mac.mm',
              '#import "chrome/browser/chrome_browser_application_mac.h"\n',
              '#include "chrome/browser/lifetime/application_lifetime_desktop.h"\n'
              '#include "chrome/browser/lifetime/browser_shutdown.h"\n' + EMBEDDER)
edit('chrome/browser/chrome_browser_application_mac.mm', '''- (void)terminate:(id)sender {
  [AppController.sharedController tryToTerminateApplication];''', '''- (void)terminate:(id)sender {
  if (nous::IsEmbedded()) {
    // Nous: the host confirms beforeunload/downloads first, then quits through
    // the same shutdown AppController uses (CloseAllBrowsersAndQuit).
    if (browser_shutdown::IsTryingToQuit() || nous::RunTerminateRequestHook()) {
      return;
    }
    chrome::OnClosingAllBrowsers(true);
    chrome::CloseAllBrowsersAndQuit();
    return;
  }
  [AppController.sharedController tryToTerminateApplication];''')

# 6. Lifecycle hooks ------------------------------------------------------------
include_after('chrome/browser/chrome_browser_main.cc',
              '#include "chrome/browser/chrome_browser_main.h"\n', EMBEDDER)
edit('chrome/browser/chrome_browser_main.cc', '''  for (auto& chrome_extra_part : chrome_extra_parts_) {
    chrome_extra_part->PostBrowserStart();
  }''', '''  for (auto& chrome_extra_part : chrome_extra_parts_) {
    chrome_extra_part->PostBrowserStart();
  }
  // Nous: profile and browser process are ready; the host builds its UI.
  nous::RunBrowserStartedHook();''')
edit('chrome/browser/chrome_browser_main.cc',
     '  TRACE_EVENT0("startup", "ChromeBrowserMainParts::PostMainMessageLoopRun");\n',
     '  TRACE_EVENT0("startup", "ChromeBrowserMainParts::PostMainMessageLoopRun");\n'
     '  nous::RunMainLoopEndedHook();\n')

# 7. TabHelpers friend ------------------------------------------------------------
edit('chrome/browser/ui/tab_helpers.h', 'class PreviewTab;\n',
     'class PreviewTab;\nclass NousTabHelpersAttacher;\n')
edit('chrome/browser/ui/tab_helpers.h', '  friend class PreviewTab;\n',
     '  friend class PreviewTab;\n  friend class NousTabHelpersAttacher;\n')

# 8. This checkout also carries //cef (the former engine). Its GN file is
#    loaded even with enable_cef=false; only CEF builds need its asserts.
if (SRC / 'cef/BUILD.gn').exists():
    edit('cef/BUILD.gn', '''if (is_mac || is_win) {
  # Enable Widevine CDM host verification and storage ID.''', '''if ((is_mac || is_win) && enable_cef) {
  # Nous Core: only CEF builds require these; enable_cef=false builds stock chrome.
  # Enable Widevine CDM host verification and storage ID.''')
    edit('cef/BUILD.gn', 'assert(enable_print_preview)', 'assert(!enable_cef || enable_print_preview)')
    # CEF's patches include this header-only downcast helper behind ENABLE_CEF
    # but call it unconditionally; non-CEF (Nous) builds need the include.
    for path in ('chrome/browser/ui/browser_command_controller.cc',
                 'chrome/browser/ui/views/toolbar/toolbar_view.cc',
                 'chrome/browser/ui/views/frame/browser_view.cc'):
        edit(path, '#if BUILDFLAG(ENABLE_CEF)\n#include "cef/libcef/browser/chrome/browser_util.h"\n',
             '#include "cef/libcef/browser/chrome/browser_util.h"  // Nous: used unguarded.\n#if BUILDFLAG(ENABLE_CEF)\n')
    edit('chrome/browser/ui/browser_window/internal/browser_window_features.cc',
         '''  if (browser->GetType() == BrowserWindowInterface::Type::TYPE_POPUP &&
      browser->cef_delegate()) {
    return true;
  }''', '''#if BUILDFLAG(ENABLE_CEF)
  if (browser->GetType() == BrowserWindowInterface::Type::TYPE_POPUP &&
      browser->cef_delegate()) {
    return true;
  }
#endif''')
    # CEF's patch declares BrowserWindowCreateParams::opener only for CEF builds.
    edit('chrome/browser/devtools/devtools_window.cc',
         '    create_params.opener = opener;\n',
         '#if BUILDFLAG(ENABLE_CEF)\n    create_params.opener = opener;\n#endif\n')
    # CEF adds an accelerated widget lookup. A Nous NSWindow has no Chrome
    # dialog host, but its native view can still parent a modal sheet.
    edit('components/constrained_window/constrained_window_views.cc',
         '''    // Use with CEF windowless rendering.
    gfx::AcceleratedWidget parent_widget =
        parent ? CurrentBrowserModalClient()
                     ->GetModalDialogHost(parent)
                     ->GetAcceleratedWidget()
               : gfx::kNullAcceleratedWidget;''',
         '''    // Use with CEF windowless rendering when a dialog host is available.
    ModalDialogHost* parent_host =
        parent ? CurrentBrowserModalClient()->GetModalDialogHost(parent)
               : nullptr;
    gfx::AcceleratedWidget parent_widget =
        parent_host ? parent_host->GetAcceleratedWidget()
                    : gfx::kNullAcceleratedWidget;''')
    edit('components/constrained_window/constrained_window_views.cc',
         '''  // Use with CEF windowless rendering.
  gfx::AcceleratedWidget parent_widget = parent
                                             ? CurrentBrowserModalClient()
                                                   ->GetModalDialogHost(parent)
                                                   ->GetAcceleratedWidget()
                                             : gfx::kNullAcceleratedWidget;''',
         '''  // Use with CEF windowless rendering when a dialog host is available.
  ModalDialogHost* parent_host =
      parent ? CurrentBrowserModalClient()->GetModalDialogHost(parent)
             : nullptr;
  gfx::AcceleratedWidget parent_widget =
      parent_host ? parent_host->GetAcceleratedWidget()
                  : gfx::kNullAcceleratedWidget;''')

# 9. Other places that spell the framework as "<product> Framework".
def import_nous_gni(path):
    file = SRC / path
    text = file.read_text()
    if 'import("//nous/nous.gni")' not in text:
        i = text.index('import(')
        file.write_text(text[:i] + 'import("//nous/nous.gni")\n' + text[i:])
        print(f'patched {path} (import)')

import_nous_gni('content/public/app/BUILD.gn')
edit('content/public/app/BUILD.gn',
     '      ldflags += [ "-Wl,-install_name,@executable_path/../Frameworks/$chrome_product_full_name Framework.framework/Versions/$chrome_version_full/Libraries/libaperitif.dylib" ]\n',
     '''      _framework = "$chrome_product_full_name Framework"
      if (nous_core) {
        _framework = "NousCore"
      }
      ldflags += [ "-Wl,-install_name,@executable_path/../Frameworks/$_framework.framework/Versions/$chrome_version_full/Libraries/libaperitif.dylib" ]
''')
import_nous_gni('chrome/browser/web_applications/os_integration/mac/BUILD.gn')
edit('chrome/browser/web_applications/os_integration/mac/BUILD.gn',
     '''  } else {
    ldflags += [
      # The helper is a standalone tool rather than a bundled app so the''',
     '''  } else if (nous_core) {
    ldflags += [ "-Wcrl,installnametool,-change,@executable_path/../Frameworks/NousCore.framework/Versions/${chrome_version_full}/NousCore,@executable_path/../NousCore" ]
  } else {
    ldflags += [
      # The helper is a standalone tool rather than a bundled app so the''')

# 10. Helper stubs dlopen the framework by a compile-time name (Dia's helpers
#     load ../../../../ArcCore the same way).
edit('chrome/BUILD.gn', '''      defines = [ "HELPER_EXECUTABLE" ]
      if (defined(invoker.defines)) {''', '''      defines = [ "HELPER_EXECUTABLE" ]
      if (nous_core) {
        defines += [ "NOUS_CORE_FRAMEWORK" ]
      }
      if (defined(invoker.defines)) {''')
edit('chrome/app/chrome_exe_main_mac.cc', '''  static constexpr char rel_path[] =
      "../../../../" PRODUCT_FULLNAME_STRING " Framework";''', '''#if defined(NOUS_CORE_FRAMEWORK)
  static constexpr char rel_path[] = "../../../../NousCore";
#else
  static constexpr char rel_path[] =
      "../../../../" PRODUCT_FULLNAME_STRING " Framework";
#endif''')

# 11. No Chromium crash reporter inside Nous (no upload server; it would also
#     write to ~/Library/Application Support/Chromium/Crashpad).
include_after('chrome/app/chrome_main_delegate.cc',
              '#include "chrome/app/chrome_main_delegate.h"\n', EMBEDDER)
edit('chrome/app/chrome_main_delegate.cc', '''#if BUILDFLAG(IS_MAC)
  InitMacCrashReporter(command_line, process_type);
  SetUpInstallerPreferences(command_line);
#endif''', '''#if BUILDFLAG(IS_MAC)
  if (!nous::IsEmbedded()) {
    InitMacCrashReporter(command_line, process_type);
  }
  SetUpInstallerPreferences(command_line);
#endif''')

# 12. Overlay scrollbars: on hover the thumb only grows thicker (as in
#     Safari/Dia); no track is drawn behind it.
edit('ui/native_theme/native_theme_mac.mm', '''  if (part == kScrollbarHorizontalTrack || part == kScrollbarVerticalTrack ||
      part == kScrollbarCorner) {
    PaintMacScrollBarTrackOrCorner(''', '''  if (part == kScrollbarHorizontalTrack || part == kScrollbarVerticalTrack ||
      part == kScrollbarCorner) {
    if (std::get<ScrollbarExtraParams>(extra_params).is_overlay) {
      return;
    }
    PaintMacScrollBarTrackOrCorner(''')

# 13. One notification identity: Chrome shows alert-style notifications from a
#     separate "Helper (Alerts)" app, which macOS lists as a second app in
#     Notifications settings. Nous shows every notification from the app itself.
edit('chrome/browser/notifications/mac/mac_notification_provider_factory.cc', '''    case mac_notifications::NotificationStyle::kAlert:
      return LaunchOutOfProcessProvider();''', '''    case mac_notifications::NotificationStyle::kAlert:
      if (nous::IsEmbedded()) {
        return LaunchInProcessProvider();
      }
      return LaunchOutOfProcessProvider();''')
include_after('chrome/browser/notifications/mac/mac_notification_provider_factory.cc',
              '#include "chrome/browser/notifications/mac/mac_notification_provider_factory.h"\n', EMBEDDER)

# 14. Page context menus: Chrome shows them only for a views::Widget window.
#     Nous windows are plain AppKit windows, so right-click showed nothing.
F14 = 'chrome/browser/ui/cocoa/renderer_context_menu/render_view_context_menu_mac_cocoa.mm'
include_after(F14, '#include "chrome/browser/ui/cocoa/renderer_context_menu/render_view_context_menu_mac_cocoa.h"\n', EMBEDDER)
edit(F14, '''  if (!widget || headless::IsHeadlessMode()) {
    return;
  }

  menu_controller_delegate_ = [[MenuControllerCocoaDelegateImpl alloc]
      initWithParams:MenuControllerParamsForWidget(widget)];''', '''  if ((!widget && !nous::IsEmbedded()) || headless::IsHeadlessMode()) {
    return;
  }

  if (widget) {
    menu_controller_delegate_ = [[MenuControllerCocoaDelegateImpl alloc]
        initWithParams:MenuControllerParamsForWidget(widget)];
  }''')
edit(F14, '''  ui::ShowContextMenu(menu_controller_.menu, clickEvent, parent_view_,
                      /*allow_nested_tasks=*/true,
                      views::ElementTrackerViews::GetContextForWidget(widget));''', '''  ui::ShowContextMenu(menu_controller_.menu, clickEvent, parent_view_,
                      /*allow_nested_tasks=*/true,
                      widget ? views::ElementTrackerViews::GetContextForWidget(widget)
                             : ui::ElementContext());''')

# 15. Reload in the page context menu: Chrome asks its Browser, which Nous
#     windows do not have, so the item was always disabled.
F15 = 'chrome/browser/renderer_context_menu/render_view_context_menu.cc'
include_after(F15, '#include "chrome/browser/renderer_context_menu/render_view_context_menu.h"\n', EMBEDDER)
edit(F15, '''  return core_tab_helper && chrome::CanReload(GetBrowser());''', '''  if (nous::IsEmbedded() && !GetBrowser()) {
    return core_tab_helper != nullptr;
  }
  return core_tab_helper && chrome::CanReload(GetBrowser());''')
edit(F15, '''    case IDC_RELOAD:
      chrome::Reload(GetBrowser(), WindowOpenDisposition::CURRENT_TAB);
      break;''', '''    case IDC_RELOAD:
      if (nous::IsEmbedded() && !GetBrowser()) {
        embedder_web_contents_->GetController().Reload(content::ReloadType::NORMAL, true);
        break;
      }
      chrome::Reload(GetBrowser(), WindowOpenDisposition::CURRENT_TAB);
      break;''')

# 16. DevTools: a page outside a Chrome tab strip is reported as an "other"
#     target, and the DevTools window ignores those, so Inspect opened empty.
#     Nous pages are tabs; report them as pages.
F16 = 'chrome/browser/devtools/chrome_devtools_manager_delegate.cc'
include_after(F16, '#include "chrome/browser/devtools/chrome_devtools_manager_delegate.h"\n', EMBEDDER)
edit(F16, '''#endif

  return DevToolsAgentHost::kTypeOther;
}''', '''#endif

  if (nous::IsEmbedded()) {
    return DevToolsAgentHost::kTypePage;
  }
  return DevToolsAgentHost::kTypeOther;
}''')

# 17. Restore Chrome's native menu availability for Incognito. Also revert the
#     older Nous patch when reusing a pinned checkout.
edit(F15, '''    if (show_open_link_off_the_record && !nous::IsEmbedded()) {
      if (features::IsMenuSimplificationEnabled()) {''', '''    if (show_open_link_off_the_record) {
      if (features::IsMenuSimplificationEnabled()) {''')

print('Nous Core Chromium patches are applied.')


# 18. Video Picture-in-Picture: Chromium's overlay window renders the video;
#     the host draws Liquid Glass controls over it, so Chromium's own controls
#     and title stay hidden and the host hears about state and position.
VOW = 'chrome/browser/ui/views/overlay/video_overlay_window_views.cc'
include_after(VOW, '#include "chrome/browser/ui/views/overlay/video_overlay_window_views.h"', EMBEDDER.rstrip('\n'))
edit(VOW, '''  PictureInPictureWindowManager::GetInstance()->OnPictureInPictureWindowShown(
      this);
}''', '''  PictureInPictureWindowManager::GetInstance()->OnPictureInPictureWindowShown(
      this);
  if (nous::IsEmbedded()) {
    ForceControlsVisibleForTesting(false, false);
    if (auto shown = nous::GetPictureInPictureHooks().shown) {
      shown(static_cast<views::Widget*>(this), controller_);
    }
  }
}''')
edit(VOW, '''  playback_state_for_testing_ = playback_state;
  play_pause_controls_view_->SetPlaybackState(playback_state);
}''', '''  playback_state_for_testing_ = playback_state;
  play_pause_controls_view_->SetPlaybackState(playback_state);
  if (auto state = nous::GetPictureInPictureHooks().playback_state) {
    state(static_cast<views::Widget*>(this), static_cast<int>(playback_state));
  }
}''')
edit(VOW, '''  position_ = position;
  progress_view_->UpdateProgress(position);
  UpdateTimestampLabel(position_.GetPosition(), position_.duration());
}''', '''  position_ = position;
  progress_view_->UpdateProgress(position);
  UpdateTimestampLabel(position_.GetPosition(), position_.duration());
  if (auto update = nous::GetPictureInPictureHooks().media_position) {
    update(static_cast<views::Widget*>(this), position_.duration().InSecondsF(),
           position_.GetPosition().InSecondsF(), position_.playback_rate());
  }
}''')
edit(VOW, '''void VideoOverlayWindowViews::OnNativeWidgetDestroying() {
  views::Widget::OnNativeWidgetDestroying();''', '''void VideoOverlayWindowViews::OnNativeWidgetDestroying() {
  if (auto destroyed = nous::GetPictureInPictureHooks().destroyed) {
    destroyed(static_cast<views::Widget*>(this));
  }
  views::Widget::OnNativeWidgetDestroying();''')

# 19. An approved external-app launch closes its otherwise empty auxiliary
#     tab. Chrome's cleanup uses its own tab strip, which Nous does not have.
#     Notify the host only after the unchanged Chrome security and prompt flow.
EP = 'chrome/browser/external_protocol/external_protocol_handler.cc'
include_after(EP, '#include "chrome/browser/external_protocol/external_protocol_handler.h"\n', EMBEDDER)
edit(EP, '''      url);

#if !BUILDFLAG(IS_ANDROID) && !BUILDFLAG(IS_CHROMEOS)
  // If the protocol navigation occurs in a new tab, close it.''', '''      url);

  if (nous::IsEmbedded()) {
    nous::RunExternalProtocolLaunchedHook(web_contents);
  }

#if !BUILDFLAG(IS_ANDROID) && !BUILDFLAG(IS_CHROMEOS)
  // If the protocol navigation occurs in a new tab, close it.''')
edit('chrome/browser/external_protocol/BUILD.gn', '''  public_deps = [ ":external_protocol" ]

  deps = [
    "//base",''', '''  public_deps = [ ":external_protocol" ]

  deps = [
    "//nous:embedder",
    "//base",''')

# 20. The Nous Library and + menu reflect successful installations from the
#     Chromium profile's extension registry. Skip Chrome's post-install
#     bubble, which would otherwise create a second browser window.
#     The Web Store's origin checks, permission prompt, and signed install
#     continue through their original Chromium paths.
EI = 'chrome/browser/ui/extensions/extension_install_ui_desktop.cc'
include_after(EI, '#include "chrome/browser/ui/extensions/extension_install_ui_desktop.h"\n',
              EMBEDDER)
edit(EI, '  if (IsUiDisabled() || skip_post_install_ui() || extension->is_theme()) {',
     '  if (nous::IsEmbedded() || IsUiDisabled() || skip_post_install_ui() ||\n'
     '      extension->is_theme()) {')
edit('chrome/browser/ui/extensions/BUILD.gn',
     '''    sources += [ "extension_install_ui_desktop.cc" ]
    deps += [''',
     '''    sources += [ "extension_install_ui_desktop.cc" ]
    deps += [
      "//nous:embedder",''')

# 21. Present the checked external-protocol request as an AppKit sheet for
#     Nous pages. Chromium still owns the security checks, localized strings,
#     per-origin permission and final application launch.
EPD = 'chrome/browser/ui/views/external_protocol_dialog.cc'
include_after(EPD, '#include "chrome/browser/ui/views/external_protocol_dialog.h"\n',
              '#include "base/functional/bind.h"\n')
include_after(EPD, '#include "content/public/browser/web_contents.h"\n', EMBEDDER)
edit('chrome/browser/ui/views/BUILD.gn',
     '''    "//components/url_formatter",
    "//ui/base",
    "//ui/base/mojom:ui_base_types",
    "//ui/gfx",
  ]
  if (!is_android) {
    deps += [ "//chrome/browser:shell_integration" ]''',
     '''    "//components/url_formatter",
    "//nous:embedder",
    "//ui/base",
    "//ui/base/mojom:ui_base_types",
    "//ui/gfx",
  ]
  if (!is_android) {
    deps += [ "//chrome/browser:shell_integration" ]''')
edit(EPD, '''  // Windowing system takes ownership.
  new ExternalProtocolDialog(web_contents, url, program_name, initiating_origin,
                             std::move(initiator_document));''', '''#if BUILDFLAG(IS_MAC)
  if (nous::IsEmbedded()) {
    std::u16string elided_program_name;
    gfx::ElideString(program_name, 32, &elided_program_name);
    nous::ExternalProtocolDialogStrings strings = {
        .title = l10n_util::GetStringFUTF16(IDS_EXTERNAL_PROTOCOL_TITLE,
                                          elided_program_name),
        .message = GetMessageTextForOrigin(initiating_origin),
        .open_button = l10n_util::GetStringFUTF16(
            IDS_EXTERNAL_PROTOCOL_OK_BUTTON_TEXT, program_name),
        .cancel_button = l10n_util::GetStringUTF16(
            IDS_EXTERNAL_PROTOCOL_CANCEL_BUTTON_TEXT),
        .remember_option = {},
    };
    Profile* profile =
        Profile::FromBrowserContext(web_contents->GetBrowserContext());
    if (profile->GetPrefs()->GetBoolean(
            prefs::kExternalProtocolDialogShowAlwaysOpenCheckbox) &&
        MayRememberAllowDecisionsForThisOrigin(
            base::OptionalToPtr(initiating_origin))) {
      strings.remember_option = l10n_util::GetStringFUTF16(
          IDS_EXTERNAL_PROTOCOL_CHECKBOX_PER_ORIGIN_TEXT,
          url_formatter::FormatOriginForSecurityDisplay(
              *initiating_origin,
              url_formatter::SchemeDisplay::OMIT_CRYPTOGRAPHIC));
    }
    nous::ExternalProtocolDialogResponse response = base::BindOnce(
        [](base::WeakPtr<WebContents> contents, const GURL& url,
           const std::optional<url::Origin>& origin,
           const content::WeakDocumentPtr& initiator, bool had_initiator,
           bool accepted, bool remember) {
          if (!accepted || !contents ||
              (had_initiator && !initiator.AsRenderFrameHostIfValid())) {
            RecordHandleStateMetrics(false, BLOCK);
            return;
          }
          RecordHandleStateMetrics(remember, DONT_BLOCK);
          if (remember && origin) {
            SetBlockState(url.GetScheme(), *origin, DONT_BLOCK,
                          Profile::FromBrowserContext(
                              contents->GetBrowserContext()));
          }
          LaunchUrlWithoutSecurityCheck(url, contents.get(), initiator);
        },
        web_contents->GetWeakPtr(), url, initiating_origin, initiator_document,
        initiator_document.AsRenderFrameHostIfValid() != nullptr);
    if (nous::RunExternalProtocolDialogHook(web_contents, url, strings,
                                            response)) {
      return;
    }
  }
#endif

  // Windowing system takes ownership.
  new ExternalProtocolDialog(web_contents, url, program_name, initiating_origin,
                             std::move(initiator_document));''')

# 22. The Web Store runs Chromium's original verification, supervision and
#     permission pipeline. Present its ordinary install decision on the Nous
#     page instead of looking up a Chrome Views browser window.
EIV = 'chrome/browser/ui/views/extensions/extension_install_dialog_view.cc'
include_after(EIV, '#include "chrome/browser/ui/views/extensions/extension_install_dialog_view.h"\n',
              '#include "nous/common/nous_extension_install.h"\n')
edit('chrome/browser/ui/views/extensions/BUILD.gn',
     '''source_set("extension_install_dialog_view_impl") {
  sources = [ "extension_install_dialog_view.cc" ]
  public_deps = [''',
     '''source_set("extension_install_dialog_view_impl") {
  sources = [ "extension_install_dialog_view.cc" ]
  public_deps = [
    "//nous:embedder",''')
edit(EIV, '''  // If the dialog has to be parented to WebContents, force activate the''',
     '''  if (auto presenter = nous::GetExtensionInstallPresenter();
      presenter && prompt->type() == InstallPromptData::INSTALL_PROMPT &&
      !prompt->requires_parent_permission() && !prompt->has_webstore_data() &&
      show_params->GetParentWebContents()) {
    const auto* data = prompt.get();
    nous::ExtensionInstallReply reply = base::BindOnce(
        [](std::unique_ptr<InstallPromptData> prompt,
           ExtensionInstallPrompt::DoneCallback done, bool accepted, bool grant_hosts) {
          auto result = ExtensionInstallPrompt::Result::USER_CANCELED;
          if (accepted) {
            prompt->OnDialogAccepted();
            result = prompt->ShouldWithheldPermissionsOnDialogAccept() && !grant_hosts
                         ? ExtensionInstallPrompt::Result::ACCEPTED_WITH_WITHHELD_PERMISSIONS
                         : ExtensionInstallPrompt::Result::ACCEPTED;
          } else {
            prompt->OnDialogCanceled();
          }
          std::move(done).Run(ExtensionInstallPrompt::DoneCallbackPayload(result));
        }, std::move(prompt), std::move(done_callback));
    presenter(show_params->GetParentWebContents(), *data, reply);
    return;
  }

  // If the dialog has to be parented to WebContents, force activate the''')

# The Library and the Web Store both call Chromium's uninstall dialog factory.
# Keep its registry/policy checks, observers, metrics and report-abuse choice.
UD = 'chrome/browser/ui/extensions/extension_uninstall_dialog_impl.cc'
include_after(UD, '#include "chrome/browser/extensions/extension_uninstall_dialog.h"\n',
              '''#if defined(NOUS_NATIVE_UNINSTALL_SHEET)
#include "nous/browser/nous_extension_uninstall_dialog.h"
#include "nous/common/nous_embedder.h"
#endif
''')
edit(UD, '  return std::make_unique<ExtensionUninstallDialogImpl>(profile, parent,',
     '''#if defined(NOUS_NATIVE_UNINSTALL_SHEET)
  if (nous::IsEmbedded()) {
    return nous::CreateExtensionUninstallSheet(profile, parent, delegate);
  }
#endif
  return std::make_unique<ExtensionUninstallDialogImpl>(profile, parent,''')
import_nous_gni('chrome/browser/ui/extensions/BUILD.gn')
edit('chrome/browser/ui/extensions/BUILD.gn', '''source_set("impl") {
  sources = [
    "controlled_home_dialog.cc",''', '''source_set("impl") {
  sources = []
  if (is_mac && nous_core) {
    defines = [ "NOUS_NATIVE_UNINSTALL_SHEET" ]
    sources += [
      "//nous/browser/nous_extension_uninstall_dialog.h",
      "//nous/browser/nous_extension_uninstall_dialog.mm",
    ]
  }
  sources += [
    "controlled_home_dialog.cc",''')

# 23. Autofill tab-modal dialogs: Nous pages live outside Chrome's TabStripModel,
#     so tabs::TabInterface::GetFromContents() crashes with SIGSEGV. Fall back
#     to constrained_window's WebContentsModalDialogHost (implemented by NousTab)
#     whenever no TabInterface is attached.
SAF = 'chrome/browser/ui/views/autofill/payments/save_and_fill_view_desktop.cc'
include_after(SAF, '#include "components/tabs/public/tab_interface.h"\n',
              '#include "components/constrained_window/constrained_window_views.h"\n')
edit(SAF, '''  TabInterface* tab_interface = TabInterface::GetFromContents(web_contents);
  CHECK(tab_interface);
  dialog_widget_ = tab_interface->GetTabFeatures()
                       ->tab_dialog_manager()
                       ->CreateAndShowDialog(
                           dialog_view.release(),
                           std::make_unique<tabs::TabDialogManager::Params>());''', '''  if (TabInterface* tab_interface = TabInterface::MaybeGetFromContents(web_contents)) {
    dialog_widget_ = tab_interface->GetTabFeatures()
                         ->tab_dialog_manager()
                         ->CreateAndShowDialog(
                             dialog_view.release(),
                             std::make_unique<tabs::TabDialogManager::Params>());
  } else {
    dialog_widget_ = constrained_window::ShowWebModalDialogViewsOwned(
        dialog_view.release(), web_contents,
        views::Widget::InitParams::CLIENT_OWNS_WIDGET);
  }''')

EAP = 'chrome/browser/ui/views/autofill/edit_address_profile_view.cc'
include_after(EAP, '#include "components/tabs/public/tab_interface.h"\n',
              '#include "components/constrained_window/constrained_window_views.h"\n')
edit(EAP, '''  tabs::TabInterface* tab_interface =
      tabs::TabInterface::GetFromContents(web_contents);
  auto widget =
      tab_interface->GetTabFeatures()
          ->tab_dialog_manager()
          ->CreateAndShowDialog(
              dialog, std::make_unique<tabs::TabDialogManager::Params>());''', '''  std::unique_ptr<views::Widget> widget;
  if (tabs::TabInterface* tab_interface =
          tabs::TabInterface::MaybeGetFromContents(web_contents)) {
    widget = tab_interface->GetTabFeatures()
                 ->tab_dialog_manager()
                 ->CreateAndShowDialog(
                     dialog, std::make_unique<tabs::TabDialogManager::Params>());
  } else {
    widget = constrained_window::ShowWebModalDialogViewsOwned(
        dialog, web_contents, views::Widget::InitParams::CLIENT_OWNS_WIDGET);
  }''')

APD = 'chrome/browser/ui/views/autofill/payments/autofill_progress_dialog_views.cc'
include_after(APD, '#include "components/tabs/public/tab_interface.h"\n',
              '#include "components/constrained_window/constrained_window_views.h"\n')
edit(APD, '''  auto* tab_interface = tabs::TabInterface::GetFromContents(web_contents);
  CHECK(tab_interface);
  dialog_ = tab_interface->GetTabFeatures()
                ->tab_dialog_manager()
                ->CreateAndShowDialog(
                    autofill_progress_dialog_view.release(),
                    std::make_unique<tabs::TabDialogManager::Params>());''', '''  if (auto* tab_interface = tabs::TabInterface::MaybeGetFromContents(web_contents)) {
    dialog_ = tab_interface->GetTabFeatures()
                  ->tab_dialog_manager()
                  ->CreateAndShowDialog(
                      autofill_progress_dialog_view.release(),
                      std::make_unique<tabs::TabDialogManager::Params>());
  } else {
    dialog_ = constrained_window::ShowWebModalDialogViewsOwned(
        autofill_progress_dialog_view.release(), web_contents,
        views::Widget::InitParams::CLIENT_OWNS_WIDGET);
  }''')

AED = 'chrome/browser/ui/views/autofill/payments/autofill_error_dialog_view_native_views.cc'
include_after(AED, '#include "components/tabs/public/tab_interface.h"\n',
              '#include "components/constrained_window/constrained_window_views.h"\n')
edit(AED, '''  tabs::TabInterface* tab_interface =
      tabs::TabInterface::GetFromContents(web_contents);
  tab_interface->GetTabFeatures()
      ->tab_dialog_manager()
      ->CreateAndShowDialog(dialog_view,
                            std::make_unique<tabs::TabDialogManager::Params>())
      .release();''', '''  if (tabs::TabInterface* tab_interface =
          tabs::TabInterface::MaybeGetFromContents(web_contents)) {
    tab_interface->GetTabFeatures()
        ->tab_dialog_manager()
        ->CreateAndShowDialog(dialog_view,
                              std::make_unique<tabs::TabDialogManager::Params>())
        .release();
  } else {
    constrained_window::ShowWebModalDialogViews(dialog_view, web_contents);
  }''')

CUA = 'chrome/browser/ui/views/autofill/payments/card_unmask_authentication_selection_dialog_view.cc'
include_after(CUA, '#include "components/tabs/public/tab_interface.h"\n',
              '#include "components/constrained_window/constrained_window_views.h"\n')
edit(CUA, '''  auto* tab_interface = tabs::TabInterface::GetFromContents(web_contents);
  tab_interface->GetTabFeatures()
      ->tab_dialog_manager()
      ->CreateAndShowDialog(dialog_view,
                            std::make_unique<tabs::TabDialogManager::Params>())
      .release();''', '''  if (auto* tab_interface = tabs::TabInterface::MaybeGetFromContents(web_contents)) {
    tab_interface->GetTabFeatures()
        ->tab_dialog_manager()
        ->CreateAndShowDialog(dialog_view,
                              std::make_unique<tabs::TabDialogManager::Params>())
        .release();
  } else {
    constrained_window::ShowWebModalDialogViews(dialog_view, web_contents);
  }''')

AFPB = 'chrome/browser/ui/views/autofill/payments/BUILD.gn'
edit(AFPB, '''source_set("save_and_fill_view_desktop") {
  public = [ "save_and_fill_view_desktop.h" ]
  sources = [ "save_and_fill_view_desktop.cc" ]
  public_deps = [
    ":save_and_fill_dialog",
    "//base",
    "//components/autofill/core/browser",
    "//ui/views",
  ]
  deps = [
    "//chrome/browser/ui/autofill/payments",''', '''source_set("save_and_fill_view_desktop") {
  public = [ "save_and_fill_view_desktop.h" ]
  sources = [ "save_and_fill_view_desktop.cc" ]
  public_deps = [
    ":save_and_fill_dialog",
    "//base",
    "//components/autofill/core/browser",
    "//ui/views",
  ]
  deps = [
    "//chrome/browser/ui/autofill/payments",
    "//components/constrained_window",''')
edit(AFPB, '''source_set("autofill_error_dialog_view_native_views") {
  public = [ "autofill_error_dialog_view_native_views.h" ]
  sources = [ "autofill_error_dialog_view_native_views.cc" ]
  public_deps = [
    "//base",
    "//components/autofill/core/browser",
    "//ui/views",
  ]
  deps = [
    ":payments_view_util",
    "//chrome/browser/ui/autofill/payments",''', '''source_set("autofill_error_dialog_view_native_views") {
  public = [ "autofill_error_dialog_view_native_views.h" ]
  sources = [ "autofill_error_dialog_view_native_views.cc" ]
  public_deps = [
    "//base",
    "//components/autofill/core/browser",
    "//ui/views",
  ]
  deps = [
    ":payments_view_util",
    "//chrome/browser/ui/autofill/payments",
    "//components/constrained_window",''')

# 24. Save / Update Password prompt: Chrome's ManagePasswordsUIController drops
#     its toolbar bubble when FindBrowserWithTab() is null (all Nous tabs live
#     outside Chrome's BrowserWindowInterface). Route pending save/update prompts
#     to Nous's native AppKit sheet so Chromium saves credentials into Login Data.
MPU = 'chrome/browser/ui/passwords/manage_passwords_ui_controller.cc'
include_after(MPU, '#include "chrome/browser/ui/passwords/manage_passwords_ui_controller.h"\n',
              '#include "base/strings/utf_string_conversions.h"\n' + EMBEDDER)
edit(MPU, '''  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(
          web_contents());
  if (!browser) {
    return;
  }''', '''  BrowserWindowInterface* browser =
      GlobalBrowserCollection::GetInstance()->FindBrowserWithTab(
          web_contents());
  if (!browser) {
    if (nous::IsEmbedded() &&
        bubble_status_ == BubbleStatus::SHOULD_POP_UP &&
        !web_contents()->GetBrowserContext()->IsOffTheRecord() &&
        (GetState() == password_manager::ui::PENDING_PASSWORD_STATE ||
         GetState() == password_manager::ui::PENDING_PASSWORD_UPDATE_STATE)) {
      const bool is_update =
          GetState() == password_manager::ui::PENDING_PASSWORD_UPDATE_STATE;
      const password_manager::PasswordForm& pending = GetPendingPassword();
      nous::PasswordPromptRequest request = {
          .is_update = is_update,
          .host = base::UTF8ToUTF16(pending.url.GetHost()),
          .username = pending.username_value,
      };
      nous::PasswordPromptResponse response = base::BindOnce(
          [](base::WeakPtr<ManagePasswordsUIController> controller,
             bool is_update,
             nous::PasswordPromptDecision decision,
             std::u16string edited_username) {
            if (!controller) {
              return;
            }
            const auto expected_state =
                is_update ? password_manager::ui::PENDING_PASSWORD_UPDATE_STATE
                          : password_manager::ui::PENDING_PASSWORD_STATE;
            if (controller->GetState() != expected_state) {
              controller->OnBubbleHidden();
              return;
            }
            switch (decision) {
              case nous::PasswordPromptDecision::kSave: {
                const password_manager::PasswordForm& form =
                    controller->GetPendingPassword();
                controller->SavePassword(
                    edited_username.empty() ? form.username_value
                                            : edited_username,
                    form.password_value);
                controller->OnBubbleHidden();
                break;
              }
              case nous::PasswordPromptDecision::kNever:
                if (!is_update) {
                  controller->NeverSavePassword();
                }
                controller->OnBubbleHidden();
                break;
              case nous::PasswordPromptDecision::kNotNow:
                if (is_update) {
                  controller->OnNopeUpdateClicked();
                } else {
                  controller->OnNotNowClicked();
                }
                controller->OnBubbleHidden();
                break;
            }
          },
          weak_ptr_factory_.GetWeakPtr(), is_update);
      if (nous::RunPasswordSavePromptHook(web_contents(), request, response)) {
        OnBubbleShown();
      }
    }
    return;
  }''')

edit('chrome/browser/ui/passwords/BUILD.gn', '''    sources += [
      "credential_leak_dialog_controller_impl.cc",''', '''    deps += [ "//nous:embedder" ]
    sources += [
      "credential_leak_dialog_controller_impl.cc",''')
