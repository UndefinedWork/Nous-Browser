// Custom EyeDropper bridge: routes Chromium's content::EyeDropper requests to
// the Swift host's Liquid Glass color loupe while keeping strict lifetime
// safety across user selection, cancellation, navigation and tab teardown.

#import "nous/public/NBEyeDropper.h"
#import "nous/public/NousChromium.h"

#include <memory>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "content/public/browser/eye_dropper.h"
#include "content/public/browser/eye_dropper_listener.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/web_contents.h"
#include "nous/browser/nous_internal.h"
#include "skia/ext/skia_utils_mac.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"

namespace {
class NousEyeDropper;
}

@interface NBEyeDropperSession ()
- (instancetype)initWithOwner:(NousEyeDropper *)owner
                  webContents:(content::WebContents *)contents
                   sourceView:(NBChromiumView *)sourceView;
- (void)invalidateFromEngine;
@end

namespace {

class NousEyeDropper final : public content::EyeDropper {
 public:
  NousEyeDropper(content::WebContents *contents,
                 content::EyeDropperListener *listener,
                 NBChromiumView *source_view)
      : listener_(listener) {
    session_ = [[NBEyeDropperSession alloc] initWithOwner:this
                                              webContents:contents
                                               sourceView:source_view];
  }

  ~NousEyeDropper() override {
    if (session_) {
      NBEyeDropperSession *session = session_;
      session_ = nil;
      [session invalidateFromEngine];
    }
  }

  NBEyeDropperSession *session() const { return session_; }

  void DetachSession() { session_ = nil; }

  void NotifySelected(SkColor color) {
    if (!listener_) return;
    content::EyeDropperListener *listener = listener_;
    listener_ = nullptr;
    session_ = nil;
    // Note: ColorSelected synchronously destroys `this`.
    listener->ColorSelected(color);
  }

  void NotifyCanceled() {
    if (!listener_) return;
    content::EyeDropperListener *listener = listener_;
    listener_ = nullptr;
    session_ = nil;
    // Note: ColorSelectionCanceled synchronously destroys `this`.
    listener->ColorSelectionCanceled();
  }

 private:
  raw_ptr<content::EyeDropperListener> listener_;
  NBEyeDropperSession *__strong session_;
};

}  // namespace

@implementation NBEyeDropperSession {
  raw_ptr<NousEyeDropper> _owner;
  base::WeakPtr<content::WebContents> _contents;
  __weak NBChromiumView *_sourceView;
  BOOL _finished;
}

@synthesize cancelHandler = _cancelHandler;

- (instancetype)initWithOwner:(NousEyeDropper *)owner
                  webContents:(content::WebContents *)contents
                   sourceView:(NBChromiumView *)sourceView {
  if ((self = [super init])) {
    _owner = owner;
    _contents = contents ? contents->GetWeakPtr() : nullptr;
    _sourceView = sourceView;
  }
  return self;
}

- (NBChromiumView *)sourceView {
  return _sourceView;
}

- (NSWindow *)sourceWindow {
  if (_contents) {
    if (NSWindow *window = nous::WindowForWebContents(_contents.get())) {
      return window;
    }
  }
  return _sourceView.window;
}

- (BOOL)isFinished {
  return _finished;
}

- (void)capturePageSnapshot:(void (^)(NSBitmapImageRep * _Nullable, NSRect))completion {
  if (!completion) return;
  if (_finished || !_contents) {
    completion(nil, NSZeroRect);
    return;
  }
  content::WebContents *contents = _contents.get();
  content::RenderWidgetHostView *rwhv = contents->GetRenderWidgetHostView();
  NSView *nativeView = contents->GetNativeView().GetNativeNSView();
  NSWindow *window = nativeView.window;
  if (!rwhv || !nativeView || !window) {
    completion(nil, NSZeroRect);
    return;
  }
  const NSRect viewInWindow = [nativeView convertRect:nativeView.bounds toView:nil];
  const NSRect screenRect = [window convertRectToScreen:viewInWindow];
  if (NSIsEmptyRect(screenRect)) {
    completion(nil, NSZeroRect);
    return;
  }

  void (^callback)(NSBitmapImageRep * _Nullable, NSRect) = [completion copy];
  rwhv->CopyFromSurface(
      gfx::Rect(), gfx::Size(), base::Milliseconds(500),
      base::BindOnce(
          [](void (^done)(NSBitmapImageRep * _Nullable, NSRect), NSRect rect,
             const content::CopyFromSurfaceResult &result) {
            SkBitmap bitmap;
            if (result.has_value()) {
              bitmap = result->bitmap;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
              if (bitmap.drawsNothing()) {
                done(nil, NSZeroRect);
                return;
              }
              NSBitmapImageRep *rep = skia::SkBitmapToNSBitmapImageRep(bitmap);
              done(rep, rep ? rect : NSZeroRect);
            });
          },
          callback, screenRect));
}

- (void)selectRed:(uint8_t)red green:(uint8_t)green blue:(uint8_t)blue {
  if (_finished) return;
  _finished = YES;
  _cancelHandler = nil;
  NousEyeDropper *owner = _owner;
  _owner = nullptr;
  if (owner) {
    owner->DetachSession();
    owner->NotifySelected(SkColorSetRGB(red, green, blue));
  }
}

- (void)cancel {
  if (_finished) return;
  _finished = YES;
  _cancelHandler = nil;
  NousEyeDropper *owner = _owner;
  _owner = nullptr;
  if (owner) {
    owner->DetachSession();
    owner->NotifyCanceled();
  }
}

- (void)invalidateFromEngine {
  if (_finished) return;
  _finished = YES;
  _owner = nullptr;
  void (^handler)(void) = _cancelHandler;
  _cancelHandler = nil;
  if (handler) handler();
}

@end

@implementation NBEyeDropperCenter

@synthesize sessionHandler = _sessionHandler;

+ (instancetype)sharedCenter {
  static NBEyeDropperCenter *center;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    center = [[NBEyeDropperCenter alloc] init];
  });
  return center;
}

@end

namespace nous {

std::unique_ptr<content::EyeDropper> OpenEyeDropper(
    content::RenderFrameHost *frame,
    content::EyeDropperListener *listener,
    NBChromiumView *source_view) {
  if (!frame || !listener) return nullptr;
  void (^handler)(NBEyeDropperSession *) = [NBEyeDropperCenter sharedCenter].sessionHandler;
  if (!handler) return nullptr;

  content::WebContents *contents = content::WebContents::FromRenderFrameHost(frame);
  if (!contents) return nullptr;

  auto dropper = std::make_unique<NousEyeDropper>(contents, listener, source_view);
  NBEyeDropperSession *session = dropper->session();
  // Defer presenting the host picker by one turn so EyeDropperChooserImpl has
  // already stored the returned unique_ptr before any synchronous cancel/select.
  dispatch_async(dispatch_get_main_queue(), ^{
    if (!session.isFinished) {
      handler(session);
    }
  });
  return dropper;
}

}  // namespace nous
