// The Web Store verifies and installs the extension. The host only presents
// Chromium's permission prompt for an embedded WebContents.
#ifndef NOUS_COMMON_NOUS_EXTENSION_INSTALL_H_
#define NOUS_COMMON_NOUS_EXTENSION_INSTALL_H_

namespace base {
template <typename Signature>
class OnceCallback;
}
namespace content {
class WebContents;
}
namespace extensions {
class InstallPromptData;
}

namespace nous {
using ExtensionInstallReply = base::OnceCallback<void(bool accepted, bool grant_hosts)>;
using ExtensionInstallPresenter = void (*)(content::WebContents*,
    const extensions::InstallPromptData&, ExtensionInstallReply&);
void SetExtensionInstallPresenter(ExtensionInstallPresenter presenter);
ExtensionInstallPresenter GetExtensionInstallPresenter();
}  // namespace nous
#endif  // NOUS_COMMON_NOUS_EXTENSION_INSTALL_H_
