import Foundation

/// One centerline stabilizer, then a position-neutral swept-disc envelope.
/// Only settled 64-observation blocks are baked permanently. The tail overlaps
/// two settled observations; downstream caches replace only its contours.
final class ObservationPenBuilder: PenStrokeBuilding {
    static let recipe = "observation-variational-protected-1"
    let stabilizer = ObservationStabilizer()
    private var buffer: [PerfectFreehand.Point]
    private var base=0,tailContours=1
    private var options: PerfectFreehand.Options
    private let tablet: Bool
    private var forceProfile: PenForceProfile
    private var lastInput: InkPoint,lastPressure: Double
    private(set) var generatedCount=1
    private(set) var maxBufferCount=1
    var initialFactors: [Double] { [buffer[0].pressure] }
    var initialOutlines: [[InkPoint]] {contours(buffer,first:true)}
    init(point: InkPoint,width: Double,pressure: Double? = nil) {
        tablet=pressure != nil;lastInput=point;lastPressure=PenForceProfile.valid(pressure ?? 0.5,otherwise:0.5)
        forceProfile=PenForceProfile(force:lastPressure,width:width)
        options=PerfectFreehand.Options(size:width,streamline:0,smoothing:0,thinning:0.5,simulatePressure:false,last:true,endNoise:0)
        buffer=[PerfectFreehand.Point(point:point,pressure:tablet ? forceProfile.factor : 1,vector:InkPoint(x:0,y:0),distance:0,runningLength:0)]
        stabilizer.push(point)
    }
    private func contours(_ points: [PerfectFreehand.Point],first: Bool,end: Bool = true) -> [[InkPoint]] {
        var p=points,o=options;o.capStart=first;o.capEnd=end
        for i in p.indices {p[i].pressure/=2}
        return PenBrushEnvelope.contours(p,o)
    }
    func append(_ point: InkPoint,pressure: Double? = nil,isRelease: Bool = false) -> InkOutlineUpdate {
        let patch=stabilizer.push(point)
        guard !patch.points.isEmpty else{return InkOutlineUpdate(removingOutlines:0)}
        let force=tablet && !isRelease ? PenForceProfile.valid(pressure ?? lastPressure,otherwise:lastPressure) : lastPressure
        let diameter=tablet ? PenForceProfile.factor(forceProfile.advance(force:force,distance:hypot(point.x-lastInput.x,point.y-lastInput.y))) : 1
        let factors=buffer.suffix(patch.removing).map(\.pressure)+[diameter]
        buffer.removeLast(patch.removing)
        for (p,f) in zip(patch.points,factors) {
            let previous=buffer.last?.point ?? p,delta=PerfectFreehand.sub(previous,p),distance=PerfectFreehand.length(delta)
            buffer.append(PerfectFreehand.Point(point:p,pressure:f,vector:PerfectFreehand.unit(delta),distance:distance,runningLength:0))
        }
        maxBufferCount=max(maxBufferCount,buffer.count)
        var update=InkOutlineUpdate(removing:patch.removing,points:patch.points,factors:factors,removingOutlines:tailContours)
        while stabilizer.fixedCount-base>=64 && buffer.count>64 {
            update.outlines+=contours(Array(buffer.prefix(64)),first:base==0,end:false)
            buffer.removeFirst(62);base+=62
        }
        let tail=contours(buffer,first:base==0);tailContours=tail.count;update.outlines+=tail
        generatedCount+=patch.points.count-patch.removing;lastInput=point;lastPressure=force
        return update
    }
    func finish() {stabilizer.finish()}
}
