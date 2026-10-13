import AppKit
import PDFKit

enum LaserForm: Int { case trail, dot }

/// Window-local ephemeral samples. This object has no document/session or ink-engine API.
final class LaserPresentation {
    struct Sample {
        let point: CGPoint
        let time: Double
        let contact: UInt64
    }
    private(set) var page: PDFPage?
    private(set) var samples: [Sample] = []
    private(set) var isContact = false
    private(set) var head: Sample?
    private var contact: UInt64 = 0
    private var lastActivity: Double?
    private var lastOpacity: Double = 1
    private var timer: Timer?
    var invalidate: ((PDFPage) -> Void)?
    var form: LaserForm = .trail { didSet { if form != oldValue { clear() } } }
    var duration: Double = 2
    var width: Double = 3
    var glow: Double = 0.75
    var color: NSColor = .systemRed
    static let capacity = 4096
    static func opacity(age: Double, duration: Double) -> Double {
        let lifetime=max(0.1,duration)
        let fade=min(0.4,lifetime*0.4)
        let t=min(1,max(0,(age-(lifetime-fade))/fade))
        return 1-t*t*(3-2*t)
    }
    func begin(on page: PDFPage, at point: CGPoint, now: Double = ProcessInfo.processInfo.systemUptime) {
        if self.page !== page {clear()}
        if !isContact,let lastActivity,now-lastActivity>=duration {clear()}
        self.page = page; contact &+= 1; isContact = true
        append(point, now: now)
    }
    func append(_ point: CGPoint, now: Double = ProcessInfo.processInfo.systemUptime) {
        guard isContact, point.x.isFinite, point.y.isFinite, now.isFinite else { return }
        lastActivity=now;lastOpacity=1
        let sample = Sample(point: point, time: now, contact: contact)
        head = sample
        if form == .trail {
            // Keep exact input coordinates; no Google Ink modeling, pressure or prediction.
            samples.append(sample)
            if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
        }
        if let page { invalidate?(page) }
        startTimer()
    }
    func end(now: Double = ProcessInfo.processInfo.systemUptime) {
        guard isContact else { return }
        isContact = false;lastActivity=now
        if let head { self.head = Sample(point: head.point, time: now, contact: head.contact) }
    }
    func clear() {
        let previous = page
        timer?.invalidate(); timer = nil
        page = nil; samples.removeAll(keepingCapacity: true); head = nil; isContact = false;lastActivity=nil;lastOpacity=1
        if let previous { invalidate?(previous) }
    }
    func prune(now: Double) {
        // A run of temporary marks stays intact while presenting. The idle
        // clock, rather than each sampled point, controls the final fade.
        if !isContact,let lastActivity,now-lastActivity>=duration {samples.removeAll(keepingCapacity:true);head=nil}
    }
    func tick(now: Double = ProcessInfo.processInfo.systemUptime) {
        prune(now: now)
        if samples.isEmpty && head == nil { clear() }
        else if let page,let lastActivity {
            let alpha=isContact ? 1:Self.opacity(age:now-lastActivity,duration:duration)
            if alpha != lastOpacity {lastOpacity=alpha;invalidate?(page)}
        }
    }
    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0/60, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.002
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }
    deinit { timer?.invalidate() }

    func draw(on page: PDFPage, in context: CGContext, transform: CGAffineTransform,
              widthScale: Double, now: Double = ProcessInfo.processInfo.systemUptime) {
        guard self.page === page else { return }
        let color = color.usingColorSpace(.sRGB) ?? .systemRed
        let base = max(0.5, width * widthScale)
        let intensity = min(1, max(0, glow))
        let alpha=isContact ? 1:Self.opacity(age:now-(lastActivity ?? now),duration:duration)
        guard alpha>0 else{return}
        let path=CGMutablePath()
        if form == .trail {
            var previous:Sample?
            for sample in samples {
                let p=sample.point.applying(transform)
                if previous?.contact != sample.contact {path.move(to:p)}
                else {path.addLine(to:previous?.point == sample.point ? CGPoint(x:p.x+0.001,y:p.y):p)}
                previous=sample
            }
            // Preserve taps without drawing another bright bead over a line tip.
            for (i,sample) in samples.enumerated() where
                (i == 0 || samples[i-1].contact != sample.contact) &&
                (i == samples.count-1 || samples[i+1].contact != sample.contact) {
                let p=sample.point.applying(transform)
                path.move(to:p);path.addLine(to:CGPoint(x:p.x+0.001,y:p.y))
            }
        } else if let head {
            let p=head.point.applying(transform)
            path.move(to:p);path.addLine(to:CGPoint(x:p.x+0.001,y:p.y))
        }
        context.saveGState()
        defer {context.restoreGState()}
        context.setLineCap(.round);context.setLineJoin(.round)
        // Apply fade to the complete light, after composing it. Its silhouette
        // stays stable; the center and Gaussian bloom disappear together.
        context.setAlpha(alpha)
        if intensity>0 {
            context.setShadow(offset:.zero,blur:base*(0.8+intensity*1.25),
                              color:color.withAlphaComponent(0.65*intensity).cgColor)
        }
        context.beginTransparencyLayer(auxiliaryInfo:nil)
        context.setLineWidth(base*0.88)
        context.setStrokeColor(color.cgColor)
        context.addPath(path);context.strokePath()
        let core=color.blended(withFraction:0.85,of:.white) ?? .white
        context.setLineWidth(base*0.25)
        context.setStrokeColor(core.cgColor)
        context.addPath(path);context.strokePath()
        context.endTransparencyLayer()
    }
}

