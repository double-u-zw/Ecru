import AppKit

// Native port of perfect-freehand, Stephen Ruiz Ltd, MIT.
// Pinned source and license: ThirdParty/perfect-freehand (176e00f2399f...).
// The batch implementation is checked against the unmodified TypeScript.
enum PerfectFreehand {
    struct Input:Codable {var point:InkPoint;var pressure:Double?}
    struct Point:Codable {var point:InkPoint;var pressure:Double;var vector:InkPoint;var distance:Double;var runningLength:Double}
    struct Options:Codable {
        var size=16.0,streamline=0.5,smoothing=0.5,thinning=0.5
        var simulatePressure=true,last=false,capStart=true,capEnd=true
        var taperStart=0.0,taperEnd=0.0
        // Ecru's mathematical pen disables the upstream 3-coordinate-unit
        // end-noise skip. The reference defaults remain upstream-exact.
        var endNoise=3.0
    }
    static let pi=Double.pi+0.0001
    static func add(_ a:InkPoint,_ b:InkPoint)->InkPoint {InkPoint(x:a.x+b.x,y:a.y+b.y)}
    static func sub(_ a:InkPoint,_ b:InkPoint)->InkPoint {InkPoint(x:a.x-b.x,y:a.y-b.y)}
    static func mul(_ a:InkPoint,_ t:Double)->InkPoint {InkPoint(x:a.x*t,y:a.y*t)}
    static func mix(_ a:InkPoint,_ b:InkPoint,_ t:Double)->InkPoint {add(a,mul(sub(b,a),t))}
    static func length(_ a:InkPoint)->Double {hypot(a.x,a.y)}
    static func unit(_ a:InkPoint)->InkPoint {let l=length(a);return l>0 ? mul(a,1/l) : InkPoint(x:0,y:0)}
    static func per(_ a:InkPoint)->InkPoint {InkPoint(x:a.y,y:-a.x)}
    static func dot(_ a:InkPoint,_ b:InkPoint)->Double {a.x*b.x+a.y*b.y}
    static func dist2(_ a:InkPoint,_ b:InkPoint)->Double {let d=sub(a,b);return dot(d,d)}
    static func rotate(_ p:InkPoint,_ center:InkPoint,_ angle:Double)->InkPoint {
        let a=sub(p,center),s=sin(angle),c=cos(angle)
        return add(center,InkPoint(x:a.x*c-a.y*s,y:a.x*s+a.y*c))
    }
    static func simulated(_ previous:Double,_ distance:Double,_ size:Double)->Double {
        let sp=min(1,distance/size);return min(1,previous+(min(1,1-sp)-previous)*(sp*0.275))
    }
    static func radius(_ pressure:Double,_ o:Options)->Double {o.size*(0.5-o.thinning*(0.5-pressure))}
    static func points(_ input:[Input],_ o:Options)->[Point] {
        guard !input.isEmpty else{return []}
        var pts=input
        if pts.count==2 {
            let first=pts[0],last=pts[1];pts=[first]
            for i in 1..<5 {pts.append(Input(point:mix(first.point,last.point,Double(i)/4),pressure:nil))}
        }
        if pts.count==1 {pts.append(Input(point:add(pts[0].point,InkPoint(x:1,y:1)),pressure:pts[0].pressure))}
        func pressure(_ value:Double?,_ fallback:Double)->Double {if let value,value>=0 {return value};return fallback}
        var result=[Point(point:pts[0].point,pressure:pressure(pts[0].pressure,0.25),vector:InkPoint(x:1,y:1),distance:0,runningLength:0)]
        var previous=result[0],running=0.0,reached=false
        let t=0.15+(1-o.streamline)*0.85
        for i in 1..<pts.count {
            let p=o.last && i==pts.count-1 ? pts[i].point : mix(previous.point,pts[i].point,t)
            if p==previous.point {continue}
            let distance=length(sub(p,previous.point));running+=distance
            if i<pts.count-1 && !reached {if running<o.size {continue};reached=true}
            previous=Point(point:p,pressure:pressure(pts[i].pressure,0.5),vector:unit(sub(previous.point,p)),distance:distance,runningLength:running)
            result.append(previous)
        }
        result[0].vector=result.count>1 ? result[1].vector : InkPoint(x:0,y:0)
        return result
    }
    static func outline(_ points:[Point],_ o:Options, joinedNormals:Bool=false)->[InkPoint] {
        guard !points.isEmpty,o.size>0 else{return []}
        let total=points.last!.runningLength,minDistance=pow(o.size*o.smoothing,2)
        var left:[InkPoint]=[],right:[InkPoint]=[]
        var pressure=points.prefix(10).reduce(points[0].pressure){acc,p in (acc+(o.simulatePressure ? simulated(acc,p.distance,o.size) : p.pressure))/2}
        var radius=Self.radius(points.last!.pressure,o),firstRadius:Double?
        var previousVector=points[0].vector,previousLeft=points[0].point,previousRight=previousLeft,previousSharp=false
        func arc(_ start:InkPoint,_ center:InkPoint,_ angle:Double,_ segments:Int,_ includeLast:Bool)->[InkPoint] {
            var result:[InkPoint]=[],t=1/Double(segments)
            while includeLast ? t<=1 : t<1 {result.append(rotate(start,center,angle*t));t+=1/Double(segments)}
            return result
        }
        for i in points.indices {
            let p=points[i],last=i==points.count-1
            if !last && total-p.runningLength<o.endNoise {continue}
            var currentPressure=p.pressure
            if o.thinning != 0 {if o.simulatePressure {currentPressure=simulated(pressure,p.distance,o.size)};radius=Self.radius(currentPressure,o)} else {radius=o.size/2}
            if firstRadius==nil {firstRadius=radius}
            let startStrength=p.runningLength<o.taperStart ? (p.runningLength/o.taperStart)*(2-p.runningLength/o.taperStart) : 1
            let endT=(total-p.runningLength)/max(1e-12,o.taperEnd)-1
            let endStrength=total-p.runningLength<o.taperEnd ? endT*endT*endT+1 : 1
            radius=max(0.01,radius*min(startStrength,endStrength))
            let nextVector=last ? p.vector : points[i+1].vector,nextDot=last ? 1 : dot(p.vector,nextVector)
            if (dot(p.vector,previousVector)<0 && !previousSharp) || nextDot<0 {
                let offset=mul(per(previousVector),radius)
                var t=0.0
                while t<=1 {left.append(rotate(sub(p.point,offset),p.point,pi*t));right.append(rotate(add(p.point,offset),p.point,-pi*t));t+=1/13.0}
                previousLeft=left.last!;previousRight=right.last!
                if nextDot<0 {previousSharp=true};continue
            }
            previousSharp=false
            if last {let offset=mul(per(p.vector),radius);left.append(sub(p.point,offset));right.append(add(p.point,offset));continue}
            // The upstream reference uses a non-unit weighted vector here.
            // Product rails use the bisector's direction with the actual radius:
            // short connections must not develop a neck solely from turn angle.
            let direction=joinedNormals ? unit(add(nextVector,p.vector)) : mix(nextVector,p.vector,nextDot)
            let offset=mul(per(direction),radius)
            let l=sub(p.point,offset),r=add(p.point,offset)
            if i<=1 || dist2(previousLeft,l)>minDistance {left.append(l);previousLeft=l}
            if i<=1 || dist2(previousRight,r)>minDistance {right.append(r);previousRight=r}
            pressure=currentPressure;previousVector=p.vector
        }
        let first=points[0].point,last=points.count>1 ? points.last!.point : add(first,InkPoint(x:1,y:1))
        if points.count==1 {
            if o.taperStart==0 && o.taperEnd==0 || o.last {
                let start=add(first,mul(unit(per(InkPoint(x:-1,y:-1))),-(firstRadius ?? radius)))
                return arc(start,first,pi*2,13,true)
            }
        }
        guard let l=left.first,let r=right.first else{return []}
        var startCap:[InkPoint]=[],endCap:[InkPoint]=[]
        if o.taperStart==0 && !(o.taperEnd>0 && points.count==1) {
            if o.capStart {startCap=arc(r,first,pi,13,true)}
            else {let d=sub(l,r);startCap=[sub(first,mul(d,0.5)),sub(first,mul(d,0.51)),add(first,mul(d,0.51)),add(first,mul(d,0.5))]}
        }
        let direction=per(mul(points.last!.vector,-1))
        if o.taperEnd>0 || o.taperStart>0 && points.count==1 {endCap=[last]}
        else if o.capEnd {
            // One semicircle is enough for a product cap. The reference's
            // 3π traversal repeats a full turn inside an already filled stroke.
            endCap=arc(add(last,mul(direction,radius)),last,joinedNormals ? Double.pi : pi*3,joinedNormals ? 13 : 29,false)
        }
        else {endCap=[add(last,mul(direction,radius)),add(last,mul(direction,radius*0.99)),sub(last,mul(direction,radius*0.99)),sub(last,mul(direction,radius))]}
        return left+endCap+right.reversed()+startCap
    }
    static func stroke(_ input:[Input],_ o:Options)->[InkPoint] {outline(points(input,o),o)}
}

