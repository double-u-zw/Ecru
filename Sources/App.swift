import AppKit
import PDFKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    static var shared: AppDelegate!
    var readers: [ReaderWindow] = []
    private var openPanel: NSOpenPanel?
    private var openingAtStartup = false
    private var pendingInitialOpen: DispatchWorkItem?
    private var receivedExternalOpen = false
    private var launchFinished = false
    private var appName:String {Bundle.main.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String ?? "Ecru"}
    private var isChinese:Bool {Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? Locale.preferredLanguages.first?.hasPrefix("zh") ?? false}
    private var recentMenu = NSMenu()
    private var menusBuilt = false
    private var quitInProgress = false
    private var quitDiscarded: [ObjectIdentifier:UUID] = [:]
    var activeReader: ReaderWindow? { readers.first { $0.window === NSApp.keyWindow } ?? readers.last }
    func applicationDidFinishLaunching(_ notification:Notification) {
        AppDelegate.shared = self; buildMenus(); NSApp.setActivationPolicy(.regular)
        InkRuntimeReport.install()
        if let iconURL=Bundle.main.url(forResource:Bundle.main.object(forInfoDictionaryKey:"CFBundleIconFile") as? String ?? "EcruIcon",withExtension:"icns"),let icon=NSImage(contentsOf:iconURL) {NSApp.applicationIconImage=icon}
        let args = Array(CommandLine.arguments.dropFirst())
        #if ECRU_UI_TESTS
        if let flagIndex = args.firstIndex(of:"--ui-test"), args.count > flagIndex+2 {
            // Let the initial LaunchServices open event finish granting file access
            // before reading the test document; direct CLI runs also use this path.
            DispatchQueue.main.async {UITestDriver.run(input:URL(fileURLWithPath:args[flagIndex+1]), output:URL(fileURLWithPath:args[flagIndex+2]))}; return
        }
        #endif
        let files = args.filter { !$0.hasPrefix("-") && $0.lowercased().hasSuffix(".pdf") }
        files.forEach { open(URL(fileURLWithPath:$0)) }
        launchFinished=true
        if readers.isEmpty && !receivedExternalOpen {
            let request=DispatchWorkItem { [weak self] in
                guard let self,self.readers.isEmpty,!self.receivedExternalOpen else{return}
                self.presentOpenPanel(atStartup:true)
            }
            pendingInitialOpen=request;DispatchQueue.main.async(execute:request)
        }
        NSApp.activate(ignoringOtherApps:true)
    }
    func application(_ sender:NSApplication,openFiles filenames:[String]) {
        // AppKit can treat positional UI-runner arguments as open-file requests.
        // The runner explicitly opens exactly its input; its output is never a document.
        #if ECRU_UI_TESTS
        if CommandLine.arguments.contains("--ui-test") { sender.reply(toOpenOrPrint:.success); return }
        #endif
        receivedExternalOpen=true;pendingInitialOpen?.cancel();pendingInitialOpen=nil
        if openingAtStartup {openPanel?.cancel(nil)}
        if AppDelegate.shared == nil { AppDelegate.shared = self; buildMenus() }
        filenames.forEach { open(URL(fileURLWithPath:$0)) }; sender.reply(toOpenOrPrint:.success)
    }
    func open(_ url:URL) {
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = readers.first(where: { $0.session.fileURL.resolvingSymlinksInPath() == canonical }) { existing.showWindow(nil); existing.window?.makeKeyAndOrderFront(nil); return }
        if let saving = readers.first(where: { $0.session.savingTarget == canonical }) {
            saving.showNotice("此 PDF 正在作为保存目标写入；完成后再打开，以免产生两份冲突的编辑内容。")
            saving.window?.makeKeyAndOrderFront(nil); return
        }
        do {
            let session = try DocumentSession.open(url:canonical)
            let reader = ReaderWindow(session:session); readers.append(reader)
            reader.didClose = { [weak self, weak reader] in
                self?.readers.removeAll { $0 === reader }
            }
            reader.showWindow(nil); reader.window?.makeKeyAndOrderFront(nil)
            NSDocumentController.shared.noteNewRecentDocumentURL(canonical); refreshRecent()
        } catch {
            let alert = NSAlert(); alert.messageText = "无法安全打开此 PDF"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    @objc private func openDocument() {presentOpenPanel(atStartup:false)}
    private func presentOpenPanel(atStartup:Bool) {
        pendingInitialOpen?.cancel();pendingInitialOpen=nil
        if let panel=openPanel {panel.makeKeyAndOrderFront(nil);return}
        let panel=NSOpenPanel();panel.allowedContentTypes=[.pdf];panel.allowsMultipleSelection=true
        panel.canChooseDirectories=false;panel.resolvesAliases=true
        openingAtStartup=atStartup;openPanel=panel
        panel.begin { [weak self,weak panel] response in
            guard let self,let panel,self.openPanel === panel else{return}
            self.openPanel=nil;self.openingAtStartup=false
            if response == .OK {panel.urls.forEach(self.open)}
        }
    }
    func applicationShouldOpenUntitledFile(_ sender:NSApplication)->Bool {false}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool {false}
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {
        if launchFinished && !flag && readers.isEmpty {presentOpenPanel(atStartup:false)}
        return true
    }
    private func buildMenus() {
        guard !menusBuilt else { return }; menusBuilt = true
        let main = NSMenu(); NSApp.mainMenu = main
        func submenu(_ title:String) -> NSMenu { let entry = NSMenuItem(title:title,action:nil,keyEquivalent:""); main.addItem(entry); let menu = NSMenu(title:title); entry.submenu = menu; return menu }
        func item(_ menu:NSMenu,_ title:String,_ action:Selector,_ key:String = "",shift:Bool = false,target:AnyObject? = nil) {
            let i = NSMenuItem(title:title,action:action,keyEquivalent:key); i.target = target ?? self
            i.keyEquivalentModifierMask = shift ? [.command,.shift] : [.command]; menu.addItem(i)
        }
        let app = submenu(appName)
        item(app,isChinese ? "关于\(appName)" : "About \(appName)",#selector(about))
        app.addItem(.separator())
        let services=NSMenuItem(title:isChinese ? "服务" : "Services",action:nil,keyEquivalent:"")
        services.submenu=NSMenu(title:services.title);app.addItem(services);NSApp.servicesMenu=services.submenu
        app.addItem(.separator())
        item(app,isChinese ? "隐藏\(appName)" : "Hide \(appName)",#selector(NSApplication.hide(_:)),"h",target:NSApp)
        let hideOthers=NSMenuItem(title:isChinese ? "隐藏其他" : "Hide Others",action:#selector(NSApplication.hideOtherApplications(_:)),keyEquivalent:"h")
        hideOthers.target=NSApp;hideOthers.keyEquivalentModifierMask=[.command,.option];app.addItem(hideOthers)
        item(app,isChinese ? "显示全部" : "Show All",#selector(NSApplication.unhideAllApplications(_:)),target:NSApp)
        app.addItem(.separator());item(app,isChinese ? "退出\(appName)" : "Quit \(appName)",#selector(NSApplication.terminate(_:)),"q",target:NSApp)
        let file = submenu("文件"); item(file,"打开 PDF…",#selector(openDocument),"o")
        let recents = NSMenuItem(title:"最近打开",action:nil,keyEquivalent:""); recents.submenu = recentMenu; file.addItem(recents)
        file.addItem(.separator()); item(file,"关闭",#selector(closeDocument),"w"); item(file,"保存",#selector(save),"s"); item(file,"另存为…",#selector(saveAs),"s",shift:true)
        let edit = submenu("编辑"); item(edit,"撤销",#selector(undo),"z"); item(edit,"重做",#selector(redo),"z",shift:true)
        edit.addItem(.separator()); item(edit,"复制",#selector(copySelection),"c")
        let cut = NSMenuItem(title:"剪切",action:#selector(NSText.cut(_:)),keyEquivalent:"x"); edit.addItem(cut)
        let paste = NSMenuItem(title:"粘贴",action:#selector(NSText.paste(_:)),keyEquivalent:"v"); edit.addItem(paste)
        let selectAll = NSMenuItem(title:"全选",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a"); edit.addItem(selectAll)
        item(edit,"查找…",#selector(find),"f")
        let tools = submenu("工具")
        for tool in ReaderTool.allCases {
            let entry = NSMenuItem(title:tool.title,action:#selector(chooseTool(_:)),keyEquivalent:String(tool.rawValue+1))
            entry.target=self; entry.tag=tool.rawValue; entry.keyEquivalentModifierMask=[.command]
            tools.addItem(entry)
        }
        let notes=submenu("批注"); item(notes,"添加批注",#selector(addNote),"n",shift:true)
        item(notes,"查找批注…",#selector(findNotes))
        let view = submenu("显示"); item(view,"显示／收起导航侧栏",#selector(sidebar))
        let window = submenu("窗口"); NSApp.windowsMenu = window
        item(window,"最小化",#selector(NSWindow.performMiniaturize(_:)),"m",target:nil)
        window.items.last?.target=nil
        item(window,"缩放",#selector(NSWindow.performZoom(_:)));window.items.last?.target=nil
        window.addItem(.separator());item(window,"前置全部窗口",#selector(NSApplication.arrangeInFront(_:)),target:NSApp)
        #if ECRU_UI_TESTS
        if EcruEnvironment.value("ECRU_PEN_COMPARE") == "1" {
            let compare=submenu("试写对照")
            item(compare,"旧默认 · e59f4cc",#selector(compareLegacy))
            item(compare,"新稳定器 · 试写候选",#selector(compareObservation))
        }
        #endif
        let help = submenu(isChinese ? "帮助" : "Help")
        item(help,isChinese ? "Ecru 使用说明" : "Ecru User Guide",#selector(openUserGuide))
        item(help,isChinese ? "反馈问题…" : "Report an Issue…",#selector(reportIssue))
        item(help,isChinese ? "第三方许可" : "Third-Party Licenses",#selector(openLicenses))
        NSApp.helpMenu=help
        refreshRecent()
    }
    @objc private func openUserGuide() { NSWorkspace.shared.open(URL(string:"https://github.com/double-u-zw/Ecru#使用方法")!) }
    @objc private func reportIssue() { NSWorkspace.shared.open(URL(string:"https://github.com/double-u-zw/Ecru/issues/new/choose")!) }
    @objc private func openLicenses() {
        if let url=Bundle.main.resourceURL?.appendingPathComponent("Licenses") { NSWorkspace.shared.open(url) }
    }
    private func refreshRecent() {
        recentMenu.removeAllItems()
        for url in NSDocumentController.shared.recentDocumentURLs.prefix(10) { let i = NSMenuItem(title:url.lastPathComponent,action:#selector(openRecent(_:)),keyEquivalent:""); i.representedObject = url; i.target = self; i.toolTip=url.path;recentMenu.addItem(i) }
        if recentMenu.items.isEmpty {let empty=NSMenuItem(title:"无最近文档",action:nil,keyEquivalent:"");empty.isEnabled=false;recentMenu.addItem(empty)}
        else {recentMenu.addItem(.separator());let clear=NSMenuItem(title:"清除菜单",action:#selector(clearRecent),keyEquivalent:"");clear.target=self;recentMenu.addItem(clear)}
    }
    @objc private func openRecent(_ sender:NSMenuItem) { if let url = sender.representedObject as? URL { open(url) } }
    @objc private func clearRecent() {NSDocumentController.shared.clearRecentDocuments(nil);refreshRecent()}
    @objc private func about() {
        let bundle=Bundle.main
        let version=bundle.object(forInfoDictionaryKey:"EcruReleaseVersion") as? String ?? "0.1"
        let build=bundle.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "1"
        let credits=NSAttributedString(string:isChinese ? "轻量 PDF 阅读与直接批注" : "Lightweight PDF reading and annotation",attributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options:[.applicationName:appName,.applicationIcon:NSApp.applicationIconImage as Any,.applicationVersion:version,.version:build,.credits:credits])
    }
    @objc private func compareLegacy() {setPenComparison(true)}
    @objc private func compareObservation() {setPenComparison(false)}
    private func setPenComparison(_ legacy:Bool) {
        for reader in readers {reader.canvas.finishInterruptedInput()}
        PenEngine.legacy=legacy
    }
    @objc private func save() { activeReader?.saveDocument() }
    @objc private func saveAs() { activeReader?.saveDocumentAs() }
    @objc private func closeDocument() { NSApp.keyWindow?.performClose(nil) }
    @objc private func undo() { if let field = NSApp.keyWindow?.firstResponder as? NSTextView, field.isFieldEditor { field.undoManager?.undo() } else { activeReader?.undoAction() } }
    @objc private func redo() { if let field = NSApp.keyWindow?.firstResponder as? NSTextView, field.isFieldEditor { field.undoManager?.redo() } else { activeReader?.redoAction() } }
    @objc private func copySelection() { if let field = NSApp.keyWindow?.firstResponder as? NSTextView { field.copy(nil) } else { activeReader?.copyText() } }
    @objc private func chooseTool(_ sender:NSMenuItem) {
        guard let tool=ReaderTool(rawValue:sender.tag) else{return}; activeReader?.selectTool(tool)
    }
    @objc private func find() { activeReader?.openSearch() }
    @objc private func addNote() { activeReader?.addNoteFromSelection() }
    func validateMenuItem(_ item:NSMenuItem)->Bool {
        if item.action == #selector(chooseTool(_:)) { item.state=activeReader?.canvas.tool.rawValue == item.tag ? .on : .off; return activeReader != nil && activeReader?.canvas.gesture == false }
        if item.action == #selector(compareLegacy) {item.state=PenEngine.legacy ? .on:.off;return !readers.contains{$0.canvas.gesture}}
        if item.action == #selector(compareObservation) {item.state=PenEngine.legacy ? .off:.on;return !readers.contains{$0.canvas.gesture}}
        if item.action == #selector(addNote) {item.title=activeReader?.noteCommandTitle ?? "添加批注";return activeReader?.canPerformNoteCommand == true}
        return true
    }
    @objc private func findNotes() { activeReader?.openNoteSearch() }
    @objc private func sidebar() { activeReader?.toggleSidebar() }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if quitInProgress { return .terminateLater }
        readers.forEach { $0.noteCard.dismiss(); $0.canvas.finishInterruptedInput(); $0.rememberPosition() }
        if let saving = readers.first(where:{ $0.session.isSaving }) {
            saving.showNotice("PDF 正在保存，完成后再退出；当前窗口和保存目标已保留。")
            return .terminateCancel
        }
        let dirty = readers.filter { $0.session.isModified }
        if dirty.isEmpty {
            for reader in readers where !reader.session.discardRecovery() {
                reader.showNotice(reader.session.lastError?.localizedDescription ?? "恢复记录未能清理，应用已保留。")
                return .terminateCancel
            }
            return .terminateNow
        }
        quitInProgress = true; quitDiscarded.removeAll()
        DispatchQueue.main.async { self.resolveQuit() }; return .terminateLater
    }
    func applicationShouldSaveApplicationState(_ app:NSApplication,coder:NSCoder) -> Bool { false }
    func applicationDidResignActive(_ notification:Notification) {
        // A different window/process may receive the release event. Finish only
        // our document action; never synthesize releases into another application.
        readers.forEach { $0.windowDidResignKey(notification) }
    }
    func applicationWillTerminate(_ notification:Notification) {
        readers.forEach { $0.disconnectInputAndViews() }
    }
    func applicationShouldRestoreApplicationState(_ app:NSApplication,coder:NSCoder) -> Bool { false }
    private func cancelQuit() {
        quitInProgress = false; quitDiscarded.removeAll()
        readers.filter { $0.session.isModified }.forEach { $0.session.checkpointRecovery() }
        NSApp.reply(toApplicationShouldTerminate:false)
    }
    private func resolveQuit() {
        readers.forEach { $0.noteCard.dismiss(); $0.canvas.finishInterruptedInput(); $0.rememberPosition() }
        if let saving = readers.first(where:{ $0.session.isSaving }) {
            saving.showNotice("PDF 正在保存，应用已保留；完成后再退出。")
            cancelQuit(); return
        }
        guard let reader = readers.first(where: { $0.session.isModified && quitDiscarded[ObjectIdentifier($0)] != $0.session.contentChangeToken }) else {
            // Recheck every current window: another document can change during asynchronous saving.
            // Only discard recovery after every modified revision has received a decision.
            for current in readers where !current.session.discardRecovery() {
                current.showNotice(current.session.lastError?.localizedDescription ?? "恢复记录未能清理，应用已保留。")
                cancelQuit(); return
            }
            quitInProgress = false; quitDiscarded.removeAll(); NSApp.reply(toApplicationShouldTerminate:true); return
        }
        let a = NSAlert(); a.messageText = "退出前保存“\(reader.session.fileURL.lastPathComponent)”？"
        a.addButton(withTitle:"保存"); a.addButton(withTitle:"不保存"); a.addButton(withTitle:"取消")
        let reply = a.runModal()
        if reply == .alertThirdButtonReturn { cancelQuit(); return }
        if reply == .alertSecondButtonReturn { quitDiscarded[ObjectIdentifier(reader)] = reader.session.contentChangeToken; resolveQuit(); return }
        reader.session.save { result in
            switch result {
            case .success(let outcome):
                if !outcome.recoveryCleanupSucceeded {
                    reader.showNotice(reader.session.lastError?.localizedDescription ?? "PDF 已保存，但恢复记录清理失败；应用已保留。")
                    self.cancelQuit()
                } else if reader.session.isModified { self.cancelQuit() }
                else { self.resolveQuit() }
            case .failure(let error): reader.showNotice(error.localizedDescription); self.cancelQuit()
            }
        }
    }
}

#if !ECRU_INPUT_TESTS
@main enum EcruMain {
    static func main() {
        let app = NSApplication.shared; let delegate = AppDelegate(); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
#endif
