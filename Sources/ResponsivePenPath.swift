import Foundation

/// A local, interpolating path, separate from the ink's offset envelope.
/// Actual endpoints stay visible, including the first interval. The next real
/// sample only settles the preceding interval; no recursive backward position
/// filter, timestamp-derived velocity, predicted tip, or pen-up refit.
struct ResponsivePenPath {
    struct Vertex {var point:InkPoint;var pressure:Double}
    struct Update {var removing=0;var stable:[Vertex]=[];var tail:[Vertex]=[]}
    private var anchor:Vertex,latest:Vertex
    private var startDirection:InkPoint?
    private var precedingLength=0.0,tailCount=0,intervals=0
    private let width:Double
    init(point:InkPoint,pressure:Double,width:Double) {
        anchor=Vertex(point:point,pressure:pressure);latest=anchor;self.width=width
    }
    mutating func append(_ point:InkPoint,pressure:Double)->Update {
        guard point != latest.point else{return Update()}
        let next=Vertex(point:point,pressure:pressure)
        if intervals==0 {latest=next;tailCount=1;intervals=1;return Update(tail:[next])}
        let incoming=PerfectFreehand.sub(latest.point,anchor.point),outgoing=PerfectFreehand.sub(point,latest.point)
        let left=PerfectFreehand.length(incoming),right=PerfectFreehand.length(outgoing)
        // An abrupt change or a tiny reversal must retain its one-sided tangent.
        // Large gaps are not rounded into a fictional curve. All budgets are in
        // PDF coordinates, so zoom does not change the authored geometry.
        let dot=PerfectFreehand.dot(PerfectFreehand.unit(incoming),PerfectFreehand.unit(outgoing))
        let corner=dot<0.25 || min(left,right)<0.04 || max(left,right)>max(12,width*6)
        var tangent:InkPoint?
        if !corner {
            // Centripetal knot weighting, unlike a uniform tangent, limits the
            // influence of a sparse neighbor on a small hook / dense interval.
            let a=sqrt(left),b=sqrt(right)
            tangent=PerfectFreehand.unit(PerfectFreehand.add(PerfectFreehand.mul(incoming,b/(a*(a+b))),PerfectFreehand.mul(outgoing,a/(b*(a+b)))))
        }
        let stable=segment(anchor,latest,start:startDirection,end:tangent,startNeighbor:precedingLength,endNeighbor:right)
        let tail=segment(latest,next,start:tangent,end:nil,startNeighbor:left,endNeighbor:0)
        let update=Update(removing:tailCount,stable:stable,tail:tail)
        anchor=latest;latest=next;startDirection=tangent;precedingLength=left;tailCount=tail.count;intervals+=1
        return update
    }
    private func segment(_ a:Vertex,_ b:Vertex,start:InkPoint?,end:InkPoint?,startNeighbor:Double,endNeighbor:Double)->[Vertex] {
        let chord=PerfectFreehand.sub(b.point,a.point),length=PerfectFreehand.length(chord)
        guard length>0.04,length<=max(12,width*6),start != nil || end != nil else{return [b]}
        let unit=PerfectFreehand.unit(chord),normal=PerfectFreehand.per(unit)
        func handle(_ tangent:InkPoint?,_ neighbor:Double)->InkPoint {
            guard let tangent else{return PerfectFreehand.mul(chord,1/3)}
            let magnitude=min(length/3,neighbor>0 ? neighbor/3:length/3)
            let h=PerfectFreehand.mul(tangent,magnitude)
            let along=max(0,min(length/3,PerfectFreehand.dot(h,unit)))
            let limit=min(width*0.18,length*0.18)
            let across=max(-limit,min(limit,PerfectFreehand.dot(h,normal)))
            return PerfectFreehand.add(PerfectFreehand.mul(unit,along),PerfectFreehand.mul(normal,across))
        }
        let c1=PerfectFreehand.add(a.point,handle(start,startNeighbor)),c2=PerfectFreehand.sub(b.point,handle(end,endNeighbor))
        var result:[Vertex]=[]
        func midpoint(_ a:InkPoint,_ b:InkPoint)->InkPoint {PerfectFreehand.mix(a,b,0.5)}
        func flatten(_ p:InkPoint,_ q:InkPoint,_ r:InkPoint,_ s:InkPoint,_ lo:Double,_ hi:Double,_ depth:Int) {
            let line=PerfectFreehand.sub(s,p),den=max(1e-12,PerfectFreehand.length(line))
            let error=max(abs(line.x*(q.y-p.y)-line.y*(q.x-p.x)),abs(line.x*(r.y-p.y)-line.y*(r.x-p.x)))/den
            if error<=0.035 || depth==4 {result.append(Vertex(point:s,pressure:a.pressure+(b.pressure-a.pressure)*hi));return}
            let pq=midpoint(p,q),qr=midpoint(q,r),rs=midpoint(r,s),left=midpoint(pq,qr),right=midpoint(qr,rs),mid=midpoint(left,right),t=(lo+hi)/2
            flatten(p,pq,left,mid,lo,t,depth+1);flatten(mid,right,rs,s,t,hi,depth+1)
        }
        flatten(a.point,c1,c2,b.point,0,1,0)
        return result
    }
}
