import AppKit

/// One native input adapter, shared by production and input regression tests.
enum NativePenInput {
    static func validPressure(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...1).contains(value) else { return nil }
        return value
    }
    static func pressure(from event: NSEvent) -> Double? {
        let cg = event.cgEvent
        let isPadInk = cg?.getIntegerValueField(.tabletEventDeviceID) == 0x5049
        guard isPadInk || event.subtype == .tabletPoint || event.type == .tabletPoint else { return nil }
        if isPadInk, let cg { return validPressure(cg.getDoubleValueField(.tabletEventPointPressure)) }
        return validPressure(Double(event.pressure))
    }
}

protocol PenStrokeBuilding: AnyObject {
    var initialFactors: [Double] {get}
    var initialOutlines: [[InkPoint]] {get}
    var generatedCount: Int {get}
    var capacityReached: Bool {get}
    func append(_ point: InkPoint, pressure: Double?, isRelease: Bool) -> InkOutlineUpdate
    func append(_ point: InkPoint, pressure: Double?, isRelease: Bool, timestamp: Double?) -> InkOutlineUpdate
    func finish()
}
extension PenStrokeBuilding {
    var capacityReached: Bool { false }
    func append(_ point: InkPoint, pressure: Double?, isRelease: Bool, timestamp: Double?) -> InkOutlineUpdate {
        append(point,pressure:pressure,isRelease:isRelease)
    }
}
extension PerfectPenBuilder: PenStrokeBuilding {func finish() {}}

enum PenEngine {
    // Historical comparison is available only in the explicit test executable.
    static var legacy = false
    static var observationReference = false
    private static var comparison: Bool {
        #if ECRU_UI_TESTS
        return observationReference || EcruEnvironment.value("ECRU_PEN_COMPARE") == "1"
        #else
        return false
        #endif
    }
    static var recipe: String { comparison ? (legacy ? PerfectPenBuilder.recipe : ObservationPenBuilder.recipe) : GoogleInkPenBuilder.recipe }
    static func make(point: InkPoint,width: Double,pressure: Double?,timestamp: Double? = nil, viewScale: Double = 2) -> PenStrokeBuilding {
        if comparison { return legacy ? PerfectPenBuilder(point:point,width:width,pressure:pressure) : ObservationPenBuilder(point:point,width:width,pressure:pressure) }
        return GoogleInkPenBuilder(point:point,width:width,pressure:pressure,timestamp:timestamp,viewScale:viewScale)
    }
}


