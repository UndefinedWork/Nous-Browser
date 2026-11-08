#pragma once

#import <AppKit/AppKit.h>

// Navigation can retain webpage focus, but may not reclaim it from host UI
// while an initial/deferred navigation finishes. Explicit SetFocus (including
// tab selection and address submission) keeps the existing system-focus path.
static inline BOOL NBChromiumShouldCancelFocus(NSView *page, BOOL closed,
                                               BOOL activeInWindow, BOOL navigation) {
    NSWindow *window=page.window;
    if (!page || closed || !activeInWindow || page.isHiddenOrHasHiddenAncestor || !window.isKeyWindow)
        return YES;
    if (!navigation) return NO;

    NSResponder *responder=window.firstResponder;
    if (!responder || responder==window || responder==page) return NO;
    // A host NSTextField's shared NSTextView field editor need not be a child
    // of that field. Checking the webpage's subtree preserves either shape.
    return ![responder isKindOfClass:NSView.class] || ![(NSView *)responder isDescendantOf:page];
}
