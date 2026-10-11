import AppKit
import PDFKit
/// Semantic surfaces resolve colors at draw time, including live appearance changes.
final class ReaderSurface: NSView {
    var sidebarStyle = false
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        (sidebarStyle ? NSColor.controlBackgroundColor : NSColor.windowBackgroundColor).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 0.5).fill()
        if sidebarStyle { NSRect(x: bounds.width-0.5, y: 0, width: 0.5, height: bounds.height).fill() }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// A bounded, intrinsic-width strip. Avoid NSStackView constraints escaping a
/// frame-based toolbar when contextual controls are replaced during refresh.
final class ReaderParameterStrip: NSView {
    var arrangedSubviews: [NSView] { subviews }
    func addArrangedSubview(_ view: NSView) { addSubview(view); needsLayout=true }
    func removeArrangedSubview(_ view: NSView) { view.removeFromSuperview(); needsLayout=true }
    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for view in subviews {
            let width = max(54,view.intrinsicContentSize.width+12)
            view.frame = NSRect(x:x,y:0,width:width,height:bounds.height)
            x += width+6
        }
    }
}

final class LayoutView: NSView {
    var onLayout: (() -> Void)?
    override func layout() { super.layout(); onLayout?() }
}

final class ReaderWindow: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSToolbarDelegate, NSSplitViewDelegate {
    let session: DocumentSession
    let pdfView = PDFView()
    let canvas = ReaderCanvas()
    lazy var noteCard = AnchoredNote(reader:self)
    private let selectionAdd = NSButton(title:"添加批注",target:nil,action:nil)
    let parameterPopover = NSPopover()
    private let root = LayoutView()
    private let readingBar = NSView()
    private let annotationBar = ReaderSurface()
    private let body = NSSplitView()
    private var preferredSidebarWidth: CGFloat = 264
    private var arrangingSidebar = false
    private var toolbarItems: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let sidebar = ReaderSurface()
    private let documentArea = NSView()
    private let titleButton = NSButton()
    private var titleWidth: NSLayoutConstraint?
    private let statusButton = NSButton()
    private let pageField = NSTextField()
    private let pageCount = NSTextField(labelWithString: "")
    private let zoom = NSPopUpButton()
    private var currentZoomItem: NSMenuItem?
    private let searchButton = NSButton()
    private let sidebarButton = NSButton()
    private let back = NSButton()
    private let forward = NSButton()
    private let undoButton = NSButton()
    private let redoButton = NSButton()
    private var toolButtons: [NSButton] = []
    private let parameters = ReaderParameterStrip()
    private let sidebarTabs = NSSegmentedControl(labels: ["缩略图", "目录"], trackingMode: .selectOne, target: nil, action: nil)
    private let thumbnails = PDFThumbnailView()
    private let tableScroll = NSScrollView()
    private let table = NSTableView()
    private let searchField = NSSearchField()
    private let matchLabel = NSTextField(labelWithString: "")
    private let closeSearch = NSButton()
    private let previousMatch = NSButton()
    private let nextMatch = NSButton()
    private var searchResults: [PDFSelection] = []
    private let searchScope = NSSegmentedControl(labels:["PDF 原文","批注"],trackingMode:.selectOne,target:nil,action:nil)
    private let noteFilter = NSPopUpButton()
    private var noteResults:[AnnotationNote]=[]
    private var noteSummaries:[UUID:(UUID,String)]=[:]
    private var searchGeneration=0
    private var searchingNotes:Bool {searchScope.selectedSegment==1}
    private var resultCount:Int {searchingNotes ? noteResults.count : searchResults.count}
    private var outlineRows: [(PDFOutline, Int)] = []
    private(set) var searchVisible = false
    private var sidebarVisible = false
    private var previousSidebarState = (false, 0)
    private var navigationHistory: [PDFDestination] = []
    private var historyIndex = -1
    private var navigatingHistory = false
    private var closingAfterSave = false
    private var notifications: [NSObjectProtocol] = []
    private var inputScope: WindowInputScope?
    private(set) var disconnected = false
    private var rebinding = false
    var didClose: (() -> Void)?

