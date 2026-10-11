import AppKit

// Frozen pre-refactor processing, used only for same-input comparison and legacy regressions.
/// Causal, bounded interpolation. Every distinct received endpoint is retained.
/// Geometry is baked once, so display, PDF, erase and lasso share identical lines.
/// No prediction, waiting for a future sample, or pen-up refitting.
struct InkStrokeBuilder {
    private var previous: InkPoint?
    private var last: InkPoint
    private var timestamp: Double
    let scale: Double
    let width: Double

    init(point: InkPoint, timestamp: Double, scale: Double, width: Double) {
        last = point; self.timestamp = timestamp
        self.scale = max(0.01, scale); self.width = width
    }

    mutating func append(_ point: InkPoint, timestamp nextTime: Double) -> [InkPoint] {
        // Stationary events remain in diagnostics but cannot create a tail.
        guard point != last else { timestamp = nextTime; return [] }
        let a = last, old = previous, elapsed = nextTime - timestamp
        previous = a; last = point; timestamp = nextTime
        let dx = point.x-a.x, dy = point.y-a.y, length = hypot(dx, dy)
        guard let old, elapsed > 0, elapsed <= 0.05, length * scale <= 12,
              length * scale > 0.1 else { return [point] }
        let px = a.x-old.x, py = a.y-old.y, priorLength = hypot(px, py)
        guard priorLength > 0 else { return [point] }
        let cosine = (px*dx+py*dy)/(priorLength*length)
        // Preserve corners, reversals and abrupt spacing changes exactly.
        guard cosine > 0.70710678118, length/priorLength < 3,
              priorLength/length < 3 else { return [point] }
        let ux = dx/length, uy = dy/length
        let vx = px/priorLength, vy = py/priorLength
        let sine = abs(vx*uy-vy*ux)
        guard sine > 0.001 else { return [point] }
        // A cubic's start handle contributes at most 4/9 of its offset.
        // Limit lateral displacement to <= 0.2 screen pt and 12% of pen width.
        let limit = min(0.2/scale, width*0.12)
        let handle = min(length/3, limit * 2.25/sine)
        let b = InkPoint(x:a.x+vx*handle, y:a.y+vy*handle)
        let c = InkPoint(x:point.x-ux*length/3, y:point.y-uy*length/3)
        // Flatten the cubic with a conservative control-polygon error bound.
        // These points ARE the model, not a second approximate hit-test path.
        var result: [InkPoint] = []
        func mid(_ a:InkPoint,_ b:InkPoint)->InkPoint { InkPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2) }
        func flatten(_ a:InkPoint,_ b:InkPoint,_ c:InkPoint,_ d:InkPoint,_ depth:Int) {
            let dx=d.x-a.x, dy=d.y-a.y, length=hypot(dx,dy)
            let error = length > 0 ? max(abs((b.x-a.x)*dy-(b.y-a.y)*dx),abs((c.x-a.x)*dy-(c.y-a.y)*dx))/length : 0
            if error <= 0.025/scale || depth == 6 { result.append(d); return }
            let ab=mid(a,b), bc=mid(b,c), cd=mid(c,d), abc=mid(ab,bc), bcd=mid(bc,cd), m=mid(abc,bcd)
            flatten(a,ab,abc,m,depth+1); flatten(m,bcd,cd,d,depth+1)
        }
        flatten(a,b,c,point,0)
        return result
    }
}

