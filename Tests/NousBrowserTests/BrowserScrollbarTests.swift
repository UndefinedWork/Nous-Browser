import Foundation
import Testing
import WebKit
@testable import NousBrowser

@Suite("Scrollbar discovery", .serialized)
@MainActor
struct BrowserScrollbarTests {
    @Test func editorDOMChurnCoalescesShadowDiscovery() async throws {
        let fixture = Fixture()
        defer { fixture.view.stopLoading() }
        try await fixture.load()
        _ = try await fixture.run("""
        const left = document.createElement('section'), right = document.createElement('section');
        document.body.append(left, right);
        const tree = document.createElement('div'); tree.id = 'churn';
        for (let i = 0; i < 600; i++) tree.appendChild(document.createElement('span'));
        left.append(tree); globalThis.churnParents = [left, right];
        return true;
        """)
        try await Task.sleep(for: .milliseconds(300))
        _ = try await fixture.run("""
        globalThis.shadowReads = 0;
        for (let i = 0; i < 40; i++) {
            globalThis.churnParents[i % 2].append(document.getElementById('churn'));
            await Promise.resolve();
        }
        return true;
        """)
        try await fixture.wait("return globalThis.shadowReads >= 601;")
        let reads = try #require(try await fixture.run("return globalThis.shadowReads;") as? Int)
        print("Scrollbar editor fixture: \(reads) shadow-root checks for 40 moves of 601 elements")
        // Reparenting one editor subtree in separate mutation callbacks must
        // not rescan every descendant once per callback.
        #expect(reads < 2_000)
    }

    @Test func nestedDynamicShadowRootsAndLateAttachmentKeepScrolling() async throws {
        let fixture = Fixture()
        defer { fixture.view.stopLoading() }
        try await fixture.load()
        _ = try await fixture.run("""
        const host = document.createElement('div'); host.id = 'host';
        const root = host.attachShadow({mode: 'open'});
        root.innerHTML = '<div id="nested"></div>';
        const nested = root.getElementById('nested').attachShadow({mode: 'open'});
        nested.innerHTML = '<div id="scroll" style="height:40px;overflow:auto"><div style="height:400px">Content</div></div>';
        document.body.append(host);
        return true;
        """)
        try await fixture.wait("const scroll=document.getElementById('host').shadowRoot.getElementById('nested').shadowRoot.getElementById('scroll'); return getComputedStyle(scroll).scrollbarWidth === 'none';")
        #expect(try await fixture.run("const scroll=document.getElementById('host').shadowRoot.getElementById('nested').shadowRoot.getElementById('scroll'); scroll.scrollTop=120; return scroll.scrollTop;") as? Int == 120)
        _ = try await fixture.run("const late=document.createElement('div'); late.id='late'; document.body.append(late); return true;")
        try await Task.sleep(for: .milliseconds(250))
        _ = try await fixture.run("""
        const root=document.getElementById('late').attachShadow({mode:'open'});
        root.innerHTML='<div id="scroll" style="height:40px;overflow:auto"><div style="height:400px">Late</div></div>';
        root.getElementById('scroll').dispatchEvent(new Event('pointerover', {bubbles:true, composed:true}));
        return true;
        """)
        try await fixture.wait("return getComputedStyle(document.getElementById('late').shadowRoot.getElementById('scroll')).scrollbarWidth === 'none';")
        _ = try await fixture.run("""
        const root=document.getElementById('late').shadowRoot;
        root.adoptedStyleSheets=[];
        root.getElementById('scroll').dispatchEvent(new Event('wheel', {bubbles:true, composed:true}));
        return true;
        """)
        try await fixture.wait("return getComputedStyle(document.getElementById('late').shadowRoot.getElementById('scroll')).scrollbarWidth === 'none';")
    }

    @Test func textEditsDoNotTraverseAndNestedInsertionsAreVisitedOnce() async throws {
        let fixture = Fixture()
        defer { fixture.view.stopLoading() }
        try await fixture.load()
        try await Task.sleep(for: .milliseconds(200))
        _ = try await fixture.run("""
        globalThis.shadowReads=0;
        const parent=document.createElement('div'); parent.id='parent'; document.body.append(parent);
        for (let i=0;i<600;i++) parent.append(document.createElement('span'));
        return true;
        """)
        try await fixture.wait("return globalThis.shadowReads >= 601;")
        let insertReads = try #require(try await fixture.run("return globalThis.shadowReads;") as? Int)
        #expect(insertReads == 601)
        _ = try await fixture.run("""
        globalThis.shadowReads=0;
        const parent=document.getElementById('parent');
        for (let i=0;i<40;i++) {
            parent.firstElementChild.textContent='Text '+i;
            parent.className='editing-'+i;
            await Promise.resolve();
        }
        return true;
        """)
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await fixture.run("return globalThis.shadowReads;") as? Int == 0)
    }

    @Test func iframePolicyAndIdempotentInstallationRemainIndependent() async throws {
        let fixture = Fixture()
        defer { fixture.view.stopLoading() }
        BrowserScrollbars.install(in: fixture.view.configuration)
        #expect(fixture.view.configuration.userContentController.userScripts.filter { $0.source.contains("nous-browser-scrollbars-v1") }.count == 1)
        try await fixture.load()
        _ = try await fixture.run("""
        const frame=document.createElement('iframe'); frame.id='frame';
        frame.srcdoc='<div id="scroll" style="height:40px;overflow:auto"><div style="height:400px">Frame</div></div>';
        document.body.append(frame); return true;
        """)
        try await fixture.wait("const frame=document.getElementById('frame'); const element=frame.contentDocument?.getElementById('scroll'); return !!element && frame.contentWindow.getComputedStyle(element).scrollbarWidth === 'none';")
    }

    @MainActor private final class Fixture {
        let view: WKWebView

        init() {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            // Counters live only in the test's isolated content world. The
            // production script contains no instrumentation or prototype edits.
            configuration.userContentController.addUserScript(WKUserScript(source: """
            globalThis.shadowReads = 0;
            const descriptor = Object.getOwnPropertyDescriptor(Element.prototype, 'shadowRoot');
            Object.defineProperty(Element.prototype, 'shadowRoot', {...descriptor, get() {
                globalThis.shadowReads++; return descriptor.get.call(this);
            }});
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
            BrowserScrollbars.install(in: configuration)
            view = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        }

        func load() async throws {
            view.loadHTMLString("<!doctype html><html><head><title>Scrollbar fixture</title></head><body></body></html>", baseURL: URL(string: "https://scrollbar.example.test/"))
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(30))
                if !view.isLoading, view.url != nil { return }
            }
            throw Failure.timeout
        }

        func run(_ source: String) async throws -> Any? {
            try await view.callAsyncJavaScript(source, arguments: [:], in: nil, contentWorld: .defaultClient)
        }

        func wait(_ source: String) async throws {
            for _ in 0..<100 {
                if try await run(source) as? Bool == true { return }
                try await Task.sleep(for: .milliseconds(30))
            }
            throw Failure.timeout
        }
        enum Failure: Error { case timeout }
    }
}
