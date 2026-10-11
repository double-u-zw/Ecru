import AppKit
import PDFKit

@main
enum InkTests {
    static var checks = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func stroke(_ points: [(Double, Double)], width: Double = 2, kind: InkKind = .pen) -> InkStroke {
        InkStroke(points: points.map { InkPoint(x: $0.0, y: $0.1) }, width: width,
                  rgba: kind == .pen ? [0.1, 0.2, 0.8, 1] : [1, 0.8, 0, 0.28], kind: kind)
    }
    static func main() throws {
        // These are algorithm/regression checks, not a human handwriting acceptance.
        let received = [InkPoint(x:0,y:0), InkPoint(x:3,y:0), InkPoint(x:6,y:1),
                        InkPoint(x:9,y:3), InkPoint(x:9,y:6), InkPoint(x:8,y:6)]
        var direct=InkDirectBuilder(point:received[0])
        var exact=[received[0]]
        for p in received.dropFirst() {exact += direct.append(p,pressure:0.99).points}
        check(exact==received,"direct default retains every received corner and hook exactly")
        check(direct.initialFactors == nil,"forwarded pressure cannot change default width")
        check(direct.append(received.last!,isRelease:true).points.isEmpty,"release cannot refit stationary endpoint")
        check(direct.append(InkPoint(x:.nan,y:0)).points.isEmpty,"invalid sample rejected without damaging prefix")
        var optional=InkDirectBuilder(point:received[0],pressure:0.2)
        let contact=optional.append(received[1],pressure:0.8)
        check(contact.factors==[1.06],"optional pressure has narrow explicit mapping")
        check(optional.append(received[2],pressure:0,isRelease:true).factors==contact.factors,"release zero is not a measured tip taper")
        var builder = InkStrokeBuilder(point:received[0],timestamp:1,scale:1,width:2)
        var generated = [received[0]]
        var prefixes: [[InkPoint]] = []
        for i in 1..<received.count {
            prefixes.append(generated)
            generated += builder.append(received[i],timestamp:1+Double(i)*0.008)
            check(generated.starts(with:prefixes.last!), "new sample never rewrites visible prefix")
        }
        check(received.allSatisfy { generated.contains($0) }, "all actual endpoints retained")
        check(generated.count > received.count, "gentle bends receive bounded interpolation")
        check(generated.last == received.last, "hook endpoint exact")
        check(builder.append(received.last!,timestamp:1.1).isEmpty, "stationary release never adds tail")
        var gap = InkStrokeBuilder(point:received[0],timestamp:1,scale:1,width:2)
        _ = gap.append(received[1],timestamp:1.01)
        check(gap.append(received[2],timestamp:1.2) == [received[2]], "input gap stays an explicit straight interval")
        var corner = InkStrokeBuilder(point:received[0],timestamp:1,scale:1,width:2)
        _ = corner.append(received[1],timestamp:1.01)
        let sharp = InkPoint(x:3,y:3)
        check(corner.append(sharp,timestamp:1.02) == [sharp], "right-angle corner preserved")
        let curved = InkStroke(points:generated,width:2,rgba:[0.1,0.2,0.8,1],kind:.pen)
        let curveCuts = InkGeometry.erase(curved,center:CGPoint(x:6,y:1),radius:0.3)
        check(curveCuts.count == 2, "erase follows actual generated curve")
        let curveBox = [CGPoint(x:-2,y:-2),CGPoint(x:12,y:-2),CGPoint(x:12,y:9),CGPoint(x:-2,y:9)]
        check(InkGeometry.isFullyInside(curved,polygon:curveBox), "lasso covers generated curve")
        check(curved.translated(dx:4,dy:5).points == generated.map { InkPoint(x:$0.x+4,y:$0.y+5) }, "curve movement is exact")
        let long = stroke([(0, 50), (100, 50)])
        let pieces = InkGeometry.erase(long, center: CGPoint(x: 50, y: 50), radius: 9)
        check(pieces.count == 2, "sparse segment must split locally")
        check(abs(pieces[0].points.last!.x - 40) < 0.001 && abs(pieces[1].points.first!.x - 60) < 0.001,
              "eraser includes half stroke width")
        check(pieces.allSatisfy { $0.id != long.id } && pieces[0].id != pieces[1].id, "fragments have separate identity")
        check(InkGeometry.erase(long, center: CGPoint(x: 50, y: 90), radius: 3) == [long], "miss keeps identity")
        check(InkGeometry.erase(long, center: CGPoint(x: CGFloat.nan, y: 0), radius: 3) == [long], "invalid eraser coordinate does not destroy geometry")
        check(InkGeometry.erase(long, center: CGPoint(x: 50, y: 50), radius: 80).isEmpty, "full erasure removes geometry")
        check(InkGeometry.erase(stroke([(15, 15)]), center: CGPoint(x: 15, y: 15), radius: 2).isEmpty, "dot erasure")
        let short = stroke([(3, 3), (4, 4)])
        check(InkGeometry.erase(short, center: CGPoint(x: 4, y: 4), radius: 1).isEmpty, "short stroke erasure")
        let zigzag = stroke([(0, 0), (10, 0), (20, 10), (30, 0), (40, 0)])
        let cut = InkGeometry.erase(zigzag, center: CGPoint(x: 10, y: 0), radius: 2)
        check(cut.count == 2 && cut[1].points.last == zigzag.points.last, "polyline partial erasure keeps remainder")
        let concave = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10),
                       CGPoint(x: 7, y: 10), CGPoint(x: 7, y: 3), CGPoint(x: 3, y: 3),
                       CGPoint(x: 3, y: 10), CGPoint(x: 0, y: 10)]
        check(!InkGeometry.isFullyInside(stroke([(1, 8), (9, 8)]), polygon: concave), "concave crossing rejected despite vertices inside")
        check(InkGeometry.isFullyInside(stroke([(1, 2), (9, 2)]), polygon: concave), "fully inside segment accepted")
        check(InkGeometry.isFullyInside(stroke([(0, 0), (10, 0)]), polygon: concave), "polygon boundary accepted")
        check(!InkGeometry.isFullyInside(stroke([(1, 2), (11, 2)]), polygon: concave), "crossing boundary rejected")
        check(InkGeometry.isFullyInside(stroke([(1, 8)]), polygon: concave), "dot selectable")
        // The lower row is in the lasso's outer rectangle but outside its concave region.
        let freehand = [CGPoint(x: 0,y: 0), CGPoint(x: 10,y: 0), CGPoint(x: 10,y: 4),
                        CGPoint(x: 4,y: 4), CGPoint(x: 4,y: 10), CGPoint(x: 0,y: 10)]
        check(InkGeometry.isFullyInside(stroke([(1,2),(8,2)]), polygon: freehand), "freehand upper row selected")
        check(!InkGeometry.isFullyInside(stroke([(5,6),(8,6)]), polygon: freehand), "lower row inside outer rectangle but outside freehand excluded")
        check(!InkGeometry.contains(CGPoint(x:6,y:6), polygon:freehand), "drag hit ignores bounding rectangle concave gap")
        check(InkGeometry.contains(CGPoint(x:2,y:6), polygon:freehand), "drag hit accepts actual freehand lobe")
        check(InkGeometry.isFullyInside(stroke([(1,2),(8,2)],kind:.marker), polygon:freehand), "freehand includes marker with pen")
        let half = [CGPoint(x:-2,y:40),CGPoint(x:44,y:40),CGPoint(x:44,y:60),CGPoint(x:-2,y:60)]
        check(InkGeometry.isFullyInside(pieces[0],polygon:half) && !InkGeometry.isFullyInside(pieces[1],polygon:half), "erased fragments selected independently")
        let moved = long.translated(dx: 5, dy: -3)
        check(moved.id == long.id && moved.points[0] == InkPoint(x: 5, y: 47), "movement preserves stroke identity")

        // Stability changes positions within a strict bound. These algorithm
        // invariants do not claim a person's hand is steadier.
        var stable=InkPositionStabilizer(point:InkPoint(x:0,y:0),timestamp:1,scale:2,width:2.5)
        var stabilized:[InkPoint]=[InkPoint(x:0,y:0)]
        for i in 1...30 {
            let p=InkPoint(x:Double(i),y:i%2==0 ? 0.1 : -0.1)
            let q=stable.append(p,timestamp:1+Double(i)*0.004)
            check(hypot(p.x-q.x,p.y-q.y)*2 <= 0.80000001,"stability displacement stays bounded")
            stabilized.append(q)
        }
        let lastRaw=InkPoint(x:30,y:0.1), lastStable=stabilized.last!
        check(lastStable != lastRaw,"small transverse jitter receives light damping")
        check(stable.append(lastRaw,timestamp:1.13)==lastStable,"stationary release cannot snap endpoint to raw")
        let gapPoint=InkPoint(x:31,y:0.2)
        check(stable.append(gapPoint,timestamp:1.20)==gapPoint,"input gap resets rather than masks missing input")
        let sparsePoint=InkPoint(x:100,y:0.3)
        check(stable.append(sparsePoint,timestamp:1.204)==sparsePoint,"sparse jump is not smoothed into fictional motion")
        var sharpStable=InkPositionStabilizer(point:received[0],timestamp:1,scale:1,width:2)
        _=sharpStable.append(received[1],timestamp:1.004)
        check(sharpStable.append(InkPoint(x:3,y:3),timestamp:1.008)==InkPoint(x:3,y:3),"right angle exits stabilization")
        check(sharpStable.append(InkPoint(x:3,y:1),timestamp:1.012)==InkPoint(x:3,y:1),"hook reversal exits stabilization")
        var straight=InkPositionStabilizer(point:received[0],timestamp:1,scale:1,width:2)
        let straightPoints=(1...5).map { i in straight.append(InkPoint(x:Double(i),y:0),timestamp:1+Double(i)*0.004) }
        check(straightPoints.enumerated().allSatisfy { i,p in p.y==0 && p.x<=Double(i+1) && Double(i+1)-p.x<=0.48000001 },"straight following displacement stays within width-scaled cap")
        check(zip(straightPoints,straightPoints.dropFirst()).allSatisfy{$1.x>$0.x},"steady forward input keeps advancing without sample waits")
        var stableBuilder=InkPenBuilder(point:received[0],timestamp:1,scale:2,width:2.5,pressure:0.1,stabilize:true,smoothPressure:true)
        var stableStroke=InkStroke(points:[received[0]],width:2.5,rgba:[0.1,0.2,0.8,1],kind:.pen,widthFactors:stableBuilder.initialFactors)
        for i in 1...30 {
            let u=stableBuilder.append(InkPoint(x:Double(i),y:i%2==0 ? 0.1 : -0.1),timestamp:1+Double(i)*0.004,pressure:0.1)
            stableStroke.points += u.points;stableStroke.widthFactors! += u.factors!
        }
        check(stableBuilder.append(lastRaw,timestamp:1.13,pressure:0,isRelease:true).points.isEmpty,"pen-up never refits stabilized curve")
        let stabilityCuts=InkGeometry.erase(stableStroke,center:CGPoint(x:15,y:0),radius:2)
        check(stabilityCuts.count==2 && stabilityCuts.allSatisfy(\.isValid),"erase splits the actual stabilized pressure model")
        check(InkGeometry.isFullyInside(stableStroke,polygon:[CGPoint(x:-2,y:-2),CGPoint(x:33,y:-2),CGPoint(x:33,y:2),CGPoint(x:-2,y:2)]),"lasso covers actual stabilized trajectory")
        // Tablet pressure is applied to the envelope, never to the centerline.
        var pressure = InkPenBuilder(point: received[0],timestamp:1,scale:1,width:2,pressure:0.1)
        let initial = pressure.initialFactors!
        let pressureNext = pressure.append(received[1],timestamp:1.01,pressure:0.2)
        check(pressureNext.points == [received[1]] && pressureNext.factors!.last! > initial[0], "real pressure changes only width")
        let release = pressure.append(received[2],timestamp:1.02,pressure:0,isRelease:true)
        check(release.factors!.allSatisfy { $0 == pressureNext.factors!.last! }, "synthetic release zero cannot pinch the tip")
        check(pressure.append(received[2],timestamp:1.03,pressure:0,isRelease:true).points.isEmpty, "stationary pressure release does not reshape dot")
        var mouse = InkPenBuilder(point:received[0],timestamp:1,scale:1,width:2,pressure:nil)
        check(mouse.append(received[1],timestamp:1.01,pressure:1).factors == nil, "ordinary mouse has no invented pressure")
        var pressureDamped=InkPenBuilder(point:received[0],timestamp:1,scale:1,width:1.5,pressure:0.1,smoothPressure:true)
        let initialDamped=pressureDamped.initialFactors![0]
        let rising=pressureDamped.append(received[1],timestamp:1.004,pressure:0.2).factors!.last!
        let targetWidth=InkPenBuilder.widthFactor(0.2)
        check(rising>initialDamped && rising<targetWidth && targetWidth-rising<=0.08000001,"pressure flutter is damped within the width bound")
        let falling=pressureDamped.append(received[2],timestamp:1.008,pressure:0).factors!.last!
        check(falling>=0.5 && falling<=0.58000001,"light contact tip remains narrow without long pressure lag")
        let releaseDamped=pressureDamped.append(received[3],timestamp:1.012,pressure:0,isRelease:true).factors!
        check(releaseDamped.allSatisfy{$0==falling},"release adds no pressure settling or shrinking")
        let afterGap=pressureDamped.append(received[4],timestamp:1.1,pressure:0.2).factors!.last!
        check(abs(afterGap-targetWidth)<1e-10,"pressure gap resets directly to actual pressure")
        var tapered = stroke([(0,50),(100,50)],width:10)
        tapered.widthFactors = [0.5,1.3]
        let taperedCuts = InkGeometry.erase(tapered,center:CGPoint(x:50,y:50),radius:5)
        check(taperedCuts.count == 2, "pressure envelope erases locally")
        check(abs(taperedCuts[0].points.last!.x - 42.5/1.04) < 1e-8 &&
              abs(taperedCuts[1].points.first!.x - 57.5/0.96) < 1e-8, "eraser intersects true varying radius")
        check(taperedCuts.allSatisfy { cut in zip(cut.points,cut.widthFactors!).allSatisfy { abs($0.1-(0.5+0.008*$0.0.x)) < 1e-8 } }, "cut endpoint width interpolates without new taper")
        check(tapered.translated(dx:7,dy:9).widthFactors == tapered.widthFactors, "movement preserves pressure envelope")
        check(InkGeometry.isFullyInside(tapered,polygon:[CGPoint(x:-10,y:30),CGPoint(x:110,y:30),CGPoint(x:110,y:70),CGPoint(x:-10,y:70)]), "pressure stroke lasso uses same canonical trajectory")
        var invalid = tapered; invalid.widthFactors = [1]
        check(!invalid.isValid, "unaligned pressure data rejected")
        invalid.widthFactors = [1,Double.nan]
        check(!invalid.isValid, "nonfinite pressure data rejected")
        let pressureSample = tapered.translated(dx:200,dy:220)
        // Fill a self-crossing, changing-width stroke and compare the actual saved
        // appearance with the same in-app renderer, including a rotated crop page.
        for rotation in [0,90,180,270] {
          for box: PDFDisplayBox in [.mediaBox,.cropBox] {
            let pressureDoc = PDFDocument(), pressurePage = PDFPage()
            pressurePage.setBounds(CGRect(x:0,y:0,width:400,height:400),for:.mediaBox)
            pressurePage.setBounds(CGRect(x:20,y:30,width:350,height:340),for:.cropBox)
            pressurePage.rotation = rotation
            var sample=stroke([(80,80),(250,250),(80,250),(250,80),(80,80)],width:12)
            sample.widthFactors=[0.5,1.3,0.7,1.1,0.5]
            if rotation == 180 { sample.rgba[3] = 0.4 }
            pressurePage.addAnnotation(InkAnnotationCodec.make(sample));pressureDoc.insert(pressurePage,at:0)
            let reopenedDocument = PDFDocument(data:pressureDoc.dataRepresentation()!)!
            let reopened = reopenedDocument.page(at:0)!
            check(InkAnnotationCodec.stroke(from:reopened.annotations[0]) == sample,"pressure metadata round trip with page rotation")
            var pixels: [[UInt8]] = []
            for saved in [false,true] {
                let ctx=CGContext(data:nil,width:800,height:800,bitsPerComponent:8,bytesPerRow:3200,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                ctx.setFillColor(CGColor(gray:1,alpha:1));ctx.fill(CGRect(x:0,y:0,width:800,height:800));ctx.scaleBy(x:2,y:2)
                if saved {
                    reopened.draw(with:box,to:ctx)
                } else {
                    ctx.concatenate(pressurePage.transform(for:box))
                    InkRenderer.drawPressure(sample,in:ctx,scale:1,convert:{$0})
                }
                pixels.append(Array(UnsafeBufferPointer(start:ctx.data!.assumingMemoryBound(to:UInt8.self),count:800*800*4)))
            }
            let largeDifferences = zip(pixels[0],pixels[1]).filter{abs(Int($0)-Int($1))>12}.count
            check(largeDifferences < 100, "saved standard pressure appearance matches live renderer")
          }
        }

        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let samples = [stroke([(100, 110), (145, 135), (160, 100)]), stroke([(180, 130)]),
                       stroke([(210, 160), (380, 160)], width: 18, kind: .marker)] + pieces + [curved, pressureSample, stableStroke.translated(dx:100,dy:300)]
        for sample in samples { page.addAnnotation(InkAnnotationCodec.make(sample)) }
        let foreign = PDFAnnotation(bounds: CGRect(x: 20, y: 20, width: 30, height: 30), forType: .ink, withProperties: nil)
        let path = NSBezierPath(); path.move(to: .zero); path.line(to: CGPoint(x: 10, y: 10)); foreign.add(path)
        page.addAnnotation(foreign)
        check(InkAnnotationCodec.stroke(from: foreign) == nil, "foreign ink preserved")
        let wrongType = PDFAnnotation(bounds: samples[0].bounds, forType: .square, withProperties: nil)
        wrongType.setValue(InkAnnotationCodec.make(samples[0]).value(forAnnotationKey: InkAnnotationCodec.metadataKey)!,
                           forAnnotationKey: InkAnnotationCodec.metadataKey)
        check(InkAnnotationCodec.stroke(from: wrongType) == nil, "metadata on other annotation types rejected")
        guard let data = document.dataRepresentation(), let reopened = PDFDocument(data: data), let reopenedPage = reopened.page(at: 0) else {
            throw NSError(domain: "InkTests", code: 1)
        }
        let restored = reopenedPage.annotations.compactMap { InkAnnotationCodec.stroke(from: $0) }
        check(restored == samples, "single PDF reopens all editable models and fragment IDs")
        check(reopenedPage.annotations.count == samples.count + 1, "foreign annotation survives serialization")
        check(restored[2].rgba[3] == 0.28, "marker transparency metadata survives")
        let ink = reopenedPage.annotations[0]
        let localPoint = ink.paths![0].element(at: 0, associatedPoints: nil)
        check(localPoint == .moveTo, "standard ink path survives serialization")
        var pathPoints = [CGPoint](repeating: .zero, count: 3)
        pathPoints.withUnsafeMutableBufferPointer { buffer in
            _ = ink.paths![0].element(at: 0, associatedPoints: buffer.baseAddress)
        }
        check(abs(pathPoints[0].x - 2) < 0.001 && abs(pathPoints[0].y - 12) < 0.001, "paths use annotation-relative geometry")
        let bitmap = CGContext(data: nil, width: 612, height: 792, bitsPerComponent: 8, bytesPerRow: 612 * 4,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.setFillColor(CGColor(gray: 1, alpha: 1))
        bitmap.fill(CGRect(x: 0, y: 0, width: 612, height: 792))
        reopenedPage.draw(with: .mediaBox, to: bitmap)
        let bytes = bitmap.data!.assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> [Int] {
            let offset = ((791 - y) * 612 + x) * 4
            return (0..<4).map { Int(bytes[offset + $0]) }
        }
        let markerPixel = pixel(250, 160)
        check(markerPixel[0] > 250 && markerPixel[1] > 225 && (175...195).contains(markerPixel[2]), "standard appearance renders marker alpha over white")
        let dotPixel = pixel(180, 130)
        check(dotPixel[2] > dotPixel[0] + 80 && dotPixel[0] < 150, "tap has a visible standard ink appearance")
        let altered = InkAnnotationCodec.make(samples[0]); altered.bounds.origin.x += 20
        check(InkAnnotationCodec.stroke(from: altered) == nil, "externally changed bounds fail closed")
        let changedPath = InkAnnotationCodec.make(samples[0])
        changedPath.remove(changedPath.paths![0])
        let unrelated = NSBezierPath(); unrelated.move(to: CGPoint(x: 2, y: 2)); unrelated.line(to: CGPoint(x: 60, y: 30))
        changedPath.add(unrelated)
        check(InkAnnotationCodec.stroke(from: changedPath) == nil, "externally changed path is preserved as foreign")
        let changedWidth = InkAnnotationCodec.make(samples[0])
        changedWidth.border!.lineWidth += 2
        check(InkAnnotationCodec.stroke(from: changedWidth) == nil, "externally changed width is preserved as foreign")
        let croppedPage = PDFPage()
        croppedPage.setBounds(CGRect(x: 0, y: 0, width: 800, height: 900), for: .mediaBox)
        croppedPage.setBounds(CGRect(x: 60, y: 40, width: 600, height: 800), for: .cropBox)
        croppedPage.rotation = 90
        let croppedStroke = stroke([(90, 80), (300, 320)])
        croppedPage.addAnnotation(InkAnnotationCodec.make(croppedStroke))
        document.insert(croppedPage, at: 1)
        let croppedReload = PDFDocument(data: document.dataRepresentation()!)!.page(at: 1)!
        check(croppedReload.rotation == 90 && croppedReload.bounds(for: .cropBox) == croppedPage.bounds(for: .cropBox), "page rotation and crop bounds survive")
        check(InkAnnotationCodec.stroke(from: croppedReload.annotations[0]) == croppedStroke, "ink keeps page coordinates on rotated cropped page")
        let malformed = InkAnnotationCodec.make(samples[0])
        malformed.setValue("bad JSON", forAnnotationKey: InkAnnotationCodec.metadataKey)
        check(InkAnnotationCodec.stroke(from: malformed) == nil, "malformed metadata preserved as foreign")
        let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/private/tmp/ecru-ink-tests.pdf")
        try data.write(to: output)
        print("PASS: \(checks) ink geometry / single-PDF round-trip checks; fixture: \(output.path)")
    }
}