/// Causal speed-adaptive stabilization with a strict spatial error bound.
/// It introduces bounded following displacement, never prediction or a delayed
/// release refit. Missing samples and deliberate sharp turns reset the filter.
struct InkPositionStabilizer {
    private var raw: InkPoint
    private var output: InkPoint
    private var time: Double
    private var previousDelta: InkPoint?
    private var speed=0.0
    private let scale: Double
    private let limit: Double
    init(point: InkPoint, timestamp: Double, scale: Double, width: Double) {
        raw=point;output=point;time=timestamp
        self.scale=max(0.01,scale)
        limit=min(0.8/self.scale,width*0.24)
    }
    mutating func append(_ point: InkPoint, timestamp: Double) -> InkPoint {
        let dt=timestamp-time;time=timestamp
        guard point != raw else {return output}
        let delta=InkPoint(x:point.x-raw.x,y:point.y-raw.y),prior=previousDelta
        let length=hypot(delta.x,delta.y)
        raw=point;previousDelta=delta
        var sharp=false
        if let prior {sharp=(prior.x*delta.x+prior.y*delta.y)/(hypot(prior.x,prior.y)*length)<=0.70710678118}
        guard dt>0,dt<=0.020,length*scale<=12,!sharp,prior != nil else {
            speed=dt>0 ? length*scale/dt : 0;output=point;return point
        }
        speed += (length*scale/dt-speed)*(1-exp(-dt/0.012))
        // Slow movements receive support; fast strokes reduce filtering. The
        // distance cap prevents a long rubber-band tail at any input speed.
        let tau=0.002+0.009/(1+speed/120)
        let alpha=1-exp(-dt/tau)
        var dx=(output.x-point.x)*(1-alpha),dy=(output.y-point.y)*(1-alpha)
        let offset=hypot(dx,dy)
        if offset>limit {dx *= limit/offset;dy *= limit/offset}
        output=InkPoint(x:point.x+dx,y:point.y+dy)
        return output
    }
}

/// Pressure affects the nib envelope independently of optional position stability.
/// Neither stage waits for future input, refits on release, or invents pressure from speed.
struct InkPenBuilder {
    private var geometry: InkStrokeBuilder
    private var stabilizer: InkPositionStabilizer?
    private var last: InkPoint
    private var factor: Double?
    private var pressureTimestamp: Double
    private let smoothPressure: Bool
    var initialFactors: [Double]? { factor.map { [$0] } }
    init(point: InkPoint, timestamp: Double, scale: Double, width: Double, pressure: Double?, stabilize: Bool = false, smoothPressure: Bool = false) {
        geometry = InkStrokeBuilder(point:point,timestamp:timestamp,scale:scale,width:width)
        stabilizer = stabilize ? InkPositionStabilizer(point:point,timestamp:timestamp,scale:scale,width:width) : nil
        pressureTimestamp=timestamp; self.smoothPressure=smoothPressure
        last=point; factor=pressure.map(Self.widthFactor)
    }
    static func widthFactor(_ pressure: Double) -> Double {
        // Fixed response across strokes; light contact remains visible. At the
        // observed median pressure (~0.094) width is ~0.98 of the toolbar width.
        guard pressure.isFinite else { return 1 }
        return min(1.35, 0.5 + 1.55*sqrt(max(0,min(1,pressure))))
    }
    mutating func append(_ point: InkPoint, timestamp: Double, pressure: Double?,
                         isRelease: Bool = false) -> (points: [InkPoint], factors: [Double]?) {
        let elapsed=timestamp-pressureTimestamp
        pressureTimestamp=timestamp
        let point=stabilizer?.append(point,timestamp:timestamp) ?? point
        let points=geometry.append(point,timestamp:timestamp)
        guard !points.isEmpty else { return ([],factor == nil ? nil : []) }
        defer { last=point }
        guard let old=factor else { return (points,nil) }
        // PadInk explicitly writes zero pressure for mouseUp. It is not a measured
        // zero-force sample. Keep the final real contact width at that endpoint.
        let target = isRelease ? old : pressure.map(Self.widthFactor) ?? old
        var next=target
        if smoothPressure, !isRelease, elapsed>0, elapsed<=0.020 {
            // Dampen sample-to-sample pressure flutter independently of position.
            // The response may lag, so cap disagreement with measured width at
            // 8% of toolbar width; gaps and release never create settling frames.
            let filtered=old+(target-old)*(1-exp(-elapsed/0.004))
            next=min(target+0.08,max(target-0.08,filtered))
        }
        var length=0.0, previous=last, distances:[Double]=[]
        for p in points { length += hypot(p.x-previous.x,p.y-previous.y); distances.append(length); previous=p }
        factor=next
        return (points,distances.map { old+(next-old)*($0/max(length,1e-10)) })
    }
}

