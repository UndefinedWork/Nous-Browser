// NBChromiumView on top of a real content::WebContents with Chrome's tab
// helpers attached (Dia: ArcWebContents + its pane host view).
//
// Event names and payloads are the contract the Swift UI already consumes:
// state, load-start, load-end, progress, error, favicon, open-tab,
// open-window, search, binding, closed.

#import "nous/public/NousChromium.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "base/no_destructor.h"
#include "base/observer_list.h"
#include "base/strings/sys_string_conversions.h"
#include "chrome/browser/picture_in_picture/picture_in_picture_window_manager.h"
#include "chrome/browser/printing/print_view_manager_common.h"
#include "chrome/browser/profiles/profile.h"
#include "chrome/browser/ui/permission_bubble/permission_prompt.h"
#include "chrome/browser/media/webrtc/media_capture_devices_dispatcher.h"
#include "chrome/browser/ui/tab_helpers.h"
#include "components/favicon/content/content_favicon_driver.h"
#include "components/favicon/core/favicon_driver_observer.h"
#include "components/find_in_page/find_tab_helper.h"
#include "components/find_in_page/find_types.h"
#include "components/input/native_web_keyboard_event.h"
#include "components/permissions/permission_prompt.h"
#include "components/permissions/permission_request.h"
#include "components/permissions/permission_uma_constants.h"
#include "components/permissions/resolvers/permission_prompt_options.h"
#include "components/web_modal/modal_dialog_host.h"
#include "components/web_modal/web_contents_modal_dialog_host.h"
#include "components/web_modal/web_contents_modal_dialog_manager.h"
#include "components/web_modal/web_contents_modal_dialog_manager_delegate.h"
#include "components/zoom/zoom_controller.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/devtools_agent_host_client.h"
#include "content/public/browser/javascript_dialog_manager.h"
#include "content/public/browser/keyboard_event_processing_result.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/video_picture_in_picture_window_controller.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/common/javascript_dialog_type.h"
#include "net/base/net_errors.h"
#include "url/origin.h"
#include "nous/browser/nous_internal.h"
#include "third_party/blink/public/common/page/page_zoom.h"
#include "ui/base/page_transition_types.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/image/image.h"
#include "ui/views/widget/widget.h"
#include "nous/common/nous_embedder.h"
#import "nous/public/NBPictureInPicture.h"
#include "url/gurl.h"
#include "url/url_constants.h"

#import "nous/browser/NBChromiumFocusPolicy.h"

class NousTab;

// ---------------------------------------------------------------------------
// Small helpers

