import Foundation
import JavaScriptCore
import Testing
import WebKit
@testable import NousBrowser

@Suite("Page navigation shortcut policy", .serialized)
@MainActor
struct BrowserPageNavigationShortcutTests {
    private func messages(path: String = "[new Element('div')]", event: String = "{}",
                          designMode: String = "off", preventedAfterDispatch: Bool = false) throws -> [String] {
        let context = try #require(JSContext())
        // Minimal platform objects let the actual injected listener run as a
        // policy unit test. Real trusted keyboard events are covered by GUI QA.
        context.evaluateScript(#"""
        var pending = [], sent = [], listener;
        function setTimeout(callback) { pending.push(callback); }
        class Element {
            constructor(localName, options = {}) { this.localName = localName; Object.assign(this, options); }
            matches(selector) { return selector.split(',').map(s => s.trim()).includes(this.localName); }
            getAttribute(name) { return name === 'role' ? this.role : null; }
        }
        var document = { designMode: 'off' };
        var window = { addEventListener(name, callback) { if (name === 'keydown') listener = callback; },
            webkit: { messageHandlers: { nousHistoryNavigation: { postMessage(body) { sent.push(body); } } } } };
        """#)
        context.evaluateScript(BrowserPageNavigationShortcuts.source)
        try #require(context.exception == nil)
        let script = """
        document.designMode = '\(designMode)';
        const path = \(path);
        const event = Object.assign({ isTrusted: true, metaKey: true, ctrlKey: false, altKey: false,
            shiftKey: false, isComposing: false, defaultPrevented: false, key: 'ArrowLeft',
            target: path[0], composedPath() { return path; },
            preventDefault() { throw new Error('The navigation listener canceled default editing'); },
            stopPropagation() { throw new Error('The navigation listener stopped event propagation'); }
        }, \(event));
        listener(event);
        if (\(preventedAfterDispatch ? "true" : "false")) event.defaultPrevented = true;
        while (pending.length) pending.shift()();
        sent;
        """
        let result = context.evaluateScript(script)
        try #require(context.exception == nil)
        return try #require(result?.toArray() as? [String])
    }

    @Test func plainPageDirectionsAreTheOnlyMessagePayload() throws {
        #expect(try messages() == ["back"])
        #expect(try messages(event: "{key: 'ArrowRight'}") == ["forward"])
        #expect(BrowserPageNavigationShortcuts.direction(from: "back") == .back)
        #expect(BrowserPageNavigationShortcuts.direction(from: "forward") == .forward)
        let invalidBodies: [Any] = ["BACK", "left", "", 1, ["direction": "back"], ["back"]]
        for body in invalidBodies {
            #expect(BrowserPageNavigationShortcuts.direction(from: body) == nil)
        }
    }

    @Test func syntheticModifiedComposingAndClaimedEventsAreIgnored() throws {
        for event in ["{isTrusted: false}", "{metaKey: false}", "{ctrlKey: true}", "{altKey: true}",
                      "{shiftKey: true}", "{isComposing: true}", "{defaultPrevented: true}", "{key: 'ArrowUp'}"] {
            #expect(try messages(event: event).isEmpty)
        }
        #expect(try messages(preventedAfterDispatch: true).isEmpty)
    }

    @Test func formControlsAndEditablePathsKeepTheirNativeBehavior() throws {
        for path in ["[new Element('input')]", "[new Element('textarea')]", "[new Element('select')]",
                     "[new Element('input', {readOnly: true})]",
                     "[new Element('span'), new Element('div', {isContentEditable: true})]",
                     "[new Element('div', {role: 'textbox'})]", "[new Element('div', {role: 'combobox'})]",
                     "[new Element('input'), new Element('open-editor', {shadowRoot: {}})]",
                     "[new Element('closed-editor')]"] {
            #expect(try messages(path: path).isEmpty)
        }
        #expect(try messages(designMode: "on").isEmpty)
        #expect(try messages(path: "[new Element('open-panel', {shadowRoot: {}})]") == ["back"])
    }

    @Test func installingInheritedPopupConfigurationDoesNotDuplicateTheListener() throws {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(WKUserScript(source: "window.fixtureMarker = true;",
                                                                         injectionTime: .atDocumentEnd,
                                                                         forMainFrameOnly: true))
        BrowserPageNavigationShortcuts.install(in: configuration)
        BrowserPageNavigationShortcuts.install(in: configuration)
        let inherited = try #require(configuration.copy() as? WKWebViewConfiguration)
        BrowserPageNavigationShortcuts.install(in: inherited)
        #expect(configuration.userContentController === inherited.userContentController)
        let scripts = configuration.userContentController.userScripts
        #expect(scripts.count == 2)
        let listener = try #require(scripts.first { $0.source.contains("nous-browser-history-shortcuts-v1") })
        #expect(listener.injectionTime == .atDocumentStart)
        #expect(!listener.isForMainFrameOnly)
    }

    @Test func sharedControllerRoutesByWebViewAndOneInvalidationLeavesItsPeerAttached() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        BrowserPageNavigationShortcuts.install(in: configuration)
        let first = WKWebView(frame: .zero, configuration: configuration)
        let second = WKWebView(frame: .zero, configuration: configuration)
        var firstDirections: [BrowserNavigationShortcuts.Direction] = []
        var secondDirections: [BrowserNavigationShortcuts.Direction] = []
        let firstAttachment = BrowserPageNavigationShortcuts.attach(to: first) { firstDirections.append($0) }
        let secondAttachment = BrowserPageNavigationShortcuts.attach(to: second) { secondDirections.append($0) }
        defer {
            firstAttachment.invalidate()
            secondAttachment.invalidate()
            first.stopLoading()
            second.stopLoading()
        }
        first.loadHTMLString("<!doctype html><title>First local fixture</title>", baseURL: nil)
        second.loadHTMLString("<!doctype html><title>Second local fixture</title>", baseURL: nil)
        try await waitUntil { first.url != nil && second.url != nil && !first.isLoading && !second.isLoading }
        _ = try await first.evaluateJavaScript("window.webkit.messageHandlers.nousHistoryNavigation.postMessage('back'); true;",
                                               in: nil, contentWorld: BrowserPageNavigationShortcuts.world)
        try await waitUntil { firstDirections == [.back] }
        #expect(secondDirections.isEmpty)
        firstAttachment.invalidate()
        _ = try await second.evaluateJavaScript("window.webkit.messageHandlers.nousHistoryNavigation.postMessage('forward'); true;",
                                                in: nil, contentWorld: BrowserPageNavigationShortcuts.world)
        try await waitUntil { secondDirections == [.forward] }
        _ = try await first.evaluateJavaScript("window.webkit.messageHandlers.nousHistoryNavigation.postMessage('forward'); true;",
                                               in: nil, contentWorld: BrowserPageNavigationShortcuts.world)
        try await Task.sleep(for: .milliseconds(50))
        #expect(firstDirections == [.back])
        #expect(secondDirections == [.forward])
        let pageHandler = try await second.evaluateJavaScript("typeof window.webkit?.messageHandlers?.nousHistoryNavigation")
        #expect(pageHandler as? String == "undefined")
        secondAttachment.invalidate()
        // The final removal must permit a fresh attachment with the same
        // handler name, without reviving either invalidated receiver.
        var replacementDirections: [BrowserNavigationShortcuts.Direction] = []
        let replacement = BrowserPageNavigationShortcuts.attach(to: second) { replacementDirections.append($0) }
        defer { replacement.invalidate() }
        _ = try await second.evaluateJavaScript("window.webkit.messageHandlers.nousHistoryNavigation.postMessage('back'); true;",
                                                in: nil, contentWorld: BrowserPageNavigationShortcuts.world)
        try await waitUntil { replacementDirections == [.back] }
        #expect(firstDirections == [.back])
        #expect(secondDirections == [.forward])
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<150 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition(), "The local WebKit bridge did not finish its operation")
    }
}
