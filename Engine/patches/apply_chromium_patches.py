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

# 17. Nous has no private windows: never offer "Open Link in Incognito Window".
edit(F15, '''    if (show_open_link_off_the_record) {
      if (features::IsMenuSimplificationEnabled()) {''', '''    if (show_open_link_off_the_record && !nous::IsEmbedded()) {
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