static NSString* Localized(NSString* key) { return NSLocalizedString(key, nil); }
static NSError* Failure(NSString* message) {
  return [NSError errorWithDomain:@"NousCore" code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}
static NSString* String(const std::string& value) { return base::SysUTF8ToNSString(value); }
static NSString* String(const std::u16string& value) { return base::SysUTF16ToNSString(value); }
static GURL URL(NSString* value) { return GURL(base::SysNSStringToUTF8(value ?: @"")); }

typedef void (^NBCommandCompletion)(NSDictionary* result, NSError* error);

// A sheet can outlive its page. Keep one completion and cancel it explicitly on
// navigation/close instead of leaving a stale renderer callback.
@interface NBPageDialog : NSObject
@property(nonatomic, strong) NSWindow* sheet;
@property(nonatomic, weak) NSWindow* parentWindow;
@property(nonatomic, strong) id presenter;
@property(nonatomic, copy) void (^completion)(NSModalResponse);
- (void)finish:(NSModalResponse)response;
@end
@implementation NBPageDialog
- (void)finish:(NSModalResponse)response {
  if (!_completion) return;
  void (^completion)(NSModalResponse) = _completion;
  _completion = nil;
  if (_sheet.sheetParent) [_sheet.sheetParent endSheet:_sheet returnCode:response];
  [_sheet orderOut:nil];
  completion(response);
  _presenter = nil;
}
@end

@interface NBChromiumView () {
 @public
  std::unique_ptr<NousTab> _tab;
  NSMutableDictionary<NSNumber*, NBCommandCompletion>* _pending;
  NSMutableDictionary<NSNumber*, NSDictionary*>* _contexts;
  NSString* _mainFrameID;
  NSMutableDictionary<NSString*, NSString*>* _bindings;
  NSMutableArray<NSDictionary*>* _scripts;
  NSString* _pendingURL;
  BOOL _reserved;
  BOOL _ready;
  BOOL _replaceInitialBlank;
  BOOL _closed;
  BOOL _closeRequested;
  NSMutableArray<void (^)(BOOL)>* _closeCompletions;
  int _nextCommand;
  NSUInteger _navigationGeneration;
  NSMutableSet<NBPageDialog*>* _dialogs;
  __weak NSWindow* _dialogPresentationWindow;
  BOOL _managesDialogPresentationWindow;
  NSUInteger _dialogPresentationGeneration;
  void (^_findCompletion)(BOOL);
  BOOL _activeInWindow;
  BOOL _pinned;
  BOOL _autoDiscardable;
  BOOL _windowFullscreenOwned;
  // Two-phase close (native beforeunload, reversible until commit).
  NSUInteger _closePreparation;
  void (^_closePreparationCompletion)(BOOL);
  BOOL _closePrepared;
}
@property(nonatomic, readwrite, copy) NSString* pageTitle;
@property(nonatomic, readwrite, copy) NSString* URLString;
@property(nonatomic, readwrite) BOOL loading;
@property(nonatomic, readwrite) BOOL canGoBack;
@property(nonatomic, readwrite) BOOL canGoForward;
@property(nonatomic, readwrite) BOOL fullscreen;
@property(nonatomic, readwrite) BOOL mediaActive;
- (void)emit:(NSString*)event payload:(NSDictionary*)payload;
- (void)emitState;
- (void)adoptContents:(std::unique_ptr<content::WebContents>)contents;
- (void)tabDidClose;
- (void)devToolsMessage:(NSDictionary*)message;
- (void)command:(NSString*)method params:(NSDictionary*)params completion:(NBCommandCompletion)completion;
- (void)cancelCommands:(NSError*)error;
- (void)invalidateContexts;
- (void)cancelPageDialogs;
- (void)findReplyCount:(int)count final:(BOOL)finalUpdate;
- (void)beforeUnloadFired:(BOOL)proceed;
- (void)pageFullscreenChanged:(BOOL)fullscreen;
- (void)presentAlert:(NSAlert*)alert javaScript:(BOOL)javaScript completion:(void (^)(NSModalResponse))completion;
- (NousTab*)tab;
- (void)updatePageBackground;
@end

// ---------------------------------------------------------------------------
// WebContents -> tab registry

static std::map<content::WebContents*, NousTab*>& Tabs() {
  static base::NoDestructor<std::map<content::WebContents*, NousTab*>> tabs;
  return *tabs;
}

void NousTabHelpersAttacher::Attach(content::WebContents* contents) {
  TabHelpers::AttachTabHelpers(contents);
}

// ---------------------------------------------------------------------------
static void NousInstallPictureInPictureHooks();

// NousTab: WebContentsDelegate + observers for one page.

class NousTab final : public content::WebContentsDelegate,
                      public content::WebContentsObserver,
                      public favicon::FaviconDriverObserver,
                      public content::DevToolsAgentHostClient,
                      public web_modal::WebContentsModalDialogManagerDelegate,
                      public web_modal::WebContentsModalDialogHost {
 public:
  NousTab(NBChromiumView* view, std::unique_ptr<content::WebContents> contents)
      : view_(view), contents_(std::move(contents)) {
    content::WebContents* wc = contents_.get();
    Observe(wc);
    Tabs()[wc] = this;
    wc->SetDelegate(this);
    NousTabHelpersAttacher::Attach(wc);
    if (auto* favicon = favicon::ContentFaviconDriver::FromWebContents(wc))
      favicon->AddObserver(this);
    if (auto* modal = web_modal::WebContentsModalDialogManager::FromWebContents(wc))
      modal->SetDelegate(this);
    agent_ = content::DevToolsAgentHost::GetOrCreateFor(wc);  // page target (Page/Runtime domains)
    const bool attached = agent_->AttachClient(this);
    LOG_IF(ERROR, !attached) << "Nous: DevTools client attach was refused.";
  }

  ~NousTab() override {
    for (auto& observer : modal_observers_) observer.OnHostDestroying();
    if (agent_) {
      agent_->DetachClient(this);
      agent_ = nullptr;
    }
    if (contents_) {
      if (auto* favicon = favicon::ContentFaviconDriver::FromWebContents(contents_.get()))
        favicon->RemoveObserver(this);
      if (auto* modal = web_modal::WebContentsModalDialogManager::FromWebContents(contents_.get()))
        modal->SetDelegate(nullptr);
      contents_->SetDelegate(nullptr);
      Tabs().erase(contents_.get());
    }
    Observe(nullptr);
  }

  content::WebContents* contents() const { return contents_.get(); }
  NBChromiumView* view() const { return view_; }
  bool fullscreen() const { return fullscreen_; }
  bool closing_prepared() const { return preparing_close_; }
  void set_preparing_close(bool preparing) { preparing_close_ = preparing; }

  static NousTab* From(content::WebContents* contents) {
    auto found = Tabs().find(contents);
    return found == Tabs().end() ? nullptr : found->second;
  }

  NSView* NativeView() const {
    return contents_ ? contents_->GetNativeView().GetNativeNSView() : nil;
  }

  void SendDevTools(int identifier, NSString* method, NSDictionary* params) {
    if (!agent_) return;
    NSData* data = [NSJSONSerialization dataWithJSONObject:@{@"id" : @(identifier), @"method" : method,
                                                             @"params" : params ?: @{}}
                                                   options:0
                                                     error:nil];
    if (!data) return;
    if (getenv("NOUS_TRACE")) fprintf(stderr, "Nous devtools -> %d %s\n", identifier, method.UTF8String);
    agent_->DispatchProtocolMessage(
        this, base::span<const uint8_t>(static_cast<const uint8_t*>(data.bytes), data.length));
  }

  // DevToolsAgentHostClient ------------------------------------------------
  void DispatchProtocolMessage(content::DevToolsAgentHost*, base::span<const uint8_t> message) override {
    NSData* data = [NSData dataWithBytes:message.data() length:message.size()];
    if (getenv("NOUS_TRACE"))
      fprintf(stderr, "Nous devtools <- %.*s\n", (int)std::min<size_t>(message.size(), 160), (const char*)message.data());
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([parsed isKindOfClass:NSDictionary.class]) [view_ devToolsMessage:parsed];
  }
  void AgentHostClosed(content::DevToolsAgentHost*) override {
    agent_ = nullptr;
    [view_ cancelCommands:Failure(@"The page connection was closed.")];
  }
  bool IsTrusted() override { return true; }
  bool MayWriteLocalFiles() override { return false; }

  // WebContentsDelegate ----------------------------------------------------
  // Camera, microphone and screen capture go through Chrome's own flow, as in
  // Chrome's Browser: the site permission (asked with the Nous sheet and
  // remembered per site), then the macOS privacy check. Without these the
  // default delegate refuses every getUserMedia() request.
  void RequestMediaAccessPermission(content::WebContents* web_contents,
                                    const content::MediaStreamRequest& request,
                                    content::MediaResponseCallback callback) override {
    MediaCaptureDevicesDispatcher::GetInstance()->ProcessMediaAccessRequest(
        web_contents, request, std::move(callback), nullptr);
  }
  bool CheckMediaAccessPermission(content::RenderFrameHost* render_frame_host,
                                  const url::Origin& security_origin,
                                  blink::mojom::MediaStreamType type) override {
    return MediaCaptureDevicesDispatcher::GetInstance()->CheckMediaAccessPermission(
        render_frame_host, security_origin, type);
  }
  content::WebContents* OpenURLFromTab(
      content::WebContents* source, const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)> navigation_handle_callback) override {
    NSString* url = String(params.url.spec());
    switch (params.disposition) {
      case WindowOpenDisposition::CURRENT_TAB: {
        content::NavigationController::LoadURLParams load(params);
        auto handle = source->GetController().LoadURLWithParams(load);
        if (handle && navigation_handle_callback) std::move(navigation_handle_callback).Run(*handle);
        return source;
      }
      case WindowOpenDisposition::NEW_FOREGROUND_TAB:
      case WindowOpenDisposition::NEW_BACKGROUND_TAB:
        [view_ emit:@"open-tab" payload:@{@"url" : url,
            @"activate" : @(params.disposition == WindowOpenDisposition::NEW_FOREGROUND_TAB)}];
        return nullptr;
      case WindowOpenDisposition::NEW_WINDOW:
      case WindowOpenDisposition::NEW_POPUP:
        [view_ emit:@"open-window" payload:@{@"url" : url}];
        return nullptr;
      default:
        // OFF_THE_RECORD has no private window yet; never downgrade it to a
        // regular-profile tab. SAVE_TO_DISK is handled by Chrome itself.
        return nullptr;
    }
  }

  content::WebContents* AddNewContents(content::WebContents* source,
                                       std::unique_ptr<content::WebContents> new_contents,
                                       const GURL& target_url, WindowOpenDisposition disposition,
                                       const blink::mojom::WindowFeatures& features, bool user_gesture,
                                       bool* was_blocked) override {
    NBChromiumView* view = view_;
    if (!user_gesture || !view.popupHandler) {
      if (was_blocked) *was_blocked = true;
      return nullptr;
    }
    const bool new_window = disposition == WindowOpenDisposition::NEW_WINDOW ||
                            disposition == WindowOpenDisposition::NEW_POPUP;
    NBChromiumView* target =
        view.popupHandler(new_window, disposition != WindowOpenDisposition::NEW_BACKGROUND_TAB);
    if (!target) {
      if (was_blocked) *was_blocked = true;
      return nullptr;
    }
    content::WebContents* raw = new_contents.get();
    [target adoptContents:std::move(new_contents)];
    return raw;
  }

  void LoadingStateChanged(content::WebContents* source, bool) override { UpdateState(); }
  void NavigationStateChanged(content::WebContents*, content::InvalidateTypes) override { UpdateState(); }

  void CloseContents(content::WebContents* source) override {
    // window.close() or an approved ClosePage(). Destroying the contents
    // inside its own callback is unsafe; finish on the next turn.
    __weak NBChromiumView* weak = view_;
    dispatch_async(dispatch_get_main_queue(), ^{ [weak tabDidClose]; });
  }

  void BeforeUnloadFired(content::WebContents* tab, bool proceed, bool* proceed_to_fire_unload) override {
    if (preparing_close_) {
      // Two-phase close: approval only. The page stays fully alive until the
      // host commits, so a later Cancel elsewhere can keep it.
      *proceed_to_fire_unload = false;
      preparing_close_ = false;
      [view_ beforeUnloadFired:proceed];
      return;
    }
    *proceed_to_fire_unload = proceed;
    if (!proceed) [view_ beforeUnloadFired:NO];
  }

  content::JavaScriptDialogManager* GetJavaScriptDialogManager(content::WebContents*) override;

  void EnterFullscreenModeForTab(content::RenderFrameHost*, const blink::mojom::FullscreenOptions&) override {
    fullscreen_ = true;
    [view_ pageFullscreenChanged:YES];
  }
  void ExitFullscreenModeForTab(content::WebContents*) override {
    fullscreen_ = false;
    [view_ pageFullscreenChanged:NO];
  }
  bool IsFullscreenForTabOrPending(const content::WebContents*) override { return fullscreen_; }

  content::PictureInPictureResult EnterPictureInPicture(content::WebContents* web_contents) override {
    NousInstallPictureInPictureHooks();
    return PictureInPictureWindowManager::GetInstance()->EnterVideoPictureInPicture(web_contents);
  }
  void ExitPictureInPicture() override {
    PictureInPictureWindowManager::GetInstance()->ExitPictureInPicture();
  }

  void FindReply(content::WebContents* web_contents, int request_id, int number_of_matches,
                 const gfx::Rect& selection_rect, int active_match_ordinal, bool final_update) override {
    if (auto* find = find_in_page::FindTabHelper::FromWebContents(web_contents))
      find->HandleFindReply(request_id, number_of_matches, selection_rect, active_match_ordinal, final_update);
    [view_ findReplyCount:number_of_matches final:final_update];
  }

  bool TakeFocus(content::WebContents*, bool reverse) override { return false; }

  content::KeyboardEventProcessingResult PreHandleKeyboardEvent(
      content::WebContents* source, const input::NativeWebKeyboardEvent& event) override {
    // Esc leaves page fullscreen before the page sees it (Chrome behaviour).
    if (fullscreen_ && event.windows_key_code == 0x1B &&
        event.GetType() == blink::WebInputEvent::Type::kRawKeyDown &&
        !(event.GetModifiers() & blink::WebInputEvent::kKeyModifiers)) {
      source->ExitFullscreen(true);
      return content::KeyboardEventProcessingResult::HANDLED;
    }
    return content::KeyboardEventProcessingResult::NOT_HANDLED;
  }

  bool HandleKeyboardEvent(content::WebContents* source, const input::NativeWebKeyboardEvent& event) override {
    // The page declined the key. Like Chrome's BrowserWindow, give the app's
    // main menu (⌘T, ⌘L, ⌘W…) and history shortcuts the event next.
    if (event.skip_if_unhandled || !event.os_event) return false;
    NSEvent* native = event.os_event.Get();
    if (native.type != NSEventTypeKeyDown) return false;
    const NSEventModifierFlags flags = native.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if ((flags & ~NSEventModifierFlagFunction) == NSEventModifierFlagCommand && !event.is_system_key) {
      auto& controller = source->GetController();
      if (native.keyCode == 123 && controller.CanGoBack()) { controller.GoBack(); return true; }
      if (native.keyCode == 124 && controller.CanGoForward()) { controller.GoForward(); return true; }
    }
    return [[NSApp mainMenu] performKeyEquivalent:native];
  }

  // WebContentsObserver ----------------------------------------------------
  void DidStartNavigation(content::NavigationHandle* handle) override {
    if (!handle->IsInPrimaryMainFrame() || handle->IsSameDocument()) return;
    NBChromiumView* view = view_;
    view->_navigationGeneration++;
    [view->_contexts removeAllObjects];
    [view cancelPageDialogs];
    [view stopFinding];
    [view emit:@"load-start" payload:@{}];
  }
  void DidFinishNavigation(content::NavigationHandle* handle) override {
    if (!handle->IsInPrimaryMainFrame()) return;
    const int error = handle->GetNetErrorCode();
    if (!handle->HasCommitted() && error != 0 && error != -3 /* ERR_ABORTED */) {
      [view_ emit:@"error" payload:@{@"message" : String(net::ErrorToShortString(error)), @"code" : @(error)}];
    }
    UpdateState();
  }
  void DidFinishLoad(content::RenderFrameHost* rfh, const GURL&) override {
    if (rfh->IsInPrimaryMainFrame()) [view_ emit:@"load-end" payload:@{@"status" : @200}];
  }
  void LoadProgressChanged(double progress) override {
    [view_ emit:@"progress" payload:@{@"progress" : @(progress)}];
  }
  void TitleWasSet(content::NavigationEntry*) override { UpdateState(); }
  void PrimaryMainFrameRenderProcessGone(base::TerminationStatus status) override {
    NBChromiumView* view = view_;
    view->_navigationGeneration++;
    [view invalidateContexts];
    [view cancelCommands:Failure(@"The page renderer was closed.")];
    [view emit:@"error" payload:@{@"message" : Localized(@"The webpage stopped responding. Reload to continue.")}];
  }
  void OnAudioStateChanged(bool audible) override { view_.mediaActive = audible; }
  // Like Chrome's ContentsWebView: paint the page's own background behind it,
  // so a navigation's render-view swap never exposes the window behind.
  void OnBackgroundColorChanged() override { [view_ updatePageBackground]; }

  // FaviconDriverObserver --------------------------------------------------
  void OnFaviconUpdated(favicon::FaviconDriver*, NotificationIconType type, const GURL& icon_url, bool,
                        const gfx::Image& image) override {
    if (type != NON_TOUCH_LARGEST && type != NON_TOUCH_16_DIP) return;
    if (image.IsEmpty()) return;
    NSImage* icon = image.ToNSImage();
    CGImageRef cg = [icon CGImageForProposedRect:nullptr context:nil hints:nil];
    if (!cg) return;
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:cg];
    NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png || png.length > 2 * 1024 * 1024) return;
    [view_ emit:@"favicon" payload:@{@"data" : png, @"url" : String(icon_url.spec()),
                                     @"pageURL" : view_.URLString ?: @""}];
  }

  // Web-modal host: Chrome's own tab-modal dialogs (HTTP auth, external
  // protocol, certificate viewer…) attach over this page.
  web_modal::WebContentsModalDialogHost* GetWebContentsModalDialogHost(content::WebContents*) override {
    return this;
  }
  bool IsWebContentsVisible(content::WebContents*) override {
    NSView* host = view_;
    return host.window && !host.isHiddenOrHasHiddenAncestor;
  }
  gfx::NativeView GetHostView() const override { return gfx::NativeView(view_); }
  gfx::Point GetDialogPosition(const gfx::Size& size) override {
    NSView* host = view_;
    return gfx::Point(std::max(0, (int)(host.bounds.size.width - size.width()) / 2), 0);
  }
  gfx::Size GetMaximumDialogSize() override {
    NSView* host = view_;
    return gfx::Size(host.bounds.size.width, host.bounds.size.height);
  }
  void AddObserver(web_modal::ModalDialogHostObserver* observer) override { modal_observers_.AddObserver(observer); }
  void RemoveObserver(web_modal::ModalDialogHostObserver* observer) override {
    modal_observers_.RemoveObserver(observer);
  }

  void UpdateState() {
    NBChromiumView* view = view_;
    if (!contents_ || !view) return;
    view.pageTitle = String(contents_->GetTitle());
    const GURL& url = contents_->GetVisibleURL();
    view.URLString = url.is_empty() ? @"" : String(url.spec());
    view.loading = contents_->IsLoading();
    view.canGoBack = contents_->GetController().CanGoBack();
    view.canGoForward = contents_->GetController().CanGoForward();
    [view emitState];
  }

  std::unique_ptr<content::WebContents> Release() {
    Tabs().erase(contents_.get());
    contents_->SetDelegate(nullptr);
    Observe(nullptr);
    return std::move(contents_);
  }

 private:
  __weak NBChromiumView* view_;
  std::unique_ptr<content::WebContents> contents_;
  scoped_refptr<content::DevToolsAgentHost> agent_;
  base::ObserverList<web_modal::ModalDialogHostObserver> modal_observers_;
  bool fullscreen_ = false;
  bool preparing_close_ = false;
};

