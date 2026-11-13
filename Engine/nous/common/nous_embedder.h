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

// Runs only after Chrome has approved and dispatched an external-protocol
// launch. The host may close an otherwise empty auxiliary tab; this hook does
// not participate in scheme, origin, gesture or permission decisions.
using ExternalProtocolLaunchedHook = void (*)(content::WebContents*);
void SetExternalProtocolLaunchedHook(ExternalProtocolLaunchedHook hook);
void RunExternalProtocolLaunchedHook(content::WebContents* contents);

// Video Picture-in-Picture: Chromium's overlay window draws the video, the
// host draws the controls over it. `window` is the overlay's views::Widget*,
// `controller` its content::VideoPictureInPictureWindowController*. Both stay
// valid until `destroyed` runs for that window.
struct PictureInPictureHooks {
  void (*shown)(void* window, void* controller) = nullptr;
  // 0 playing, 1 paused, 2 ended (content::VideoOverlayWindow::PlaybackState).
  void (*playback_state)(void* window, int state) = nullptr;
  // Seconds; duration is 0 when unknown and infinite for live streams.
  void (*media_position)(void* window, double duration, double position, double rate) = nullptr;
  void (*destroyed)(void* window) = nullptr;
};
void SetPictureInPictureHooks(const PictureInPictureHooks& hooks);
const PictureInPictureHooks& GetPictureInPictureHooks();

}  // namespace nous

#endif  // NOUS_COMMON_NOUS_EMBEDDER_H_
