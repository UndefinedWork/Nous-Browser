#import <AppKit/AppKit.h>

#include "nous/browser/nous_extension_uninstall_dialog.h"

#include "base/strings/sys_string_conversions.h"
#include "chrome/grit/generated_resources.h"
#include "components/strings/grit/components_strings.h"
#include "extensions/browser/ui_util.h"
#include "ui/base/l10n/l10n_util.h"
#include "ui/gfx/image/image.h"

namespace nous {
namespace {
class ExtensionUninstallSheet final : public extensions::ExtensionUninstallDialog {
 public:
  ExtensionUninstallSheet(Profile* profile, gfx::NativeWindow parent, Delegate* delegate)
      : ExtensionUninstallDialog(profile, parent, delegate) {}
  ~ExtensionUninstallSheet() override {
    weak_.InvalidateWeakPtrs();
    Detach();
  }

 private:
  void Show() override {
    NSWindow* window = parent().GetNativeNSWindow();
    if (!window.visible || window.attachedSheet) {
      OnDialogClosed(CLOSE_ACTION_CANCELED);
      return;
    }
    auto name = extensions::ui_util::GetFixupExtensionNameForUIDisplay(extension()->name());
    alert_ = [NSAlert new];
    alert_.messageText = base::SysUTF16ToNSString(
        l10n_util::GetStringFUTF16(IDS_EXTENSION_PROMPT_UNINSTALL_TITLE, name));
    if (!icon().isNull()) alert_.icon = gfx::Image(icon()).AsNSImage();
    if (const auto* requester = triggering_extension()) {
      alert_.informativeText = base::SysUTF16ToNSString(l10n_util::GetStringFUTF16(
          IDS_EXTENSION_PROMPT_UNINSTALL_TRIGGERED_BY_EXTENSION,
          extensions::ui_util::GetFixupExtensionNameForUIDisplay(requester->name())));
    }
    if (ShouldShowCheckbox()) {
      alert_.showsSuppressionButton = YES;
      alert_.suppressionButton.title = base::SysUTF16ToNSString(triggering_extension()
          ? l10n_util::GetStringFUTF16(IDS_EXTENSION_PROMPT_UNINSTALL_REPORT_ABUSE_FROM_EXTENSION, name)
          : l10n_util::GetStringUTF16(IDS_EXTENSION_PROMPT_UNINSTALL_REPORT_ABUSE));
      alert_.suppressionButton.state = NSControlStateValueOff;
    }
    NSButton* remove = [alert_ addButtonWithTitle:base::SysUTF16ToNSString(
        l10n_util::GetStringUTF16(IDS_EXTENSION_PROMPT_UNINSTALL_BUTTON))];
    remove.hasDestructiveAction = YES;
    [alert_ addButtonWithTitle:base::SysUTF16ToNSString(l10n_util::GetStringUTF16(IDS_CANCEL))];
    alert_.window.defaultButtonCell = nil;
    remove.keyEquivalent = @"";
    alert_.buttons[1].keyEquivalent = @"\033";

    auto weak = weak_.GetWeakPtr();
    close_observer_ = [NSNotificationCenter.defaultCenter
        addObserverForName:NSWindowWillCloseNotification object:window queue:nil
                usingBlock:^(NSNotification*) { if (weak) weak->Close(); }];
    [alert_ beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
      if (!weak || !weak->alert_) return;
      const bool report = weak->alert_.showsSuppressionButton &&
          weak->alert_.suppressionButton.state == NSControlStateValueOn;
      weak->Finish(response != NSAlertFirstButtonReturn ? CLOSE_ACTION_CANCELED
          : report ? CLOSE_ACTION_UNINSTALL_AND_CHECKBOX_CHECKED : CLOSE_ACTION_UNINSTALL);
    }];
  }

  void Close() override { Finish(CLOSE_ACTION_CANCELED); }

  void Finish(CloseAction action) {
    Detach();
    OnDialogClosed(action);  // The delegate can destroy this object.
  }

  void Detach() {
    if (close_observer_) {
      [NSNotificationCenter.defaultCenter removeObserver:close_observer_];
      close_observer_ = nil;
    }
    NSAlert* alert = alert_;
    alert_ = nil;
    if (alert.window.sheetParent)
      [alert.window.sheetParent endSheet:alert.window returnCode:NSModalResponseCancel];
  }

  NSAlert* __strong alert_ = nil;
  id __strong close_observer_ = nil;
  base::WeakPtrFactory<ExtensionUninstallSheet> weak_{this};
};
}  // namespace

std::unique_ptr<extensions::ExtensionUninstallDialog> CreateExtensionUninstallSheet(
    Profile* profile, gfx::NativeWindow parent,
    extensions::ExtensionUninstallDialog::Delegate* delegate) {
  return std::make_unique<ExtensionUninstallSheet>(profile, parent, delegate);
}
}  // namespace nous