namespace nous {
NSWindow* WindowForWebContents(content::WebContents* contents) {
  NousTab* tab = NousTab::From(contents);
  return tab ? tab->view().dialogPresentationWindow : nil;
}
}  // namespace nous

// ---------------------------------------------------------------------------
// JavaScript dialogs as native sheets on the owning browser window
// (Dia: ArcWebContentsUIDelegate willRunJavaScript*Panel).

class NousJavaScriptDialogManager final : public content::JavaScriptDialogManager {
 public:
  static NousJavaScriptDialogManager* Get() {
    static base::NoDestructor<NousJavaScriptDialogManager> manager;
    return manager.get();
  }

  void RunJavaScriptDialog(content::WebContents* web_contents, content::RenderFrameHost* rfh,
                           content::JavaScriptDialogType type, const std::u16string& message,
                           const std::u16string& default_prompt, DialogClosedCallback callback,
                           bool* did_suppress_message) override {
    NousTab* tab = NousTab::From(web_contents);
    NBChromiumView* view = tab ? tab->view() : nil;
    if (!view) { *did_suppress_message = true; std::move(callback).Run(false, u""); return; }
    NSAlert* alert = [NSAlert new];
    alert.messageText = String(rfh->GetLastCommittedOrigin().Serialize());
    alert.informativeText = String(message);
    [alert addButtonWithTitle:Localized(@"OK")];
    NSTextField* field = nil;
    if (type != content::JAVASCRIPT_DIALOG_TYPE_ALERT) [alert addButtonWithTitle:Localized(@"Cancel")];
    if (type == content::JAVASCRIPT_DIALOG_TYPE_PROMPT) {
      field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 280, 24)];
      field.stringValue = String(default_prompt);
      alert.accessoryView = field;
    }
    __block DialogClosedCallback shared = std::move(callback);
    [view presentAlert:alert javaScript:YES completion:^(NSModalResponse response) {
      if (!shared) return;
      const bool ok = response == NSAlertFirstButtonReturn;
      std::move(shared).Run(ok, field ? base::SysNSStringToUTF16(field.stringValue) : u"");
    }];
  }

  void RunBeforeUnloadDialog(content::WebContents* web_contents, content::RenderFrameHost*, bool is_reload,
                             DialogClosedCallback callback) override {
    NousTab* tab = NousTab::From(web_contents);
    NBChromiumView* view = tab ? tab->view() : nil;
    if (!view) { std::move(callback).Run(true, u""); return; }
    NSAlert* alert = [NSAlert new];
    alert.messageText = Localized(is_reload ? @"Reload this site?" : @"Leave this site?");
    alert.informativeText = Localized(@"Changes you made may not be saved.");
    [alert addButtonWithTitle:Localized(is_reload ? @"Reload" : @"Leave")];
    [alert addButtonWithTitle:Localized(@"Cancel")];
    __block DialogClosedCallback shared = std::move(callback);
    [view presentAlert:alert javaScript:YES completion:^(NSModalResponse response) {
      if (shared) std::move(shared).Run(response == NSAlertFirstButtonReturn, u"");
    }];
  }

  bool HandleJavaScriptDialog(content::WebContents*, bool, const std::u16string*) override { return false; }

  void CancelDialogs(content::WebContents* web_contents, bool) override {
    if (NousTab* tab = NousTab::From(web_contents)) [tab->view() cancelPageDialogs];
  }
};