/// Native stroke modeling produces an immutable body and a replaceable catch-up
/// tip. The catch-up predicts relaxation toward the received point, never motion
/// beyond it. This is distinct from interpolating every noisy input observation.
final class HandwritingPath {
    struct Vertex {var point:InkPoint;var factor:Double}
    struct Patch {var removing=0;var stable:[Vertex]=[];var tail:[Vertex]=[]}
    private var model:UnsafeMutableRawPointer?
    private var lastRaw:Vertex
    private var incoming:InkPoint?
    private let cornerSpan:Double
    private var output=Array(repeating:EcruModeledPoint(x:0,y:0,factor:1),count:1024)
    private var clock=0.0
    private var timestamp:Double?
    private var tailCount=0
    private var lastStable:Vertex
    private(set) var failed=false
    init(point:InkPoint,factor:Double,width:Double,timestamp:Double?) {
        model=ecru_ink_create(point.x,point.y,factor)
        self.timestamp=timestamp;lastStable=Vertex(point:point,factor:factor)
        lastRaw=lastStable;cornerSpan=max(0.25,min(0.7,width*0.3))
        failed=model == nil
    }
    deinit {if let model {ecru_ink_destroy(model)}}
    func append(_ point:InkPoint,factor:Double,timestamp:Double?,release:Bool=false)->Patch {
        guard !failed else {return Patch()}
        let delta:Double
        if let now=timestamp,let previous=self.timestamp,now.isFinite,now>previous {
            delta=min(0.05,max(1.0/2000,now-previous))
        } else {delta=1.0/240}
        let outgoing=InkPoint(x:point.x-lastRaw.point.x,y:point.y-lastRaw.point.y)
        var removing=tailCount
        if let incoming {
            let a=hypot(incoming.x,incoming.y),b=hypot(outgoing.x,outgoing.y)
            // An explicit compact fold is a pen-direction change, not noise.
            // Seal the already visible catch-up to the corner before starting
            // the next modeled leg. Curves never trigger a reset for curvature
            // alone: both adjacent movements must have meaningful spatial size.
            if min(a,b)>=cornerSpan,(incoming.x*outgoing.x+incoming.y*outgoing.y)/(a*b)<0.15 {
                if let model {ecru_ink_destroy(model)}
                model=ecru_ink_create(lastRaw.point.x,lastRaw.point.y,lastRaw.factor)
                guard model != nil else {failed=true;return Patch()}
                lastStable=lastRaw;clock=0;removing=0
            }
        }
        incoming=outgoing;lastRaw=Vertex(point:point,factor:factor)
        self.timestamp=timestamp;clock+=delta
        var stableCount:Int32=0
        let count=ecru_ink_update(model,point.x,point.y,factor,clock,release ? 1:0,&output,1024,&stableCount)
        guard count>=0 else {failed=true;return Patch()}
        var stable:[Vertex]=[],tail:[Vertex]=[],previous=lastStable
        for i in 0..<Int(count) {
            let raw=output[i]
            guard raw.x.isFinite,raw.y.isFinite,raw.factor.isFinite,abs(raw.x)<=1e7,abs(raw.y)<=1e7 else {failed=true;return Patch()}
            let v=Vertex(point:InkPoint(x:raw.x,y:raw.y),factor:max(0.35,min(1.6,raw.factor)))
            // Suppress redundant relaxation vertices, not received samples.
            if hypot(v.point.x-previous.point.x,v.point.y-previous.point.y)<0.015 {continue}
            if i<Int(stableCount) {stable.append(v);lastStable=v}
            else {tail.append(v)}
            previous=v
        }
        // Preserve the exact visible pen location without feeding this endpoint
        // back into the native model or freezing a provisional prediction.
        if previous.point != point {tail.append(Vertex(point:point,factor:factor))}
        let patch=Patch(removing:removing,stable:stable,tail:tail)
        tailCount=tail.count
        return patch
    }
}

/// Brush response is independent of centerline fitting. The pressure curve makes
/// the low part of Pencil's range useful, without adapting to the writer's past
/// strokes. Distance damping avoids event-rate-dependent width steps.
struct WritingNibResponse {
    static func diameter(_ pressure: Double?) -> Double {
        guard let pressure else { return 1 }
        return 0.40 + 0.86 * pow(pressure, 0.42)
    }
    private(set) var body: Double
    private var previousTarget: Double
    private let width: Double
    init(width: Double, pressure: Double?) {
        self.width=width;body=Self.diameter(pressure);previousTarget=body
    }
    var initial: Double { max(0.35,body*0.76) }
    mutating func advance(distance: Double, pressure: Double?) -> Double {
        let target=pressure.map { Self.diameter($0) } ?? previousTarget
        let x=distance/max(0.15,width*0.55),e=exp(-x)
        let next=target+(body-previousTarget)*e-(target-previousTarget)*(-expm1(-x)/x)
        // The footprint must not grow faster than the pen travels.
        let step=0.65*distance/width
        body=max(body-step,min(body+step,next));previousTarget=target
        return max(0.35,body)
    }
}

