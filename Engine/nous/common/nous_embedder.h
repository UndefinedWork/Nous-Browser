// Nous Core embedder hooks.
//
// This target has no dependencies so that small patches inside //chrome can
// consult it without creating a dependency cycle with //nous/browser (which
// itself depends on //chrome/browser). It is the Nous equivalent of the
// "is ADK hosting us" switches The Browser Company keeps inside ArcCore.

#ifndef NOUS_COMMON_NOUS_EMBEDDER_H_
#define NOUS_COMMON_NOUS_EMBEDDER_H_

#include <memory>

namespace content {
class WebContents;
}
namespace permissions {
class PermissionPrompt;
}

namespace nous {

// True once NousBrowserApplication has started ChromeMain in the browser
// process. Chrome's own AppController, main menu, startup browser windows and
// termination UI are disabled while this is set; the host app owns them.
bool IsEmbedded();
void SetEmbedded(bool embedded);

// Called by the patched ChromeBrowserMainParts::PostBrowserStart().
using BrowserStartedHook = void (*)();
void SetBrowserStartedHook(BrowserStartedHook hook);
void RunBrowserStartedHook();

// Called by the patched -[BrowserCrApplication terminate:]. Returns true when
// the host took over termination (it later calls chrome::AttemptExit()).
using TerminateRequestHook = bool (*)();
void SetTerminateRequestHook(TerminateRequestHook hook);
bool RunTerminateRequestHook();

// Called by the patched ChromeBrowserMainParts::PostMainMessageLoopRun().
using MainLoopEndedHook = void (*)();
void SetMainLoopEndedHook(MainLoopEndedHook hook);
void RunMainLoopEndedHook();

// Permission prompts are drawn by the host (Dia: ArcWebContentsUIDelegate
// willAskForPermission). `delegate` is a permissions::PermissionPrompt::Delegate*.
using PermissionPromptFactory =
    std::unique_ptr<permissions::PermissionPrompt> (*)(content::WebContents*,
                                                      void* delegate);
void SetPermissionPromptFactory(PermissionPromptFactory factory);
PermissionPromptFactory GetPermissionPromptFactory();

}  // namespace nous

#endif  // NOUS_COMMON_NOUS_EMBEDDER_H_