content::JavaScriptDialogManager* NousTab::GetJavaScriptDialogManager(content::WebContents*) {
  return NousJavaScriptDialogManager::Get();
}

// ---------------------------------------------------------------------------
// Permission prompts as sheets (Chrome's location-bar bubbles need a Chrome
// BrowserWindow, which Nous intentionally does not have).

class NousPermissionPrompt final : public permissions::PermissionPrompt {
 public:
  NousPermissionPrompt(NBChromiumView* view, permissions::PermissionPrompt::Delegate* delegate)
      : delegate_(delegate->GetWeakPtr()) {
    NSMutableArray<NSString*>* lines = [NSMutableArray array];
    [lines addObject:[NSString stringWithFormat:Localized(@"%@ wants to:"),
                                                String(url::Origin::Create(delegate->GetRequestingOrigin()).Serialize())]];
    for (const auto& request : delegate->Requests())
      [lines addObject:[@"• " stringByAppendingString:String(request->GetMessageTextFragment())]];
    NSAlert* alert = [NSAlert new];
    alert.messageText = Localized(@"Website Permission");
    alert.informativeText = [lines componentsJoinedByString:@"\n"];
    [alert addButtonWithTitle:Localized(@"Don't Allow")];
    [alert addButtonWithTitle:Localized(@"Allow")];
    [alert addButtonWithTitle:Localized(@"Cancel")];
    alert.buttons[0].keyEquivalent = @"\r";
    alert.buttons[1].keyEquivalent = @"";
    alert.buttons[2].keyEquivalent = @"\e";
    base::WeakPtr<permissions::PermissionPrompt::Delegate> weak = delegate_;
    [view presentAlert:alert javaScript:NO completion:^(NSModalResponse response) {
      if (!weak) return;
      const PromptOptions options = std::monostate();
      if (response == NSAlertSecondButtonReturn) weak->Accept(options);
      else if (response == NSAlertFirstButtonReturn) weak->Deny(options);
      else weak->Dismiss(options);
    }];
  }
  bool UpdateAnchor() override { return true; }
  TabSwitchingBehavior GetTabSwitchingBehavior() override { return kDestroyPromptButKeepRequestPending; }
  permissions::PermissionPromptDisposition GetPromptDisposition() const override {
    return permissions::PermissionPromptDisposition::CUSTOM_MODAL_DIALOG;
  }
  bool IsAskPrompt() const override { return true; }
  std::optional<gfx::Rect> GetViewBoundsInScreen() const override { return std::nullopt; }
  std::vector<permissions::ElementAnchoredBubbleVariant> GetPromptVariants() const override { return {}; }
  std::optional<permissions::feature_params::PermissionElementPromptPosition> GetPromptPosition() const override {
    return std::nullopt;
  }

 private:
  base::WeakPtr<permissions::PermissionPrompt::Delegate> delegate_;
};

static std::unique_ptr<permissions::PermissionPrompt> CreateNousPermissionPrompt(
    content::WebContents* web_contents, permissions::PermissionPrompt::Delegate* delegate,
    bool* default_handling) {
  NousTab* tab = NousTab::From(web_contents);
  if (!tab) return nullptr;  // Not a Nous page: let Chrome handle it.
  *default_handling = false;
  NBChromiumView* view = tab->view();
  NSWindow* parent = view.dialogPresentationWindow;
  if (!parent || !parent.visible || parent.attachedSheet) return nullptr;
  return std::make_unique<NousPermissionPrompt>(view, delegate);
}

namespace nous {
void InstallTabServices() { SetCreatePermissionPromptFunction(&CreateNousPermissionPrompt); }
void CloseAllTabs() {
  std::vector<NBChromiumView*> views;
  for (auto& [contents, tab] : Tabs()) {
    if (NBChromiumView* view = tab->view()) views.push_back(view);
  }
  for (NBChromiumView* view : views) {
    // Shutdown teardown is not a user close: never let it edit the saved session.
    view.eventHandler = nil;
    view.popupHandler = nil;
    [view closeBrowser];
  }
}
}  // namespace nous

// ---------------------------------------------------------------------------
// NBChromiumView

@implementation NBChromiumView

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _pending = [NSMutableDictionary new];
    _contexts = [NSMutableDictionary new];
    _bindings = [NSMutableDictionary new];
    _scripts = [NSMutableArray new];
    _closeCompletions = [NSMutableArray new];
    _dialogs = [NSMutableSet new];
    _zoomFactor = 1;
    _nextCommand = 1;
    _autoDiscardable = YES;
    _pageTitle = @"";
    _URLString = @"";
    self.wantsLayer = YES;
    [self updatePageBackground];
  }
  return self;
}

- (void)dealloc {
  [self cancelCommands:Failure(@"The tab was released.")];
  _tab.reset();
}