/// A mildly oval, fixed nib in page coordinates. Each span is a convex sweep of
/// two footprints. Unioning those spans resolves inside corners and crossings
/// geometrically, without intersecting infinite offset rails or adding miters.
/// The affine footprint preserves direction contrast without rotating at hooks.
enum WritingNibEnvelope {
    private static let angle = Double.pi/4
    private static let aspect = 0.90
    private static func nibSpace(_ p: InkPoint) -> InkPoint {
        let c=cos(angle),s=sin(angle)
        return InkPoint(x:p.x*c+p.y*s,y:(-p.x*s+p.y*c)/aspect)
    }
    private static func pageSpace(_ p: InkPoint) -> InkPoint {
        let c=cos(angle),s=sin(angle),y=p.y*aspect
        return InkPoint(x:p.x*c-y*s,y:p.x*s+y*c)
    }
    private static func compact(_ input:[HandwritingPath.Vertex],width:Double)->[HandwritingPath.Vertex] {
        guard input.count>2 else {return input}
        let tolerance=min(0.035,width*0.02)
        var keep=Set([0,input.count-1]),stack=[(0,input.count-1)]
        while let (lo,hi)=stack.popLast() {
            guard hi>lo+1 else {continue}
            let a=input[lo],b=input[hi],dx=b.point.x-a.point.x,dy=b.point.y-a.point.y
            let dd=dx*dx+dy*dy
            var worst=tolerance,index:Int?
            for i in (lo+1)..<hi {
                let v=input[i]
                let t=dd>1e-12 ? max(0,min(1,((v.point.x-a.point.x)*dx+(v.point.y-a.point.y)*dy)/dd)):0
                let position=hypot(v.point.x-a.point.x-t*dx,v.point.y-a.point.y-t*dy)
                let radius=abs(v.factor-(a.factor+t*(b.factor-a.factor)))*width/2
                let error=position+radius
                if error>worst {worst=error;index=i}
            }
            if let index {keep.insert(index);stack.append((lo,index));stack.append((index,hi))}
        }
        return keep.sorted().map {input[$0]}
    }
    static func contours(_ vertices: [HandwritingPath.Vertex], width: Double, normalize: Bool = false) -> [[InkPoint]] {
        guard !vertices.isEmpty else { return [] }
        // Bound footprint error, rather than spending Boolean geometry on
        // hundreds of nearly collinear native integration steps. Pressure is
        // included in the error so a straight pressure swell remains intact.
        let vertices=compact(vertices,width:width)
        let points=vertices.map { nibSpace($0.point) }
        let radii=vertices.map { width*$0.factor/2 }
        let path=CGMutablePath()
        func disc(_ i:Int) {
            let p=points[i],r=radii[i]
            path.move(to:CGPoint(x:p.x+r,y:p.y))
            path.addArc(center:p.cgPoint,radius:r,startAngle:0,endAngle:2*Double.pi,clockwise:false)
            path.closeSubpath()
        }
        if points.count==1 {disc(0)}
        else {
            for i in 1..<points.count {
                let a=points[i-1],b=points[i],ra=radii[i-1],rb=radii[i]
                let dx=b.x-a.x,dy=b.y-a.y,d=hypot(dx,dy)
                if d<=abs(rb-ra)+1e-9 {disc(ra>rb ? i-1:i);continue}
                let theta=atan2(dy,dx),alpha=acos((ra-rb)/d)
                let low=theta-alpha,high=theta+alpha
                // Same winding for every convex span; overlap adds coverage.
                path.move(to:CGPoint(x:a.x+ra*cos(low),y:a.y+ra*sin(low)))
                path.addLine(to:CGPoint(x:b.x+rb*cos(low),y:b.y+rb*sin(low)))
                path.addArc(center:b.cgPoint,radius:rb,startAngle:low,endAngle:high,clockwise:false)
                path.addLine(to:CGPoint(x:a.x+ra*cos(high),y:a.y+ra*sin(high)))
                path.addArc(center:a.cgPoint,radius:ra,startAngle:high,endAngle:low+2*Double.pi,clockwise:false)
                path.closeSubpath()
            }
        }
        // Live overlap is resolved by one nonzero fill, with no per-span alpha.
        // Normalize only frozen blocks to compact storage without adding latency.
        return InkOutline.contours(normalize ? path.normalized():path).map { $0.map(pageSpace) }
    }
}

