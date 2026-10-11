import Foundation

/// observation-variational-protected-1, ported without retuning from the pinned
/// Python reference. All distances are unrotated PDF pt, not display pixels.
/// Only independent moving observations enter this layer. No timer/filter at
/// event-batch boundaries, no interpolated evidence, and no pen-up solve.
final class ObservationStabilizer {
    struct Node {
        var raw: InkPoint, point: InkPoint
        var arc: Double, lag: Double
        var fixed: Bool = false
        var travel: Double = 0
    }
    struct Patch { var removing: Int; var points: [InkPoint] }
    // Linear retained observation archive supports physical-distance anchor
    // lookup. No prefix snapshots are retained/copied; only the <=54-node solve
    // and <=48-observation mutable suffix are assembled on each input.
    private(set) var nodes: [Node] = []
    private(set) var fixedCount = 0
    private(set) var closed = false
    private(set) var maxRevision = 0.0
    private(set) var maxSolveCount = 0
    private func length(_ p: InkPoint) -> Double { hypot(p.x,p.y) }
    private func sub(_ a: InkPoint,_ b: InkPoint) -> InkPoint { InkPoint(x:a.x-b.x,y:a.y-b.y) }
    // NumPy dot accumulation returns +0 for a zero anchor vector. Preserve
    // that semantic: atan2(+0,-0) would otherwise invent a pi turn.
    private func dot(_ a: InkPoint,_ b: InkPoint) -> Double { let v=a.x*b.x+a.y*b.y;return v==0 ? 0:v }
    private func clamp(_ x: Double) -> Double { max(0,min(1,x)) }
    private func feature(_ i: Int) -> Double {
        var anchors: Set<Int> = [i]
        for offset in [-1.5,-0.75,0.75,1.5] {
            let target = nodes[i].arc+offset
            var lo=0,hi=nodes.count
            while lo<hi { let m=(lo+hi)/2; if nodes[m].arc<target {lo=m+1} else {hi=m} }
            let candidates=[lo-1,lo].filter{$0>=0 && $0<nodes.count}
            var best=candidates[0]
            for j in candidates.dropFirst() where abs(nodes[j].arc-target)<abs(nodes[best].arc-target) {best=j}
            anchors.insert(best)
        }
        let ids=anchors.sorted(),vectors=zip(ids,ids.dropFirst()).map{sub(nodes[$1].raw,nodes[$0].raw)}
        let angles=zip(vectors,vectors.dropFirst()).map {atan2($0.x*$1.y-$0.y*$1.x,dot($0,$1))}
        var value=0.0
        if angles.count>=2 {
            let sum=angles.reduce(0,+),total=angles.reduce(0){$0+abs($1)}
            value=clamp((abs(sum)/max(total,1e-12)-0.45)/0.4)*clamp((abs(sum)-0.35)/0.85)
        }
        if vectors.count>=3 {
            let path=vectors.reduce(0){$0+length($1)},chord=length(vectors.reduce(InkPoint(x:0,y:0)){InkPoint(x:$0.x+$1.x,y:$0.y+$1.y)})
            value=max(value,clamp((0.72-chord/max(path,1e-12))/0.25))
        }
        return value
    }
    // Partial-pivot LU with two right-hand sides. Small dense system; no
    // dependency on third-party smoothing or another geometry interpretation.
    private func solve(_ input: [Double],_ rhs: [InkPoint],_ n: Int) -> [InkPoint]? {
        var a=input,b=rhs
        for k in 0..<n {
            var pivot=k
            for i in k..<n where abs(a[i*n+k])>abs(a[pivot*n+k]) {pivot=i}
            guard a[pivot*n+k].isFinite,abs(a[pivot*n+k])>1e-30 else{return nil}
            if pivot != k {for j in 0..<n {a.swapAt(k*n+j,pivot*n+j)};b.swapAt(k,pivot)}
            if k+1<n { for i in k+1..<n {
                let f=a[i*n+k]/a[k*n+k]
                for j in k+1..<n {a[i*n+j]-=f*a[k*n+j]}
                b[i].x-=f*b[k].x;b[i].y-=f*b[k].y
            }}
        }
        for k in stride(from:n-1,through:0,by:-1) {
            if k+1<n {for j in k+1..<n {b[k].x-=a[k*n+j]*b[j].x;b[k].y-=a[k*n+j]*b[j].y}}
            b[k].x/=a[k*n+k];b[k].y/=a[k*n+k]
        }
        return b.allSatisfy{$0.x.isFinite && $0.y.isFinite} ? b:nil
    }
    private func solveTail() {
        var first=max(0,fixedCount-6)
        let last=nodes.count-1
        while first<fixedCount-1 && nodes[fixedCount].arc-nodes[first].arc>4.2 {first+=1}
        let n=last-first+1
        guard n>=5 else{return}
        maxSolveCount=max(maxSolveCount,n)
        let h=(first..<last).map{nodes[$0+1].arc-nodes[$0].arc}
        var a=[Double](repeating:0,count:n*n),rhs=[InkPoint]()
        for j in 0..<n {
            let w=max(0.001,j==0 ? h[0]/2 : j==n-1 ? h[n-2]/2 : (h[j-1]+h[j])/2)
            a[j*n+j]=w;rhs.append(InkPoint(x:w*nodes[first+j].raw.x,y:w*nodes[first+j].raw.y))
        }
        for j in 1..<n-1 {
            let x=max(h[j-1],1e-5),y=max(h[j],1e-5),span=(x+y)/2
            let d=[1/x/span,(-1/x-1/y)/span,1/y/span]
            let strength=0.65*pow(1-feature(first+j),4)+0.0001
            for r in 0..<3 {for c in 0..<3 {a[(j-1+r)*n+j-1+c]+=strength*span*d[r]*d[c]}}
        }
        let free=(0..<n).filter{!nodes[first+$0].fixed && first+$0 != last}
        guard !free.isEmpty else{return}
        let fixed=(0..<n).filter{nodes[first+$0].fixed || first+$0==last}
        var b=free.map{rhs[$0]}
        for (k,j) in free.enumerated() {for f in fixed {b[k].x-=a[j*n+f]*nodes[first+f].point.x;b[k].y-=a[j*n+f]*nodes[first+f].point.y}}
        guard let target=solve(free.flatMap{j in free.map{a[j*n+$0]}},b,free.count) else{return}
        let changes=zip(free,target).map{sub($1,nodes[first+$0].point)}
        var fraction=1.0
        for (k,j) in free.enumerated() {
            let q=nodes[first+j],d=changes[k],l=length(d)
            if l>1e-12 {fraction=min(fraction,0.20/l,max(0,0.65-q.travel)/l)}
            let offset=sub(q.point,q.raw),aa=dot(d,d),bb=2*dot(offset,d),cc=dot(offset,offset)-0.45*0.45
            if aa>1e-16 {fraction=min(fraction,max(0,(-bb+sqrt(max(0,bb*bb-4*aa*cc)))/(2*aa)))}
        }
        for (k,j) in free.enumerated() {
            let delta=InkPoint(x:changes[k].x*fraction,y:changes[k].y*fraction),amount=length(delta)
            nodes[first+j].point.x+=delta.x;nodes[first+j].point.y+=delta.y
            nodes[first+j].travel+=amount;maxRevision=max(maxRevision,amount)
        }
    }
    @discardableResult func push(_ p: InkPoint, auxiliary: Bool = false) -> Patch {
        guard !closed,!auxiliary,p.x.isFinite,p.y.isFinite,abs(p.x)<=1e7,abs(p.y)<=1e7 else{return Patch(removing:0,points:[])}
        let distance=nodes.last.map{length(sub(p,$0.raw))} ?? 0
        if !nodes.isEmpty && distance<1e-10 {return Patch(removing:0,points:[])}
        let start=fixedCount,removing=nodes.count-start
        var spacing=0.734
        if !nodes.isEmpty {
            var hops=(max(1,nodes.count-8)..<nodes.count).map{nodes[$0].arc-nodes[$0-1].arc};hops.append(distance);hops.sort()
            spacing=hops.count%2==1 ? hops[hops.count/2] : (hops[hops.count/2-1]+hops[hops.count/2])/2
        }
        let arc=(nodes.last?.arc ?? 0)+distance
        nodes.append(Node(raw:p,point:p,arc:arc,lag:max(1.5,min(2.2,1.2*spacing)),fixed:nodes.isEmpty))
        let last=nodes.count-1
        if fixedCount<last {for i in fixedCount..<last where arc-nodes[i].arc>3.2 || last-i>=48 {nodes[i].fixed=true}}
        while fixedCount<nodes.count && nodes[fixedCount].fixed {fixedCount+=1}
        solveTail()
        if fixedCount<last {for i in fixedCount..<last {
            let q=nodes[i]
            if (last-i>=3 && arc-q.arc>=q.lag) || q.travel>=0.65-1e-9 || length(sub(q.point,q.raw))>=0.45-1e-9 {nodes[i].fixed=true}
        }}
        while fixedCount<nodes.count && nodes[fixedCount].fixed {fixedCount+=1}
        return Patch(removing:removing,points:nodes[start...].map(\.point))
    }
    func finish() {closed=true;for i in fixedCount..<nodes.count {nodes[i].fixed=true};fixedCount=nodes.count} // No geometry mutation.
}