- (NousTab*)tab { return _tab.get(); }

- (void)updatePageBackground {
  NSColor* color = nil;
  if (_tab) {
    if (std::optional<SkColor> page = _tab->contents()->GetBackgroundColor(); page && SkColorGetA(*page)) {
      color = [NSColor colorWithSRGBRed:SkColorGetR(*page) / 255.0 green:SkColorGetG(*page) / 255.0
                                   blue:SkColorGetB(*page) / 255.0 alpha:1];
    }
  }
  // Chrome's kColorWebContentsBackground: white, dark grey in Dark Mode.
  if (!color) {
    BOOL dark = [self.effectiveAppearance bestMatchFromAppearancesWithNames:@[
                   NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] == NSAppearanceNameDarkAqua;
    color = dark ? [NSColor colorWithSRGBRed:0x20 / 255.0 green:0x21 / 255.0 blue:0x24 / 255.0 alpha:1]
                 : NSColor.whiteColor;
  }
  self.layer.backgroundColor = color.CGColor;
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self updatePageBackground];
}
- (BOOL)isFlipped { return YES; }

// Presentation window: explicit owner while managed, else the attached window.
- (NSWindow*)dialogPresentationWindow {
  return _managesDialogPresentationWindow ? _dialogPresentationWindow : self.window;
}
- (void)setDialogPresentationWindow:(NSWindow*)window {
  if (_managesDialogPresentationWindow && _dialogPresentationWindow == window) return;
  _managesDialogPresentationWindow = YES;
  _dialogPresentationWindow = window;
  ++_dialogPresentationGeneration;
  [self cancelPageDialogs];
  if (window && _pendingURL && !_tab) [self ensureContents];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window && _pendingURL && !_tab) [self ensureContents];
}

- (void)layout {
  [super layout];
  for (NSView* child in self.subviews) child.frame = self.bounds;
}

// Creates the page lazily: a background tab loads without being mounted, but
// it needs an owning window for dialogs (same rule as the CEF host).
- (void)ensureContents {
  if (_tab || _closed || _reserved) return;
  Profile* profile = nous::GetProfile();
  if (!profile || !self.dialogPresentationWindow) {
    LOG(WARNING) << "Nous: page creation deferred (profile=" << !!profile
                 << " window=" << !!self.dialogPresentationWindow << ")";
    return;
  }
  content::WebContents::CreateParams params(profile);
  params.initially_hidden = self.isHiddenOrHasHiddenAncestor || !self.window;
  std::unique_ptr<content::WebContents> contents = content::WebContents::Create(params);
  // Like CEF's CreateBrowser("about:blank"): start a renderer so DevTools
  // (isolated worlds, document-start scripts) is live before the real URL.
  content::NavigationController::LoadURLParams blank{GURL(url::kAboutBlankURL)};
  blank.transition_type = ui::PAGE_TRANSITION_AUTO_TOPLEVEL;
  contents->GetController().LoadURLWithParams(blank);
  _replaceInitialBlank = YES;
  [self adoptContents:std::move(contents)];
}

- (void)adoptContents:(std::unique_ptr<content::WebContents>)contents {
  if (_closed || _tab) return;
  _reserved = NO;
  _tab = std::make_unique<NousTab>(self, std::move(contents));
  NSView* native = _tab->NativeView();
  native.frame = self.bounds;
  native.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self addSubview:native];
  if (_zoomFactor != 1) self.zoomFactor = _zoomFactor;
  [self updatePageBackground];
  [self setPageVisible:!self.isHiddenOrHasHiddenAncestor && self.window != nil];
  __weak NBChromiumView* weak = self;
  [self command:@"Page.enable" params:@{} completion:^(NSDictionary*, NSError* pageError) {
    if (pageError) { [weak emit:@"error" payload:@{@"message" : pageError.localizedDescription}]; return; }
    [weak command:@"Runtime.enable" params:@{} completion:^(NSDictionary*, NSError* runtimeError) {
      NBChromiumView* view = weak;
      if (!view || view->_closed) return;
      if (runtimeError) { [view emit:@"error" payload:@{@"message" : runtimeError.localizedDescription}]; return; }
      __block NSUInteger remaining = view->_scripts.count;
      dispatch_block_t ready = ^{
        NBChromiumView* strong = weak;
        if (!strong || strong->_closed) return;
        strong->_ready = YES;
        if (strong->_pendingURL.length) {
          NSString* url = strong->_pendingURL;
          strong->_pendingURL = nil;
          [strong loadURL:url];
        }
      };
      if (!remaining) { ready(); return; }
      for (NSDictionary* script in [view->_scripts copy]) {
        [view installScript:script completion:^(NSError* error) {
          if (error) [weak emit:@"error" payload:@{@"message" : error.localizedDescription}];
          if (--remaining == 0) ready();
        }];
      }
    }];
  }];
  _tab->UpdateState();
}

- (void)emit:(NSString*)event payload:(NSDictionary*)payload {
  if (_eventHandler) _eventHandler(event, payload);
}
- (void)emitState {
  [self emit:@"state" payload:@{@"url" : self.URLString ?: @"", @"title" : self.pageTitle ?: @"",
                                @"isLoading" : @(self.loading), @"canGoBack" : @(self.canGoBack),
                                @"canGoForward" : @(self.canGoForward), @"fullscreen" : @(self.fullscreen)}];
}

// Navigation ------------------------------------------------------------------
- (void)loadURL:(NSString*)url {
  if (_closed) return;
  if (!_tab || !_ready) { _pendingURL = [url copy]; [self ensureContents]; return; }
  GURL target = URL(url);
  if (!target.is_valid()) return;
  content::NavigationController::LoadURLParams params(target);
  params.transition_type = ui::PAGE_TRANSITION_TYPED;
  // The bootstrap about:blank must not become a Back entry.
  params.should_replace_current_entry = _replaceInitialBlank;
  _replaceInitialBlank = NO;
  _tab->contents()->GetController().LoadURLWithParams(params);
}
- (void)reserveForPopup { _reserved = YES; }
- (void)goBack {
  if (_tab && _tab->contents()->GetController().CanGoBack()) _tab->contents()->GetController().GoBack();
}
- (void)goForward {
  if (_tab && _tab->contents()->GetController().CanGoForward()) _tab->contents()->GetController().GoForward();
}
- (void)navigationURLBackwards:(BOOL)backwards completion:(void (^)(NSString*, NSError*))completion {
  if (!_tab) { completion(nil, Failure(@"The page is unavailable.")); return; }
  content::NavigationEntry* entry = _tab->contents()->GetController().GetEntryAtOffset(backwards ? -1 : 1);
  completion(entry ? String(entry->GetURL().spec()) : nil, nil);
}
- (void)reloadBypassingCache:(BOOL)bypass {
  if (_tab) _tab->contents()->GetController().Reload(bypass ? content::ReloadType::BYPASSING_CACHE
                                                            : content::ReloadType::NORMAL, true);
}
- (void)stopLoading { if (_tab) _tab->contents()->Stop(); }
- (void)printPage {
  if (!_closed && _tab && self.window.isKeyWindow && !self.window.attachedSheet)
    printing::StartBasicPrint(_tab->contents());
}
- (void)print:(id)sender { [self printPage]; }

// Fullscreen --------------------------------------------------------------------
- (void)pageFullscreenChanged:(BOOL)fullscreen {
  if (fullscreen && (_closed || !_activeInWindow)) { [self exitPageFullscreen]; return; }
  self.fullscreen = fullscreen;
  NSWindow* window = self.window;
  const BOOL windowFullscreen = (window.styleMask & NSWindowStyleMaskFullScreen) != 0;
  if (fullscreen && !windowFullscreen) { _windowFullscreenOwned = YES; [window toggleFullScreen:nil]; }
  else if (!fullscreen && _windowFullscreenOwned && windowFullscreen) { [window toggleFullScreen:nil]; }
  if (!fullscreen) _windowFullscreenOwned = NO;
  [self emitState];
}
- (void)exitPageFullscreen {
  if (_tab && _tab->fullscreen()) _tab->contents()->ExitFullscreen(true);
}

