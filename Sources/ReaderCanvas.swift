import AppKit
import PDFKit

enum ReaderTool: Int, CaseIterable {
    case select, pen, textHighlight, marker, eraser, lasso
    static let toolbarOrder: [ReaderTool] = [.select,.pen,.eraser,.textHighlight,.marker,.lasso]
    var title: String { ["选择", "笔", "文字高亮", "自由荧光笔", "橡皮", "圈选"][rawValue] }
    var symbol: String { ["cursorarrow", "pencil.tip", "textformat", "highlighter", "eraser", "lasso"][rawValue] }
}

/// Transparent input router. Page content is rendered exclusively by PDFKit-owned overlays.
final class ReaderCanvas: NSView {
    lazy var presentation = PageInkPresentation(canvas: self)
    override var needsDisplay: Bool {
        get { super.needsDisplay }
        set {
            super.needsDisplay = newValue
            if newValue && (tool == .lasso || selectedHighlight != nil) { presentation.invalidateAll() }
        }
    }

    weak var reader: ReaderWindow?
    var pdfView: PDFView { reader!.pdfView }
    var session: DocumentSession { reader!.session }
    var tool: ReaderTool = .pen
    var colors: [ReaderTool: NSColor] = [.pen: .systemBlue, .textHighlight: .systemYellow, .marker: .systemYellow]
    var widths: [ReaderTool: Double] = [.pen: 1.6, .marker: 14]
    var eraserRadius: CGFloat = 10
    private(set) var activePage: PDFPage?
    private(set) var gesture = false
    private var start = CGPoint.zero
    private var previous = CGPoint.zero
    private var points: [CGPoint] = []
    private var activeInkID: UUID?
    private var inkBuilder: PenStrokeBuilding?
    private var markerBuilder: InkDirectBuilder?
    private var inputTrace: InkInputTrace?
    private var latestInputTimestamp: Double?
    private var previousCoalescing: Bool?

