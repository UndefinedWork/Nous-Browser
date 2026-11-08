#include "nous/common/nous_embedder.h"

namespace nous {
namespace {
bool g_embedded = false;
BrowserStartedHook g_browser_started = nullptr;
TerminateRequestHook g_terminate_request = nullptr;
MainLoopEndedHook g_main_loop_ended = nullptr;
PermissionPromptFactory g_permission_prompt_factory = nullptr;
PictureInPictureHooks g_picture_in_picture_hooks;
}  // namespace

bool IsEmbedded() { return g_embedded; }
void SetEmbedded(bool embedded) { g_embedded = embedded; }

void SetBrowserStartedHook(BrowserStartedHook hook) { g_browser_started = hook; }
void RunBrowserStartedHook() {
  if (g_browser_started) g_browser_started();
}

void SetTerminateRequestHook(TerminateRequestHook hook) {
  g_terminate_request = hook;
}
bool RunTerminateRequestHook() {
  return g_terminate_request && g_terminate_request();
}

void SetMainLoopEndedHook(MainLoopEndedHook hook) { g_main_loop_ended = hook; }
void RunMainLoopEndedHook() {
  if (g_main_loop_ended) g_main_loop_ended();
}

void SetPermissionPromptFactory(PermissionPromptFactory factory) {
  g_permission_prompt_factory = factory;
}
PermissionPromptFactory GetPermissionPromptFactory() {
  return g_permission_prompt_factory;
}

void SetPictureInPictureHooks(const PictureInPictureHooks& hooks) {
  g_picture_in_picture_hooks = hooks;
}
const PictureInPictureHooks& GetPictureInPictureHooks() {
  return g_picture_in_picture_hooks;
}

}  // namespace nous