// Closing -----------------------------------------------------------------------
- (void)tabDidClose {
  if (!_tab && _closed) return;
  BOOL wasClosed = _closed;
  _closed = YES;
  [self cancelPreparedClose];
  [self pageFullscreenChanged:NO];
  [self invalidateContexts];
  [self cancelCommands:Failure(@"The tab was closed.")];
  [self cancelPageDialogs];
  [self stopFinding];
  NSView* native = _tab ? _tab->NativeView() : nil;
  NSResponder* responder = native.window.firstResponder;
  if ([responder isKindOfClass:NSView.class] && [(NSView*)responder isDescendantOf:native])
    [native.window makeFirstResponder:nil];
  [native removeFromSuperview];
  _tab.reset();
  _closeRequested = NO;
  NSArray* completions = [_closeCompletions copy];
  [_closeCompletions removeAllObjects];
  for (void (^completion)(BOOL) in completions) completion(YES);
  if (!wasClosed || completions.count == 0) [self emit:@"closed" payload:@{}];
}

- (void)closeBrowser {
  if (_closed) return;
  _reserved = NO;
  [self tabDidClose];
}

- (void)requestCloseWithCompletion:(void (^)(BOOL))completion {
  if (_closed) { completion(YES); return; }
  if (_closePreparation) { completion(NO); return; }
  [_closeCompletions addObject:[completion copy]];
  if (_closeRequested) return;
  _closeRequested = YES;
  if (!_tab) { [self tabDidClose]; return; }
  content::WebContents* contents = _tab->contents();
  if (contents->NeedToFireBeforeUnloadOrUnloadEvents()) contents->ClosePage();  // -> CloseContents
  else [self tabDidClose];
}

- (void)beforeUnloadFired:(BOOL)proceed {
  if (_closePreparationCompletion) {
    void (^completion)(BOOL) = _closePreparationCompletion;
    _closePreparationCompletion = nil;
    _closePrepared = proceed;
    if (!proceed) _closePreparation = 0;
    completion(proceed);
    return;
  }
  if (!proceed && _closeRequested) {
    _closeRequested = NO;
    NSArray* completions = [_closeCompletions copy];
    [_closeCompletions removeAllObjects];
    for (void (^completion)(BOOL) in completions) completion(NO);
  }
}

- (void)prepareCloseWithCompletion:(void (^)(BOOL))completion {
  if (_closed || _closeRequested || _closePreparation || _reserved) { completion(NO); return; }
  static NSUInteger nextPreparation;
  _closePreparation = ++nextPreparation;
  if (!_tab || !_tab->contents()->NeedToFireBeforeUnloadOrUnloadEvents()) {
    _closePrepared = YES;
    completion(YES);
    return;
  }
  _closePreparationCompletion = [completion copy];
  _tab->set_preparing_close(true);
  _tab->contents()->DispatchBeforeUnload(false /* auto_cancel */);
}
- (BOOL)validatePreparedClose {
  return _closePreparation && _closePrepared && !_closed && !_closeRequested && !_closePreparationCompletion;
}
- (void)cancelPreparedClose {
  void (^completion)(BOOL) = _closePreparationCompletion;
  _closePreparationCompletion = nil;
  _closePreparation = 0;
  _closePrepared = NO;
  if (_tab) _tab->set_preparing_close(false);
  if (completion) completion(NO);
}
- (void)commitPreparedCloseWithCompletion:(void (^)(BOOL))completion {
  if (![self validatePreparedClose]) { [self cancelPreparedClose]; completion(NO); return; }
  _closePreparation = 0;
  _closePrepared = NO;
  [_closeCompletions addObject:[completion copy]];
  _closeRequested = YES;
  [self tabDidClose];
}

// Focus / visibility ------------------------------------------------------------
- (void)focusBrowser {
  if (_tab && !NBChromiumShouldCancelFocus(self, _closed, _activeInWindow, NO)) _tab->contents()->Focus();
}
- (void)setPageVisible:(BOOL)visible {
  if (!_tab) return;
  NSView* native = _tab->NativeView();
  if (native.hidden == visible) native.hidden = !visible;
  if (visible) _tab->contents()->WasShown();
  else _tab->contents()->WasHidden();
}
- (void)setTabActiveInWindow:(BOOL)active pinned:(BOOL)pinned autoDiscardable:(BOOL)autoDiscardable {
  _activeInWindow = active;
  _pinned = pinned;
  _autoDiscardable = autoDiscardable;
  if (!active) [self exitPageFullscreen];
}

- (void)setZoomFactor:(double)value {
  _zoomFactor = MAX(0.25, MIN(5, value));
  if (!_tab) return;
  if (auto* zoom = zoom::ZoomController::FromWebContents(_tab->contents()))
    zoom->SetZoomLevel(blink::ZoomFactorToZoomLevel(_zoomFactor));
}

// Dialog plumbing -----------------------------------------------------------------
- (NBPageDialog*)dialogWithSheet:(NSWindow*)sheet presenter:(id)presenter
                      completion:(void (^)(NSModalResponse))completion {
  NSWindow* parent = self.dialogPresentationWindow;
  if (_closed || !parent || parent.attachedSheet) {
    dispatch_async(dispatch_get_main_queue(), ^{ completion(NSModalResponseCancel); });
    return nil;
  }
  NBPageDialog* dialog = [NBPageDialog new];
  dialog.sheet = sheet;
  dialog.presenter = presenter;
  dialog.parentWindow = parent;
  const NSUInteger generation = _navigationGeneration, presentation = _dialogPresentationGeneration;
  __weak NBChromiumView* weak = self;
  __weak NBPageDialog* weakDialog = dialog;
  __weak NSWindow* weakParent = parent;
  dialog.completion = ^(NSModalResponse response) {
    NBChromiumView* view = weak;
    if (view) [view->_dialogs removeObject:weakDialog];
    const BOOL valid = view && !view->_closed && view->_navigationGeneration == generation &&
                       view->_dialogPresentationGeneration == presentation && weakParent &&
                       view.dialogPresentationWindow == weakParent;
    completion(valid ? response : NSModalResponseCancel);
  };
  [_dialogs addObject:dialog];
  return dialog;
}
- (void)presentAlert:(NSAlert*)alert javaScript:(BOOL)javaScript completion:(void (^)(NSModalResponse))completion {
  NBPageDialog* dialog = [self dialogWithSheet:alert.window presenter:alert completion:completion];
  if (!dialog) return;
  [alert beginSheetModalForWindow:dialog.parentWindow
                completionHandler:^(NSModalResponse response) { [dialog finish:response]; }];
}
- (void)cancelPageDialogs {
  for (NBPageDialog* dialog in _dialogs.allObjects) [dialog finish:NSModalResponseCancel];
}

// DevTools protocol bridge (in-process, no debugging port) --------------------------
- (void)command:(NSString*)method params:(NSDictionary*)params completion:(NBCommandCompletion)completion {
  if (!_tab || _closed) {
    if (completion) completion(@{}, Failure(@"The page is unavailable."));
    return;
  }
  const int identifier = _nextCommand++;
  if (completion) {
    _pending[@(identifier)] = [completion copy];
    __weak NBChromiumView* weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      NBChromiumView* view = weak;
      if (!view) return;
      NBCommandCompletion pending = view->_pending[@(identifier)];
      if (!pending) return;
      [view->_pending removeObjectForKey:@(identifier)];
      pending(@{}, Failure(@"The page operation timed out."));
    });
  }
  _tab->SendDevTools(identifier, method, params);
}