/// Only a bounded geometric suffix stays editable. Input positions and brush
/// footprints have separate responsibilities: release shapes the last 1.8 nib
/// widths but never moves the centerline, extends a flourish, or refits the word.
final class HandwritingPenBuilder: PenStrokeBuilding {
    static let recipe = "modeled-writing-nib-v1"
    private let width: Double
    private var path: HandwritingPath
    private var nib: WritingNibResponse
    private var lastRaw: InkPoint
    private var buffer: [HandwritingPath.Vertex]
    private var tailContours=1,closed=false
    private var contourCount=1
    private var distance=0.0
    private var provisionalCount=0
    private var publishedTailCount=1
    private var frozenLength=0.0
    private let initialFactor: Double
    private let initialPoint: InkPoint
    private(set) var capacityReached=false
    private(set) var generatedCount=1
    private(set) var maxBufferCount=1
    var initialFactors: [Double] { [initialFactor] }
    var initialOutlines: [[InkPoint]] { WritingNibEnvelope.contours([.init(point:initialPoint,factor:initialFactor)],width:width) }
    init(point: InkPoint,width: Double,pressure: Double?,timestamp: Double? = nil) {
        self.width=width;lastRaw=point;initialPoint=point
        nib=WritingNibResponse(width:width,pressure:Self.validPressure(pressure))
        initialFactor=nib.initial
        path=HandwritingPath(point:point,factor:nib.body,width:width,timestamp:timestamp)
        buffer=[.init(point:point,factor:nib.body)]
    }
    static func validPressure(_ p: Double?) -> Double? {
        guard let p,p.isFinite,(0...1).contains(p) else { return nil };return p
    }
    func append(_ point:InkPoint,pressure:Double?,isRelease:Bool)->InkOutlineUpdate {
        append(point,pressure:pressure,isRelease:isRelease,timestamp:nil)
    }
    func append(_ point:InkPoint,pressure:Double?,isRelease:Bool,timestamp:Double?)->InkOutlineUpdate {
        guard !closed,point.x.isFinite,point.y.isFinite,abs(point.x)<=1e7,abs(point.y)<=1e7 else { return InkOutlineUpdate(removingOutlines:0) }
        guard point != lastRaw || isRelease else { return InkOutlineUpdate(removingOutlines:0) }
        let d=hypot(point.x-lastRaw.x,point.y-lastRaw.y)
        if d>0 {
            // PadInk up pressure is synthetic zero. Keep the last contact's
            // response, then apply an explicit geometric terminal below.
            let factor=nib.advance(distance:d,pressure:isRelease ? nil:Self.validPressure(pressure))
            let patch=path.append(point,factor:factor,timestamp:timestamp)
            if path.failed {capacityReached=true;closed=true;return InkOutlineUpdate(removingOutlines:0)}
            buffer.removeLast(patch.removing);buffer+=patch.stable+patch.tail
            provisionalCount=patch.tail.count
            distance+=d;lastRaw=point
        }
        var update=InkOutlineUpdate(removing:publishedTailCount,removingOutlines:tailContours)
        // Keep the release region and provisional curve separate from baked
        // geometry. Every block shares one footprint, so no extra join is needed.
        while !isRelease,buffer.count>64,buffer.count-31>=provisionalCount+1 {
            let suffix=Self.length(Array(buffer.dropFirst(31)))
            if suffix<width*3 && buffer.count<192 {break}
            let chunk=Array(buffer.prefix(32))
            let shaped=shape(chunk,offset:frozenLength,terminal:false)
            update.points+=shaped.dropLast().map(\.point)
            update.factors+=shaped.dropLast().map(\.factor)
            update.outlines+=WritingNibEnvelope.contours(shaped,width:width,normalize:true)
            frozenLength+=Self.length(chunk);buffer.removeFirst(31)
        }
        maxBufferCount=max(maxBufferCount,buffer.count)
        let shaped=shape(buffer,offset:frozenLength,terminal:isRelease)
        let tail=WritingNibEnvelope.contours(shaped,width:width)
        update.points+=shaped.map(\.point);update.factors+=shaped.map(\.factor)
        let nextGenerated=generatedCount-publishedTailCount+update.points.count
        let nextCount=contourCount-tailContours+update.outlines.count+tail.count
        guard nextGenerated<=99_900,nextCount<=9_900 else {capacityReached=true;closed=true;return InkOutlineUpdate(removingOutlines:0)}
        tailContours=tail.count;update.outlines+=tail
        publishedTailCount=shaped.count
        contourCount=nextCount;generatedCount=nextGenerated
        if isRelease {closed=true}
        return update
    }
    private static func length(_ vertices:[HandwritingPath.Vertex])->Double {
        zip(vertices,vertices.dropFirst()).reduce(0.0){$0+hypot($1.1.point.x-$1.0.point.x,$1.1.point.y-$1.0.point.y)}
    }
    private func shape(_ input:[HandwritingPath.Vertex],offset:Double,terminal:Bool)->[HandwritingPath.Vertex] {
        var result=[HandwritingPath.Vertex](),travel=0.0
        let length=Self.length(input)
        let taper=terminal && distance>width*3 ? min(width*1.8,distance*0.2):0
        let tip=max(0.35,input.last!.factor*0.48)
        func vertex(_ p:InkPoint,_ body:Double,_ at:Double)->HandwritingPath.Vertex {
            var factor=body*(0.76+0.24*min(1,(offset+at)/(width*1.5)))
            if taper>0,length-at<taper {
                let t=max(0,(length-at)/taper),blend=t*t*(3-2*t)
                factor=tip+(factor-tip)*blend
            }
            return .init(point:p,factor:max(0.35,factor))
        }
        result.append(vertex(input[0].point,input[0].factor,0))
        for (a,b) in zip(input,input.dropFirst()) {
            let d=hypot(b.point.x-a.point.x,b.point.y-a.point.y)
            // Add support only where the nib profile bends. A long straight
            // interval remains one sweep, independent of coordinate magnitude.
            var cuts=[1.0]
            if d>1e-12 {
                for range in [(0.0,width*1.5-offset),(length-taper,length)] {
                    let lo=max(travel,range.0),hi=min(travel+d,range.1)
                    if hi>lo {
                        let steps=max(1,Int(ceil((hi-lo)/max(0.1,width*0.25))))
                        for i in 0...steps {
                            let t=(lo+(hi-lo)*Double(i)/Double(steps)-travel)/d
                            if t>1e-10 && t<1-1e-10 {cuts.append(t)}
                        }
                    }
                }
            }
            cuts.sort()
            var previous = -1.0
            for t in cuts where t-previous>1e-10 {
                let p=t==1 ? b.point:InkPoint(x:a.point.x+(b.point.x-a.point.x)*t,y:a.point.y+(b.point.y-a.point.y)*t)
                result.append(vertex(p,a.factor+(b.factor-a.factor)*t,travel+d*t));previous=t
            }
            travel+=d
        }
        return result
    }
    func finish() {closed=true}
}


