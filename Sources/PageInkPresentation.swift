import AppKit
import PDFKit

/// Owns only visible presentation, never annotation data. PDFKit owns geometry,
/// clipping, scrolling, zooming and overlay recycling. No scroll notification redraw loop.
final class PageInkPresentation: NSObject, PDFPageOverlayViewProvider {
    weak var canvas: ReaderCanvas?
    private(set) var views: [ObjectIdentifier: PageInkView] = [:]
    init(canvas: ReaderCanvas) { self.canvas = canvas }
    func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        PageInkView(page: page, presentation: self)
    }
    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: NSView, for page: PDFPage) {
        guard let overlay = overlayView as? PageInkView else { return }
        views[ObjectIdentifier(page)] = overlay
        overlay.needsDisplay = true
    }
    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        if views[ObjectIdentifier(page)] === overlayView { views.removeValue(forKey: ObjectIdentifier(page)) }
    }
    func disconnect() { canvas = nil; views.removeAll() }
    func invalidateAll() { for view in views.values { view.needsDisplay = true } }
    func invalidate(_ page: PDFPage, bounds: CGRect, change:InkChange?=nil) {
        guard let view = views[ObjectIdentifier(page)], let pdf = canvas?.reader?.pdfView else { return }
        if let change {view.geometryChanged(change)}
        let local = view.convert(pdf.convert(bounds, from: page), from: pdf)
        view.setNeedsDisplay(local.insetBy(dx: -2, dy: -2))
    }
}

/// Pixel backing belongs to the PDF page, so scrolling moves existing pixels
/// atomically with page content. AppKit chooses backing resolution after zoom.
final class PageInkView: NSView {
    let page: PDFPage
    weak var presentation: PageInkPresentation?
    private(set) var drawCount = 0
    private var paths:[UUID:InkPathCache]=[:]
    private let index=InkPageIndex()
    private var structureDirty=true
    private var changed=Set<UUID>()
    private(set) var lastCandidateCount=0
    func geometryChanged(_ change:InkChange) {
        switch change {
        case .reset:paths.removeAll();index.clear();structureDirty=true;changed.removeAll()
        case .replaced(let ids):index.invalidate(ids);for id in ids {paths.removeValue(forKey:id)};if !ids.isEmpty {structureDirty=true}
        case .tail(let id,let from):paths[id]?.invalidate(from:from);changed.insert(id)
        }
    }
    init(page: PDFPage, presentation: PageInkPresentation) {
        self.page = page; self.presentation = presentation
        super.init(frame: .zero)
        wantsLayer = true; layer?.masksToBounds = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        guard let canvas = presentation?.canvas, let reader = canvas.reader else { return }
        let started=ProcessInfo.processInfo.systemUptime
        // AppKit can draw a retained backing layer after its window closes.
        // Keep the controller alive throughout this frame, or skip it entirely.
        defer { withExtendedLifetime(reader) {} }
        drawCount += 1
        let pdf = reader.pdfView
        let origin = convert(pdf.convert(CGPoint.zero, from: page), from: pdf)
        let x = convert(pdf.convert(CGPoint(x: 1, y: 0), from: page), from: pdf)
        let y = convert(pdf.convert(CGPoint(x: 0, y: 1), from: page), from: pdf)
        let transform = CGAffineTransform(a: x.x-origin.x, b: x.y-origin.y,
                                          c: y.x-origin.x, d: y.y-origin.y,
                                          tx: origin.x, ty: origin.y)
        let scale = hypot(transform.a, transform.b)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds.intersection(dirtyRect)).addClip()
        let strokes=reader.session.inkStrokes(on:page)
        if structureDirty {
            index.reset(strokes);let ids=Set(strokes.map(\.id));paths=paths.filter{ids.contains($0.key)}
            structureDirty=false
        }
        for id in changed {
            guard let position=index.positions[id],strokes.indices.contains(position) else{continue}
            let stroke=strokes[position]
            if let path=paths[id] {path.sync(stroke);index.update(id,bounds:path.bounds)}
            else {index.update(id,bounds:stroke.bounds)}
        }
        changed.removeAll()
        let pageClip=dirtyRect.applying(transform.inverted()).insetBy(dx:-2,dy:-2)
        let candidates=index.candidates(in:pageClip);lastCandidateCount=candidates.count
        for position in candidates {
            let stroke=strokes[position]
            if stroke.kind == .pen,(stroke.widthFactors == nil || stroke.appearance == .flowV1 || stroke.outlines != nil),stroke.rgba[3]==1,
               let context=NSGraphicsContext.current?.cgContext {
                let path=paths[stroke.id] ?? InkPathCache();paths[stroke.id]=path;path.sync(stroke)
                guard path.bounds.applying(transform).intersects(dirtyRect) else {continue}
                context.saveGState();context.concatenate(transform)
                path.draw(stroke,in:context,clip:dirtyRect.applying(transform.inverted()))
                context.restoreGState()
            } else {
                guard stroke.bounds.applying(transform).insetBy(dx: -1, dy: -1).intersects(dirtyRect) else { continue }
                InkRenderer.draw(stroke, scale: scale) { $0.applying(transform) }
            }
        }
        canvas.drawPageDecorations(page, in: self, dirtyRect: dirtyRect)
        NSGraphicsContext.restoreGraphicsState()
        canvas.inkDrawCompleted(on:page,started:started)
    }
}