- (void)cancelCommands:(NSError*)error {
  NSArray<NBCommandCompletion>* completions = _pending.allValues;
  [_pending removeAllObjects];
  for (NBCommandCompletion completion in completions) completion(@{}, error);
}

- (void)devToolsMessage:(NSDictionary*)message {
  NSNumber* identifier = message[@"id"];
  if ([identifier isKindOfClass:NSNumber.class]) {
    NBCommandCompletion completion = _pending[identifier];
    if (!completion) return;
    [_pending removeObjectForKey:identifier];
    NSDictionary* result = [message[@"result"] isKindOfClass:NSDictionary.class] ? message[@"result"] : @{};
    completion(result, message[@"error"] ? Failure(@"The page changed or the Chromium operation failed.") : nil);
    return;
  }
  if (_closed) return;
  NSString* name = message[@"method"];
  NSDictionary* event = [message[@"params"] isKindOfClass:NSDictionary.class] ? message[@"params"] : @{};
  if ([name isEqual:@"Runtime.executionContextCreated"]) {
    NSDictionary* context = event[@"context"];
    NSString* world = context[@"name"];
    NSNumber* identifier = context[@"id"];
    NSString* uniqueID = context[@"uniqueId"];
    NSString* frameID = context[@"auxData"][@"frameId"];
    if ([identifier isKindOfClass:NSNumber.class] && [world isKindOfClass:NSString.class] &&
        [uniqueID isKindOfClass:NSString.class] && uniqueID.length && [frameID isKindOfClass:NSString.class]) {
      _contexts[identifier] = @{@"world" : world, @"origin" : context[@"origin"] ?: @"", @"frameID" : frameID,
                                @"uniqueID" : uniqueID, @"generation" : @(_navigationGeneration),
                                @"isolated" : @([context[@"auxData"][@"type"] isEqual:@"isolated"])};
    }
  } else if ([name isEqual:@"Runtime.executionContextDestroyed"]) {
    NSNumber* identifier = event[@"executionContextId"];
    if (identifier && [_contexts[identifier][@"uniqueID"] isEqual:event[@"executionContextUniqueId"]])
      [_contexts removeObjectForKey:identifier];
  } else if ([name isEqual:@"Runtime.executionContextsCleared"]) {
    [_contexts removeAllObjects];
  } else if ([name isEqual:@"Page.frameNavigated"]) {
    NSDictionary* frame = event[@"frame"];
    if (!frame[@"parentId"]) {
      [self invalidateContexts];
      _mainFrameID = frame[@"id"];
    }
  } else if ([name isEqual:@"Page.frameDetached"]) {
    NSString* frameID = event[@"frameId"];
    if ([frameID isEqual:_mainFrameID]) [self invalidateContexts];
    else
      for (NSNumber* key in [_contexts.allKeys copy])
        if ([_contexts[key][@"frameID"] isEqual:frameID]) [_contexts removeObjectForKey:key];
  } else if ([name isEqual:@"Runtime.bindingCalled"]) {
    NSString* binding = event[@"name"];
    NSString* world = _bindings[binding];
    NSNumber* context = event[@"executionContextId"];
    NSString* payload = event[@"payload"];
    // Never accept page-world messages or an unregistered binding.
    NSDictionary* trusted = context ? _contexts[context] : nil;
    if (world.length && [trusted[@"isolated"] boolValue] &&
        [trusted[@"generation"] unsignedIntegerValue] == _navigationGeneration && [trusted[@"world"] isEqual:world] &&
        _mainFrameID.length && [trusted[@"frameID"] isEqual:_mainFrameID] && [payload isKindOfClass:NSString.class] &&
        payload.length <= 65536) {
      [self emit:@"binding" payload:@{@"name" : binding, @"payload" : payload, @"contextID" : context,
                                      @"world" : world, @"origin" : trusted[@"origin"], @"isMainFrame" : @YES}];
    }
  }
}

- (void)invalidateContexts {
  [_contexts removeAllObjects];
  _mainFrameID = nil;
}
- (NSDictionary*)contextForWorld:(NSString*)world {
  if (!world.length || !_mainFrameID.length) return nil;
  for (NSDictionary* context in _contexts.allValues) {
    if ([context[@"world"] isEqual:world] && [context[@"isolated"] boolValue] &&
        [context[@"frameID"] isEqual:_mainFrameID] &&
        [context[@"generation"] unsignedIntegerValue] == _navigationGeneration && [context[@"uniqueID"] length])
      return context;
  }
  return nil;
}

- (void)evaluate:(NSString*)source world:(NSString*)world completion:(void (^)(id, NSError*))completion {
  if (!_ready || _closed) { completion(nil, Failure(@"The page is not ready.")); return; }
  const NSUInteger generation = _navigationGeneration;
  __weak NBChromiumView* weak = self;
  void (^run)(NSString*) = ^(NSString* uniqueID) {
    NBChromiumView* view = weak;
    if (!view || view->_closed || view->_navigationGeneration != generation) {
      completion(nil, Failure(@"The page changed."));
      return;
    }
    NSMutableDictionary* params =
        [@{@"expression" : source, @"returnByValue" : @YES, @"awaitPromise" : @YES, @"userGesture" : @NO} mutableCopy];
    if (uniqueID) params[@"uniqueContextId"] = uniqueID;
    [view command:@"Runtime.evaluate" params:params completion:^(NSDictionary* result, NSError* error) {
      NBChromiumView* current = weak;
      if (!current || current->_closed || current->_navigationGeneration != generation ||
          (world.length && ![[current contextForWorld:world][@"uniqueID"] isEqual:uniqueID])) {
        completion(nil, Failure(@"The page changed."));
        return;
      }
      if (error || result[@"exceptionDetails"]) { completion(nil, error ?: Failure(@"The page script failed.")); return; }
      id value = result[@"result"][@"value"];
      completion(value == NSNull.null ? nil : value, nil);
    }];
  };
  if (!world.length) { run(nil); return; }
  NSDictionary* cached = [self contextForWorld:world];
  if (cached) { run(cached[@"uniqueID"]); return; }
  [self command:@"Page.getFrameTree" params:@{} completion:^(NSDictionary* tree, NSError* error) {
    NBChromiumView* view = weak;
    if (!view || view->_closed || view->_navigationGeneration != generation) {
      completion(nil, Failure(@"The page changed."));
      return;
    }
    NSString* frame = tree[@"frameTree"][@"frame"][@"id"];
    if (error || ![frame isKindOfClass:NSString.class] || !frame.length) {
      completion(nil, error ?: Failure(@"The page frame is unavailable."));
      return;
    }
    if (view->_mainFrameID.length && ![view->_mainFrameID isEqual:frame]) {
      completion(nil, Failure(@"The page changed."));
      return;
    }
    view->_mainFrameID = frame;
    NSDictionary* existing = [view contextForWorld:world];
    if (existing) { run(existing[@"uniqueID"]); return; }
    [view command:@"Page.createIsolatedWorld"
           params:@{@"frameId" : frame, @"worldName" : world, @"grantUniveralAccess" : @NO}
       completion:^(NSDictionary* result, NSError* createError) {
         NBChromiumView* current = weak;
         if (!current || current->_closed || current->_navigationGeneration != generation) {
           completion(nil, Failure(@"The page changed."));
           return;
         }
         NSNumber* identifier = result[@"executionContextId"];
         NSDictionary* context = identifier ? current->_contexts[identifier] : nil;
         if (createError || !context || context != [current contextForWorld:world] ||
             ![context[@"frameID"] isEqual:frame]) {
           completion(nil, createError ?: Failure(@"The isolated page context is unavailable."));
           return;
         }
         run(context[@"uniqueID"]);
       }];
  }];
}