/// A separate backing surface: fading never redraws PDF content, images or saved ink.
final class LaserPageView: NSView {
    let page: PDFPage
    weak var presentation: PageInkPresentation?
    init(page: PDFPage, presentation: PageInkPresentation) {
        self.page = page; self.presentation = presentation
        super.init(frame:.zero); wantsLayer = true; layer?.masksToBounds = true
        autoresizingMask = [.width,.height]
    }
    required init?(coder:NSCoder) { fatalError() }
    override func hitTest(_ point:NSPoint) -> NSView? { nil }
    private func pageTransform(_ pdf:PDFView) -> CGAffineTransform {
        let o=convert(pdf.convert(CGPoint.zero,from:page),from:pdf)
        let x=convert(pdf.convert(CGPoint(x:1,y:0),from:page),from:pdf)
        let y=convert(pdf.convert(CGPoint(x:0,y:1),from:page),from:pdf)
        return CGAffineTransform(a:x.x-o.x,b:x.y-o.y,c:y.x-o.x,d:y.y-o.y,tx:o.x,ty:o.y)
    }
    override func draw(_ dirtyRect:NSRect) {
        guard let canvas=presentation?.canvas, let reader=canvas.reader,
              let context=NSGraphicsContext.current?.cgContext else { return }
        let pdf=reader.pdfView
        let transform=pageTransform(pdf)
        context.saveGState(); context.clip(to:bounds)
        var clippingTransform=transform
        context.addPath(CGPath(rect:page.bounds(for:.cropBox),transform:&clippingTransform)); context.clip()
        canvas.laser.draw(on:page,in:context,transform:transform,
                          widthScale:hypot(transform.a,transform.b)/max(pdf.scaleFactor,0.001))
        context.restoreGState()
    }
    private var previousDamage=CGRect.null
    func invalidateLaser() {
        guard let canvas=presentation?.canvas,let reader=canvas.reader else {return}
        let laser=canvas.laser
        var damage=CGRect.null
        if laser.page === page {
            // Resolve PDFKit geometry once per frame, never once per stored sample.
            for sample in laser.samples {damage=damage.union(CGRect(origin:sample.point,size:CGSize(width:0.01,height:0.01)))}
            if let head=laser.head {damage=damage.union(CGRect(origin:head.point,size:CGSize(width:0.01,height:0.01)))}
            damage=damage.applying(pageTransform(reader.pdfView))
            damage=damage.insetBy(dx:-laser.width*3-2,dy:-laser.width*3-2)
        }
        let dirty=damage.union(previousDamage).intersection(bounds)
        if !dirty.isNull && !dirty.isEmpty {setNeedsDisplay(dirty)}
        previousDamage=damage
    }
}
