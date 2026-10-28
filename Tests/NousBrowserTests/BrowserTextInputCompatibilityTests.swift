import Testing
import WebKit
@testable import NousBrowser

/// Exercises capture/propagation between isolated and page worlds in real
/// WebKit. Synthetic DOM keyboard events are not native IME acceptance evidence.
@Suite("Zoom Slides IME Return compatibility", .serialized)
@MainActor
struct BrowserTextInputCompatibilityTests {
    @Test func configurePreservesScriptsAndDoesNotDuplicateInheritedListener() throws {
        let configuration = WKWebViewConfiguration()
        let store = WKWebsiteDataStore.nonPersistent()
        configuration.websiteDataStore = store
        let existing = WKUserScript(source: "window.existing = true", injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        configuration.userContentController.addUserScript(existing)
        BrowserTextInputCompatibility.configure(configuration)
        BrowserTextInputCompatibility.configure(configuration)
        let popup = try #require(configuration.copy() as? WKWebViewConfiguration)
        BrowserTextInputCompatibility.configure(popup)
        #expect(configuration.websiteDataStore === store)
        #expect(configuration.userContentController.userScripts.count == 2)
        #expect(popup.userContentController.userScripts.count == 2)
        #expect(configuration.userContentController.userScripts[0].source == existing.source)
        let listener = configuration.userContentController.userScripts[1]
        #expect(listener.injectionTime == .atDocumentStart)
        #expect(!listener.isForMainFrameOnly)
    }

    @Test func lateLegacyCommitDoesNotBecomeCanvasNewlineAndNextReturnStillWorks() async throws {
        for guarded in [false, true] {
            let view = try await makeView(guarded: guarded)
            defer { view.stopLoading() }
            let result = try await evaluate(view, #"""
            (() => {
                const target = document.getElementById('canvas');
                let ended = 0, newlines = 0, elapsed = 0;
                target.addEventListener('compositionend', () => {
                    ended = performance.now();
                    // Zoom records this time before synchronous text/layout work.
                    while (performance.now() - ended < 100) {}
                });
                target.addEventListener('keydown', event => {
                    elapsed = performance.now() - ended;
                    if (elapsed < 50) return;
                    if (event.key === 'Enter') newlines++;
                });
                target.dispatchEvent(new CompositionEvent('compositionend', { bubbles: true, data: 'hello' }));
                const commit = send('canvas', 'keydown', {key: 'Enter', code: 'Enter', keyCode: 229});
                const press = send('canvas', 'keypress', {key: 'Enter', code: 'Enter', keyCode: 13});
                const release = send('canvas', 'keyup', {key: 'Enter', code: 'Enter', keyCode: 13});
                const afterCommit = { newlines, events: events.map(e => e.type), defaults: [commit, press, release] };
                events.length = 0;
                send('canvas', 'keydown', {key: 'Enter', code: 'Enter', keyCode: 13});
                send('canvas', 'keypress', {key: 'Enter', code: 'Enter', keyCode: 13});
                send('canvas', 'keyup', {key: 'Enter', code: 'Enter', keyCode: 13});
                return {afterCommit, newlines, elapsed, nextEvents: events.map(e => e.type)};
            })()
            """#)
            let committed = try #require(result["afterCommit"] as? [String: Any])
            #expect(committed["newlines"] as? Int == (guarded ? 0 : 1))
            #expect(committed["events"] as? [String] == (guarded ? [] : ["keydown", "keypress", "keyup"]))
            #expect(committed["defaults"] as? [Bool] == [false, false, false])
            #expect(result["newlines"] as? Int == (guarded ? 1 : 2))
            #expect((result["elapsed"] as? Double ?? 0) >= 100)
            #expect(result["nextEvents"] as? [String] == ["keydown", "keypress", "keyup"])
        }
    }

    @Test func modernCompositionAndHeldRepeatAreSuppressedUntilRelease() async throws {
        let view = try await makeView()
        defer { view.stopLoading() }
        let result = try await evaluate(view, #"""
        (() => {
            const defaults = [];
            defaults.push(send('canvas','keydown',{key:'Enter',code:'NumpadEnter',keyCode:13,isComposing:true}));
            defaults.push(send('canvas','keydown',{key:'Enter',code:'NumpadEnter',keyCode:13,repeat:true}));
            defaults.push(send('canvas','keypress',{key:'Enter',code:'NumpadEnter',keyCode:13}));
            defaults.push(send('canvas','keyup',{key:'Enter',code:'NumpadEnter',keyCode:13}));
            const confirmed = events.length;
            send('canvas','keydown',{key:'Enter',code:'NumpadEnter',keyCode:13});
            return {defaults,confirmed,events};
        })()
        """#)
        #expect(result["defaults"] as? [Bool] == [false, false, false, false])
        #expect(result["confirmed"] as? Int == 0)
        #expect((result["events"] as? [[String: Any]])?.count == 1)
    }

    @Test func missingReleaseFocusChangeAndDifferentTargetDoNotSwallowNextReturn() async throws {
        let view = try await makeView()
        defer { view.stopLoading() }
        let result = try await evaluate(view, #"""
        (() => {
            send('canvas','keydown',{key:'Enter',code:'Enter',keyCode:229});
            send('canvas','keydown',{key:'Enter',code:'Enter',keyCode:13});
            const afterMissingRelease = events.length;
            send('canvas','keydown',{key:'Enter',code:'Enter',keyCode:229});
            send('other','keyup',{key:'Enter',code:'Enter',keyCode:13});
            const afterDifferentTarget = events.length;
            send('canvas','keydown',{key:'Enter',code:'Enter',keyCode:229});
            document.getElementById('canvas').dispatchEvent(new FocusEvent('blur'));
            send('canvas','keyup',{key:'Enter',code:'Enter',keyCode:13});
            const afterBlur = events.length;
            send('canvas','keydown',{key:'Enter',code:'Enter',keyCode:229});
            window.dispatchEvent(new PageTransitionEvent('pagehide'));
            send('canvas','keyup',{key:'Enter',code:'Enter',keyCode:13});
            return {afterMissingRelease,afterDifferentTarget,afterBlur,count:events.length};
        })()
        """#)
        #expect(result["afterMissingRelease"] as? Int == 1)
        #expect(result["afterDifferentTarget"] as? Int == 2)
        #expect(result["afterBlur"] as? Int == 3)
        #expect(result["count"] as? Int == 4)
    }

    @Test func ordinaryCommandsCandidateKeysAndNonEditableControlsPassThrough() async throws {
        let view = try await makeView()
        defer { view.stopLoading() }
        let result = try await evaluate(view, #"""
        (() => {
            const cases = [
                ['canvas',{key:' ',code:'Space',keyCode:229,isComposing:true}],
                ['canvas',{key:'ArrowDown',code:'ArrowDown',keyCode:229,isComposing:true}],
                ['canvas',{key:'a',code:'KeyA',keyCode:229,isComposing:true}],
                ['canvas',{key:'Enter',code:'Enter',keyCode:13,shiftKey:true}],
                ['canvas',{key:'z',code:'KeyZ',keyCode:90,metaKey:true}],
                ['button',{key:'Enter',code:'Enter',keyCode:229}],
                ['check',{key:'Enter',code:'Enter',keyCode:229}]
            ];
            const defaults=cases.map(([id, options]) => send(id,'keydown',options));
            return {defaults,count:events.length};
        })()
        """#)
        #expect(result["count"] as? Int == 7)
        #expect(result["defaults"] as? [Bool] == Array(repeating: false, count: 7))
    }

    @Test func contentEditableAndShadowTextareaReceiveTheSameGuard() async throws {
        let view = try await makeView()
        defer { view.stopLoading() }
        let result = try await evaluate(view, #"""
        (() => {
            send('rich','keydown',{key:'Enter',code:'Enter',keyCode:229});
            send('rich','keyup',{key:'Enter',code:'Enter',keyCode:13});
            const root=document.getElementById('shadow').attachShadow({mode:'open'});
            root.innerHTML='<textarea id="hidden"></textarea>';
            const target=root.querySelector('textarea');
            for (const type of ['keydown','keypress','keyup'])
                target.dispatchEvent(new KeyboardEvent(type,{key:'Enter',code:'Enter',keyCode:type==='keydown'?229:13,bubbles:true,composed:true,cancelable:true}));
            const composing=events.length;
            target.dispatchEvent(new KeyboardEvent('keydown',{key:'Enter',code:'Enter',keyCode:13,bubbles:true,composed:true}));
            return {composing,count:events.length};
        })()
        """#)
        #expect(result["composing"] as? Int == 0)
        #expect(result["count"] as? Int == 1)
    }

    @Test func compositionInputAndSpaceConfirmationStillReachTheEditor() async throws {
        let view = try await makeView()
        defer { view.stopLoading() }
        let result = try await evaluate(view, #"""
        (() => {
            const target = document.getElementById('canvas'), composition = [], defaults = [];
            for (const type of ['compositionstart','compositionupdate','compositionend','beforeinput','input'])
                target.addEventListener(type, event => composition.push({type,data:event.data}));
            for (const type of ['compositionstart','compositionupdate','compositionend']) {
                const event = new CompositionEvent(type,{bubbles:true,cancelable:true,data:'hello'});
                target.dispatchEvent(event); defaults.push(event.defaultPrevented);
            }
            send('canvas','keydown',{key:'Enter',code:'Enter',keyCode:229});
            for (const type of ['beforeinput','input']) {
                const event = new InputEvent(type,{bubbles:true,cancelable:true,inputType:'insertText',data:'hello'});
                target.dispatchEvent(event); defaults.push(event.defaultPrevented);
            }
            send('canvas','keyup',{key:'Enter',code:'Enter',keyCode:13});
            const afterConfirmingReturn = events.length;
            target.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}));
            send('canvas','keydown',{key:' ',code:'Space',keyCode:229,isComposing:true});
            target.dispatchEvent(new CompositionEvent('compositionend',{bubbles:true,data:'你好'}));
            send('canvas','keyup',{key:' ',code:'Space',keyCode:32});
            send('canvas','keydown',{key:'Enter',code:'Enter',keyCode:13});
            return {composition,defaults,afterConfirmingReturn,keys:events.map(e=>e.key)};
        })()
        """#)
        let composition = try #require(result["composition"] as? [[String: Any]])
        #expect(composition.compactMap { $0["type"] as? String } == [
            "compositionstart", "compositionupdate", "compositionend", "beforeinput", "input",
            "compositionstart", "compositionend"
        ])
        #expect(composition[4]["data"] as? String == "hello")
        #expect(composition[6]["data"] as? String == "你好")
        #expect(result["defaults"] as? [Bool] == Array(repeating: false, count: 5))
        #expect(result["afterConfirmingReturn"] as? Int == 0)
        #expect(result["keys"] as? [String] == [" ", " ", "Enter"])
    }

    @Test func guardIsRestrictedToVerifiedDocumentOrigins() async throws {
        let cases = [
            ("https://slides.zoom.us/p/fixture", true),
            ("https://slides.zoom.com/", true),
            ("https://present.zoom.us:443/", true),
            ("https://zoom.us/", false),
            ("https://docs.zoom.us/", false),
            ("https://slides.zoom.us.evil.test/", false),
            ("https://slides.zoom.us:8443/", false),
            ("http://slides.zoom.us/", false)
        ]
        for (address, protected) in cases {
            let view = try await makeView(address: address)
            defer { view.stopLoading() }
            let result = try await evaluate(view, "send('canvas','keydown',{key:'Enter',code:'Enter',keyCode:229}); ({count:events.length})")
            #expect(result["count"] as? Int == (protected ? 0 : 1), Comment(rawValue: address))
        }
    }

    private func makeView(guarded: Bool = true, address: String = "https://slides.zoom.us/p/fixture") async throws -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        if guarded { BrowserTextInputCompatibility.configure(configuration) }
        let view = WKWebView(frame: .zero, configuration: configuration)
        let title = UUID().uuidString
        view.loadHTMLString("<title>\(title)</title>" + Self.fixture, baseURL: try #require(URL(string: address)))
        for _ in 0..<150 {
            if !view.isLoading, view.title == title { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(view.title == title)
        return view
    }

    private func evaluate(_ view: WKWebView, _ script: String) async throws -> [String: Any] {
        try #require(try await view.evaluateJavaScript(script) as? [String: Any])
    }

    private static let fixture = #"""
    <textarea id="canvas"></textarea><input id="other"><div id="rich" contenteditable="true">Text</div>
    <button id="button">Button</button><input id="check" type="checkbox"><div id="shadow"></div>
    <script>
    window.events=[];
    for(const type of ['keydown','keypress','keyup'])
        window.addEventListener(type,event=>events.push({type,key:event.key,target:event.target.id}),true);
    window.send=(id,type,options)=>{
        const event=new KeyboardEvent(type,{bubbles:true,composed:true,cancelable:true,...options});
        document.getElementById(id).dispatchEvent(event);
        return event.defaultPrevented;
    };
    </script>
    """#
}