/// The product adapter retains the responsive trajectory but uses the native
/// swept-circle brush. Width is derived from received force before flattening.
/// No simulated velocity/taper, short-stroke or end-noise deletion.
/// Stable groups have 64 points; only the bounded <=80-point tail group changes.
/// Groups overlap three centerpoints
/// and fill as a union; fragment edits clip baked outlines, never rerun this pen.
final class PerfectPenBuilder {
    typealias Update=InkOutlineUpdate
    static let recipe="native-swept-brush-v4"
    private var buffer:[PerfectFreehand.Point]
    private var firstBlock=true,tailContours=1
    private let tablet:Bool
    private var options:PerfectFreehand.Options
    private var path:ResponsivePenPath
    private var lastInput:InkPoint,lastPressure:Double
    private var forceProfile:PenForceProfile
    private(set) var generatedCount=1
    var initialFactors:[Double] {[factor(buffer[0].pressure)]}
    var initialOutlines:[[InkPoint]] {contours(buffer,options)}
    init(point:InkPoint,width:Double,pressure:Double?=nil) {
        tablet=pressure != nil;lastInput=point;lastPressure=PenForceProfile.valid(pressure ?? 0.5,otherwise:0.5)
        forceProfile=PenForceProfile(force:lastPressure,width:width)
        options=PerfectFreehand.Options(size:width,streamline:0,smoothing:0,thinning:0.5,simulatePressure:false,last:true,endNoise:0)
        path=ResponsivePenPath(point:point,pressure:tablet ? forceProfile.factor : 1,width:width)
        buffer=[PerfectFreehand.Point(point:point,pressure:tablet ? forceProfile.factor : 1,vector:InkPoint(x:0,y:0),distance:0,runningLength:0)]
    }
    // ResponsivePenPath interpolates a scalar; in v4 it carries the already
    // decided diameter factor, never another raw force / filtering step.
    private func factor(_ diameter:Double)->Double {diameter}
    private func contours(_ points:[PerfectFreehand.Point],_ options:PerfectFreehand.Options)->[[InkPoint]] {
        var p=points;for i in p.indices {p[i].pressure=p[i].pressure/2}
        return PenBrushEnvelope.contours(p,options)
    }
    private func appendVertices(_ vertices:[ResponsivePenPath.Vertex]) {
        for vertex in vertices {
            let previous=buffer.last!,delta=PerfectFreehand.sub(previous.point,vertex.point),distance=PerfectFreehand.length(delta)
            buffer.append(PerfectFreehand.Point(point:vertex.point,pressure:vertex.pressure,vector:PerfectFreehand.unit(delta),distance:distance,runningLength:previous.runningLength+distance))
        }
        if firstBlock,buffer.count>1 {buffer[0].vector=buffer[1].vector}
    }
    func append(_ point:InkPoint,pressure:Double?=nil,isRelease:Bool=false)->Update {
        guard point.x.isFinite,point.y.isFinite,abs(point.x)<=10_000_000,abs(point.y)<=10_000_000,point != lastInput else{return Update(removingOutlines:0)}
        let force=tablet && !isRelease ? PenForceProfile.valid(pressure ?? lastPressure,otherwise:lastPressure) : lastPressure
        let diameter=tablet ? PenForceProfile.factor(forceProfile.advance(force:force,distance:PerfectFreehand.length(PerfectFreehand.sub(point,lastInput)))) : 1
        let curve=path.append(point,pressure:diameter)
        var update=Update(removing:curve.removing,points:(curve.stable+curve.tail).map(\.point),factors:(curve.stable+curve.tail).map{factor($0.pressure)},removingOutlines:tailContours)
        buffer.removeLast(curve.removing)
        appendVertices(curve.stable)
        // Freeze only settled intervals. A provisional curve must never enter a
        // stable block, even if flattening adds enough vertices to cross 64.
        while buffer.count>64 {
            var settled=options;settled.capStart=firstBlock;settled.capEnd=false
            update.outlines+=contours(Array(buffer.prefix(64)),settled)
            buffer=Array(buffer.dropFirst(62));firstBlock=false
        }
        appendVertices(curve.tail)
        var tailOptions=options;tailOptions.capStart=firstBlock
        let tail=contours(buffer,tailOptions);tailContours=tail.count;update.outlines+=tail
        generatedCount+=update.points.count-update.removing;lastInput=point;lastPressure=force
        return update
    }
}

