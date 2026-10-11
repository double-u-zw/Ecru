import AppKit
import PDFKit

@main enum InkNaturalTests {
    static var checks=0
    static func check(_ condition:Bool,_ label:String) {checks+=1;guard condition else{fatalError(label)};print("PASS: \(label)")}
    static func build(_ input:[InkPoint],scale:Double=1)->[InkPoint] {
        let builder=InkCurveBuilder(point:input[0],timestamp:1,scale:scale)
        var result=[input[0]]
        for (i,p) in input.dropFirst().enumerated() {
            let u=builder.append(p,timestamp:1+Double(i+1)*0.004)
            result.removeLast(u.removing);result+=u.points
        }
        return result
    }
    static func main() throws {
        let hook=[InkPoint(x:10,y:10),InkPoint(x:12,y:10),InkPoint(x:14,y:10),InkPoint(x:14,y:12),InkPoint(x:13.5,y:12.2)]
        let path=build(hook)
        check(path.first==hook.first && path.last==hook.last,"short hook preserves actual first and last point")
        check(path.contains(hook[2]) && path.contains(hook[3]),"Chinese right-angle turn and hook vertex survive")
        check(build([hook[0],hook[1]])==Array(hook.prefix(2)),"two-sample short dash remains a straight stroke")
        check(build([hook[0],hook[0]])==[hook[0]],"tap and repeated position do not create a tail")
        let noisy=(0..<90).map{InkPoint(x:Double($0),y:$0%2==0 ? 0.12 : -0.12)}
        let cleaned=build(noisy)
        let rawVariation=zip(noisy,noisy.dropFirst()).reduce(0){$0+abs($1.1.y-$1.0.y)}
        let newVariation=zip(cleaned,cleaned.dropFirst()).reduce(0){$0+abs($1.1.y-$1.0.y)}
        check(newVariation<rawVariation*0.85,"subpixel straight-line chatter decreases without velocity-based width")
        let circle=(0...80).map{InkPoint(x:10+3*cos(Double($0)*2*Double.pi/80),y:10+3*sin(Double($0)*2*Double.pi/80))}
        let small=build(circle)
        func area(_ pts:[InkPoint])->Double {abs(zip(pts,pts.dropFirst()).reduce(0){$0+$1.0.x*$1.1.y-$1.1.x*$1.0.y})/2}
        check(abs(area(small)-area(circle))/area(circle)<0.025,"small loop area changes less than 2.5 percent")
        check(small.last==circle.last,"small closed loop keeps exact closure")
        let builder=InkCurveBuilder(point:circle[0],timestamp:2,scale:2)
        var geometry=[circle[0]],stable=[circle[0]],endpointsExact=true,prefixesStable=true
        for (i,p) in circle.dropFirst().enumerated() {
            let before=geometry,u=builder.append(p,timestamp:2+Double(i+1)*0.004)
            geometry.removeLast(u.removing);geometry+=u.points
            endpointsExact = endpointsExact && geometry.last==p
            prefixesStable = prefixesStable && geometry.starts(with:before.dropLast(u.removing))
            stable=geometry
        }
        check(endpointsExact,"every latest actual endpoint is immediately displayed")
        check(prefixesStable,"all settled prefixes are immutable")
        let up=builder.append(circle.last!,timestamp:3,isRelease:true)
        check(up.points.isEmpty && up.removing==0 && geometry==stable,"stationary pen-up cannot refit or alter pixels")
        check(builder.append(InkPoint(x:.nan,y:0),timestamp:4).points.isEmpty,"invalid input cannot corrupt current curve")
        let gap=InkCurveBuilder(point:hook[0],timestamp:1,scale:1)
        _=gap.append(hook[1],timestamp:1.004)
        let afterGap=gap.append(InkPoint(x:20,y:16),timestamp:1.5)
        check(afterGap.points==[hook[1],InkPoint(x:20,y:16)],"long timestamp gap is not smoothed into fictional motion")
        let equal=InkCurveBuilder(point:hook[0],timestamp:1,scale:1)
        _=equal.append(hook[1],timestamp:1)
        check(equal.append(hook[2],timestamp:1).points.last==hook[2],"batch-equal timestamps preserve callback coordinate order")
        let stroke=InkStroke(points:path,width:1.6,rgba:[0.1,0.2,0.8,1],kind:.pen)
        check(InkAnnotationCodec.stroke(from:InkAnnotationCodec.make(stroke))==stroke,"baked geometry roundtrips existing PDF schema without rerunning curve recipe")
        let fragments=InkGeometry.erase(stroke,center:hook[2].cgPoint,radius:0.1)
        check(fragments.count==2 && fragments.last?.points.last==hook.last,"eraser hits displayed corner and retains actual hook end")
        let box=[CGPoint(x:8,y:8),CGPoint(x:17,y:8),CGPoint(x:17,y:15),CGPoint(x:8,y:15)]
        check(InkGeometry.isFullyInside(stroke,polygon:box),"lasso selects the same baked geometry")
        // Cache must match the original renderer, including boundaries between blocks.
        let pts=(0..<650).map{InkPoint(x:10+Double($0)*0.42,y:100+sin(Double($0)/9)*12)}
        var long=InkStroke(points:pts,width:2.5,rgba:[0.1,0.2,0.8,1],kind:.pen)
        let cache=InkPathCache();cache.sync(long)
        func pixels(cached:Bool)->Data {
            let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:600,pixelsHigh:300,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:2400,bitsPerPixel:32)!
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
            NSColor.white.setFill();NSBezierPath(rect:CGRect(x:0,y:0,width:600,height:300)).fill()
            if cached {cache.draw(long,in:NSGraphicsContext.current!.cgContext,clip:CGRect(x:0,y:0,width:600,height:300))}
            else {InkRenderer.draw(long,scale:1,convert:{$0})}
            NSGraphicsContext.restoreGraphicsState()
            return Data(bytes:bitmap.bitmapData!,count:720000)
        }
        let a=pixels(cached:false),b=pixels(cached:true)
        let significant=zip(a,b).filter{abs(Int($0)-Int($1))>8}.count
        check(significant<100,"chunk cache preserves original fixed-width appearance (\(significant) significant RGBA bytes)")
        let incremental=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:600,pixelsHigh:300,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:2400,bitsPerPixel:32)!
        func paint(_ bitmap:NSBitmapImageRep,_ path:InkPathCache,clip:CGRect) {
            NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
            NSBezierPath(rect:clip).addClip();NSColor.white.setFill();NSBezierPath(rect:clip).fill()
            path.draw(long,in:NSGraphicsContext.current!.cgContext,clip:clip)
            NSGraphicsContext.restoreGraphicsState()
        }
        paint(incremental,cache,clip:CGRect(x:0,y:0,width:600,height:300))
        let oldTail=Array(long.points.suffix(5))
        let prior=cache.rebuiltPoints
        long.points.removeLast(4);long.points += [InkPoint(x:284,y:95),InkPoint(x:285,y:94)]
        cache.invalidate(from:646);cache.sync(long)
        check(cache.rebuiltPoints-prior<150,"tail amendment rebuilds bounded block, not entire long stroke")
        let fresh=InkPathCache();fresh.sync(long)
        check(cache.bounds==fresh.bounds,"tail amendment updates cache bounds exactly")
        let damage=(oldTail+Array(long.points.suffix(3))).reduce(CGRect.null){$0.union(CGRect(origin:$1.cgPoint,size:.zero))}.insetBy(dx:-4,dy:-4).integral
        paint(incremental,cache,clip:damage)
        let full=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:600,pixelsHigh:300,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:2400,bitsPerPixel:32)!
        paint(full,fresh,clip:CGRect(x:0,y:0,width:600,height:300))
        let incrementalBytes=Data(bytes:incremental.bitmapData!,count:720000),fullBytes=Data(bytes:full.bitmapData!,count:720000)
        let damageDifference=zip(incrementalBytes,fullBytes).reduce(0){$0+abs(Int($1.0)-Int($1.1))}
        let differences=zip(incrementalBytes,fullBytes).map{abs(Int($0)-Int($1))}
        // CoreGraphics clipping can quantize coverage differently by a few
        // byte levels. Reject visible residues, not harmless antialias rounding.
        check(differences.max()!<=8 && damageDifference<150,"amended cached tail clears old pixels and matches full redraw within antialias tolerance (\(damageDifference) RGBA total)")

        let grid:[InkStroke]=(0..<5000).map {i in
            let x=Double(i%50)*12,y=Double(i/50)*12
            let points=[InkPoint(x:x,y:y),InkPoint(x:x+5,y:y+2)]
            return InkStroke(points:points,width:1.6,rgba:[0,0,0,1],kind:.pen)
        }
        let index=InkPageIndex();index.reset(grid)
        let query=CGRect(x:23,y:23,width:16,height:16)
        check(index.candidates(in:query)==grid.indices.filter{grid[$0].bounds.intersects(query)},"5000-stroke spatial lookup matches exhaustive geometry in paint order")
        let moved=grid[77].translated(dx:1,dy:1)
        index.invalidate([moved.id]);var changed=grid;changed[77]=moved;index.reset(changed)
        check(index.candidates(in:query)==changed.indices.filter{changed[$0].bounds.intersects(query)},"moved stroke replaces spatial bounds without stale historical entries")
        index.update(grid.last!.id,bounds:query)
        check(index.candidates(in:query).last==4999,"tail update becomes immediately discoverable and keeps stacking order")
        print("\(checks) natural geometry and cache checks passed; algorithm tests are not human acceptance.")
    }
}
