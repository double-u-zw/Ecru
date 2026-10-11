import AppKit
import PDFKit
import WebKit
import QuartzCore

/// One reusable editor/renderer per reader. Its position is derived only from PDF geometry.
final class NoteTextView: NSTextView {
    var history: ((Bool) -> Void)?
    var finish: (() -> Void)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Candidate selection belongs to the input manager, including Escape/Return.
        guard !hasMarkedText() else { return super.performKeyEquivalent(with:event) }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "z" {
            history?(event.modifierFlags.contains(.shift)); return true
        }
        if event.modifierFlags.contains(.command), event.keyCode == 36 { finish?(); return true }
        return super.performKeyEquivalent(with:event)
    }
}

final class AnchoredNote: NSView, NSTextViewDelegate, WKNavigationDelegate, WKScriptMessageHandler {
    weak var reader: ReaderWindow?
    let editor = NoteTextView()
    let preview: WKWebView
    private let editScroll = NSScrollView()
    private let heading = NSTextField(labelWithString:"批注")
    private let dot = NSTextField(labelWithString:"●")
    private let more = NSButton(title:"",target:nil,action:nil)
    private let close = NSButton(title:"",target:nil,action:nil)
    private let edit = NSButton(title:"编辑",target:nil,action:nil)
    private let done = NSButton(title:"完成",target:nil,action:nil)
    private let mode = NSSegmentedControl(labels:["编辑","预览"],trackingMode:.selectOne,target:nil,action:nil)
    private let status = NSTextField(wrappingLabelWithString:"")
    private(set) var selectedID: UUID?
    private(set) var anchor: PageAnchor?
    private(set) var editing = false
    private(set) var unlocated = false
    private var provisional: (UUID,Bool)? // note, preserve pre-existing marks
    private var updating = false
    private var groupTimer: Timer?
    private var previewWork: DispatchWorkItem?
    private var serial = 0
    private var ready = false
    private var disconnected = false
    private var contentHeight: CGFloat = 90
    private var readingWidth:CGFloat=380
    private var editingWidth:CGFloat=400
    private var measuredViewportWidth:CGFloat=0
    private var editorLayoutWork:DispatchWorkItem?
    private enum Placement {case below,above,right,left}
    private var placement:Placement?
    private struct ReadingSize {
        var revision:UUID
        var limit:CGFloat
        var size:CGSize
    }
    private var readingSizes:[UUID:ReadingSize]=[:]
    private var renderedNote:UUID?
    private var renderedRevision:UUID?
    private var renderedLimit:CGFloat=0
    private var awaitingReadingSize=false
    private var clipObservation: NSObjectProtocol?
    private weak var observedClip: NSClipView?
    var isOpen: Bool { !isHidden && selectedID != nil }
    var isComposing: Bool { editing && editor.hasMarkedText() }

