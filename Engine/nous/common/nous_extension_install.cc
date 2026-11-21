#include "nous/common/nous_extension_install.h"

namespace nous {
namespace {
ExtensionInstallPresenter g_presenter = nullptr;
}
void SetExtensionInstallPresenter(ExtensionInstallPresenter presenter) {
  g_presenter = presenter;
}
ExtensionInstallPresenter GetExtensionInstallPresenter() { return g_presenter; }
}  // namespace nous
