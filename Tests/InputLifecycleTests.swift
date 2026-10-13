import AppKit
import PDFKit
import Darwin

/// No native monitor is installed; events are objects passed to a private sink.
/// Windows stay hidden, NSApplication.run/sendEvent/CGEventPost are never used.
private final class FakeEvents {
    var callback: WindowInputScope.Handler?
    var retired: WindowInputScope.Handler?
    var installed = 0
    var removed = 0
    var mask: NSEvent.EventTypeMask = []
    func install(_ mask: NSEvent.EventTypeMask, _ handler: @escaping WindowInputScope.Handler) -> Any? {
        installed += 1; self.mask = mask; callback = handler; return installed
    }
    func remove(_ token: Any) { removed += 1; retired = callback; callback = nil }
}

@main enum InputLifecycleTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        guard condition() else { fatalError("FAIL: " + label) }
        checks += 1; print("PASS: " + label)
    }
    static func key(_ type: NSEvent.EventType, code: UInt16 = 49, repeat repeated: Bool = false, window: Int = 0) -> NSEvent {
        NSEvent.keyEvent(with:type, location:.zero, modifierFlags:[], timestamp:1,
                        windowNumber:window, context:nil, characters:code == 49 ? " " : "\u{1b}",
                        charactersIgnoringModifiers:code == 49 ? " " : "\u{1b}", isARepeat:repeated, keyCode:code)!
    }
    static func routing() {
        let bus = FakeEvents(); var commands = 0; var commandOpen = true
        var scope: WindowInputScope? = WindowInputScope(install:bus.install, remove:bus.remove,
            belongs:{$0.windowNumber == 0}, handle:{ event in
                guard event.type == .keyDown, event.keyCode == 53, commandOpen else { return false }
                commands += 1; commandOpen = false; return true
            })
        check(bus.mask.contains(.keyUp), "local command monitor receives release events")
        let down = key(.keyDown), up = key(.keyUp)
        check(bus.callback!(down) === down && bus.callback!(up) === up, "Space down/up pass unchanged")
        let repeatSpace = key(.keyDown, repeat:true)
        check((0..<1000).allSatisfy { _ in bus.callback!(repeatSpace) === repeatSpace }, "1000 repeated Spaces stay unchanged; no synthesized input")
        check(commands == 0, "Space never invokes a document shortcut")
        let escape = key(.keyDown, code:53)
        check(bus.callback!(escape) == nil && commands == 1, "one Escape performs one local dismissal")
        check((0..<1000).allSatisfy { _ in bus.callback!(key(.keyDown, code:53, repeat:true)) == nil } && commands == 1,
              "held command repeats do not cascade into other actions")
        check(bus.callback!(key(.keyUp,code:53)) == nil, "handled command up is paired locally")
        let nativeEscape = key(.keyDown,code:53)
        check(bus.callback!(nativeEscape) === nativeEscape, "unhandled Escape remains available to native text/IME")
        commandOpen = true; _ = bus.callback!(escape); scope?.lostFocus()
        let release = key(.keyUp,code:53)
        check(bus.callback!(release) === release, "focus loss forgets only local routing state")
        let otherWindow = key(.keyDown,code:53,window:999)
        check(bus.callback!(otherWindow) === otherWindow, "other windows are never intercepted")
        scope?.stop(); scope?.stop()
        check(bus.removed == 1 && bus.callback == nil, "close removes monitor exactly once")
        check(bus.retired!(down) === down, "a late callback after close cannot consume or create input")
        scope = nil; check(bus.removed == 1, "deinit after explicit cleanup remains idempotent")
        var restarted: WindowInputScope? = WindowInputScope(install:bus.install,remove:bus.remove,belongs:{_ in true},handle:{_ in false})
        check(bus.installed == 2 && bus.callback!(down) === down, "reopen installs one fresh scope with no held state")
        restarted = nil; check(bus.removed == 2, "unexpected controller disposal removes its monitor")
        withExtendedLifetime(restarted) {}
    }
    static func mouse(_ reader: ReaderWindow, _ type: NSEvent.EventType, _ p: CGPoint) {
        let page = reader.session.document.page(at:0)!
        let point = reader.pdfView.convert(reader.pdfView.convert(p,from:page),to:nil)
        let event = NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:1,
                    windowNumber:reader.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        if type == .leftMouseDown { reader.canvas.mouseDown(with:event) }
        else if type == .leftMouseDragged { reader.canvas.mouseDragged(with:event) }
        else { reader.canvas.mouseUp(with:event) }
    }
    static func readerLifecycle(_ dir: URL) throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let delegate = AppDelegate(); AppDelegate.shared = delegate
        let url = dir.appendingPathComponent("fixture.pdf")
        let doc = PDFDocument(); let page = PDFPage(); page.setBounds(CGRect(x:0,y:0,width:612,height:792),for:.mediaBox)
        doc.insert(page,at:0); check(doc.write(to:url), "isolated PDF fixture created")
        let original = try Data(contentsOf:url)
        let session = try DocumentSession.open(url:url); let bus = FakeEvents()
        let reader = ReaderWindow(session:session,installInputMonitor:bus.install,removeInputMonitor:bus.remove)
        delegate.readers = [reader]
        reader.pdfView.autoScales = false; reader.pdfView.scaleFactor = 0.8; reader.pdfView.layoutDocumentView()
        check(!reader.window!.isVisible, "native PDF reader stays hidden and never activates")
        let down = key(.keyDown,window:reader.window!.windowNumber), up = key(.keyUp,window:reader.window!.windowNumber)
        check(bus.callback!(down) === down && bus.callback!(up) === up, "real reader routing preserves Space pair")
        reader.canvas.setTool(.pen)
        let previousCoalescing = NSEvent.isMouseCoalescingEnabled
        mouse(reader,.leftMouseDown,CGPoint(x:100,y:400)); mouse(reader,.leftMouseUp,CGPoint(x:100,y:400))
        check(!reader.canvas.gesture && NSEvent.isMouseCoalescingEnabled == previousCoalescing,
              "normal pen release restores coalescing without a keyboard event")
        session.undo()
        // Exercise the shipped canvas -> path -> session route through a
        // hidden reader and private callbacks only; never send/post events.
        let responsiveSamples=[CGPoint(x:100,y:400),CGPoint(x:101,y:400),CGPoint(x:102,y:401),CGPoint(x:103,y:401.5),CGPoint(x:103,y:402),CGPoint(x:102.5,y:401.5),CGPoint(x:102,y:401)]
        mouse(reader,.leftMouseDown,responsiveSamples[0])
        for p in responsiveSamples.dropFirst() {mouse(reader,.leftMouseDragged,p)}
        let forming=reader.canvas.activeInkStroke!
        check(forming.isValid && hypot(forming.points.last!.x-responsiveSamples.last!.x,forming.points.last!.y-responsiveSamples.last!.y)<1e-7 &&
              forming.points.map(\.x).max()! > 102.8 && forming.points.map(\.y).max()! > 401.7,
              "hidden native canvas retains short return-hook extent and exact live tip")
        mouse(reader,.leftMouseUp,responsiveSamples.last!)
        check(forming.points.allSatisfy {session.inkStrokes(on:session.document.page(at:0)!).last!.points.contains($0)},
              "native mouse-up preserves the written trajectory while completing the nib")
        check(NSEvent.isMouseCoalescingEnabled == previousCoalescing && !reader.canvas.gesture,
              "responsive curve release restores the existing input lease")
        session.undo()
        check(session.inkStrokes(on:session.document.page(at:0)!).isEmpty,
              "responsive native input remains one complete undo action")
        mouse(reader,.leftMouseDown,CGPoint(x:120,y:400)); mouse(reader,.leftMouseDragged,CGPoint(x:140,y:405))
        check(reader.canvas.gesture && !NSEvent.isMouseCoalescingEnabled, "pen action acquires its coalescing setting")
        reader.selectTool(.eraser); reader.openSearch()
        check(reader.canvas.gesture && reader.canvas.tool == .pen && !reader.searchVisible,
              "held pen rejects tool changes and search without prematurely committing")
        reader.canvas.keyDown(with:key(.keyDown,code:53,window:reader.window!.windowNumber))
        check(!reader.canvas.gesture && reader.canvas.activePage == nil && NSEvent.isMouseCoalescingEnabled == previousCoalescing,
              "Escape closes actual pen transaction and restores coalescing")
        let storedPage = session.document.page(at:0)!
        check(session.inkStrokes(on:storedPage).count == 1 && session.canUndo, "interrupted received ink is preserved in one undo action")
        reader.canvas.finishInterruptedInput(); session.undo()
        check(session.inkStrokes(on:storedPage).isEmpty && session.canRedo, "repeated cleanup creates no duplicate undo entry")
        session.redo(); check(session.inkStrokes(on:storedPage).count == 1, "redo restores received geometry")
        mouse(reader,.leftMouseDown,CGPoint(x:150,y:400)); mouse(reader,.leftMouseDown,CGPoint(x:155,y:400))
        reader.canvas.finishInterruptedInput()
        check(NSEvent.isMouseCoalescingEnabled == previousCoalescing && session.inkStrokes(on:storedPage).count == 3,
              "duplicate down without up preserves both actions and original coalescing setting")
        mouse(reader,.leftMouseDown,CGPoint(x:170,y:400))
        delegate.applicationDidResignActive(Notification(name:NSApplication.didResignActiveNotification))
        check(!reader.canvas.gesture && NSEvent.isMouseCoalescingEnabled == previousCoalescing && bus.removed == 0,
              "app focus loss ends pen but leaves live window routing installed")
        mouse(reader,.leftMouseDown,CGPoint(x:200,y:400))
        delegate.applicationWillTerminate(Notification(name:NSApplication.willTerminateNotification))
        check(reader.disconnected && bus.removed == 1 && !reader.canvas.gesture && NSEvent.isMouseCoalescingEnabled == previousCoalescing,
              "real app termination disconnects retained reader and restores input settings")
        check(session.onChange == nil && session.onInkChange == nil && session.onHistoryNote == nil,
              "termination detaches session callbacks")
        check(session.recoverableRecord != nil, "unsaved content retains isolated recovery protection")
        reader.disconnectInputAndViews(); check(bus.removed == 1, "termination/close cleanup is idempotent")
        let after = try Data(contentsOf:url)
        check(after == original, "input cleanup never writes source PDF")
        let reopened = try DocumentSession.open(url:url)
        let nextBus = FakeEvents()
        let next = ReaderWindow(session:reopened,installInputMonitor:nextBus.install,removeInputMonitor:nextBus.remove)
        check(!next.disconnected && nextBus.installed == 1, "new reader starts with fresh input lifetime")
        // Close while the controller remains retained; deinit must not be required.
        next.windowWillClose(Notification(name:NSWindow.willCloseNotification,object:next.window))
        check(next.disconnected && nextBus.removed == 1, "window close immediately removes monitor on retained controller")
        let until = Date().addingTimeInterval(0.03)
        while Date() < until { RunLoop.current.run(until:Date().addingTimeInterval(0.005)) }
        check(reader.disconnected && next.disconnected && !reader.window!.isVisible && !next.window!.isVisible,
              "queued initialization cannot revive a closed/terminated reader")
        delegate.readers = []
    }
    static func abruptExit(_ dir:URL) throws {
        let ready = dir.appendingPathComponent("child-ready")
        let child = Process(); child.executableURL = URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--fake-source-crash",ready.path]
        let input = Pipe(); child.standardInput = input; child.standardOutput = Pipe(); child.standardError = Pipe()
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath:ready.path) && child.isRunning && Date()<deadline { Thread.sleep(forTimeInterval:0.005) }
        check(FileManager.default.fileExists(atPath:ready.path), "isolated child installs only fake event source")
        check(kill(child.processIdentifier,SIGKILL) == 0, "forced exit kills only the isolated test child")
        child.waitUntilExit()
        check(child.terminationReason == .uncaughtSignal, "forced exit does not rely on deinit or key-up cleanup")
        let bus = FakeEvents(); let fresh = WindowInputScope(install:bus.install,remove:bus.remove,belongs:{_ in true},handle:{_ in false})
        let space = key(.keyDown)
        check(bus.callback!(space) === space && bus.installed == 1, "fresh lifetime after forced exit has no inherited routing state")
        fresh.stop()
    }
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--fake-source-crash" {
            let bus = FakeEvents(); let scope = WindowInputScope(install:bus.install,remove:bus.remove,belongs:{_ in true},handle:{_ in false})
            try Data("fake event source; no AppKit monitor or posted events".utf8).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
            withExtendedLifetime(scope) { _ = readLine() }; return
        }
        unsetenv("ECRU_COMPAT_TEST"); setenv("LEAFINK_COMPAT_TEST", "legacy", 1)
        check(EcruEnvironment.value("ECRU_COMPAT_TEST") == "legacy", "legacy diagnostic environment remains supported")
        setenv("ECRU_COMPAT_TEST", "current", 1)
        check(EcruEnvironment.value("ECRU_COMPAT_TEST") == "current", "Ecru environment takes precedence without moving user data")
        unsetenv("ECRU_COMPAT_TEST"); unsetenv("LEAFINK_COMPAT_TEST")
        let dir = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/input-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        setenv("ECRU_DATA_DIR",dir.appendingPathComponent("data").path,1)
        routing(); try abruptExit(dir); try readerLifecycle(dir)
        print("\(checks) isolated input checks passed. No system keyboard injection, native monitor, foreground app launch or live fault reproduction.")
    }
}
