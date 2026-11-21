// Internal (non-exported) glue shared by //nous/browser translation units.
#ifndef NOUS_BROWSER_NOUS_INTERNAL_H_
#define NOUS_BROWSER_NOUS_INTERNAL_H_

#import <AppKit/AppKit.h>

@class NBChromiumView;

class Profile;
namespace content {
class WebContents;
}

namespace nous {
// The profile regular Nous tabs use (Chromium's "Default" profile in the
// configured --user-data-dir). Null before the browser process is ready.
Profile* GetProfile();
// Null outside an active, explicitly started private browsing session.
Profile* GetPrivateProfile();
// The NSWindow that hosts (or will host) a Nous tab's page.
NSWindow* WindowForWebContents(content::WebContents* contents);
content::WebContents* WebContentsForView(NBChromiumView* view);
// Replace Chrome's download target step with the Nous host flow.
void InstallDownloadDelegate(Profile* profile);
// Chrome UI singletons (JS dialogs, permission prompts) routed to Nous tabs.
void InstallTabServices();
// Destroys every remaining Nous page before Chromium tears down profiles.
void CloseAllTabs();
}  // namespace nous

// Friend of TabHelpers (see patches/chromium): attaches Chrome's full set of
// per-tab features (password manager, autofill, find, favicon, zoom, content
// settings, safe browsing, permissions...) to a Nous-owned WebContents.
class NousTabHelpersAttacher {
 public:
  static void Attach(content::WebContents* contents);
};

#endif  // NOUS_BROWSER_NOUS_INTERNAL_H_