- (void)capturePNG:(void (^)(NSData*, NSError*))completion {
  [self command:@"Page.captureScreenshot"
         params:@{@"format" : @"png", @"captureBeyondViewport" : @NO}
     completion:^(NSDictionary* result, NSError* error) {
       NSString* base64 = result[@"data"];
       NSData* png = base64 ? [[NSData alloc] initWithBase64EncodedString:base64 options:0] : nil;
       completion(png, error ?: (png ? nil : Failure(@"The screenshot is unavailable.")));
     }];
}

- (void)addScript:(NSString*)source world:(NSString*)world binding:(NSString*)binding {
  NSDictionary* script = @{@"source" : source, @"world" : world, @"binding" : binding};
  [_scripts addObject:script];
  if (_ready) {
    __weak NBChromiumView* weak = self;
    [self installScript:script completion:^(NSError* error) {
      if (error) [weak emit:@"error" payload:@{@"message" : error.localizedDescription}];
    }];
  }
}
- (void)installScript:(NSDictionary*)script completion:(void (^)(NSError*))completion {
  NSString *world = script[@"world"], *binding = script[@"binding"];
  __weak NBChromiumView* weak = self;
  dispatch_block_t install = ^{
    [weak command:@"Page.addScriptToEvaluateOnNewDocument"
           params:@{@"source" : script[@"source"], @"worldName" : world, @"runImmediately" : @YES}
       completion:^(NSDictionary*, NSError* error) { completion(error); }];
  };
  if (binding.length) {
    _bindings[binding] = world;
    [self command:@"Runtime.addBinding"
           params:@{@"name" : binding, @"executionContextName" : world}
       completion:^(NSDictionary*, NSError* error) {
         if (error) completion(error);
         else install();
       }];
  } else {
    install();
  }
}

// Find (Chrome's FindTabHelper) ---------------------------------------------------
- (void)findText:(NSString*)text backwards:(BOOL)backwards next:(BOOL)next completion:(void (^)(BOOL))completion {
  if (!_tab || _closed || !text.length) { [self stopFinding]; completion(NO); return; }
  void (^previous)(BOOL) = _findCompletion;
  _findCompletion = [completion copy];
  if (previous) previous(NO);
  auto* find = find_in_page::FindTabHelper::FromWebContents(_tab->contents());
  if (!find) { [self findReplyCount:0 final:YES]; return; }
  find->StartFinding(base::SysNSStringToUTF16(text), !backwards, false /* case */, true /* find_match */);
}
- (void)findReplyCount:(int)count final:(BOOL)finalUpdate {
  if (!finalUpdate || !_findCompletion) return;
  void (^completion)(BOOL) = _findCompletion;
  _findCompletion = nil;
  completion(count > 0);
}
- (void)stopFinding {
  if (_tab)
    if (auto* find = find_in_page::FindTabHelper::FromWebContents(_tab->contents()))
      find->StopFinding(find_in_page::SelectionAction::kKeep);
  void (^completion)(BOOL) = _findCompletion;
  _findCompletion = nil;
  if (completion) completion(NO);
}
@end

// MARK: - Picture-in-Picture

@interface NBPictureInPictureSession ()
- (instancetype)initWithWidget:(views::Widget*)widget
                    controller:(content::VideoPictureInPictureWindowController*)controller;
- (void)setPlaybackState:(int)state;
- (void)setDuration:(double)duration position:(double)position rate:(double)rate;
- (void)invalidate;
@end

@implementation NBPictureInPictureSession {
  raw_ptr<views::Widget> _widget;
  raw_ptr<content::VideoPictureInPictureWindowController> _controller;
}

- (instancetype)initWithWidget:(views::Widget*)widget
                    controller:(content::VideoPictureInPictureWindowController*)controller {
  if ((self = [super init])) {
    _widget = widget;
    _controller = controller;
    _window = widget->GetNativeWindow().GetNativeNSWindow();
    if (NousTab* tab = NousTab::From(controller->GetWebContents())) _sourceView = tab->view();
    _playing = YES;
    _playbackRate = 1;
    _positionDate = [NSDate date];
  }
  return self;
}

- (void)notify {
  if (_updateHandler) _updateHandler(self);
}

- (void)setPlaybackState:(int)state {
  // Freeze the position where it was, then advance from there at the new rate.
  NSDate* now = [NSDate date];
  if (_playing && _playbackRate > 0)
    _position += [now timeIntervalSinceDate:_positionDate] * _playbackRate;
  _positionDate = now;
  _playing = state == 0;
  _ended = state == 2;
  [self notify];
}

- (void)setDuration:(double)duration position:(double)position rate:(double)rate {
  _duration = duration;
  _position = position;
  _playbackRate = rate;
  _positionDate = [NSDate date];
  [self notify];
}

- (void)invalidate {
  if (_closed) return;
  _closed = YES;
  _widget = nullptr;
  _controller = nullptr;
  void (^handler)(NBPictureInPictureSession*) = _closeHandler;
  _updateHandler = nil;
  _closeHandler = nil;
  if (handler) handler(self);
}

- (void)togglePlayPause {
  if (_controller) _controller->TogglePlayPause();
}

- (void)seekTo:(NSTimeInterval)seconds {
  if (!_controller) return;
  double target = std::max(0.0, seconds);
  if (_duration > 0 && std::isfinite(_duration)) target = std::min(target, _duration);
  _controller->SeekTo(base::Seconds(target));
  _position = target;
  _positionDate = [NSDate date];
  [self notify];
}

- (void)close {
  if (_controller) _controller->Close(/*should_pause_video=*/true);
}

- (void)returnToPage {
  if (_controller) _controller->CloseAndFocusInitiator();
}
@end

@implementation NBPictureInPictureCenter {
  NSMutableDictionary<NSValue*, NBPictureInPictureSession*>* _sessions;
}

+ (instancetype)sharedCenter {
  static NBPictureInPictureCenter* center = [[NBPictureInPictureCenter alloc] init];
  return center;
}

- (instancetype)init {
  if ((self = [super init])) {
    _sessions = [NSMutableDictionary dictionary];
    NousInstallPictureInPictureHooks();
  }
  return self;
}

- (NBPictureInPictureSession*)sessionFor:(void*)window {
  return _sessions[[NSValue valueWithPointer:window]];
}

- (void)shown:(void*)window controller:(void*)controller {
  if ([self sessionFor:window]) return;
  auto* session = [[NBPictureInPictureSession alloc]
      initWithWidget:static_cast<views::Widget*>(window)
          controller:static_cast<content::VideoPictureInPictureWindowController*>(controller)];
  _sessions[[NSValue valueWithPointer:window]] = session;
  if (_sessionHandler) _sessionHandler(session);
}

- (void)destroyed:(void*)window {
  NSValue* key = [NSValue valueWithPointer:window];
  NBPictureInPictureSession* session = _sessions[key];
  [_sessions removeObjectForKey:key];
  [session invalidate];
}
@end

static void NousInstallPictureInPictureHooks() {
  static bool installed = false;
  if (installed) return;
  installed = true;
  nous::PictureInPictureHooks hooks;
  hooks.shown = [](void* window, void* controller) {
    [[NBPictureInPictureCenter sharedCenter] shown:window controller:controller];
  };
  hooks.playback_state = [](void* window, int state) {
    [[[NBPictureInPictureCenter sharedCenter] sessionFor:window] setPlaybackState:state];
  };
  hooks.media_position = [](void* window, double duration, double position, double rate) {
    [[[NBPictureInPictureCenter sharedCenter] sessionFor:window] setDuration:duration position:position rate:rate];
  };
  hooks.destroyed = [](void* window) {
    [[NBPictureInPictureCenter sharedCenter] destroyed:window];
  };
  nous::SetPictureInPictureHooks(hooks);
}