    init(reader: ReaderWindow) {
        self.reader=reader
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        preview=WKWebView(frame:.zero,configuration:config)
        super.init(frame:.zero)
        isHidden=true; wantsLayer=true
        layer?.backgroundColor=NSColor.windowBackgroundColor.cgColor
        layer?.cornerRadius=10; layer?.borderWidth=1;layer?.borderColor=NSColor.separatorColor.cgColor
        layer?.shadowOpacity=0.16;layer?.shadowRadius=8;layer?.shadowOffset=CGSize(width:0,height:-2)
        heading.font = .systemFont(ofSize:12,weight:.semibold);dot.font = .systemFont(ofSize:12);dot.textColor = .systemOrange
        for (b,symbol,action,label) in [(more,"ellipsis",#selector(showMore),"批注更多操作"),(close,"xmark",#selector(closeNote),"收起批注")] {
            b.image=NSImage(systemSymbolName:symbol,accessibilityDescription:label);b.bezelStyle = .accessoryBarAction;b.showsBorderOnlyWhileMouseInside=true;b.target=self;b.action=action;b.setAccessibilityLabel(label)
        }
        editor.isRichText=false;editor.allowsUndo=false;editor.font = .systemFont(ofSize:14)
        editor.isAutomaticQuoteSubstitutionEnabled=false;editor.isAutomaticDashSubstitutionEnabled=false;editor.isAutomaticTextReplacementEnabled=false
        editor.textContainerInset=CGSize(width:12,height:10);editor.isVerticallyResizable=true;editor.isHorizontallyResizable=false
        editor.autoresizingMask = [.width];editor.textContainer?.widthTracksTextView=true;editor.delegate=self
        editor.setAccessibilityLabel("原位 Markdown 批注正文")
        editor.history = { [weak reader] redo in if redo {reader?.redoAction()} else {reader?.undoAction()} }
        editor.finish = { [weak self] in self?.finishEditing() }
        editScroll.documentView=editor;editScroll.hasVerticalScroller=true
        done.toolTip="完成编辑（⌘↩）";close.toolTip="收起批注（Esc）"
        mode.target=self;mode.action=#selector(changeEditorMode);mode.selectedSegment=0
        for (b,a) in [(edit,#selector(startEditing)),(done,#selector(finishEditing))] {b.target=self;b.action=a;b.bezelStyle = .rounded;b.font = .systemFont(ofSize:12)}
        status.font = .systemFont(ofSize:11);status.textColor = .secondaryLabelColor
        for v in [dot,heading,more,close,editScroll,preview,edit,done,mode,status] {addSubview(v)}
        preview.navigationDelegate=self
        let doubleClick=NSClickGestureRecognizer(target:self,action:#selector(startEditing))
        doubleClick.numberOfClicksRequired=2
        preview.addGestureRecognizer(doubleClick)
        config.userContentController.add(WeakNoteMessage(self),name:"noteSize")
        config.userContentController.add(WeakNoteMessage(self),name:"copyFormula")
        if let root=Bundle.main.resourceURL?.appendingPathComponent("Preview") {preview.loadFileURL(root.appendingPathComponent("index.html"),allowingReadAccessTo:root)}
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
    required init?(coder:NSCoder) {fatalError()}
    override func layout() {
        super.layout();let w=bounds.width,h=bounds.height
        dot.frame=CGRect(x:10,y:h-29,width:14,height:20);heading.frame=CGRect(x:28,y:h-29,width:editing ? 70 : max(50,w-155),height:20)
        more.frame=CGRect(x:w-64,y:h-31,width:26,height:25);close.frame=CGRect(x:w-34,y:h-31,width:26,height:25)
        edit.frame=CGRect(x:w-120,y:h-30,width:50,height:24)
        mode.frame=CGRect(x:98,y:h-30,width:112,height:24);done.frame=CGRect(x:w-120,y:h-30,width:50,height:24)
        let warning=warningHeight(width:w)
        status.frame=CGRect(x:12,y:4,width:w-24,height:warning)
        let rect=CGRect(x:4,y:4+warning,width:w-8,height:max(28,h-40-warning))
        editScroll.frame=rect;preview.frame=rect
        editor.setFrameSize(CGSize(width:rect.width,height:max(rect.height,editor.frame.height)))
    }

    func open(_ id:UUID,anchor requested:PageAnchor?,editing:Bool=false,provisional preserve:Bool?=nil,unlocated:Bool=false) {
        if selectedID != id {dismiss()} else {commit()}
        guard let r=reader,let note=r.session.annotations.notes.first(where:{$0.id==id}) else{return}
        selectedID=id;self.unlocated=unlocated;anchor=unlocated ? nil : requested ?? note.anchors.first;placement=nil
        self.editing=editing && !r.session.annotationReadOnly;mode.selectedSegment=0
        if let preserve {provisional=(id,preserve)}
        updating=true;editor.string=note.markdown;updating=false
        isHidden=false;alphaValue=1;editingWidth=400;measuredViewportWidth=0;contentHeight=90
        refresh()
        if !self.editing {prepareReading()}
        reposition();requestPreview();measureEditorSoon()
        if self.editing {window?.makeFirstResponder(editor);editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0))}
        else {window?.makeFirstResponder(preview)}
    }
    func commit() {
        groupTimer?.invalidate();groupTimer=nil
        if editor.hasMarkedText() {editor.unmarkText()}
        if editing,let id=selectedID,!updating {
            reader?.session.editBody(id,markdown:editor.string)
            if !editor.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {provisional=nil}
        }
        reader?.session.finishBodyEditing()
    }
    func dismiss() {
        let ownsFocus = (window?.firstResponder as? NSView).map { $0.isDescendant(of:self) } ?? false
        commit();isHidden=true;alphaValue=1;awaitingReadingSize=false
        if let (id,preserve)=provisional {reader?.session.discardEmptyNote(id,preserveMarks:preserve)}
        provisional=nil;selectedID=nil;anchor=nil;placement=nil;previewWork?.cancel();editorLayoutWork?.cancel();serial+=1
        if let r=reader,ownsFocus {window?.makeFirstResponder(r.canvas)}
    }
    @objc func closeNote() {dismiss()}
    @objc func startEditing() {
        guard selectedID != nil,reader?.session.annotationReadOnly == false else{return}
        editing=true;alphaValue=1;awaitingReadingSize=false;editingWidth=400;contentHeight=90;placement=nil;mode.selectedSegment=0;refresh();reposition();measureEditorSoon();window?.makeFirstResponder(editor)
    }
    @objc func finishEditing() {
        // Keyboard completion is filtered by NoteTextView during composition;
        // the explicit button accepts the current native editing state.
        commit();editing=false;refresh();prepareReading();reposition();requestPreview();window?.makeFirstResponder(preview)
    }
    @objc private func changeEditorMode() {
        commit();refresh()
        if mode.selectedSegment==1 {prepareReading()}
        else {alphaValue=1;awaitingReadingSize=false;contentHeight=90;placement=nil;measureEditorSoon()}
        reposition();requestPreview();window?.makeFirstResponder(mode.selectedSegment==0 ? editor : preview)
    }
    private var readingLimit:CGFloat {
        let width=(superview?.bounds.width ?? 496)-16
        return min(480,max(240,width*0.62),width)
    }
    private func prepareReading() {
        guard let id=selectedID,let note=reader?.session.annotations.notes.first(where:{$0.id==id}) else{return}
        placement=nil
        if let measured=readingSizes[id],measured.revision==note.revision,abs(measured.limit-readingLimit)<1 {
            readingWidth=measured.size.width;contentHeight=measured.size.height
        } else {readingWidth=min(380,readingLimit);contentHeight=60}
        // Never expose the provisional 380-point frame or another note's WebKit
        // contents while its asynchronous intrinsic-size result is still pending.
        awaitingReadingSize = renderedNote != id || renderedRevision != note.revision || abs(renderedLimit-readingLimit)>=1
        alphaValue=awaitingReadingSize ? 0 : 1
    }
    func refresh() {
        guard let r=reader,let id=selectedID,let note=r.session.annotations.notes.first(where:{$0.id==id}) else {if selectedID != nil {isHidden=true};return}
        let color=note.links.compactMap { link in
            r.session.annotations.marks.first{$0.id==link.markID}?.rgba ?? r.session.annotations.ink.flatMap{$0}.first{$0.id==link.markID}?.rgba
        }.first
        if let color {dot.textColor=NSColor(srgbRed:color[0],green:color[1],blue:color[2],alpha:1)}
        else {dot.textColor = .systemOrange}
        var messages=r.session.annotationWarnings
        if r.session.annotationReadOnly {messages.append("当前批注只读，原有数据已保留")}
        if unlocated {messages.append("原文位置待重新关联；当前为临时查看／编辑") }
        else if note.locationUncertain {messages.append("原文位置待重新关联")}
        else if !r.session.annotations.hasMarks(note) {messages.append("页面标记已移除，正文已保留")}
        status.stringValue=messages.joined(separator:" · ");status.toolTip=status.stringValue
        editor.isEditable=editing && !r.session.annotationReadOnly
        edit.isHidden=editing;mode.isHidden = !editing;done.isHidden = !editing
        edit.isEnabled = !r.session.annotationReadOnly;heading.stringValue=unlocated ? "批注 · 临时" : "批注"
        editScroll.isHidden = !editing || mode.selectedSegment==1;preview.isHidden=editing && mode.selectedSegment==0
        needsLayout=true
    }
    func historyChanged(_ id:UUID?,label:String) {
        groupTimer?.invalidate();groupTimer=nil;provisional=nil
        guard let r=reader else{return}
        if let id,let note=r.session.annotations.notes.first(where:{$0.id==id}) {
            if selectedID != id {r.navigateToNote(note);placement=nil}
            selectedID=id;unlocated=note.locationUncertain || note.anchors.isEmpty;anchor=unlocated ? nil : note.anchors.first;isHidden=false
        }
        updating=true;editor.string=r.session.annotations.notes.first{$0.id==selectedID}?.markdown ?? "";updating=false
        refresh();status.stringValue=label+" · "+status.stringValue;requestPreview();reposition();measureEditorSoon()
    }
    func textDidChange(_ notification:Notification) {
        guard !updating,editing,let id=selectedID else{return}
        reader?.session.editBody(id,markdown:editor.string)
        groupTimer?.invalidate();groupTimer=Timer.scheduledTimer(withTimeInterval:0.8,repeats:false) { [weak self] _ in guard let self,!self.isComposing else{return};self.reader?.session.finishBodyEditing() }
        requestPreview();measureEditorSoon()
    }
    func observeScrolling() {
        guard let clip=reader?.pdfView.documentView?.enclosingScrollView?.contentView,observedClip !== clip else{return}
        if let token=clipObservation {NotificationCenter.default.removeObserver(token)}
        observedClip=clip;clip.postsBoundsChangedNotifications=true
        // Synchronous notification: the anchor and card enter the same display transaction.
        clipObservation=NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:clip,queue:nil) { [weak self] _ in self?.reader?.positionNoteUI() }
    }
    private func measureEditorSoon() {
        editorLayoutWork?.cancel()
        guard editing,mode.selectedSegment==0,!isComposing else{return}
        let work=DispatchWorkItem { [weak self] in
            guard let self,self.isOpen,self.editing,!self.isComposing,let host=self.superview else{return}
            let w=min(self.editingWidth,host.bounds.width-16)-8
            if abs(self.editor.frame.width-w)>1 {self.editor.setFrameSize(CGSize(width:w,height:self.editor.frame.height))}
            guard let manager=self.editor.layoutManager,let container=self.editor.textContainer else{return}
            manager.ensureLayout(for:container)
            let height=max(80,ceil(manager.usedRect(for:container).height+self.editor.textContainerInset.height*2))
            self.editor.setFrameSize(CGSize(width:w,height:height));self.needsLayout=true
            if abs(self.contentHeight-height)>1 {self.contentHeight=height;self.reposition()}
        }
        editorLayoutWork=work;DispatchQueue.main.async(execute:work)
    }
    private func warningHeight(width:CGFloat)->CGFloat {
        guard !status.stringValue.isEmpty else{return 0}
        let rect=(status.stringValue as NSString).boundingRect(with:CGSize(width:max(100,width-24),height:1000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:NSFont.systemFont(ofSize:11)])
        return min(72,max(24,ceil(rect.height)+8))
    }
    func reposition() {
        guard !isHidden,let r=reader,let host=superview else{return}
        let view=host.bounds.insetBy(dx:8,dy:8)
        guard view.width>200,view.height>100 else{return}
        let maximumWidth=editing && mode.selectedSegment==0 ? min(400,view.width) : min(480,max(240,view.width*0.62),view.width)
        let width=min(editing && mode.selectedSegment==0 ? editingWidth : readingWidth,maximumWidth)
        let overhead:CGFloat=40+warningHeight(width:width)
        var height=min(max(editing ? 150 : 84,contentHeight+overhead),view.height*0.60)
        var x=view.midX-width/2,y=view.maxY-height-12
        if !unlocated {
            guard let a=anchor,let page=r.session.document.page(at:a.page) else{return}
            let rect=host.convert(r.pdfView.convert(a.bounds,from:page),from:r.pdfView)
            guard rect.intersects(host.bounds) else{dismiss();return}
            let below=rect.minY-8-view.minY,above=view.maxY-rect.maxY-8
            let minimum=min(height,editing ? 150 : 84)
            // Fix the side while it remains usable. Grow within its space rather
            // than jumping above/below the source on each keystroke.
            if !editing || mode.selectedSegment==1 || placement==nil || (placement == .below && below<minimum) || (placement == .above && above<minimum)
                || (placement == .right && rect.maxX+12+width>view.maxX) || (placement == .left && rect.minX-12-width<view.minX) {
                // Prefer the side of the quoted passage; do not cover the lines directly below it.
                // Keep the chosen side during typing; only reconsider when it no longer fits.
                if rect.maxX+12+width<=view.maxX {placement = .right}
                else if rect.minX-12-width>=view.minX {placement = .left}
                else if below>=minimum {placement = .below}
                else if above>=minimum {placement = .above}
                else {placement = below>=above ? .below : .above}
            }
            x=min(max(rect.minX,view.minX),view.maxX-width)
            switch placement! {
            case .below:if below>=minimum {height=min(height,below)};y=max(view.minY,rect.minY-8-height)
            case .above:if above>=minimum {height=min(height,above)};y=min(view.maxY-height,rect.maxY+8)
            case .right:x=rect.maxX+12;y=min(max(rect.midY-height/2,view.minY),view.maxY-height)
            case .left:x=rect.minX-12-width;y=min(max(rect.midY-height/2,view.minY),view.maxY-height)
            }
        }
        x=min(max(x,view.minX),view.maxX-width);y=min(max(y,view.minY),view.maxY-height)
        let next=CGRect(x:x,y:y,width:width,height:height)
        if frame != next {CATransaction.begin();CATransaction.setDisableActions(true);frame=next;CATransaction.commit();needsLayout=true}
        if abs(measuredViewportWidth-maximumWidth)>1 {
            measuredViewportWidth=maximumWidth;requestPreview();measureEditorSoon()
        }
    }
    private func requestPreview() {
        previewWork?.cancel();serial+=1
        guard ready,!disconnected,!preview.isHidden,let r=reader,let n=r.session.annotations.notes.first(where:{$0.id==selectedID}) else{return}
        let payload:[String:Any]=["serial":serial,"note":n.id.uuidString,"revision":n.revision.uuidString,"document":r.session.annotations.documentID.uuidString,"source":n.markdown.isEmpty ? "（尚未填写正文）" : n.markdown,"macros":n.macros,"layout":["minimum":min(212,measuredViewportWidth-8),"base":min(380,measuredViewportWidth)-8,"maximum":measuredViewportWidth-8]]
        guard let data=try? JSONSerialization.data(withJSONObject:payload),let json=String(data:data,encoding:.utf8) else{return}
        let work=DispatchWorkItem { [weak self] in guard let self,!self.disconnected,self.isOpen,self.serial == payload["serial"] as? Int else{return};self.preview.evaluateJavaScript("renderNote(\(json))",completionHandler:nil) }
        previewWork=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.08,execute:work)
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {ready=true;requestPreview();reader?.previewBecameReady()}
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        guard !disconnected,isOpen,let value=message.body as? [String:Any],let r=reader,
              let note=r.session.annotations.notes.first(where:{$0.id==selectedID}),
              value["serial"] as? Int==serial,value["note"] as? String==note.id.uuidString,
              value["revision"] as? String==note.revision.uuidString,
              value["document"] as? String==r.session.annotations.documentID.uuidString else{return}
        if message.name=="copyFormula" {
            guard let text=value["source"] as? String,text.utf8.count<=500_000 else{return}
            NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string);return
        }
        guard let h=value["height"] as? Double,let w=value["width"] as? Double,h.isFinite,w.isFinite,w>0 else{return}
        if !editing || mode.selectedSegment==1 {
            let nextWidth=CGFloat(w)+8
            if readingSizes.count>128 {readingSizes.removeAll()}
            readingSizes[note.id]=ReadingSize(revision:note.revision,limit:measuredViewportWidth,size:CGSize(width:nextWidth,height:h))
            renderedNote=note.id;renderedRevision=note.revision;renderedLimit=measuredViewportWidth
            if abs(contentHeight-CGFloat(h))>1 || abs(readingWidth-nextWidth)>1 {
                contentHeight=CGFloat(h);readingWidth=nextWidth;reposition()
            }
            if awaitingReadingSize {awaitingReadingSize=false;layoutSubtreeIfNeeded();alphaValue=1}
        }
    }
    func summarize(_ notes:[AnnotationNote],completion:@escaping([(UUID,UUID,String)])->Void) {
        guard ready,!disconnected,!notes.isEmpty else{return}
        let payload=notes.map{["id":$0.id.uuidString,"revision":$0.revision.uuidString,"source":String($0.markdown.prefix(10000)),"quote":$0.anchors.map(\.quote).joined(separator:" ")]}
        guard let data=try? JSONSerialization.data(withJSONObject:payload),let json=String(data:data,encoding:.utf8) else{return}
        preview.evaluateJavaScript("summarizeNoteSources(\(json))") { [weak self] result,_ in
            guard let self,!self.disconnected,let rows=result as? [[String:String]] else{return}
            completion(rows.compactMap{row in guard let id=row["id"].flatMap(UUID.init(uuidString:)),let revision=row["revision"].flatMap(UUID.init(uuidString:)) else{return nil};return (id,revision,row["text"] ?? "")})
        }
    }
    func webView(_ webView:WKWebView,decidePolicyFor action:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        if action.navigationType == .linkActivated {
            if let u=action.request.url,["http","https","mailto"].contains(u.scheme?.lowercased() ?? "") {NSWorkspace.shared.open(u)}
            decisionHandler(.cancel);return
        }
        decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
    }
    @objc private func showMore() {
        let menu=NSMenu();menu.autoenablesItems=false
        if unlocated || reader?.session.annotations.notes.first(where:{$0.id==selectedID})?.locationUncertain == true {
            let repair=NSMenuItem(title:"修复原文位置…",action:#selector(relink),keyEquivalent:"");repair.target=self
            repair.isEnabled=reader?.session.annotationReadOnly == false;menu.addItem(repair)
        }
        let delete=NSMenuItem(title:"删除批注",action:#selector(deleteNote),keyEquivalent:"");delete.target=self
        delete.isEnabled=reader?.session.annotationReadOnly == false;menu.addItem(delete)
        menu.popUp(positioning:nil,at:NSPoint(x:more.frame.minX,y:more.frame.minY),in:self)
    }
    @objc private func relink() {commit();reader?.showNotice("请在正确的原文位置框选，完成后修复此批注的定位。正文不会删除；按 Escape 取消。");reader?.beginRegionNote(relink:selectedID)}
    @objc private func deleteNote() {commit();guard let id=selectedID else{return};provisional=nil;dismiss();reader?.session.deleteNote(id)}
    func disconnect() {commit();disconnected=true;groupTimer?.invalidate();previewWork?.cancel();editorLayoutWork?.cancel();if let token=clipObservation {NotificationCenter.default.removeObserver(token)};clipObservation=nil;preview.stopLoading();preview.navigationDelegate=nil;preview.configuration.userContentController.removeScriptMessageHandler(forName:"noteSize");preview.configuration.userContentController.removeScriptMessageHandler(forName:"copyFormula");reader=nil}
}
private final class WeakNoteMessage: NSObject,WKScriptMessageHandler {
    weak var note:AnchoredNote?
    init(_ note:AnchoredNote) {self.note=note}
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {note?.userContentController(userContentController,didReceive:message)}
}