/// Owns one upstream InProgressStroke. Its outlines are the authoritative ink
/// for the live page, PDF appearance, hit testing, erasure, and restoration.
/// Retain the old baked-contour storage format so existing readers can edit it.
final class GoogleInkPenBuilder: PenStrokeBuilding {
    static let recipe = "google-ink-daily-v5"
    private var handle: UnsafeMutableRawPointer?
    private var originTime: Double?
    private var elapsed = 0.0
    private var closed = false
    private var lastPoint: InkPoint
    private var contours: [[InkPoint]] = []
    private(set) var generatedCount = 1
    private(set) var capacityReached = false
    let initialFactors = [1.0]
    private(set) var initialOutlines: [[InkPoint]] = []

    init(point: InkPoint, width: Double, pressure: Double?, timestamp: Double? = nil, viewScale: Double = 2) {
        lastPoint = point
        originTime = timestamp.flatMap { $0.isFinite ? $0 : nil }
        handle = ecru_google_ink_create_scaled(point.x, point.y, width,
                                       NativePenInput.validPressure(pressure) ?? -1, viewScale)
        if let shape = readContours() { contours = shape; initialOutlines = shape }
        else { capacityReached = true }
    }
    deinit { if let handle { ecru_google_ink_destroy(handle) } }
    private func readContours() -> [[InkPoint]]? {
        var data: UnsafePointer<EcruInkVertex>?
        let count = Int(ecru_google_ink_outline(handle, &data))
        guard count > 0, count <= 32_000, let data else { return nil }
        var shapes: [[InkPoint]] = [], contour: [InkPoint] = []
        for i in 0..<count {
            let v = data[i]
            guard v.x.isFinite, v.y.isFinite, abs(v.x) <= 1e7, abs(v.y) <= 1e7 else { return nil }
            if v.starts_contour != 0, !contour.isEmpty { shapes.append(contour); contour = [] }
            contour.append(InkPoint(x: v.x, y: v.y))
        }
        if !contour.isEmpty { shapes.append(contour) }
        guard shapes.count <= 9900, shapes.allSatisfy({ $0.count >= 3 }) else { return nil }
        return shapes
    }
    func append(_ point: InkPoint, pressure: Double?, isRelease: Bool) -> InkOutlineUpdate {
        append(point, pressure: pressure, isRelease: isRelease, timestamp: nil)
    }
    func append(_ point: InkPoint, pressure: Double?, isRelease: Bool, timestamp: Double?) -> InkOutlineUpdate {
        guard !closed, !capacityReached, point.x.isFinite, point.y.isFinite,
              abs(point.x) <= 1e7, abs(point.y) <= 1e7 else { return InkOutlineUpdate(removingOutlines: 0) }
        if let timestamp, timestamp.isFinite {
            if originTime == nil { originTime = timestamp - elapsed }
            elapsed = max(elapsed, timestamp - originTime!)
        } else { elapsed += 1.0 / 240 }
        guard generatedCount < 99_900,
              ecru_google_ink_update(handle, point.x, point.y,
                  NativePenInput.validPressure(pressure) ?? -1, elapsed, isRelease ? 1 : 0) != 0,
              let next = readContours() else {
            capacityReached = true; closed = true
            return InkOutlineUpdate(removingOutlines: 0)
        }
        var prefix = 0
        while prefix < min(contours.count, next.count), contours[prefix] == next[prefix] { prefix += 1 }
        // Center samples serve as editable metadata; only native outlines paint.
        let repeated = point == lastPoint
        let update = InkOutlineUpdate(removing: repeated ? 1 : 0, points: [point], factors: [1],
            removingOutlines: contours.count - prefix, outlines: Array(next.dropFirst(prefix)))
        generatedCount += repeated ? 0 : 1
        lastPoint = point; contours = next; closed = isRelease
        return update
    }
    // Interrupted gestures commit exactly what the user last saw. There is no
    // late re-fit; destruction releases native buffers after the transaction.
    func finish() { closed = true }
}