    private var draggingMove = false
    private var originalMove: [InkStroke] = []
    private(set) var selectionOutline: [CGPoint] = []
    private var originalOutline: [CGPoint] = []
    private var selectionPage: PDFPage?
    private(set) var selectedIDs = Set<UUID>()
    private var selectedHighlightID: UUID?
    private var clickedInkNote: (UUID,PageAnchor)?
    var selectedHighlight: PDFAnnotation? {
        guard let id=selectedHighlightID else{return nil}
        return selectionPage?.annotations.first { session.markID(for:$0) == id }
    }
    private var regionMode = false
    private var regionRelink: UUID?
    private var regionRect: CGRect?
    func beginRegion(relink:UUID?) { clearSelection(); regionMode=true; regionRelink=relink; regionRect=nil; refreshToolCursor(); NSCursor.crosshair.set() }
    var selectedNoteID:UUID? {
        if let id=selectedHighlightID {return session.annotations.note(for:id)?.id}
        if let clicked=clickedInkNote {return clicked.0}
        let ids=Set(selectedIDs.compactMap{session.annotations.note(for:$0)?.id})
        return ids.count==1 ? ids.first : nil
    }
    override func menu(for event:NSEvent)->NSMenu? {
        guard let reader else{return nil}
        selectedHighlightID=nil
        if let (page,p)=location(event),let mark=page.annotations.reversed().first(where:{($0.type=="Highlight" || $0.type=="Square") && $0.bounds.contains(p)}).flatMap({session.markID(for:$0)}) {
            selectedHighlightID=mark;selectionPage=page
        }
        let menu=NSMenu();menu.autoenablesItems=false
        let text=NSMenuItem(title:reader.noteCommandTitle,action:#selector(ReaderWindow.addNoteFromSelection),keyEquivalent:"")
        text.target=reader;text.isEnabled=reader.canPerformNoteCommand;menu.addItem(text)
        return menu
    }
    private var textStartPage: PDFPage?
    private var textStart = CGPoint.zero
    private var pendingLink: PDFAnnotation?
    private var hadDrag = false
    private var tracking: NSTrackingArea?
    private(set) var eraserHoverPoint: CGPoint?
    var eraserHoverBounds: CGRect? {
        guard let point=eraserHoverPoint,let reader else{return nil}
        let radius=eraserRadius * reader.pdfView.scaleFactor
        return CGRect(x:point.x-radius,y:point.y-radius,width:radius*2,height:radius*2)
    }

    var activeInkStroke: InkStroke? {
        guard let page = activePage, let id = activeInkID else { return nil }
        let strokes=session.inkStrokes(on:page)
        return strokes.last?.id==id ? strokes.last : strokes.first { $0.id == id }
    }
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        // Leave native scrollbar dragging to NSScrollView, even in pen mode.
        if let scroll = reader?.pdfView.documentView?.enclosingScrollView {
            for scroller in [scroll.verticalScroller, scroll.horizontalScroller].compactMap({ $0 }) {
                if !scroller.isHidden && scroller.alphaValue > 0 &&
                    scroller.bounds.contains(scroller.convert(local, from: self)) { return nil }
            }
        }
        return super.hitTest(point)
    }
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .inVisibleRect], owner: self)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
        refreshToolCursor()
    }
    func clearSelection() {
        if selectionPage != nil { presentation.invalidateAll() }
        selectedIDs.removeAll(); selectionOutline = []; selectedHighlightID = nil; selectionPage = nil;clickedInkNote=nil
        needsDisplay = true; reader?.updateParameters()
    }
    func setTool(_ value: ReaderTool) {
        if regionMode { regionMode=false; regionRect=nil; regionRelink=nil; gesture=false; activePage=nil; presentation.invalidateAll(); NSCursor.arrow.set() }
        finishInterruptedInput(); clearSelection(); pdfView.clearSelection()
        tool = value; refreshToolCursor(); needsDisplay = true
    }
    private func location(_ event: NSEvent) -> (PDFPage, CGPoint)? {
        let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
        guard let page = pdfView.page(for: viewPoint, nearest: false) else { return nil }
        let point = pdfView.convert(viewPoint, to: page)
        guard page.bounds(for: .cropBox).contains(point) else { return nil }
        return (page, point)
    }
    private func strokes(_ page: PDFPage) -> [InkStroke] { session.inkStrokes(on: page) }
    private func replace(_ page: PDFPage, ids: Set<UUID>, with strokes: [InkStroke]) {
        session.replaceInk(on: page, ids: ids, with: strokes)
        needsDisplay = true
    }
    private var selectedBounds: CGRect? {
        if let selectedHighlight { return selectedHighlight.bounds }
        guard let page = selectionPage else { return nil }
        return strokes(page).filter { selectedIDs.contains($0.id) }.map(\.bounds).reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
    }
    override func mouseDown(with event: NSEvent) {
        cancelPadInkZoom()
        let received = ProcessInfo.processInfo.systemUptime
        guard let reader else { return }
        // A duplicate down or missing up must not overwrite the original
        // coalescing setting or abandon the preceding document transaction.
        if activePage != nil || previousCoalescing != nil { finishInterruptedInput() }
        // The click that dismisses a parameter popover is consumed before it reaches a page.
        if reader.parameterPopover.isShown { reader.closeParameters(); return }
        reader.noteCard.commit()
        window?.makeFirstResponder(self)
        updateToolCursor(at:event.locationInWindow)
        guard let (page, p) = location(event) else { clearSelection(); return }
        activePage = page; start = p; previous = p; points = [p]; hadDrag = false; pendingLink = nil;clickedInkNote=nil
        updateToolCursor(at:event.locationInWindow)
        if regionMode { gesture=true; regionRect=CGRect(origin:p,size:.zero); return }
        if session.annotationReadOnly && tool != .select { return }
        if tool == .select || tool == .textHighlight {
            if tool == .select, let link = page.annotations.reversed().first(where: { $0.type == "Link" && $0.bounds.contains(p) }) {
                clearSelection(); pendingLink = link; textStartPage = page; textStart = p
                pdfView.clearSelection()
                return
            }
            clearSelection()
            selectedHighlightID = page.annotations.reversed().first { ($0.type == "Highlight" || $0.type == "Square") && $0.bounds.contains(p) }.flatMap { session.markID(for:$0) }
            if tool == .select,selectedHighlightID == nil,
               let stroke=strokes(page).reversed().first(where:{stroke in
                   guard session.annotations.note(for:stroke.id) != nil else{return false}
                   let radius=max(stroke.width/2,4/pdfView.scaleFactor)
                   return InkGeometry.erase(stroke,center:p,radius:radius) != [stroke]
               }),let note=session.annotations.note(for:stroke.id) {
                clickedInkNote=(note.id,session.pageAnchor(page:page,bounds:stroke.bounds))
            }
            selectionPage = selectedHighlightID == nil ? nil : page
            textStartPage = page; textStart = p
            pdfView.clearSelection(); reader.updateParameters(); needsDisplay = true
            return
        }
        clearTextSelection()
        gesture = true
        if tool == .lasso, page === selectionPage, !selectedIDs.isEmpty, InkGeometry.contains(p, polygon: selectionOutline) {
            draggingMove = true; originalMove = strokes(page).filter { selectedIDs.contains($0.id) }
            originalOutline = selectionOutline
            guard startAction("移动笔迹") else { return }
        } else {
            clearSelection(); draggingMove = false
            if tool == .pen || tool == .marker {
                previousCoalescing = NSEvent.isMouseCoalescingEnabled
                NSEvent.isMouseCoalescingEnabled = false
                guard startAction(tool == .pen ? "书写" : "自由荧光笔") else {
                    restoreCoalescing(); return
                }
                let c = colors[tool]!.usingColorSpace(.sRGB)!
                var stroke = InkStroke(points: [InkPoint(p)], width: widths[tool]!,
                    rgba: [c.redComponent, c.greenComponent, c.blueComponent, tool == .marker ? 0.28 : 1],
                    kind: tool == .marker ? .marker : .pen)
                if tool == .pen {
                    InkRuntimeReport.record(window:window,scale:pdfView.scaleFactor,penDown:true)
                    inkBuilder=PenEngine.make(point:InkPoint(p),width:stroke.width,pressure:penPressure(event),timestamp:event.timestamp,viewScale:pdfView.scaleFactor)
                    stroke.widthFactors=inkBuilder?.initialFactors;stroke.appearance = .perfectFreehandV1;stroke.outlines=inkBuilder?.initialOutlines
                }
                else {markerBuilder=InkDirectBuilder(point:InkPoint(p))}
                if EcruEnvironment.value("ECRU_INPUT_TRACE_DIR") != nil {
                    inputTrace = InkInputTrace(id: stroke.id, scale: pdfView.scaleFactor, width: stroke.width, kind: stroke.kind)
                    inputTrace?.penResponse = tool == .pen ? PenEngine.recipe : "direct-marker-v1"
                    inputTrace?.pageIndex = session.document.index(for: page)
                    inputTrace?.mouseCoalescingEnabled = NSEvent.isMouseCoalescingEnabled
                    inputTrace?.captureVersion=2;inputTrace?.drawCallbacks=[]
                }
                guard stroke.isValid else {
                    finishInterruptedInput()
                    reader.showNotice("笔迹引擎未能开始此笔，请重新落笔。")
                    return
                }
                activeInkID = stroke.id
                session.replaceInk(on: page, ids: [], with: [stroke])
                recordInput(event, raw: p, point: p, received: received)
            }
            if tool == .eraser { guard startAction("局部擦除") else { return }; erase(at: p, on: page) }
        }
        needsDisplay = true
    }
    private func restoreCoalescing() {
        if let previousCoalescing { NSEvent.isMouseCoalescingEnabled = previousCoalescing }
        previousCoalescing = nil
    }
    deinit { restoreCoalescing() }
    private func clearTextSelection() { pdfView.clearSelection(); textStartPage = nil }
    private func startAction(_ label:String) -> Bool {
        let began = session.beginInkAction(label)
        guard began else { gesture = false; activePage = nil; reader?.refresh(); return false }
        return true
    }
    override func mouseDragged(with event: NSEvent) {
        let received = ProcessInfo.processInfo.systemUptime
        guard let page = activePage else { return }
        let viewPoint = pdfView.convert(event.locationInWindow, from: nil)
        var p = pdfView.convert(viewPoint, to: page)
        if regionMode {
            let crop=page.bounds(for:.cropBox)
            p.x=min(max(p.x,crop.minX),crop.maxX); p.y=min(max(p.y,crop.minY),crop.maxY)
            regionRect=CGRect(x:min(start.x,p.x),y:min(start.y,p.y),width:abs(p.x-start.x),height:abs(p.y-start.y))
            presentation.invalidate(page,bounds:crop); return
        }
        let rawPoint = p
        let b = page.bounds(for: .cropBox)
        if gesture, (tool == .pen || tool == .marker), !b.contains(p), let id = activeInkID {
            // End at the first page boundary. Repeated out-of-page samples must
            // never become a spurious line along the paper edge or toolbar.
            let dx = p.x-previous.x, dy = p.y-previous.y
            var t: CGFloat = 1
            if dx > 0 { t = min(t, (b.maxX-previous.x)/dx) }
            if dx < 0 { t = min(t, (b.minX-previous.x)/dx) }
            if dy > 0 { t = min(t, (b.maxY-previous.y)/dy) }
            if dy < 0 { t = min(t, (b.minY-previous.y)/dy) }
            p = CGPoint(x: previous.x+dx*max(0,t), y: previous.y+dy*max(0,t))
            appendInput(p, event: event, id: id, page: page)
            recordInput(event, raw: rawPoint, point: p, received: received)
            previous = p; finishInput(); return
        }
        // A lasso records the pointer's actual trajectory, including excursions
        // beyond the page. Clamping would replace that trajectory with page edges.
        if tool != .lasso || draggingMove {
            p.x = min(max(p.x, b.minX), b.maxX); p.y = min(max(p.y, b.minY), b.maxY)
        }
        hadDrag = hadDrag || hypot(p.x-start.x, p.y-start.y) > 1.5 / pdfView.scaleFactor
        if tool == .select || tool == .textHighlight {
            if hadDrag, let firstPage = textStartPage {
                selectedHighlightID = nil; selectionPage = nil;clickedInkNote=nil; reader?.updateParameters()
                let endPage = pdfView.page(for: viewPoint, nearest: true) ?? page
                let end = pdfView.convert(viewPoint, to: endPage)
                let selection = session.document.selection(from: firstPage, at: textStart, to: endPage, at: end)
                pdfView.setCurrentSelection(selection, animate: false)
            }
            return
        }
        guard gesture else { return }
        if draggingMove {
            selectionOutline = originalOutline.map { CGPoint(x: $0.x + p.x-start.x, y: $0.y + p.y-start.y) }
            replace(page, ids: selectedIDs, with: originalMove.map { $0.translated(dx: p.x-start.x, dy: p.y-start.y) })
        } else if tool == .eraser {
            let distance = hypot(p.x-previous.x, p.y-previous.y)
            let steps = max(1, Int(ceil(distance / max(1, eraserRadius / 2))))
            for step in 1...steps {
                let t = CGFloat(step) / CGFloat(steps)
                erase(at: CGPoint(x: previous.x + (p.x-previous.x)*t, y: previous.y + (p.y-previous.y)*t), on: page)
            }
        } else if let id = activeInkID {
            appendInput(p, event: event, id: id, page: page)
            recordInput(event, raw: rawPoint, point: p, received: received)
        } else { points.append(p) }
        previous = p
        updateToolCursor(at:event.locationInWindow)
        // Ink updates invalidate their page-local damage through the session.
        // Clearing the entire transparent viewport on every sample adds a second
        // backing-store redraw without displaying any additional ink.
        if tool != .pen && tool != .marker { needsDisplay = true }
    }
    private func erase(at p: CGPoint, on page: PDFPage) {
        for stroke in strokes(page) {
            guard stroke.bounds.insetBy(dx: -eraserRadius, dy: -eraserRadius).contains(p) else { continue }
            let fragments = InkGeometry.erase(stroke, center: p, radius: eraserRadius)
            if fragments != [stroke] { session.replaceInk(on: page, ids: [stroke.id], with: fragments) }
        }
        needsDisplay = true
    }
    private func penPressure(_ event: NSEvent) -> Double? {
        NativePenInput.pressure(from: event)
    }
    private func appendInput(_ p: CGPoint, event: NSEvent, id: UUID, page: PDFPage) {
        if let builder=inkBuilder {
            let update=builder.append(InkPoint(p),pressure:penPressure(event),isRelease:event.type == .leftMouseUp,timestamp:event.timestamp)
            if builder.generatedCount>99_900 {finishInterruptedInput();return}
            session.updatePerfectInk(update,to:id,on:page)
            if builder.capacityReached { finishInterruptedInput() }
        } else if var builder=markerBuilder {
            let generated=builder.append(InkPoint(p));markerBuilder=builder
            if builder.generatedCount>99_900 {finishInterruptedInput();return}
            session.appendInkPoints(generated.points,to:id,on:page)
        }
    }
    private func recordInput(_ event: NSEvent, raw: CGPoint, point: CGPoint, received: Double) {
        latestInputTimestamp = event.timestamp
        let cg=event.cgEvent,device=cg?.getIntegerValueField(.tabletEventDeviceID)
        let correlation=UInt64(bitPattern:cg?.getIntegerValueField(.eventSourceUserData) ?? 0)
        let padInk=device == 0x5049 && correlation != 0
        inputTrace?.samples.append(InkInputSample(point: InkPoint(point), rawPoint: InkPoint(raw),
            timestamp: event.timestamp, received: received, handled: ProcessInfo.processInfo.systemUptime,
            type: event.type.rawValue, subtype: event.subtype.rawValue, pressure: event.pressure,
            tablet: event.subtype == .tabletPoint || event.type == .tabletPoint || device == 0x5049,
            windowPoint:InkPoint(event.locationInWindow),quartzPoint:cg.map{InkPoint($0.location)},deviceID:device,
            forwardedGesture:padInk ? UInt32(truncatingIfNeeded:correlation>>32) : nil,
            forwardedSequence:padInk ? UInt32(truncatingIfNeeded:correlation) : nil,
            submitted:ProcessInfo.processInfo.systemUptime, nativePressure:penPressure(event)))
    }
    func inkDrawCompleted(on page:PDFPage,started:Double) {
        guard page === activePage,let count=inputTrace?.samples.count,count>0 else{return}
        inputTrace?.drawCallbacks?.append(InkDrawCallback(throughSample:count,started:started,completed:ProcessInfo.processInfo.systemUptime))
    }
    override func mouseUp(with event: NSEvent) {
        let received = ProcessInfo.processInfo.systemUptime
        if gesture, let id = activeInkID, let page = activePage {
            let raw = pdfView.convert(pdfView.convert(event.locationInWindow, from: nil), to: page)
            let b = page.bounds(for: .cropBox)
            var p = raw
            if !b.contains(raw) {
                // Match drag boundary handling even if up is the first event
                // outside the paper; component clamping would invent an edge line.
                let dx=raw.x-previous.x,dy=raw.y-previous.y
                var t:CGFloat=1
                if dx>0 {t=min(t,(b.maxX-previous.x)/dx)}
                if dx<0 {t=min(t,(b.minX-previous.x)/dx)}
                if dy>0 {t=min(t,(b.maxY-previous.y)/dy)}
                if dy<0 {t=min(t,(b.minY-previous.y)/dy)}
                p=CGPoint(x:previous.x+dx*max(0,t),y:previous.y+dy*max(0,t))
            }
            appendInput(p, event: event, id: id, page: page)
            recordInput(event, raw: raw, point: p, received: received)
        }
        if gesture, tool == .lasso, !draggingMove, let page = activePage {
            let p = pdfView.convert(pdfView.convert(event.locationInWindow, from: nil), to: page)
            if points.last != p { points.append(p) }
        }
        // Mouse-up does not erase again: show the last point actually erased.
        updateToolCursor(at:event.locationInWindow)
        finishInput()
    }
    func finishInterruptedInput() { cancelPadInkZoom(); inputTrace?.interrupted = true; finishInput(); restoreCoalescing(); refreshToolCursor() }
    private func finishInput() {
        guard let page = activePage else { return }
        if regionMode {
            let rect=regionRect; let relink=regionRelink
            regionMode=false; regionRect=nil; regionRelink=nil; gesture=false; activePage=nil; refreshToolCursor()
            presentation.invalidate(page,bounds:page.bounds(for:.cropBox))
            if let rect,let id=session.addRegion(page:page,rect:rect,to:relink) { reader?.showNote(id,focus:true,anchor:session.pageAnchor(page:page,bounds:rect),provisional:relink == nil ? false : nil) }
            return
        }
        defer {
            restoreCoalescing()
            inputTrace?.finished = ProcessInfo.processInfo.systemUptime
            inkBuilder?.finish(); inputTrace?.save(); inputTrace = nil; inkBuilder = nil; markerBuilder=nil; latestInputTimestamp = nil
            activePage = nil; activeInkID = nil; gesture = false; draggingMove = false; originalMove = []; originalOutline = []; points = []
            textStartPage = nil; reader?.updateParameters()
            if tool != .pen && tool != .marker { pdfView.needsDisplay = true }
            needsDisplay = true
        }
        if tool == .select, !hadDrag, let link = pendingLink {
            if let destination = link.destination { reader?.navigate(to: destination) }
            else if let action = link.action as? PDFActionGoTo { reader?.navigate(to: action.destination) }
            else if let action = link.action as? PDFActionURL, let url = action.url { NSWorkspace.shared.open(url) }
        }
        pendingLink = nil
        if tool == .textHighlight, hadDrag, let selection = pdfView.currentSelection, !(selection.string ?? "").isEmpty {
            session.addTextSelection(selection,color:colors[.textHighlight]!,withNote:false)
            pdfView.clearSelection()
        } else if (tool == .textHighlight || tool == .select), selectedHighlight == nil, pendingLink == nil, (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reader?.showNotice("此页没有可选择文字；文字选择与文字高亮不可用，可继续使用笔或自由荧光笔。")
        }
        if tool == .select, !hadDrag, let id=selectedHighlightID,let note=session.annotations.note(for:id) { reader?.showNote(note.id,anchor:session.annotations.marks.first{$0.id==id}?.anchor ?? session.pageAnchor(page:page,bounds:selectedHighlight?.bounds ?? page.bounds(for:.cropBox))) }
        if tool == .select,!hadDrag,let (id,anchor)=clickedInkNote {reader?.showNote(id,anchor:anchor)}
        if tool == .select {reader?.selectionChanged()}
        if gesture {
            if tool == .lasso && !draggingMove && points.count >= 3 {
                selectedIDs = Set(strokes(page).filter { InkGeometry.isFullyInside($0, polygon: points) }.map(\.id))
                selectionPage = selectedIDs.isEmpty ? nil : page
                selectionOutline = selectedIDs.isEmpty ? [] : points
            }
            if tool != .lasso || draggingMove { session.finishAction() }
        }
    }
    func deleteSelected() {
        guard let page = selectionPage else { return }
        if let id=selectedHighlightID { session.removeMark(id) }
        else { guard session.beginInkAction("删除所选笔迹") else{return}; replace(page,ids:selectedIDs,with:[]) }
        clearSelection(); session.finishAction(); pdfView.needsDisplay = true
    }
    var hasDeletableSelection: Bool { selectedHighlight != nil || !selectedIDs.isEmpty }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            // Escape cancels a pending repair rectangle, but commits received ink
            // once, including its action history and the coalescing lease.
            if regionMode { regionMode=false; regionRect=nil; regionRelink=nil; gesture=false; activePage=nil }
            finishInterruptedInput(); presentation.invalidateAll(); refreshToolCursor(); reader?.closeParameters(); clearSelection(); return
        }
        if event.keyCode == 51 || event.keyCode == 117 { if hasDeletableSelection { deleteSelected() }; return }
        super.keyDown(with: event)
    }
    override func scrollWheel(with event: NSEvent) {
        guard !gesture else { return }
        pdfView.documentView?.enclosingScrollView?.scrollWheel(with: event)
        reader?.positionNoteUI();needsDisplay = true
    }
    // Shared native PDF path for trackpad magnification and PadInk bridge v1.
    // Resolve the PDF coordinate BEFORE changing scale, then put it beneath the
    // new centroid. This also permits translation during an established pinch.
    func zoomPDF(logDelta: Double, from oldCenter: CGPoint, to center: CGPoint) {
        guard !gesture, logDelta.isFinite, abs(logDelta) <= 1 else { return }
        let oldPoint = pdfView.convert(oldCenter, from: nil)
        guard let page = pdfView.page(for: oldPoint, nearest: true) else { return }
        let anchor = pdfView.convert(oldPoint, to: page)
        reader?.closeParameters()
        if logDelta != 0 {
            pdfView.autoScales = false
            pdfView.scaleFactor = min(pdfView.maxScaleFactor, max(pdfView.minScaleFactor,
                                                                pdfView.scaleFactor * exp(logDelta)))
            pdfView.layoutDocumentView()
        }
        if let document = pdfView.documentView, let scroll = document.enclosingScrollView {
            let desired = document.convert(center, from: nil)
            let actual = document.convert(pdfView.convert(anchor, from: page), from: pdfView)
            let clip = scroll.contentView
            let proposed = CGRect(origin: CGPoint(x: clip.bounds.minX + actual.x-desired.x,
                                                   y: clip.bounds.minY + actual.y-desired.y), size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(proposed).origin)
            scroll.reflectScrolledClipView(clip)
        }
        reader?.positionNoteUI(); reader?.refresh(); needsDisplay = true
    }
    override func magnify(with event: NSEvent) {
        guard event.magnification > -1 else { return }
        zoomPDF(logDelta: log(1 + event.magnification), from: event.locationInWindow, to: event.locationInWindow)
    }
    private var padInkCenter: CGPoint?
    func cancelPadInkZoom() { padInkCenter = nil }
    /// Called by the window-local input scope, including when the moving center
    /// crosses a note overlay. Only a gesture that began on the canvas is admitted.
    static func isPadInkZoom(_ event: NSEvent) -> Bool {
        event.type == .scrollWheel && event.cgEvent?.getIntegerValueField(.eventSourceUserData) == 0x50494E4B0001
    }
    func handlePadInkZoom(_ event: NSEvent) -> Bool {
        guard Self.isPadInkZoom(event), let cg = event.cgEvent else { return false }
        let phase = cg.getIntegerValueField(.scrollWheelEventScrollPhase)
        if phase == 4 || phase == 8 { cancelPadInkZoom(); return true }
        guard !gesture, window?.isKeyWindow == true, NSApp.isActive,
              ProcessInfo.processInfo.systemUptime - event.timestamp < 0.25,
              event.timestamp <= ProcessInfo.processInfo.systemUptime + 0.01 else { cancelPadInkZoom(); return true }
        // Process-targeted events bypass WindowServer hit routing and have
        // windowNumber 0. Convert Quartz global coordinates in the key reader.
        guard let window, let primary = NSScreen.screens.first else { cancelPadInkZoom(); return true }
        let center = event.window == nil
            ? window.convertPoint(fromScreen: CGPoint(x: cg.location.x, y: primary.frame.maxY-cg.location.y))
            : event.locationInWindow
        if phase == 1 {
            cancelPadInkZoom()
            if let content = window.contentView,
               content.hitTest(content.convert(center, from: nil)) === self { padInkCenter = center }
        } else if phase == 2, let oldCenter = padInkCenter {
            let delta = Double(cg.getIntegerValueField(.scrollWheelEventPointDeltaAxis3)) / 1_000_000
            guard abs(delta) <= 1 else { cancelPadInkZoom(); return true }
            zoomPDF(logDelta: delta, from: oldCenter, to: center)
            padInkCenter = center
        } else { cancelPadInkZoom() }
        return true
    }
    // Transparent cursor image is scoped by AppKit cursor rectangles, without
    // process/global hide counters. ScreenCaptureKit receives the same image.
    static let paperCursor = NSCursor(image:NSImage(size:NSSize(width:16,height:16),flipped:false) { _ in true },hotSpot:.zero)
    var menuTracking = false
    var usesPaperCursor: Bool { !regionMode && [.pen,.marker,.eraser].contains(tool) }
    func cursorless(at windowPoint:CGPoint) -> Bool {
        guard usesPaperCursor, !menuTracking, NSApp.isActive, let window,
              window.isKeyWindow, reader != nil, let content=window.contentView,
              content.hitTest(content.convert(windowPoint,from:nil)) === self else { return false }
        let viewPoint=pdfView.convert(windowPoint,from:nil)
        guard let page=pdfView.page(for:viewPoint,nearest:false) else{return false}
        return page.bounds(for:.cropBox).contains(pdfView.convert(viewPoint,to:page))
    }
    func updateToolCursor(at point:CGPoint) {
        let onPaper=cursorless(at:point)
        let nextHover = onPaper && tool == .eraser ? convert(point,from:nil) : nil
        if eraserHoverPoint != nil || nextHover != nil {needsDisplay=true}
        eraserHoverPoint=nextHover
        if onPaper {Self.paperCursor.set()}
        else if NSCursor.current === Self.paperCursor {NSCursor.arrow.set()}
        else if regionMode {NSCursor.crosshair.set()}
    }
    func refreshToolCursor() {
        guard let window else {return}
        window.invalidateCursorRects(for:self)
        updateToolCursor(at:window.mouseLocationOutsideOfEventStream)
    }
    override func resetCursorRects() {
        guard usesPaperCursor,!menuTracking,window?.isKeyWindow == true,NSApp.isActive,reader != nil else{return}
        for page in pdfView.visiblePages {
            let rect=convert(pdfView.convert(page.bounds(for:.cropBox),from:page),from:pdfView).intersection(visibleRect)
            if !rect.isEmpty {addCursorRect(rect,cursor:Self.paperCursor)}
        }
    }
    override func cursorUpdate(with event:NSEvent) {updateToolCursor(at:event.locationInWindow)}
    override func mouseEntered(with event:NSEvent) {updateToolCursor(at:event.locationInWindow)}
    override func mouseMoved(with event:NSEvent) {updateToolCursor(at:event.locationInWindow)}
    override func mouseExited(with event:NSEvent) {
        eraserHoverPoint=nil;needsDisplay=true
        if NSCursor.current === Self.paperCursor {NSCursor.arrow.set()}
    }
    private func viewPoint(_ p: CGPoint, page: PDFPage) -> CGPoint { convert(pdfView.convert(p, from: page), from: pdfView) }
    // Called inside the page overlay's drawing context; PDFKit owns its transform.
    func drawPageDecorations(_ page: PDFPage, in overlay: PageInkView, dirtyRect: CGRect) {
        func viewPoint(_ p: CGPoint, page: PDFPage) -> CGPoint {
            overlay.convert(pdfView.convert(p, from: page), from: pdfView)
        }
        let origin = viewPoint(.zero, page: page)
        let xAxis = viewPoint(CGPoint(x: 1, y: 0), page: page)
        let scale = hypot(xAxis.x-origin.x, xAxis.y-origin.y)
        let screenScale = max(pdfView.scaleFactor, 0.001)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: overlay.bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        if page === activePage, let rect=regionRect {
            let converted=overlay.convert(pdfView.convert(rect,from:page),from:pdfView)
            NSColor.controlAccentColor.setStroke(); NSBezierPath(rect:converted).stroke()
        }
        if page === activePage, let timestamp = latestInputTimestamp {
            // Pair: newest received event represented in this draw, draw completion uptime.
            inputTrace?.displayedThrough.append(contentsOf: [timestamp, ProcessInfo.processInfo.systemUptime])
        }
        if page === activePage, gesture, !draggingMove, tool == .lasso, let first = points.first {
            let path = NSBezierPath(); path.move(to: viewPoint(first, page: page))
            for point in points.dropFirst() { path.line(to: viewPoint(point, page: page)) }
            // While dragging, show only the sampled pointer trajectory. The
            // implicit closing segment is added only when selection completes.
            path.lineCapStyle = .round; path.lineJoinStyle = .round
            NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.5 * scale / screenScale
            path.setLineDash([5,3], count: 2, phase: 0); path.stroke()
        }
        if page === selectionPage, !selectedIDs.isEmpty, let first = selectionOutline.first {
            let outline = NSBezierPath()
            outline.move(to: viewPoint(first, page: page))
            for p in selectionOutline.dropFirst() { outline.line(to: viewPoint(p, page: page)) }
            outline.close(); outline.windingRule = .evenOdd
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill(); outline.fill()
            NSColor.controlAccentColor.setStroke(); outline.lineWidth = 1.5 * scale / screenScale
            outline.setLineDash([5,3], count: 2, phase: 0); outline.stroke()
        }
        if page === selectionPage, selectedHighlight?.type == "Square",let rect = selectedHighlight?.bounds {
            let converted = overlay.convert(pdfView.convert(rect, from: page), from: pdfView).insetBy(dx: -3 * scale / screenScale, dy: -3 * scale / screenScale)
            NSColor.controlAccentColor.withAlphaComponent(0.08).setFill(); NSBezierPath(rect: converted).fill()
            NSColor.controlAccentColor.setStroke(); let border = NSBezierPath(rect: converted); border.lineWidth = 1.5 * scale / screenScale; border.stroke()
        }
    }
    // Only the eraser affordance belongs to viewport space. Ink remains in page overlays.
    override func draw(_ dirtyRect:NSRect) {
        guard let rect=eraserHoverBounds,let point=eraserHoverPoint,let reader else{return}
        let viewPoint=reader.pdfView.convert(point,from:self)
        guard let page=reader.pdfView.page(for:viewPoint,nearest:false) else{return}
        NSGraphicsContext.saveGraphicsState()
        defer {NSGraphicsContext.restoreGraphicsState()}
        let paper=convert(reader.pdfView.convert(page.bounds(for:.cropBox),from:page),from:reader.pdfView)
        NSBezierPath(rect:paper.intersection(bounds)).addClip()
        NSColor.secondaryLabelColor.setStroke()
        let ring=NSBezierPath(ovalIn:rect);ring.lineWidth=1;ring.stroke()
    }
}