/// Reversing directions must not share a folded pair of offset rails. A cusp
/// divides the envelope into overlapping, equally wound spans at its actual
/// centerpoint. This changes the outline topology, not the input trajectory,
/// brush radius, streamline or force mapping. All spans fill once (nonzero).
/// Historical baked outlines never pass through this generator.
enum PerfectPenOutline {
    static func contours(_ points:[PerfectFreehand.Point],_ options:PerfectFreehand.Options)->[[InkPoint]] {
        guard !points.isEmpty else{return []}
        var starts=[0]
        if points.count>2 {
            for i in 1..<points.count-1 {
                if PerfectFreehand.dot(points[i].vector,points[i+1].vector)<0 {starts.append(i)}
            }
        }
        starts.append(points.count-1)
        var result:[[InkPoint]]=[]
        for k in 0..<starts.count-1 {
            let lower=starts[k],upper=starts[k+1]
            var span=Array(points[lower...upper]),o=options
            if span.count>1 {span[0].vector=span[1].vector}
            o.capStart=lower>0 || options.capStart
            o.capEnd=upper<points.count-1 || options.capEnd
            // This is edge sample spacing, not an input smoothing strength.
            // Keep short rail details; trajectory streamline remains unchanged.
            o.smoothing=0.12
            let contour=InkOutline.smooth(PerfectFreehand.outline(span,o,joinedNormals:true))
            // Upstream sharp-turn traversal can invert a span's winding.
            // Consistent winding makes overlap an ink union instead of a hole.
            let area=zip(contour,contour.dropFirst()+contour.prefix(1)).reduce(0.0){$0+$1.0.x*$1.1.y-$1.1.x*$1.0.y}
            result.append(area<0 ? contour.reversed() : contour)
        }
        return result
    }
}
