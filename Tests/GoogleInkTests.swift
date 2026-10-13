import AppKit
import PDFKit

@main enum GoogleInkTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { print("FAIL: \(message)"); fflush(stdout); exit(1) }
        print("PASS: \(message)")
    }
    static func initial(_ b: GoogleInkPenBuilder, _ p: InkPoint, _ width: Double) -> InkStroke {
        InkStroke(points:[p],width:width,rgba:[0.08,0.16,0.28,1],kind:.pen,widthFactors:b.initialFactors,appearance:.perfectFreehandV1,outlines:b.initialOutlines)
    }
    static func apply(_ u: InkOutlineUpdate, _ s: inout InkStroke) {
        s.points.removeLast(u.removing);s.points += u.points
        s.widthFactors!.removeLast(u.removing);s.widthFactors! += u.factors
        s.outlines!.removeLast(u.removingOutlines);s.outlines! += u.outlines
    }
    static func run(_ points:[InkPoint], _ width:Double=1.6, pressure:Double?=0.3) -> InkStroke {
        let b=GoogleInkPenBuilder(point:points[0],width:width,pressure:pressure,timestamp:100)
        var s=initial(b,points[0],width)
        precondition(s.isValid)
        for (i,p) in points.dropFirst().enumerated() {
            apply(b.append(p,pressure:pressure,isRelease:false,timestamp:100+Double(i+1)/120),&s)
            precondition(!b.capacityReached && s.isValid)
        }
        let before=s.outlines
        apply(b.append(points.last!,pressure:0,isRelease:true,timestamp:100+Double(points.count)/120),&s)
        precondition(before == s.outlines, "stationary release must not change visible ink")
        precondition(s.isValid)
        return s
    }
    static func main() throws {
        let out=URL(fileURLWithPath:"output/google-ink",isDirectory:true)
        try FileManager.default.createDirectory(at:out,withIntermediateDirectories:true)
        check(PenEngine.recipe==GoogleInkPenBuilder.recipe,"shipping default is the complete Google Ink engine")
        let cg = CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:.zero,mouseButton:.left)!
        cg.setIntegerValueField(.mouseEventSubtype,value:1)
        cg.setIntegerValueField(.tabletEventDeviceID,value:0x5049)
        cg.setDoubleValueField(.tabletEventPointPressure,value:0.123456)
        cg.setDoubleValueField(.mouseEventPressure,value:0.8)
        let tabletEvent = NSEvent(cgEvent:cg)!
        check(NativePenInput.pressure(from:tabletEvent)==cg.getDoubleValueField(.tabletEventPointPressure) && abs(NativePenInput.pressure(from:tabletEvent)!-0.123456)<1.0/65535,"PadInk exact tablet pressure takes precedence over mouse pressure")
        let mouse = NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:0,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        check(NativePenInput.pressure(from:mouse)==nil,"ordinary mouse contact does not fabricate pen pressure")
        check(NativePenInput.validPressure(.nan)==nil && NativePenInput.validPressure(-1)==nil && NativePenInput.validPressure(0)==0,"missing, invalid and light pressure remain distinct")
        let p=InkPoint(x:20,y:40)
        for pressure in [nil,0,0.2,1] as [Double?] {
            let s=run([p,InkPoint(x:100,y:40)],4,pressure:pressure)
            check(s.isValid && s.bounds.width>80,"pressure and mouse strokes produce valid complete geometry")
            let fragments=InkGeometry.erase(s,center:CGPoint(x:60,y:40),radius:5)
            check(fragments.count==2 && fragments.allSatisfy(\.isValid),"eraser clips native contour into two valid pieces")
            for f in fragments {
                let moved=f.translated(dx:3,dy:5)
                check(InkAnnotationCodec.stroke(from:InkAnnotationCodec.make(moved))==moved,"moved fragment roundtrips exactly")
            }
        }
        // Identical physical/display paths, normalized geometry size only in
        // this fixture, must have the same modeled response at every zoom.
        var reference:[[InkPoint]]?
        for zoom in [0.5,1.0,2.0,4.0] {
            let width=0.8/zoom
            let builder=GoogleInkPenBuilder(point:InkPoint(x:0,y:0),width:width,pressure:nil,timestamp:0,viewScale:zoom)
            var stroke=initial(builder,InkPoint(x:0,y:0),width)
            for i in 1...240 {
                let t=Double(i)/120
                let point=InkPoint(x:(20*t+2*sin(t*8))/zoom,y:(4*sin(t*6)+0.15*sin(t*90))/zoom)
                apply(builder.append(point,pressure:nil,isRelease:false,timestamp:t),&stroke)
            }
            let normalized=stroke.outlines!.map{$0.map{InkPoint(x:$0.x*zoom,y:$0.y*zoom)}}
            if let reference {
                check(normalized.count==reference.count && zip(normalized,reference).allSatisfy { a,b in
                    a.count==b.count && zip(a,b).allSatisfy{hypot($0.x-$1.x,$0.y-$1.y)<0.0001}
                },"same display trajectory has identical modeled geometry at zoom \(zoom)")
            } else {reference=normalized}
            check(stroke.width==width,"model scale leaves requested PDF brush width intact")
        }
        let dot=run([p],2)
        check(dot.isValid && dot.outlines!.flatMap{$0}.count>=3,"single tap is visible")
        let timing=GoogleInkPenBuilder(point:p,width:1,pressure:0.3,timestamp:100)
        var timed=initial(timing,p,1)
        for t in [100.0,100.0,99.0,103.0,103.0001] {
            apply(timing.append(InkPoint(x:timed.points.last!.x+1,y:40),pressure:nil,isRelease:false,timestamp:t),&timed)
        }
        check(!timing.capacityReached && timed.isValid,"equal, backward and paused event times preserve callback order")
        // Measure the actual rendered contour, not the raw center metadata.
        let quiet=GoogleInkPenBuilder(point:InkPoint(x:0,y:0),width:0.8,pressure:nil,timestamp:0)
        var quietStroke=initial(quiet,InkPoint(x:0,y:0),0.8)
        for i in 1...240 {
            let t=Double(i)/240
            apply(quiet.append(InkPoint(x:8*t,y:0.12*sin(2 * .pi * 16*t)),pressure:nil,isRelease:false,timestamp:t),&quietStroke)
        }
        var mids:[Double]=[],widths:[Double]=[]
        for i in 40...260 {
            let x=Double(i)/40
            var ys:[Double]=[]
            for contour in quietStroke.outlines! {
                for j in contour.indices {
                    let a=contour[j],b=contour[(j+1)%contour.count]
                    if (a.x<=x && b.x>x) || (b.x<=x && a.x>x) {
                        ys.append(a.y+(b.y-a.y)*(x-a.x)/(b.x-a.x))
                    }
                }
            }
            if let lo=ys.min(),let hi=ys.max() {mids.append((lo+hi)/2);widths.append(hi-lo)}
        }
        let contourRMS=sqrt(mids.map{$0*$0}.reduce(0,+)/Double(mids.count))
        check(mids.count==221 && contourRMS<0.045,"actual native outline retains slow-motion jitter attenuation")
        check(widths.allSatisfy{abs($0-0.8)<0.1},"constant-pressure contour has no extra local width modulation")
        print("Slow jitter contour center RMS PDF points: \(contourRMS)")
        let last=quietStroke.points.last!,beforeStop=quietStroke.outlines
        for i in 1...120 {
            apply(quiet.append(last,pressure:nil,isRelease:false,timestamp:1+Double(i)/120),&quietStroke)
        }
        check(quietStroke.outlines==beforeStop,"stationary callbacks do not grow a catch-up tail")
        apply(quiet.append(last,pressure:0,isRelease:true,timestamp:3),&quietStroke)
        check(quietStroke.outlines==beforeStop,"lift after a pause preserves the exact displayed contour")
        // Distinct release coordinates receive precisely the same causal update
        // as a drag: no final fit or connection back to an unfiltered endpoint.
        let releaseA=GoogleInkPenBuilder(point:p,width:1.6,pressure:nil,timestamp:0)
        let releaseB=GoogleInkPenBuilder(point:p,width:1.6,pressure:nil,timestamp:0)
        var sa=initial(releaseA,p,1.6),sb=initial(releaseB,p,1.6)
        for i in 1...30 {
            let q=InkPoint(x:p.x+Double(i)*0.1,y:p.y+sin(Double(i)*0.3)*0.1)
            apply(releaseA.append(q,pressure:nil,isRelease:i==30,timestamp:Double(i)/120),&sa)
            apply(releaseB.append(q,pressure:nil,isRelease:false,timestamp:Double(i)/120),&sb)
        }
        check(sa.outlines==sb.outlines,"moving release and live input generate identical contours")
        var specimens:[InkStroke]=[]
        let loop=(0...160).map { i -> InkPoint in let t=Double(i)*4 * .pi/160;return InkPoint(x:40+t*5+8*cos(t),y:130+7*sin(t)) }
        specimens.append(run(loop,1.6))
        let hook=[InkPoint(x:140,y:125),InkPoint(x:151,y:125),InkPoint(x:151,y:136),InkPoint(x:148,y:134),InkPoint(x:146,y:133)]
        specimens.append(run(hook,1.3))
        check(specimens[1].bounds.maxY>135,"compact hook retains its upper extremity")
        let circle=(0...80).map{i -> InkPoint in let t=Double(i)*2 * .pi/80;return InkPoint(x:185+3*cos(t),y:130+3*sin(t))}
        let cs=run(circle,0.8)
        check(!InkOutline.path(cs.outlines!).contains(CGPoint(x:185,y:130)),"small loop keeps an open counter")
        specimens.append(cs)
        var costs:[Double]=[],count=0,events=0
        #if ECRU_PRIVATE_CORPUS
        for directory in ["handwriting-input","handwriting-input-balanced"] {
            let files=try FileManager.default.contentsOfDirectory(at:URL(fileURLWithPath:"Tests/Fixtures/"+directory),includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}.sorted{$0.path<$1.path}
            for file in files {
                let trace=try JSONDecoder().decode(InkInputTrace.self,from:Data(contentsOf:file))
                guard trace.kind == .pen,let first=trace.samples.first else{continue}
                let b=GoogleInkPenBuilder(point:first.point,width:1.6,pressure:first.nativePressure ?? (first.tablet ? Double(first.pressure):nil),timestamp:first.timestamp)
                var s=initial(b,first.point,1.6)
                for sample in trace.samples.dropFirst() {
                    let start=ProcessInfo.processInfo.systemUptime
                    apply(b.append(sample.point,pressure:sample.nativePressure ?? (sample.tablet ? Double(sample.pressure):nil),isRelease:sample.type==2,timestamp:sample.timestamp),&s)
                    costs.append((ProcessInfo.processInfo.systemUptime-start)*1000)
                    precondition(!b.capacityReached && s.points.last==sample.point)
                }
                precondition(s.isValid)
                if directory=="handwriting-input-balanced" {specimens.append(s)}
                count+=1;events+=trace.samples.count
            }
        }
        check(count>=200,"entire captured handwriting corpus passes geometry and ordering validation")
        #endif
        let long=GoogleInkPenBuilder(point:p,width:1.3,pressure:nil,timestamp:0)
        var ls=initial(long,p,1.3),tailCosts:[Double]=[]
        for i in 1...5000 {
            let start=ProcessInfo.processInfo.systemUptime
            apply(long.append(InkPoint(x:20+Double(i)*0.1,y:40+sin(Double(i)*0.02)*3),pressure:nil,isRelease:false,timestamp:Double(i)/240),&ls)
            if i>4500 {tailCosts.append((ProcessInfo.processInfo.systemUptime-start)*1000)}
        }
        check(ls.isValid && !long.capacityReached,"5000-event continuous stroke remains valid")
        costs.sort();tailCosts.sort()
        let report:[String:Any]=["recipe":PenEngine.recipe,"strokes":count,"events":events,"p95ms":costs.isEmpty ? 0:costs[Int(Double(costs.count)*0.95)],"maxms":costs.last ?? 0,"longP95ms":tailCosts[Int(Double(tailCosts.count)*0.95)],"longVertices":ls.outlines!.flatMap{$0}.count]
        print(report)
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("results.json"))
        try JSONEncoder().encode(specimens).write(to:out.appendingPathComponent("specimens.json"))
        // Independent standard PDF appearance and editable metadata roundtrip.
        let doc=PDFDocument();let page=PDFPage();page.setBounds(CGRect(x:0,y:0,width:600,height:800),for:.mediaBox);doc.insert(page,at:0)
        for s in specimens {page.addAnnotation(InkAnnotationCodec.make(s))}
        check(doc.write(to:out.appendingPathComponent("specimens.pdf")),"standard PDF appearance saved")
        let reopened=PDFDocument(url:out.appendingPathComponent("specimens.pdf"))!
        check(reopened.page(at:0)!.annotations.compactMap{InkAnnotationCodec.stroke(from:$0)}==specimens,"PDF reopen preserves every native contour exactly")
        let image=page.thumbnail(of:CGSize(width:1200,height:1600),for:.mediaBox)
        let rep=NSBitmapImageRep(data:image.tiffRepresentation!)!
        try rep.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent("specimens.png"))
        let savedImage=reopened.page(at:0)!.thumbnail(of:CGSize(width:1200,height:1600),for:.mediaBox)
        let savedRep=NSBitmapImageRep(data:savedImage.tiffRepresentation!)!
        check(rep.pixelsWide==savedRep.pixelsWide && rep.pixelsHigh==savedRep.pixelsHigh && rep.bytesPerRow==savedRep.bytesPerRow,"saved PDF renders at the same resolution")
        let bytes=rep.bytesPerRow*rep.pixelsHigh
        var delta=0.0
        for i in 0..<bytes { delta += Double(abs(Int(rep.bitmapData![i])-Int(savedRep.bitmapData![i]))) }
        check(delta/Double(bytes)<0.1,"standard PDF appearance matches the native contour render within subpixel rounding")
        try savedRep.representation(using:.png,properties:[:])!.write(to:out.appendingPathComponent("reopened.png"))

    }
}
