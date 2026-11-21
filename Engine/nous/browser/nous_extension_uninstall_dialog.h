#ifndef NOUS_BROWSER_NOUS_EXTENSION_UNINSTALL_DIALOG_H_
#define NOUS_BROWSER_NOUS_EXTENSION_UNINSTALL_DIALOG_H_

#include "chrome/browser/extensions/extension_uninstall_dialog.h"

namespace nous {
std::unique_ptr<extensions::ExtensionUninstallDialog> CreateExtensionUninstallSheet(
    Profile* profile, gfx::NativeWindow parent,
    extensions::ExtensionUninstallDialog::Delegate* delegate);
}
#endif  // NOUS_BROWSER_NOUS_EXTENSION_UNINSTALL_DIALOG_H_