    init(session: DocumentSession,
         installInputMonitor: WindowInputScope.Install = WindowInputScope.nativeInstall,
         removeInputMonitor: @escaping (Any) -> Void = WindowInputScope.nativeRemove) {
        self.session = session
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1160, height: 830), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = session.fileURL.lastPathComponent; window.minSize = CGSize(width: 820, height: 560)
        window.isReleasedWhenClosed = false; window.delegate = self; window.center()
        window.isRestorable = false
        window.contentView = root; window.setFrameAutosaveName("LeafInkReaderWindow")
        root.onLayout = { [weak self] in self?.layoutViews() }
        canvas.reader = self; buildInterface()
        parameterPopover.animates = false
        pdfView.pageOverlayViewProvider = canvas.presentation
        pdfView.document = session.document; pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical; pdfView.displayBox = .cropBox
        pdfView.backgroundColor = NSColor.underPageBackgroundColor
        pdfView.minScaleFactor = 0.15; pdfView.maxScaleFactor = 6; pdfView.autoScales = true
        thumbnails.pdfView = pdfView; thumbnails.thumbnailSize = CGSize(width: 160, height: 190)
        session.onInkChange = { [weak self] page,bounds,change in self?.canvas.presentation.invalidate(page,bounds:bounds,change:change) }
        session.onHistoryNote = { [weak self] id,label in self?.noteCard.historyChanged(id,label:label) }
        session.onChange = { [weak self] in self?.sessionChanged() }
        session.isTargetOpenElsewhere = { [weak self] url in
            guard let self else { return true }
            let canonical = url.resolvingSymlinksInPath()
            let blockers = AppDelegate.shared.readers.filter { $0 !== self && ($0.session.fileURL.resolvingSymlinksInPath() == canonical || $0.session.savingTarget == canonical) }
            if !blockers.isEmpty { print("Save target open:", blockers.map { $0.session.fileURL.path }) }
            return !blockers.isEmpty
        }
        buildOutline(); layoutViews(); refresh()
        if !session.annotationWarnings.isEmpty { DispatchQueue.main.async { [weak self] in guard let self, !self.disconnected else { return }; self.openNoteSearch() } }
        notifications.append(NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            guard let self, !self.rebinding else { return }
            self.closeParameters(); self.canvas.clearSelection(); self.pdfView.clearSelection(); self.refresh(); self.positionNoteUI(); self.rememberPosition()
        })
        notifications.append(NotificationCenter.default.addObserver(forName: .PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in self?.refresh(); self?.canvas.presentation.invalidateAll(); self?.canvas.needsDisplay = true; self?.positionNoteUI() })
        if let clip=pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications=true
            notifications.append(NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:clip,queue:.main) { [weak self] _ in
                self?.canvas.refreshToolCursor()
                self?.updatePageIndicator()
            })
        }
        for name in [NSApplication.didBecomeActiveNotification,NSApplication.didResignActiveNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.canvas.refreshToolCursor() })
        }
        for name in [NSMenu.didBeginTrackingNotification,NSMenu.didEndTrackingNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] note in
                self?.canvas.menuTracking = note.name == NSMenu.didBeginTrackingNotification
                self?.canvas.refreshToolCursor()
            })
        }
        inputScope = WindowInputScope(install:installInputMonitor, remove:removeInputMonitor, belongs: { [weak self] event in
            guard let self, !self.disconnected else { return false }
            return event.window === self.window || (event.window == nil && self.window?.isKeyWindow == true && ReaderCanvas.isPadInkZoom(event))
        }, handle: { [weak self] event in
            guard let self else { return false }
            if self.canvas.handlePadInkZoom(event) { return true }
            if event.type == .keyDown, event.keyCode == 53,
               (self.window?.firstResponder as? NSTextView)?.hasMarkedText() == true { return false }
            if event.type == .leftMouseDown || event.type == .rightMouseDown {
                let p=self.documentArea.convert(event.locationInWindow,from:nil)
                if self.noteCard.isOpen && !self.noteCard.frame.contains(p) {self.noteCard.dismiss()}
            }
            if event.type == .keyDown, event.keyCode == 53, self.noteCard.isOpen, !self.noteCard.isComposing {self.noteCard.dismiss();return true}
            if event.type == .keyDown, event.keyCode == 53 && self.parameterPopover.isShown { self.closeParameters(); return true }
            return false
        })
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.disconnected else { return }
            self.restorePosition(); self.window?.makeFirstResponder(self.canvas); self.offerRecovery()
        }
        if session.currentFileIsReadOnly { DispatchQueue.main.async { [weak self] in guard let self, !self.disconnected else { return }; self.showNotice("当前 PDF 为只读；可以阅读和批注，但保存需要另存到可写文件。") } }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { notifications.forEach(NotificationCenter.default.removeObserver); inputScope?.stop() }

    private func button(_ b: NSButton, title: String, symbol: String? = nil, action: Selector, host: NSView) {
        b.title = title; b.target = self; b.action = action; b.bezelStyle = .accessoryBarAction
        b.isBordered = false; b.font = .systemFont(ofSize: 13); b.imagePosition = symbol == nil ? .noImage : .imageLeading
        if let symbol { b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        b.setAccessibilityLabel(title); host.addSubview(b)
    }
    private func buildInterface() {
        for v in [annotationBar, body] { root.addSubview(v) }
        for surface in [annotationBar,sidebar] { surface.wantsLayer = true }
        annotationBar.sidebarStyle = false
        body.isVertical = true; body.dividerStyle = .thin; body.delegate = self
        body.addSubview(sidebar); body.addSubview(documentArea)
        // Explicit compositor clipping prevents content from escaping into the toolbar/sidebar.
        documentArea.wantsLayer = true; documentArea.layer?.masksToBounds = true
        canvas.wantsLayer = true; canvas.layer?.masksToBounds = true
        documentArea.addSubview(pdfView); documentArea.addSubview(canvas);documentArea.addSubview(noteCard)
        selectionAdd.target=self;selectionAdd.action=#selector(addNoteFromSelection);selectionAdd.bezelStyle = .rounded;selectionAdd.font = .systemFont(ofSize:12);selectionAdd.isHidden=true
        selectionAdd.setAccessibilityLabel("为选中文字添加批注");documentArea.addSubview(selectionAdd)
        button(sidebarButton, title: "", symbol: "sidebar.left", action: #selector(toggleSidebar), host: readingBar); sidebarButton.toolTip = "显示导航侧栏"
        button(back, title: "", symbol: "chevron.left", action: #selector(goBack), host: readingBar); back.toolTip = "返回之前的阅读位置"
        button(forward, title: "", symbol: "chevron.right", action: #selector(goForward), host: readingBar); forward.toolTip = "前进到阅读位置"
        button(titleButton, title: "", action: #selector(showPath), host: readingBar)
        titleButton.alignment = .center; titleButton.font = .systemFont(ofSize: 13, weight: .medium)
        titleButton.lineBreakMode = .byTruncatingMiddle
        button(statusButton, title: "", action: #selector(showSaveState), host: readingBar)
        pageField.alignment = .right; pageField.target = self; pageField.action = #selector(jumpPage); pageField.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        pageField.setAccessibilityLabel("当前页码"); readingBar.addSubview(pageField); readingBar.addSubview(pageCount)
        zoom.addItems(withTitles: ["适合宽度", "适合页面", "50%", "75%", "100%", "125%", "150%", "200%"])
        zoom.target = self; zoom.action = #selector(changeZoom); zoom.setAccessibilityLabel("缩放"); readingBar.addSubview(zoom)
        button(searchButton, title: "搜索", symbol: "magnifyingglass", action: #selector(openSearch), host: readingBar)
        for tool in ReaderTool.toolbarOrder {
            let b = NSButton(); button(b, title: tool.title, symbol: tool.symbol, action: #selector(changeTool(_:)), host: annotationBar)
            b.tag = tool.rawValue; b.setButtonType(.pushOnPushOff); b.isBordered = true; b.showsBorderOnlyWhileMouseInside = true
            b.toolTip = tool.title+"（⌘\(tool.rawValue+1)）"; toolButtons.append(b)
        }
        annotationBar.addSubview(parameters)
        button(undoButton, title: "", symbol: "arrow.uturn.backward", action: #selector(undoAction), host: annotationBar); undoButton.toolTip = "撤销（⌘Z）"
        button(redoButton, title: "", symbol: "arrow.uturn.forward", action: #selector(redoAction), host: annotationBar); redoButton.toolTip = "重做（⇧⌘Z）"
        sidebar.sidebarStyle = true
        sidebarButton.setButtonType(.pushOnPushOff); searchButton.setButtonType(.pushOnPushOff)
        for b in [sidebarButton, back, forward, undoButton, redoButton, closeSearch, previousMatch, nextMatch] { b.setAccessibilityLabel(b.toolTip ?? (b === previousMatch ? "上一个搜索结果" : "下一个搜索结果")) }
        pageCount.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular); pageCount.textColor = .secondaryLabelColor
        pageField.bezelStyle = .roundedBezel; statusButton.font = .systemFont(ofSize: 11); statusButton.lineBreakMode = .byTruncatingTail
        sidebarTabs.selectedSegment = 0; sidebarTabs.target = self; sidebarTabs.action = #selector(changeSidebarTab); sidebar.addSubview(sidebarTabs)
        sidebar.addSubview(thumbnails)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("result")); column.width = 216
        table.addTableColumn(column); table.headerView = nil; table.rowHeight = 58; table.dataSource = self; table.delegate = self
        table.style = .inset; table.backgroundColor = .controlBackgroundColor; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.setAccessibilityLabel("目录与搜索结果")
        table.target = self; table.action = #selector(activateRow); table.allowsEmptySelection = true
        tableScroll.documentView = table; tableScroll.hasVerticalScroller = true; tableScroll.drawsBackground = false; sidebar.addSubview(tableScroll)
        searchField.placeholderString = "搜索 PDF 原文"; searchField.delegate = self; searchField.target = self; searchField.action = #selector(searchChanged)
        searchField.setAccessibilityLabel("搜索 PDF 原文"); sidebar.addSubview(searchField)
        searchScope.selectedSegment=0;searchScope.target=self;searchScope.action=#selector(changeSearchScope);sidebar.addSubview(searchScope)
        noteFilter.addItems(withTitles:["全部批注","无页面标记","待重新关联"]);noteFilter.target=self;noteFilter.action=#selector(searchChanged);sidebar.addSubview(noteFilter)
        sidebar.addSubview(matchLabel); matchLabel.font = .systemFont(ofSize: 12); matchLabel.textColor = .secondaryLabelColor
        button(closeSearch, title: "", symbol: "xmark", action: #selector(hideSearch), host: sidebar); closeSearch.toolTip = "关闭搜索"
        button(previousMatch, title: "", symbol: "chevron.up", action: #selector(previousSearchMatch), host: sidebar)
        button(nextMatch, title: "", symbol: "chevron.down", action: #selector(nextSearchMatch), host: sidebar)
        installReadingToolbar()
        closeSearch.setAccessibilityLabel("关闭搜索"); previousMatch.setAccessibilityLabel("上一个搜索结果"); nextMatch.setAccessibilityLabel("下一个搜索结果")
    }
    private func installReadingToolbar() {
        // AppKit centers the document item in a single compact native toolbar.
        // NSWindow retains its document identity for Window menus and edited state.
        let navigation = NSStackView(views:[sidebarButton,back,forward])
        navigation.orientation = .horizontal; navigation.alignment = .centerY
        navigation.spacing = 6; navigation.distribution = .fillEqually
        for b in [sidebarButton,back,forward] {
            b.imagePosition = .imageOnly
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize:14,weight:.regular)
            b.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([b.widthAnchor.constraint(equalToConstant:26),b.heightAnchor.constraint(equalToConstant:26)])
        }
        pageField.isBezeled = false; pageField.isBordered = false; pageField.drawsBackground = false
        pageField.alignment = .right; pageField.focusRingType = .none
        pageCount.font = pageField.font
        let pagination = NSStackView(views:[pageField,pageCount])
        pagination.orientation = .horizontal; pagination.alignment = .centerY
        pagination.spacing = 4; pagination.distribution = .fill
        for field in [pageField,pageCount] {
            field.translatesAutoresizingMaskIntoConstraints = false
            field.heightAnchor.constraint(equalToConstant:20).isActive = true
        }
        pageField.widthAnchor.constraint(equalToConstant:34).isActive = true
        zoom.isBordered = false; zoom.font = .monospacedDigitSystemFont(ofSize:13,weight:.regular)
        zoom.controlSize = .small
        searchButton.title="";searchButton.imagePosition = .imageOnly
        searchButton.toolTip="搜索（⌘F）";searchButton.setAccessibilityLabel("搜索")
        for (key,label,view,width) in [("navigation","阅读导航",navigation,90.0),("page","页码",pagination,78.0),("zoom","缩放",zoom,92.0),("search","搜索",searchButton,30.0),("status","保存状态",statusButton,26.0)] {
            let id=NSToolbarItem.Identifier(key),item=NSToolbarItem(itemIdentifier:id)
            view.removeFromSuperview();view.setFrameSize(NSSize(width:width,height:28))
            item.label=label;item.paletteLabel=label;item.view=view
            if key == "navigation" {item.isNavigational=true}
            view.translatesAutoresizingMaskIntoConstraints=false
            NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant:width),view.heightAnchor.constraint(equalToConstant:28)])
            item.visibilityPriority = .high;toolbarItems[id]=item
        }
        let titleItem=NSToolbarItem(itemIdentifier:NSToolbarItem.Identifier("document"))
        titleItem.label="当前文档";titleItem.view=titleButton;titleItem.visibilityPriority = .high
        titleButton.removeFromSuperview();titleButton.translatesAutoresizingMaskIntoConstraints=false
        titleWidth=titleButton.widthAnchor.constraint(equalToConstant:320)
        NSLayoutConstraint.activate([titleWidth!,titleButton.heightAnchor.constraint(equalToConstant:28)])
        toolbarItems[titleItem.itemIdentifier]=titleItem
        let toolbar=NSToolbar(identifier:"EcruReadingToolbar")
        toolbar.delegate=self;toolbar.displayMode = .iconOnly;toolbar.allowsUserCustomization=false
        toolbar.centeredItemIdentifiers=[NSToolbarItem.Identifier("document")]
        window?.titleVisibility = .hidden
        window?.toolbarStyle = .unifiedCompact;window?.toolbar=toolbar
    }
    func toolbarDefaultItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] {
        [NSToolbarItem.Identifier("navigation"),.flexibleSpace,NSToolbarItem.Identifier("document"),.flexibleSpace,NSToolbarItem.Identifier("page"),NSToolbarItem.Identifier("zoom"),NSToolbarItem.Identifier("search"),NSToolbarItem.Identifier("status")]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar:NSToolbar)->[NSToolbarItem.Identifier] {toolbarDefaultItemIdentifiers(toolbar)}
    func toolbar(_ toolbar:NSToolbar,itemForItemIdentifier id:NSToolbarItem.Identifier,willBeInsertedIntoToolbar flag:Bool)->NSToolbarItem? {toolbarItems[id]}
    func splitView(_ splitView:NSSplitView,constrainSplitPosition proposedPosition:CGFloat,ofSubviewAt dividerIndex:Int)->CGFloat {
        canvas.gesture ? sidebar.frame.width : min(max(228,proposedPosition),min(360,root.bounds.width*0.38))
    }
    func splitView(_ splitView:NSSplitView,shouldHideDividerAt dividerIndex:Int)->Bool {!sidebarVisible}
    func splitView(_ splitView:NSSplitView,canCollapseSubview subview:NSView)->Bool {false}
    func splitView(_ splitView:NSSplitView,shouldAdjustSizeOfSubview view:NSView)->Bool {view === documentArea}
    func splitViewDidResizeSubviews(_ notification:Notification) {
        guard !arrangingSidebar,sidebarVisible else{return}
        preferredSidebarWidth=sidebar.frame.width;closeParameters();layoutViews()
    }
    private func layoutViews() {
        let w = root.bounds.width, h = root.bounds.height
        // Leave room for page/zoom/search at the minimum supported window width.
        titleWidth?.constant = min(320,max(80,w-700))
        // All six tools remain in one persistent row below the native toolbar.
        let toolHeight: CGFloat = 40
        annotationBar.frame = CGRect(x: 0, y: h-toolHeight, width: w, height: toolHeight)
        arrangingSidebar=true
        defer {arrangingSidebar=false}
        body.frame = CGRect(x: 0, y: 0, width: w, height: h-toolHeight)
        var x: CGFloat = 12
        let widths: [CGFloat] = [68,54,100,114,68,68]
        for b in toolButtons {
            let width=widths[b.tag]
            b.frame = CGRect(x: x, y: 5, width: width, height: 30); x += width+2
        }
        parameters.frame = CGRect(x: x+12, y: 5, width: max(0,w-x-100), height: 30)
        undoButton.frame = CGRect(x: w-76, y: 5, width: 30, height: 30)
        redoButton.frame = CGRect(x: w-42, y: 5, width: 30, height: 30)
        let sideWidth = min(max(228,preferredSidebarWidth),min(360,w*0.38))
        let sidebarInset: CGFloat = sidebarVisible ? sideWidth+body.dividerThickness : 0
        sidebar.isHidden = !sidebarVisible; body.needsDisplay=true; sidebar.frame = CGRect(x: 0, y: 0, width: sideWidth, height: body.bounds.height)
        documentArea.frame = CGRect(x: sidebarInset, y: 0, width: max(200,w-sidebarInset), height: body.bounds.height)
        pdfView.frame = documentArea.bounds; canvas.frame = documentArea.bounds
        let sh = sidebar.bounds.height
        sidebarTabs.frame = CGRect(x: 12, y: sh-40, width: sideWidth-24, height: 27)
        thumbnails.frame = CGRect(x: 0, y: 0, width: sideWidth, height: sh-48)
        searchField.frame = CGRect(x: 12, y: sh-42, width: sideWidth-58, height: 26)
        closeSearch.frame = CGRect(x: sideWidth-41, y: sh-42, width: 29, height: 26)
        searchScope.frame=CGRect(x:12,y:sh-76,width:sideWidth-24,height:26)
        noteFilter.frame=CGRect(x:12,y:sh-108,width:sideWidth-24,height:26)
        let resultTop:CGFloat=searchingNotes ? 142 : 110
        matchLabel.frame = CGRect(x: 12, y: sh-resultTop, width: sideWidth-92, height: 24)
        previousMatch.frame = CGRect(x: sideWidth-79, y: sh-resultTop, width: 30, height: 24); nextMatch.frame = CGRect(x: sideWidth-44, y: sh-resultTop, width: 30, height: 24)
        tableScroll.frame = CGRect(x: 0, y: 0, width: sideWidth, height: sh-(searchVisible ? resultTop+10 : 48))
        sidebarTabs.isHidden = searchVisible; thumbnails.isHidden = searchVisible || sidebarTabs.selectedSegment != 0
        tableScroll.isHidden = !searchVisible && sidebarTabs.selectedSegment == 0
        for v in [searchField, searchScope, matchLabel, closeSearch, previousMatch, nextMatch] { v.isHidden = !searchVisible }
        noteFilter.isHidden = !searchVisible || !searchingNotes
        sidebarButton.state = sidebarVisible ? .on : .off; searchButton.state = searchVisible ? .on : .off
        table.rowHeight = searchVisible ? 72 : (outlineRows.isEmpty ? 56 : 32)
        canvas.needsDisplay = true; positionNoteUI()
    }
    private func updatePageIndicator() {
        guard !rebinding else { return }
        // In continuous reading PDFKit's currentPage can lag behind the viewport.
        // Observe scrolling directly and identify the page at the reading center.
        let center = CGPoint(x:pdfView.bounds.midX,y:pdfView.bounds.midY)
        if pageField.currentEditor() == nil,
           let page = pdfView.page(for:center,nearest:true) ?? pdfView.currentPage {
            let index = session.document.index(for:page)
            if index != NSNotFound { pageField.stringValue = String(index+1) }
        }
        pageCount.stringValue = "/ \(session.document.pageCount)"
    }

    func refresh() {
        canvas.refreshToolCursor()
        window?.title = session.fileURL.lastPathComponent
        window?.subtitle = ""
        window?.isDocumentEdited = session.isModified
        window?.representedURL = session.fileURL
        titleButton.title = session.fileURL.lastPathComponent; titleButton.toolTip = session.fileURL.path
        titleButton.setAccessibilityLabel("当前文档："+session.fileURL.lastPathComponent)
        statusButton.title = session.annotationReadOnly ? "批注冲突 · 只读" : session.conflictDetected ? "外部修改 · 未保存" : session.statusText; statusButton.isHidden = session.statusText.isEmpty && !session.annotationReadOnly
        statusButton.toolTip = session.statusText.isEmpty ? "已保存" : session.statusText
        statusButton.setAccessibilityLabel(statusButton.title.isEmpty ? "已保存" : statusButton.title)
        statusButton.image=NSImage(systemSymbolName:session.conflictDetected || session.annotationReadOnly ? "exclamationmark.circle" : "circle.fill",accessibilityDescription:statusButton.toolTip)
        statusButton.imagePosition = .imageOnly
        statusButton.symbolConfiguration=NSImage.SymbolConfiguration(pointSize:session.conflictDetected || session.annotationReadOnly ? 13 : 6,weight:.regular)
        statusButton.contentTintColor = session.conflictDetected ? .systemRed : (session.isModified ? .secondaryLabelColor : nil)
        updatePageIndicator()
        if let item = currentZoomItem { zoom.menu?.removeItem(item); currentZoomItem = nil }
        if pdfView.autoScales { zoom.selectItem(at:0) }
        else {
            let title = "\(Int(pdfView.scaleFactor*100))%"
            if let item = zoom.item(withTitle:title) { zoom.select(item) }
            else {
                let item = NSMenuItem(title:title,action:nil,keyEquivalent:"")
                zoom.menu?.addItem(item); zoom.select(item); currentZoomItem = item
            }
        }
        back.isEnabled = historyIndex > 0; forward.isEnabled = historyIndex >= 0 && historyIndex < navigationHistory.count-1
        undoButton.isEnabled = session.canUndo; redoButton.isEnabled = session.canRedo
        for b in toolButtons {
            let selected = b.tag == canvas.tool.rawValue
            b.state = selected ? .on : .off
            b.showsBorderOnlyWhileMouseInside = !selected
            b.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
            b.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        }
        updateOutlineSelection(); updateParameters()
    }
    func updateParameters() {
        for v in parameters.arrangedSubviews { parameters.removeArrangedSubview(v); v.removeFromSuperview() }
        func parameterButton(_ title: String, action: Selector) -> NSButton {
            let b = NSButton(title: title, target: self, action: action); b.bezelStyle = .accessoryBarAction; b.showsBorderOnlyWhileMouseInside = true
            b.font = .systemFont(ofSize: 12); b.setAccessibilityLabel(title); parameters.addArrangedSubview(b); return b
        }
        if canvas.tool == .select, !(pdfView.currentSelection?.string ?? "").isEmpty {
            _ = parameterButton("添加批注", action:#selector(addNoteFromSelection));return
        }
        if canvas.hasDeletableSelection {
            _ = parameterButton("添加正文", action: #selector(addNoteFromSelection))
            _ = parameterButton(canvas.selectedHighlight != nil ? "删除高亮" : "删除所选", action: #selector(deleteSelection)); return
        }
        if [.pen,.textHighlight,.marker].contains(canvas.tool) {
            let c = canvas.colors[canvas.tool]!
            let label = colorName(c)
            let b = parameterButton(label, action: #selector(showColors(_:)))
            b.image=NSImage(size:CGSize(width:12,height:12),flipped:false) {_ in c.setFill();NSBezierPath(ovalIn:CGRect(x:1,y:1,width:10,height:10)).fill();return true};b.imagePosition = .imageLeft
            b.toolTip="当前颜色："+label+"；点击切换"
        }
        if canvas.tool == .pen || canvas.tool == .marker { _ = parameterButton("\(canvas.widths[canvas.tool]!) pt", action: #selector(showWidths(_:)));parameters.arrangedSubviews.last?.toolTip="PDF 页坐标点；显示粗细随缩放变化" }
        if canvas.tool == .eraser { _ = parameterButton("直径 \(Int(canvas.eraserRadius*2)) pt", action: #selector(showWidths(_:))) }
    }
    private func colorName(_ color: NSColor) -> String {
        let colors: [(NSColor,String)] = [(.systemBlue,"蓝色"),(.black,"黑色"),(.systemRed,"红色"),(.systemYellow,"黄色"),(.systemGreen,"绿色")]
        return colors.first { $0.0 == color }?.1 ?? "自选颜色"
    }
    @objc func changeTool(_ sender: NSButton) { guard !canvas.gesture else { return }; noteCard.dismiss(); selectionAdd.isHidden=true; closeParameters(); canvas.setTool(ReaderTool(rawValue: sender.tag)!); refresh(); window?.makeFirstResponder(canvas) }
    func closeParameters() { parameterPopover.close() }
    private func showParameterChoices(_ labels: [String], tagBase: Int, from sender: NSButton) {
        closeParameters(); let content = NSViewController(); let stack = NSStackView(); stack.orientation = .vertical; stack.spacing = 6; stack.alignment = .leading; stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for (i,label) in labels.enumerated() { let b = NSButton(title: label, target: self, action: #selector(parameterChoice(_:))); b.tag = tagBase+i; b.bezelStyle = .rounded; b.setButtonType(.radio)
            let values: [Double] = canvas.tool == .eraser ? [8,20,36] : canvas.tool == .marker ? [8,14,22] : [0.8,1.6,2.8,4.0]
            let currentWidth = canvas.tool == .eraser ? canvas.eraserRadius*2 : canvas.widths[canvas.tool] ?? 0
            let selected = tagBase == 100 ? label == colorName(canvas.colors[canvas.tool] ?? .black) : abs(values[i]-currentWidth)<0.01
            b.state = selected ? .on : .off; b.setAccessibilityLabel(label)
            b.font = .systemFont(ofSize:13)
            let row=NSStackView();row.orientation = .horizontal;row.spacing=10
            row.addArrangedSubview(b)
            let sample=NSImageView();sample.imageScaling = .scaleNone
            sample.image=NSImage(size:NSSize(width:42,height:18),flipped:false) { _ in
                if tagBase == 100 {
                    let color=[NSColor.systemBlue,.black,.systemRed,.systemYellow,.systemGreen][i]
                    let path=NSBezierPath(roundedRect:NSRect(x:5,y:2,width:32,height:14),xRadius:4,yRadius:4)
                    color.setFill();path.fill();NSColor.separatorColor.setStroke();path.lineWidth=0.5;path.stroke()
                } else {
                    NSColor.labelColor.setStroke();let line=NSBezierPath();line.lineWidth=min(values[i],8);line.lineCapStyle = .round
                    line.move(to:NSPoint(x:6,y:9));line.line(to:NSPoint(x:36,y:9));line.stroke()
                }
                return true
            }
            sample.image?.isTemplate=false;row.addArrangedSubview(sample);stack.addArrangedSubview(row) }
        content.view = stack; content.preferredContentSize = CGSize(width: 176, height: labels.count*26+24)
        parameterPopover.contentViewController = content; parameterPopover.behavior = .transient
        parameterPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
    @objc private func showColors(_ sender: NSButton) { showParameterChoices(["蓝色", "黑色", "红色", "黄色", "绿色"], tagBase: 100, from: sender) }
    @objc private func showWidths(_ sender: NSButton) { showParameterChoices(canvas.tool == .eraser ? ["8 pt", "20 pt", "36 pt"] : (canvas.tool == .marker ? ["8 pt", "14 pt", "22 pt"] : ["细 · 0.8 pt", "标准 · 1.6 pt", "粗 · 2.8 pt", "强调 · 4.0 pt"]), tagBase: 200, from: sender) }
    @objc private func parameterChoice(_ sender: NSButton) {
        if sender.tag >= 200 {
            let choices: [Double] = canvas.tool == .eraser ? [8,20,36] : (canvas.tool == .marker ? [8,14,22] : [0.8,1.6,2.8,4.0])
            if canvas.tool == .eraser { canvas.eraserRadius = choices[sender.tag-200]/2 } else { canvas.widths[canvas.tool] = choices[sender.tag-200] }
        } else { canvas.colors[canvas.tool] = [NSColor.systemBlue,.black,.systemRed,.systemYellow,.systemGreen][sender.tag-100] }
        closeParameters(); updateParameters(); window?.makeFirstResponder(canvas)
    }
    @objc func deleteSelection() { guard !canvas.gesture else { return }; canvas.deleteSelected(); window?.makeFirstResponder(canvas) }
    @objc func undoAction() { noteCard.commit(); canvas.finishInterruptedInput(); closeParameters(); canvas.clearSelection(); session.undo() }
    @objc func redoAction() { noteCard.commit(); canvas.finishInterruptedInput(); closeParameters(); canvas.clearSelection(); session.redo() }
    @objc func copyText() { if noteCard.isOpen && !noteCard.preview.isHidden {NSApp.sendAction(#selector(NSText.copy(_:)),to:nil,from:nil);return}; if let text = pdfView.currentSelection?.string { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } }

    private func sessionChanged() {
        if pdfView.document !== session.document {
            let index = pdfView.currentPage.map { pdfView.document?.index(for: $0) ?? 0 } ?? 0
            let point = pdfView.currentDestination?.point ?? CGPoint.zero
            let scale = pdfView.scaleFactor; let auto = pdfView.autoScales
            closeParameters(); noteCard.dismiss(); rebinding = true; canvas.clearSelection(); pdfView.document = session.document
            pdfView.autoScales = auto; if !auto { pdfView.scaleFactor = scale }
            if let page = session.document.page(at: min(index,session.document.pageCount-1)) { pdfView.go(to: PDFDestination(page: page, at: point)) }
            thumbnails.pdfView = pdfView; buildOutline(); rebinding = false
            navigationHistory.removeAll(); historyIndex = -1
            if searchVisible { performSearch() }
        }
        refresh(); if searchVisible && searchingNotes {performSearch()}; noteCard.refresh()
    }
    private func preservePosition(keepExactZoom:Bool = false,_ action: () -> Void) {
        let destination = pdfView.currentDestination; let scale = pdfView.scaleFactor; let auto = pdfView.autoScales
        if keepExactZoom { pdfView.autoScales = false }
        action(); layoutViews(); pdfView.layoutDocumentView()
        if !auto || keepExactZoom { pdfView.scaleFactor = scale }
        if let destination { pdfView.go(to: destination) }
    }
    func showNote(_ id:UUID, focus:Bool = false, anchor:PageAnchor?=nil, provisional:Bool?=nil) {
        selectionAdd.isHidden=true
        guard let note=session.annotations.notes.first(where:{$0.id==id}) else{return}
        var target=note.locationUncertain ? nil : (anchor ?? note.anchors.first)
        if var selected=target {
            // A text selection is stored as one highlight per line. Reopening a
            // line must anchor to the same nearby text block as initial creation.
            let linked=Set(note.links.map(\.markID))
            let lines=session.annotations.marks.filter{linked.contains($0.id) && $0.kind == .highlight && $0.anchor.page==selected.page}.map(\.anchor.bounds)
            var changed=true
            while changed {
                changed=false
                for line in lines where selected.bounds.insetBy(dx:-1,dy:-line.height*1.5).intersects(line) {
                    let combined=selected.bounds.union(line)
                    if combined != selected.bounds {selected.bounds=combined;changed=true}
                }
            }
            target=selected
        }
        let located=target.flatMap { a -> PageAnchor? in
            guard let page=session.document.page(at:a.page),a.bounds.intersects(page.bounds(for:.cropBox)) else{return nil};return a
        }
        if let target=located,let page=session.document.page(at:target.page),!pdfView.convert(target.bounds,from:page).intersects(pdfView.bounds) {
            navigate(to:target)
        }
        noteCard.open(id,anchor:located,editing:focus,provisional:provisional,unlocated:located == nil)
    }
    func navigateToNote(_ note:AnnotationNote) {
        guard !note.locationUncertain,let a=note.anchors.first else{return}
        navigate(to:a)
    }
    private func navigate(to anchor:PageAnchor) {
        guard !canvas.gesture,let page=session.document.page(at:anchor.page) else{return}
        closeParameters();canvas.clearSelection();recordHistory()
        pdfView.go(to:anchor.bounds,on:page);pdfView.layoutDocumentView()
        recordHistory();refresh();rememberPosition()
    }
    func positionNoteUI() {noteCard.observeScrolling();noteCard.reposition();positionSelectionAdd()}
    func selectionChanged() {updateParameters();positionSelectionAdd()}
    private func positionSelectionAdd() {
        guard canvas.tool == .select,!noteCard.isOpen,let selection=pdfView.currentSelection,!(selection.string ?? "").isEmpty,
              let page=selection.pages.first else {selectionAdd.isHidden=true;return}
        let box=documentArea.convert(pdfView.convert(selection.bounds(for:page),from:page),from:pdfView),view=documentArea.bounds.insetBy(dx:8,dy:8)
        guard box.intersects(view) else {selectionAdd.isHidden=true;return}
        selectionAdd.frame=CGRect(x:min(max(box.minX,view.minX),view.maxX-98),y:min(max(box.minY-34,view.minY),view.maxY-28),width:98,height:28);selectionAdd.isHidden=false
    }
    @objc func addNoteFromSelection() {
        noteCard.commit();canvas.finishInterruptedInput()
        let oldIDs=Set(session.annotations.notes.map(\.id))
        var id:UUID?,anchor:PageAnchor?,preserve=true
        if let mark=canvas.selectedHighlight.flatMap({session.markID(for:$0)}) {
            id=session.annotateMarks([mark]);anchor=session.annotations.marks.first{$0.id==mark}?.anchor
        } else if let existing=canvas.selectedNoteID {id=existing}
        else if let selection=pdfView.currentSelection,!(selection.string ?? "").isEmpty {
            if let page=selection.pages.first {anchor=session.pageAnchor(page:page,bounds:selection.bounds(for:page),quote:selection.string ?? "")}
            id=session.addTextSelection(selection,withNote:true);preserve=false
        } else if noteCard.isOpen {id=noteCard.selectedID}
        if let id {pdfView.clearSelection();showNote(id,focus:oldIDs.contains(id),anchor:anchor,provisional:oldIDs.contains(id) ? nil : preserve)}
        else {showNotice("请先选中文字，或点击已有批注／高亮，再添加或编辑批注。")}
    }
    var noteCommandTitle:String {canvas.selectedNoteID != nil || (noteCard.isOpen && (pdfView.currentSelection?.string ?? "").isEmpty) ? "编辑批注" : "添加批注"}
    var canPerformNoteCommand:Bool {
        !canvas.gesture && !session.annotationReadOnly && (noteCard.isOpen || canvas.selectedNoteID != nil || canvas.selectedHighlight != nil || !(pdfView.currentSelection?.string ?? "").isEmpty)
    }
    func beginRegionNote(relink:UUID?) {
        noteCard.dismiss(); canvas.finishInterruptedInput()
        guard !session.annotationReadOnly else { showNotice(session.annotationWarnings.joined(separator:"\n")); return }
        canvas.beginRegion(relink:relink); window?.makeFirstResponder(canvas)
    }
    @objc func toggleSidebar() { guard !canvas.gesture else { return }; closeParameters(); if searchVisible { hideSearch() } else { preservePosition { sidebarVisible.toggle() } } }
    @objc func changeSidebarTab() { guard !canvas.gesture else { return }; closeParameters(); layoutViews(); table.reloadData(); updateOutlineSelection() }
    @objc func openSearch() {
        guard !canvas.gesture else { return }; noteCard.dismiss(); selectionAdd.isHidden=true; closeParameters(); canvas.clearSelection()
        if !searchVisible { previousSidebarState = (sidebarVisible, sidebarTabs.selectedSegment); preservePosition { searchVisible = true; sidebarVisible = true } }
        layoutViews();performSearch(); window?.makeFirstResponder(searchField)
    }
    @objc func openNoteSearch() {
        searchScope.selectedSegment=1;searchField.stringValue="";noteFilter.selectItem(at:0);openSearch()
    }
    @objc private func changeSearchScope() {noteCard.dismiss();layoutViews();performSearch();window?.makeFirstResponder(searchField)}
    func previewBecameReady() {if searchVisible && searchingNotes {performSearch()}}
    @objc func hideSearch() {
        guard !canvas.gesture else { return }; closeParameters()
        preservePosition(keepExactZoom:true) { searchVisible = false; sidebarVisible = previousSidebarState.0; sidebarTabs.selectedSegment = previousSidebarState.1 }
        pdfView.highlightedSelections = nil; pdfView.clearSelection(); table.reloadData(); window?.makeFirstResponder(canvas); refresh()
    }
    func controlTextDidChange(_ obj: Notification) { if obj.object as AnyObject? === searchField { performSearch() } }
    @objc func searchChanged() { performSearch() }
    private func performSearch() {
        let query=searchField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        searchGeneration+=1;let generation=searchGeneration
        if searchingNotes {
            searchField.placeholderString="搜索正文或引用；留空查看全部";searchField.setAccessibilityLabel("搜索批注")
            noteResults=session.annotations.notes.filter { n in
                let matches=query.isEmpty || (n.markdown+" "+n.anchors.map(\.quote).joined(separator:" ")).localizedCaseInsensitiveContains(query)
                let category=noteFilter.indexOfSelectedItem
                return matches && (category==0 || (category==1 && !session.annotations.hasMarks(n)) || (category==2 && (n.locationUncertain || n.anchors.isEmpty)))
            }
            matchLabel.stringValue="\(noteResults.count) 条批注"+(query.isEmpty ? " · 可直接查看" : "")
            let needed=noteResults.filter{noteSummaries[$0.id]?.0 != $0.revision}
            noteCard.summarize(needed) { [weak self] summaries in
                guard let self,self.searchVisible,self.searchingNotes,self.searchGeneration==generation else{return}
                for (id,revision,text) in summaries {self.noteSummaries[id]=(revision,text)}
                self.table.reloadData()
            }
        } else {
            searchField.placeholderString="搜索 PDF 原文";searchField.setAccessibilityLabel("搜索 PDF 原文")
            searchResults=query.isEmpty ? [] : session.document.findString(query,withOptions:[.caseInsensitive])
            let hasText=(session.document.string ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty == false
            matchLabel.stringValue = !hasText ? "此 PDF 无可检索文字" : query.isEmpty ? "输入文字开始查找" : searchResults.isEmpty ? "没有匹配结果" : "\(searchResults.count) 个匹配"
        }
        pdfView.highlightedSelections=nil;table.deselectAll(nil);table.reloadData();previousMatch.isEnabled=resultCount>0;nextMatch.isEnabled=resultCount>0
    }
    @objc private func previousSearchMatch() {activateMatch(at:table.selectedRow<=0 ? resultCount-1 : table.selectedRow-1)}
    @objc private func nextSearchMatch() {activateMatch(at:table.selectedRow+1>=resultCount ? 0 : table.selectedRow+1)}
    private func activateMatch(at index:Int) {
        guard !canvas.gesture else{return}
        if searchingNotes {
            guard noteResults.indices.contains(index) else{return}
            let note=noteResults[index];hideSearch();showNote(note.id);return
        }
        guard searchResults.indices.contains(index) else{return}
        closeParameters();canvas.clearSelection();let selection=searchResults[index]
        if let page=selection.pages.first {navigate(to:PDFDestination(page:page,at:CGPoint(x:selection.bounds(for:page).minX,y:selection.bounds(for:page).maxY)))}
        selection.color=NSColor.systemOrange.withAlphaComponent(0.40);pdfView.highlightedSelections=[selection]
        table.selectRowIndexes(IndexSet(integer:index),byExtendingSelection:false);table.scrollRowToVisible(index);matchLabel.stringValue="第 \(index+1) / \(searchResults.count) 个匹配";refresh()
    }
    private func updateOutlineSelection() {
        guard sidebarVisible,!searchVisible,sidebarTabs.selectedSegment==1,let page=pdfView.currentPage else{return}
        let index=session.document.index(for:page)
        if let row=outlineRows.indices.last(where:{ i in
            guard let target=outlineRows[i].0.destination?.page else{return false}
            return session.document.index(for:target)<=index
        }) {table.selectRowIndexes(IndexSet(integer:row),byExtendingSelection:false)}
    }
    private func buildOutline() {
        outlineRows = []
        func append(_ item: PDFOutline, level: Int) { outlineRows.append((item,level)); for i in 0..<item.numberOfChildren { if let child = item.child(at:i) { append(child,level:level+1) } } }
        if let outline = session.document.outlineRoot { for i in 0..<outline.numberOfChildren { if let child = outline.child(at:i) { append(child,level:0) } } }
        table.reloadData()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { searchVisible ? resultCount : max(outlineRows.count,1) }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView(); let label = NSTextField(wrappingLabelWithString: "")
        cell.frame = CGRect(x:0,y:0,width:table.bounds.width,height:table.rowHeight)
        label.font = .systemFont(ofSize: 13)
        label.maximumNumberOfLines = searchVisible ? 3 : (outlineRows.isEmpty ? 2 : 1); label.lineBreakMode = .byTruncatingTail
        label.frame = CGRect(x: 10, y: 5, width: max(80,table.bounds.width-28), height: table.rowHeight-10)
        label.autoresizingMask = [.width]; cell.addSubview(label); cell.textField = label
        if searchVisible && searchingNotes {
            guard noteResults.indices.contains(row) else{return cell};let n=noteResults[row]
            let state=n.locationUncertain || n.anchors.isEmpty ? "待重新关联" : !session.annotations.hasMarks(n) ? "页面标记已移除" : "第 "+Set(n.anchors.map{$0.page+1}).sorted().map(String.init).joined(separator:",")+" 页"
            let summary=noteSummaries[n.id].flatMap{$0.0==n.revision ? $0.1 : nil} ?? (n.markdown.isEmpty ? "空正文 · 点击编辑" : "点击阅读正文与公式")
            label.stringValue=state+"\n"+summary
        } else if searchVisible {
            guard searchResults.indices.contains(row) else { return cell }; let selection = searchResults[row]
            let pageIndex = selection.pages.first.map { session.document.index(for:$0)+1 } ?? 0
            let line = selection.pages.first.flatMap { $0.selectionForLine(at:selection.bounds(for:$0).origin)?.string } ?? selection.string ?? ""
            let clean=line.replacingOccurrences(of:"\n",with:" ").trimmingCharacters(in:.whitespacesAndNewlines)
            let query=searchField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            var snippet=String(clean.prefix(90))
            if !query.isEmpty,let match=clean.range(of:query,options:.caseInsensitive) {
                let start=clean.index(match.lowerBound,offsetBy:-24,limitedBy:clean.startIndex) ?? clean.startIndex
                let end=clean.index(match.upperBound,offsetBy:60,limitedBy:clean.endIndex) ?? clean.endIndex
                snippet=(start>clean.startIndex ? "…" : "")+String(clean[start..<end])+(end<clean.endIndex ? "…" : "")
            }
            label.stringValue = "第 \(pageIndex) 页\n\(snippet)"
        } else if outlineRows.isEmpty { label.stringValue = "此 PDF 没有目录\n可切换到缩略图" }
        else { label.stringValue = String(repeating:"  ", count:outlineRows[row].1) + (outlineRows[row].0.label ?? "未命名目录") }
        if searchVisible, let newline = label.stringValue.firstIndex(of:"\n") {
            let text = NSMutableAttributedString(string:label.stringValue,attributes:[.font:NSFont.systemFont(ofSize:13),.foregroundColor:NSColor.labelColor])
            let paragraph=NSMutableParagraphStyle();paragraph.lineSpacing=4;paragraph.lineBreakMode = .byTruncatingTail
            text.addAttribute(.paragraphStyle,value:paragraph,range:NSRange(location:0,length:text.length))
            text.addAttributes([.font:NSFont.systemFont(ofSize:11,weight:.medium),.foregroundColor:NSColor.secondaryLabelColor],range:NSRange(label.stringValue.startIndex..<newline,in:label.stringValue))
            let query=searchField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
            if !query.isEmpty {
                let source=text.string as NSString;var remaining=NSRange(location:0,length:source.length)
                while remaining.length>0 {
                    let match=source.range(of:query,options:[.caseInsensitive],range:remaining)
                    if match.location == NSNotFound {break}
                    text.addAttribute(.font,value:NSFont.systemFont(ofSize:13,weight:.semibold),range:match)
                    remaining=NSRange(location:NSMaxRange(match),length:source.length-NSMaxRange(match))
                }
            }
            label.attributedStringValue=text
        }
        return cell
    }
    @objc private func activateRow() {
        if searchVisible { activateMatch(at:table.clickedRow) }
        else if outlineRows.indices.contains(table.clickedRow), let destination = outlineRows[table.clickedRow].0.destination { navigate(to:destination) }
    }
    func navigate(to destination: PDFDestination, record: Bool = true) {
        guard !canvas.gesture else { return }; closeParameters(); canvas.clearSelection()
        if record { recordHistory() }; pdfView.go(to:destination)
        if record { recordHistory() }; refresh(); rememberPosition()
    }
    private func recordHistory() {
        guard !navigatingHistory, let destination = pdfView.currentDestination else { return }
        if historyIndex >= 0, historyIndex < navigationHistory.count {
            let old = navigationHistory[historyIndex]
            if old.page === destination.page && hypot(old.point.x-destination.point.x,old.point.y-destination.point.y)<3 { return }
        }
        if historyIndex+1 < navigationHistory.count { navigationHistory.removeSubrange((historyIndex+1)..<navigationHistory.count) }
        navigationHistory.append(destination); historyIndex = navigationHistory.count-1
    }
    @objc private func goBack() { historyJump(-1) }
    @objc private func goForward() { historyJump(1) }
    private func historyJump(_ delta:Int) {
        guard !canvas.gesture else { return }
        let target = historyIndex+delta; guard navigationHistory.indices.contains(target) else { return }
        navigatingHistory = true; historyIndex = target; navigate(to:navigationHistory[target],record:false); navigatingHistory = false; refresh()
    }
    @objc private func jumpPage() {
        guard !canvas.gesture, let index = Int(pageField.stringValue), let page = session.document.page(at:index-1) else { refresh(); return }
        navigate(to:PDFDestination(page:page,at:CGPoint(x:page.bounds(for:.cropBox).minX,y:page.bounds(for:.cropBox).maxY))); window?.makeFirstResponder(canvas)
    }
    @objc private func changeZoom() {
        guard !canvas.gesture else { return }; closeParameters(); let destination = pdfView.currentDestination
        if zoom.indexOfSelectedItem == 0 { pdfView.autoScales = true }
        else if zoom.indexOfSelectedItem == 1, let page = pdfView.currentPage {
            pdfView.autoScales = false; let rect = page.bounds(for:.cropBox); let rotated = page.rotation % 180 != 0
            pdfView.scaleFactor = min((pdfView.bounds.width-24)/(rotated ? rect.height:rect.width),(pdfView.bounds.height-24)/(rotated ? rect.width:rect.height))
        } else if let number = Double(zoom.title.replacingOccurrences(of:"%",with:"")) { pdfView.autoScales = false; pdfView.scaleFactor = number/100 }
        if let destination { pdfView.go(to:destination) }; refresh(); rememberPosition()
    }

    @objc private func showPath() {
        let menu = NSMenu(); let item = NSMenuItem(title:"在 Finder 中显示",action:#selector(revealFile),keyEquivalent:""); item.target = self; menu.addItem(item)
        menu.addItem(NSMenuItem(title:session.fileURL.path,action:nil,keyEquivalent:"")); menu.popUp(positioning:nil,at:CGPoint(x:0,y:0),in:titleButton)
    }
    @objc private func revealFile() { NSWorkspace.shared.activateFileViewerSelecting([session.fileURL]) }
    func showNotice(_ message:String) { let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle:"好"); if let window { alert.beginSheetModal(for:window) } }
    @objc private func showSaveState() {
        if session.annotationReadOnly { showNotice(session.annotationWarnings.joined(separator:"\n")); return }
        guard !session.isSaving else { return }
        let alert = NSAlert(); alert.messageText = session.statusText.isEmpty ? "已保存" : session.statusText
        if session.isModified { if !session.conflictDetected { alert.addButton(withTitle:"重试保存") }; alert.addButton(withTitle:"另存为…") }
        alert.addButton(withTitle:"关闭")
        alert.beginSheetModal(for:window!) { [weak self] response in
            guard let self else { return }
            if self.session.isModified {
                if !self.session.conflictDetected && response == .alertFirstButtonReturn { self.saveDocument() }
                else if response == (self.session.conflictDetected ? .alertFirstButtonReturn : .alertSecondButtonReturn) { self.saveDocumentAs() }
            }
        }
    }
    @objc func saveDocument() { performSave(to:nil) }
    @objc func saveDocumentAs() {
        guard !session.isSaving else { return }; canvas.finishInterruptedInput(); closeParameters()
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = session.fileURL.lastPathComponent
        panel.beginSheetModal(for:window!) { [weak self] response in if response == .OK, let url = panel.url { self?.performSave(to:url) } }
    }
    private func performSave(to url:URL?, thenClose:Bool = false) {
        noteCard.commit(); canvas.finishInterruptedInput(); closeParameters()
        session.save(to:url) { [weak self] result in
            guard let self else { return }; self.refresh()
            switch result {
            case .success(let outcome):
                if !outcome.recoveryCleanupSucceeded { self.showNotice(self.session.lastError?.localizedDescription ?? "PDF 已保存，但恢复记录清理失败；窗口已保留。") }
                else if thenClose && !self.session.isModified { self.closingAfterSave = true; self.window?.close() }
            case .failure(let error): self.showNotice(error.localizedDescription)
            }
        }
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool {
        noteCard.dismiss(); canvas.finishInterruptedInput(); closeParameters(); rememberPosition()
        guard !session.isSaving else { showNotice("PDF 正在保存，完成后再关闭；当前窗口和保存目标已保留。"); return false }
        if closingAfterSave || !session.isModified {
            guard session.discardRecovery() else { showNotice(session.lastError?.localizedDescription ?? "恢复记录未能清理，窗口已保留。"); return false }
            return true
        }
        let alert = NSAlert(); alert.messageText = "保存对“\(session.fileURL.lastPathComponent)”的修改？"
        alert.informativeText = "未保存的笔记还没有写入当前 PDF。"; alert.addButton(withTitle:"保存"); alert.addButton(withTitle:"不保存"); alert.addButton(withTitle:"取消")
        alert.beginSheetModal(for:sender) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { self.performSave(to:nil,thenClose:true) }
            if response == .alertSecondButtonReturn {
                guard self.session.discardRecovery() else { self.showNotice(self.session.lastError?.localizedDescription ?? "恢复记录未能清理，窗口已保留。"); return }
                self.closingAfterSave = true; self.window?.close()
            }
        }; return false
    }
    func windowWillClose(_ notification:Notification) {
        disconnectInputAndViews()
        rememberPosition()
        didClose?()
    }
    /// Called on actual close/termination, never on a cancelled save/quit prompt.
    func disconnectInputAndViews() {
        guard !disconnected else { return }
        canvas.finishInterruptedInput()
        disconnected = true
        if NSCursor.current === ReaderCanvas.paperCursor {NSCursor.arrow.set()}
        inputScope?.stop(); inputScope = nil
        notifications.forEach(NotificationCenter.default.removeObserver); notifications.removeAll()
        closeParameters(); root.onLayout = nil
        noteCard.disconnect(); session.onHistoryNote = nil
        pdfView.pageOverlayViewProvider = nil
        canvas.presentation.disconnect()
        session.onInkChange = nil; session.onChange = nil; session.isTargetOpenElsewhere = nil
    }
    func windowDidBecomeKey(_ notification:Notification) { canvas.refreshToolCursor(); InkRuntimeReport.record(window:window,scale:pdfView.scaleFactor) }
    func windowDidResignKey(_ notification:Notification) { canvas.refreshToolCursor(); inputScope?.lostFocus(); noteCard.commit(); canvas.finishInterruptedInput(); closeParameters(); canvas.clearSelection(); pdfView.clearSelection() }
    func windowWillResize(_ sender:NSWindow,to frameSize:NSSize) -> NSSize { canvas.gesture ? sender.frame.size : frameSize }
    func windowDidResize(_ notification:Notification) { closeParameters(); root.needsLayout = true }
    private func offerRecovery() {
        guard let record = session.recoverableRecord else { return }
        let alert = NSAlert(); alert.messageText = "发现此 PDF 的未保存恢复内容"
        alert.informativeText = "恢复不会覆盖原 PDF；恢复后仍需要保存或另存。"; alert.addButton(withTitle:"恢复"); alert.addButton(withTitle:"丢弃恢复内容")
        alert.beginSheetModal(for:window!) { [weak self] response in
            guard let self else { return }
            if response == .alertFirstButtonReturn { do { try self.session.restoreRecovery(record) } catch { self.showNotice(error.localizedDescription) } }
            else if !self.session.discardRecovery() { self.showNotice(self.session.lastError?.localizedDescription ?? "恢复记录未能清理，请稍后重试。") }
        }
    }
    private var positionURL: URL {
        let base = EcruEnvironment.applicationSupportDirectory
        try? FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        return base.appendingPathComponent("reading-positions.plist")
    }
    func rememberPosition() {
        guard !rebinding, let page = pdfView.currentPage else { return }
        var all = (NSDictionary(contentsOf:positionURL) as? [String:[String:Any]]) ?? [:]
        let p = pdfView.currentDestination?.point ?? CGPoint.zero
        all[session.fileURL.path] = ["page":session.document.index(for:page),"x":p.x,"y":p.y,"scale":pdfView.scaleFactor,"auto":pdfView.autoScales]
        (all as NSDictionary).write(to:positionURL,atomically:true)
    }
    private func restorePosition() {
        guard let all = NSDictionary(contentsOf:positionURL) as? [String:[String:Any]], let value = all[session.fileURL.path], let index = value["page"] as? Int, let page = session.document.page(at:index) else {
            // The native toolbar/split view settles after PDFKit first lays out.
            // With no saved destination, start at the first page rather than
            // retaining the intermediate scroll offset from that initial layout.
            root.layoutSubtreeIfNeeded();pdfView.layoutDocumentView()
            if let first=session.document.page(at:0) {pdfView.go(to:first)}
            return
        }
        pdfView.autoScales = value["auto"] as? Bool ?? true
        if !pdfView.autoScales { pdfView.scaleFactor = value["scale"] as? Double ?? 1 }
        pdfView.go(to:PDFDestination(page:page,at:CGPoint(x:value["x"] as? Double ?? 0,y:value["y"] as? Double ?? 0))); refresh()
    }
    // Used by the native UI integration runner, exercising the same controls/events.
    func selectTool(_ tool:ReaderTool) { toolButtons.first(where:{$0.tag == tool.rawValue})?.performClick(nil) }
    func testSelectTool(_ tool:ReaderTool) { selectTool(tool) }
    func testSearch(_ query:String) { searchScope.selectedSegment=0; openSearch(); searchField.stringValue = query; performSearch() }
    func testMatch(_ index:Int) { activateMatch(at:index) }
    var testResultCount:Int { resultCount }
    func testNoteSearch(_ category:Int=0) {openNoteSearch();noteFilter.selectItem(at:category);performSearch()}
    var testNoteResultIDs:[UUID] {noteResults.map(\.id)}
    func testNoteSummary(_ id:UUID)->String? {noteSummaries[id]?.1}
    var testSidebarVisible:Bool { sidebarVisible }
    var testSearchField:NSSearchField { searchField }
    var testPageField:NSTextField { pageField }
    func testOpenColor() { (parameters.arrangedSubviews.first as? NSButton)?.performClick(nil) }
    func testGoBack() { goBack() }
    #if ECRU_UI_TESTS
    func testChooseZoom(_ title:String) { zoom.selectItem(withTitle:title); changeZoom() }
    var testZoomMenuTitles:[String] { zoom.itemTitles }
    func testResizeSidebar(_ width:CGFloat) {body.setPosition(splitView(body,constrainSplitPosition:width,ofSubviewAt:0),ofDividerAt:0);layoutViews()}
    var testSidebarWidth:CGFloat {sidebar.frame.width}
    func testOpenWidth() {(parameters.arrangedSubviews.last as? NSButton)?.performClick(nil)}
    func testShowThumbnails() { sidebarTabs.selectedSegment=0; changeSidebarTab() }
    func testShowOutline() { sidebarTabs.selectedSegment=1; changeSidebarTab() }
    var testInterfaceIssues: [String] {
        root.layoutSubtreeIfNeeded()
        var issues: [String] = []
        if window?.title != session.fileURL.lastPathComponent || window?.subtitle != "" || titleButton.title != session.fileURL.lastPathComponent { issues.append("document title identity") }
        if let window, titleButton.window === window {
            let titleRect=titleButton.convert(titleButton.bounds,to:nil)
            if abs(titleRect.midX-window.frame.width/2)>2 { issues.append("document title not centered") }
            for id in ["navigation","page","zoom","search"] {
                if let view=toolbarItems[NSToolbarItem.Identifier(id)]?.view {
                    let rect=view.convert(view.bounds,to:nil)
                    if titleRect.intersection(rect).width>1 {issues.append("document title overlaps "+id)}
                }
            }
        }
        for (id, controls) in [("navigation", [sidebarButton,back,forward] as [NSView]), ("page",[pageField,pageCount] as [NSView])] {
            if let group = toolbarItems[NSToolbarItem.Identifier(id)]?.view {
                for control in controls {
                    let rect = control.convert(control.bounds,to:group)
                    if abs(rect.midY-group.bounds.midY)>1 { issues.append(id+" control not vertically centered") }
                }
            }
        }
        let visibleIDs=Set(window?.toolbar?.visibleItems?.map(\.itemIdentifier) ?? [])
        for (id,item) in toolbarItems where id.rawValue != "status" {
            if !visibleIDs.contains(id) || item.view?.window !== window {issues.append("native toolbar overflow: "+id.rawValue)}
        }
        let controls = toolButtons + [undoButton,redoButton] + parameters.arrangedSubviews.compactMap {$0 as? NSButton}
        for control in controls {
            let rect = annotationBar.convert(control.bounds,from:control)
            if !annotationBar.bounds.contains(rect) { issues.append(control.title+" clipped") }
        }
        for (i,a) in controls.enumerated() {
            for b in controls.dropFirst(i+1) {
                if annotationBar.convert(a.bounds,from:a).intersection(annotationBar.convert(b.bounds,from:b)).width > 1 { issues.append(a.title+" overlaps "+b.title) }
            }
        }
        if toolButtons.map(\.title) != ReaderTool.toolbarOrder.map(\.title) { issues.append("tool labels") }
        if searchVisible && sidebar.frame.intersects(annotationBar.convert(annotationBar.bounds,to:body)) { issues.append("search overlaps tools") }
        return issues
    }
    #endif

}
