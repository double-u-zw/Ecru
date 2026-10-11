import Foundation

/// Width is decided once per *received moving sample*, before curve flattening.
/// This is reported AppKit force, not a claim of calibrated Pencil pressure.
/// The distance-domain response has an analytic solution for linearly varying
/// force; subdividing the same force interval cannot add another filter step.
struct PenForceProfile {
    private var previous:Double
    private var filtered:Double
    private let distanceScale:Double
    init(force:Double,width:Double) {
        previous=Self.valid(force,otherwise:0.5);filtered=previous
        distanceScale=max(0.15,width*0.45)
    }
    static func valid(_ force:Double,otherwise:Double)->Double {force.isFinite ? min(1,max(0,force)):otherwise}
    static func factor(_ force:Double)->Double {min(1.16,max(0.78,0.78+0.38*force))}
    var factor:Double {Self.factor(filtered)}
    mutating func advance(force:Double,distance:Double)->Double {
        let next=Self.valid(force,otherwise:previous)
        guard distance>0 else{return filtered}
        let x=distance/distanceScale,e=exp(-x),ramp = -expm1(-x)/x
        filtered=next+(filtered-previous)*e-(next-previous)*ramp
        previous=next;return min(1,max(0,filtered))
    }
}

/// Continuous swept-circle envelope. A straight interval is the convex hull of
/// its two radius discs: exact common tangent rails and analytic circular caps.
/// Joins use outer arcs / inner rail intersections. No midpoint edge smoothing,
/// point-count pressure simulation, width-dependent edge decimation or taper.
/// The same baked polygon is used for display, clipping, movement and export.
enum PenBrushEnvelope {
    private struct Rail {var right:InkPoint;var left:InkPoint}
    private static func cross(_ a:InkPoint,_ b:InkPoint)->Double {a.x*b.y-a.y*b.x}
    private static func angle(_ a:InkPoint,_ b:InkPoint)->Double {atan2(cross(a,b),PerfectFreehand.dot(a,b))}
    private static func arc(center:InkPoint,radius:Double,from:InkPoint,through angle:Double)->[InkPoint] {
        // Fixed geometric tolerance, not an arbitrary number of rail samples.
        let step=2*acos(max(-1,min(1,1-0.02/max(0.02,radius))))
        let count=max(1,Int(ceil(abs(angle)/min(Double.pi/4,step))))
        return (1...count).map{PerfectFreehand.add(center,PerfectFreehand.mul(PerfectFreehand.rotate(from,InkPoint(x:0,y:0),angle*Double($0)/Double(count)),radius))}
    }
    private static func circle(_ p:InkPoint,_ r:Double)->[InkPoint] {
        let normal=InkPoint(x:1,y:0)
        return [PerfectFreehand.add(p,PerfectFreehand.mul(normal,r))]+arc(center:p,radius:r,from:normal,through:2*Double.pi).dropLast()
    }
    static func contours(_ points:[PerfectFreehand.Point],_ options:PerfectFreehand.Options)->[[InkPoint]] {
        guard let first=points.first else{return []}
        let radius=points.map{PerfectFreehand.radius($0.pressure,options)}
        guard points.count>1 else{return [circle(first.point,radius[0])]}
        let lengths=zip(points,points.dropFirst()).map{PerfectFreehand.length(PerfectFreehand.sub($1.point,$0.point))}
        var rails:[Rail]=[]
        for i in lengths.indices {
            let u=PerfectFreehand.unit(PerfectFreehand.sub(points[i+1].point,points[i].point)),n=PerfectFreehand.per(u)
            let slope=(radius[i+1]-radius[i])/max(1e-12,lengths[i])
            // Normal profile's bounded spatial derivative cannot contain a
            // neighbor disc. Defensive fallback splits malformed external data.
            let k=max(-0.999,min(0.999,slope)),s=sqrt(max(0,1-k*k))
            rails.append(Rail(right:PerfectFreehand.add(PerfectFreehand.mul(u,-k),PerfectFreehand.mul(n,s)),left:PerfectFreehand.add(PerfectFreehand.mul(u,-k),PerfectFreehand.mul(n,-s))))
        }
        func edge(_ index:Int,_ center:Int,_ right:Bool)->InkPoint {
            PerfectFreehand.add(points[center].point,PerfectFreehand.mul(right ? rails[index].right:rails[index].left,radius[center]))
        }
        func intersection(_ i:Int,_ right:Bool)->InkPoint? {
            let a=edge(i-1,i-1,right),b=edge(i-1,i,right),c=edge(i,i,right),d=edge(i,i+1,right)
            let u=PerfectFreehand.sub(b,a),v=PerfectFreehand.sub(d,c),den=cross(u,v)
            if abs(den)<1e-10 {return PerfectFreehand.mix(b,c,0.5)}
            let t=cross(PerfectFreehand.sub(c,a),v)/den,s=cross(PerfectFreehand.sub(c,a),u)/den
            guard t.isFinite,s.isFinite else{return nil}
            let p=PerfectFreehand.add(a,PerfectFreehand.mul(u,t))
            return PerfectFreehand.length(PerfectFreehand.sub(p,points[i].point))<=radius[i]*3 ? p:nil
        }
        // Extremely tight joins and reversals are unions of capped spans, not
        // folded rail pairs. Do not reinterpret the trajectory or lose a hook.
        var boundaries=[0]
        for i in 1..<points.count-1 {
            let incoming=PerfectFreehand.unit(PerfectFreehand.sub(points[i].point,points[i-1].point)),outgoing=PerfectFreehand.unit(PerfectFreehand.sub(points[i+1].point,points[i].point))
            let turn=angle(incoming,outgoing)
            let slopeBad=abs(radius[i]-radius[i-1])>=lengths[i-1] || abs(radius[i+1]-radius[i])>=lengths[i]
            if abs(turn)>Double.pi/2 || slopeBad {boundaries.append(i)}
        }
        boundaries.append(points.count-1)
        var result:[[InkPoint]]=[]
        for k in 0..<boundaries.count-1 {
            let lo=boundaries[k],hi=boundaries[k+1]
            func side(_ right:Bool)->[InkPoint] {
                var output=[edge(lo,lo,right)]
                if hi>lo+1 {
                    for i in lo+1..<hi {
                        let a=right ? rails[i-1].right:rails[i-1].left,b=right ? rails[i].right:rails[i].left,turn=angle(a,b)
                        if right ? turn>0 : turn<0 {
                            output.append(edge(i-1,i,right));output+=arc(center:points[i].point,radius:radius[i],from:a,through:turn)
                        } else {
                            if let join=intersection(i,right) {output.append(join)}
                            else {output.append(edge(i-1,i,right));output.append(edge(i,i,right))}
                        }
                    }
                }
                output.append(edge(hi-1,hi,right));return output
            }
            var contour=side(true)
            let endR=rails[hi-1].right,endL=rails[hi-1].left
            if hi<points.count-1 || options.capEnd {
                var end=angle(endR,endL);if end<=0 {end+=2*Double.pi}
                contour+=arc(center:points[hi].point,radius:radius[hi],from:endR,through:end)
            }
            contour+=side(false).reversed()
            if lo>0 || options.capStart {
                var start=angle(rails[lo].left,rails[lo].right);if start<=0 {start+=2*Double.pi}
                contour+=arc(center:points[lo].point,radius:radius[lo],from:rails[lo].left,through:start)
            }
            let area=contour.indices.reduce(0.0){$0+cross(contour[$1],contour[($1+1)%contour.count])}
            result.append(area<0 ? contour.reversed():contour)
        }
        return result
    }
}