/// Immutable native identity, plus a local receipt of the input-owning window.
/// Never derive running-code identity from Info.plist (the bundle can be replaced).
enum InkRuntimeReport {
    static let configuration: [String:Any] = {
        let data = Data(String(cString:ecru_google_ink_configuration()).utf8)
        return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any] ?? [:]
    }()
    static let buildLabel = "Ecru \(configuration["version"] ?? "?") (\(configuration["build"] ?? "?"))"
    private static let queue = DispatchQueue(label:"local.ecru.ink-runtime",qos:.utility)
    private static var observers:[NSObjectProtocol] = []
    private static var scales:[Int:Double] = [:]
    private static var lastInput:[String:Any] = [:]
    static var receiptURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("EcruInkRuntime",isDirectory:true)
            .appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier).json")
    }
    static func install() {
        guard observers.isEmpty else { return }
        for name in [NSWindow.didBecomeKeyNotification,NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification,NSApplication.didResignActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { _ in record() })
        }
        record()
    }
    static func record(window:NSWindow? = nil, scale:Double? = nil, penDown:Bool = false) {
        if let window,let scale {scales[window.windowNumber]=scale}
        if penDown,let window {
            lastInput=["windowNumber":window.windowNumber,"windowTitle":window.title,
                       "uptime":ProcessInfo.processInfo.systemUptime,"scale":scale ?? 0]
        }
        let windows = NSApp.windows.filter{$0.isVisible}.map { w -> [String:Any] in
            ["windowNumber":w.windowNumber,"title":w.title,"key":w.isKeyWindow,
             "edited":w.isDocumentEdited,"scale":scales[w.windowNumber] ?? 0]
        }
        let report:[String:Any] = ["pid":ProcessInfo.processInfo.processIdentifier,
            "configuration":configuration,"active":NSApp.isActive,"windows":windows,
            "lastPenDown":lastInput,"uptime":ProcessInfo.processInfo.systemUptime]
        guard let data=try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) else{return}
        let url=receiptURL
        queue.async {
            try? FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
            try? data.write(to:url,options:.atomic)
        }
    }
}
