import AppKit
import PDFKit

/// New diagnostic names take precedence; legacy environment contracts stay usable.
enum EcruEnvironment {
    static func value(_ key: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        return environment[key] ?? environment[key.replacingOccurrences(of: "ECRU_", with: "LEAFINK_")]
    }
}


enum InkKind: String, Codable {
    case pen, marker
}

/// All editable geometry uses the PDF page's unrotated coordinate system.
struct InkPoint: Codable, Equatable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) { self.x = x; self.y = y }
    init(_ point: CGPoint) { x = Double(point.x); y = Double(point.y) }
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

enum InkAppearance:String,Codable {case flowV1 = "flow-disc-v1",perfectFreehandV1 = "perfect-freehand-outline-v1"}

struct InkOutlineUpdate {var removing=0;var points:[InkPoint]=[];var factors:[Double]=[];var removingOutlines=1;var outlines:[[InkPoint]]=[]}

struct InkStroke: Codable, Equatable {
    var id: UUID = UUID()
    var points: [InkPoint]
    var width: Double
    var rgba: [Double]
    var kind: InkKind
    // Optional for backward-compatible fixed-width ink. Values align with the
    // canonical displayed points, not with a separate raw-input trajectory.
    var widthFactors: [Double]? = nil
    // Absent means the frozen legacy painter, never reinterpreted on reopen.
    var appearance:InkAppearance? = nil
    // Baked closed outline blocks are authoritative for the new pen. No renderer
    // or eraser regenerates caps/pressure from the remaining centerline.
    var outlines:[[InkPoint]]? = nil
    var requiredReader:Int {appearance == .perfectFreehandV1 ? 3 : (appearance == nil ? 1 : 2)}

    func radius(at index: Int) -> Double { width * (widthFactors?[index] ?? 1) / 2 }
    var maximumWidth: Double { width * (widthFactors?.max() ?? 1) }

    var bounds: CGRect {
        if let outlines {return InkOutline.bounds(outlines).insetBy(dx:-1,dy:-1)}
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        // Padding prevents the standard appearance from clipping round stroke ends.
        let padding = max(0.5, maximumWidth / 2 + 1)
        return CGRect(x: minX - padding, y: minY - padding,
                      width: maxX - minX + padding * 2,
                      height: maxY - minY + padding * 2)
    }

    func translated(dx: Double, dy: Double) -> InkStroke {
        var result = self
        result.points = points.map { InkPoint(x: $0.x + dx, y: $0.y + dy) }
        result.outlines=outlines?.map{$0.map{InkPoint(x:$0.x+dx,y:$0.y+dy)}}
        return result
    }

    var isValid: Bool {
        (appearance == .perfectFreehandV1 ? outlines != nil && !outlines!.isEmpty && outlines!.count<=10000 && outlines!.allSatisfy{$0.count>=3} && outlines!.reduce(0,{$0+$1.count})<=2_000_000 && outlines!.flatMap{$0}.allSatisfy{$0.x.isFinite && $0.y.isFinite && abs($0.x)<=10_000_000 && abs($0.y)<=10_000_000} : outlines == nil) &&
        (appearance == nil || kind == .pen) &&
        (widthFactors == nil || (kind == .pen && widthFactors!.count == points.count &&
            widthFactors!.allSatisfy { $0.isFinite && (0.35...1.6).contains($0) })) &&
        !points.isEmpty && points.count <= 100_000 && width.isFinite && width >= 0.1 && width <= 256 &&
        rgba.count == 4 && rgba.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        points.allSatisfy { $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 10_000_000 && abs($0.y) <= 10_000_000 }
    }
}

enum InkGeometry {
    private static let epsilon = 1e-8

    /// Erases actual geometry, including the middle of a sparsely sampled segment.
    /// New fragments receive their own identity; a missed stroke keeps its identity.
    static func erase(_ stroke: InkStroke, center: CGPoint, radius: CGFloat) -> [InkStroke] {
        guard stroke.isValid, radius.isFinite, radius >= 0, center.x.isFinite, center.y.isFinite else { return [stroke] }
        if stroke.outlines != nil {return InkOutline.erase(stroke,center:center,radius:radius)}
        let c = InkPoint(center)
        if stroke.points.count == 1 {
            let r = Double(radius) + stroke.radius(at: 0)
            return squaredDistance(stroke.points[0], c) > r*r + epsilon ? [stroke] : []
        }
        var fragments: [InkStroke] = [], current: [InkPoint] = [], factors: [Double] = []
        var changed = false
        func finish() {
            if !current.isEmpty {
                fragments.append(InkStroke(points: current, width: stroke.width, rgba: stroke.rgba,
                    kind: stroke.kind, widthFactors: stroke.widthFactors == nil ? nil : factors,appearance:stroke.appearance))
                current = []; factors = []
            }
        }
        func append(_ p: InkPoint, _ factor: Double) {
            if let last = current.last, squaredDistance(last, p) <= epsilon * epsilon { return }
            current.append(p); factors.append(factor)
        }
        for i in 1..<stroke.points.count {
            let a = stroke.points[i-1], b = stroke.points[i]
            let f0 = stroke.widthFactors?[i-1] ?? 1, f1 = stroke.widthFactors?[i] ?? 1
            let r0 = Double(radius) + stroke.width*f0/2, dr = stroke.width*(f1-f0)/2
            let dx = b.x-a.x, dy = b.y-a.y, fx = a.x-c.x, fy = a.y-c.y
            // Distance to the moving center minus the linearly varying radius.
            // This is the same swept-disc envelope that the renderer fills.
            let qa = dx*dx + dy*dy - dr*dr
            let qb = 2*(fx*dx + fy*dy - r0*dr)
            let qc = fx*fx + fy*fy - r0*r0
            func outside(_ t: Double) -> Bool { (qa*t + qb)*t + qc > epsilon }
            var cuts = [0.0, 1.0]
            if abs(qa) <= epsilon {
                if abs(qb) > epsilon {
                    let t = -qc/qb
                    if t > epsilon && t < 1-epsilon { cuts.append(t) }
                }
            } else {
                let discriminant = qb*qb - 4*qa*qc
                if discriminant > epsilon {
                    let root = sqrt(discriminant)
                    for t in [(-qb-root)/(2*qa), (-qb+root)/(2*qa)] {
                        if t > epsilon && t < 1-epsilon { cuts.append(t) }
                    }
                }
            }
            cuts.sort()
            for j in 1..<cuts.count {
                let start = cuts[j-1], end = cuts[j]
                if outside((start+end)/2) {
                    append(interpolate(a,b,start), f0+(f1-f0)*start)
                    append(interpolate(a,b,end), f0+(f1-f0)*end)
                } else { changed = true; finish() }
            }
        }
        finish()
        return changed ? fragments : [stroke]
    }

    /// Tests every interval between polygon-edge crossings. Checking sampled
    /// vertices alone would incorrectly select strokes crossing a concave notch.
    static func isFullyInside(_ stroke: InkStroke, polygon: [CGPoint]) -> Bool {
        guard stroke.isValid, polygon.count >= 3,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        if let outlines=stroke.outlines {
            return outlines.allSatisfy{isFullyInside(InkStroke(points:$0+[$0[0]],width:stroke.width,rgba:stroke.rgba,kind:.pen),polygon:polygon)}
        }
        let poly = polygon.map(InkPoint.init)
        guard stroke.points.allSatisfy({ contains($0, in: poly) }) else { return false }
        for i in 1..<stroke.points.count {
            let a = stroke.points[i - 1], b = stroke.points[i]
            if squaredDistance(a, b) <= epsilon * epsilon { continue }
            var cuts = [0.0, 1.0]
            for j in 0..<poly.count {
                cuts.append(contentsOf: segmentParameters(a, b, poly[j], poly[(j + 1) % poly.count]))
            }
            cuts.sort()
            for j in 1..<cuts.count where cuts[j] - cuts[j - 1] > epsilon {
                if !contains(interpolate(a, b, (cuts[j] + cuts[j - 1]) / 2), in: poly) { return false }
            }
        }
        return true
    }

    /// Uses the same even-odd closed polygon as whole-stroke selection and display.
    static func contains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3, point.x.isFinite, point.y.isFinite,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        return contains(InkPoint(point), in: polygon.map(InkPoint.init))
    }

    private static func squaredDistance(_ a: InkPoint, _ b: InkPoint) -> Double {
        let dx = a.x - b.x, dy = a.y - b.y
        return dx * dx + dy * dy
    }
    private static func interpolate(_ a: InkPoint, _ b: InkPoint, _ t: Double) -> InkPoint {
        InkPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }
    private static func cross(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
        ax * by - ay * bx
    }
    private static func onSegment(_ p: InkPoint, _ a: InkPoint, _ b: InkPoint) -> Bool {
        let scale = max(1, abs(b.x - a.x) + abs(b.y - a.y))
        return abs(cross(p.x - a.x, p.y - a.y, b.x - a.x, b.y - a.y)) <= epsilon * scale &&
            p.x >= min(a.x, b.x) - epsilon && p.x <= max(a.x, b.x) + epsilon &&
            p.y >= min(a.y, b.y) - epsilon && p.y <= max(a.y, b.y) + epsilon
    }
    private static func contains(_ p: InkPoint, in polygon: [InkPoint]) -> Bool {
        var inside = false
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            if onSegment(p, a, b) { return true }
            if (a.y > p.y) != (b.y > p.y) {
                let intersectionX = a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y)
                if p.x < intersectionX { inside.toggle() }
            }
        }
        return inside
    }
    private static func segmentParameters(_ a: InkPoint, _ b: InkPoint, _ c: InkPoint, _ d: InkPoint) -> [Double] {
        let rx = b.x - a.x, ry = b.y - a.y, sx = d.x - c.x, sy = d.y - c.y
        let denominator = cross(rx, ry, sx, sy)
        let qx = c.x - a.x, qy = c.y - a.y
        if abs(denominator) > epsilon {
            let t = cross(qx, qy, sx, sy) / denominator
            let u = cross(qx, qy, rx, ry) / denominator
            if t >= -epsilon && t <= 1 + epsilon && u >= -epsilon && u <= 1 + epsilon {
                return [min(1, max(0, t))]
            }
        } else if abs(cross(qx, qy, rx, ry)) <= epsilon {
            // Collinear polygon edges also partition the segment correctly.
            let length2 = rx * rx + ry * ry
            guard length2 > epsilon * epsilon else { return [] }
            let t1 = (qx * rx + qy * ry) / length2
            let t2 = ((d.x - a.x) * rx + (d.y - a.y) * ry) / length2
            return [t1, t2].filter { $0 >= 0 && $0 <= 1 }
        }
        return []
    }
}

/// Baked outline geometry shared by screen, PDF, hit testing and erasure.
enum InkOutline {
    static func bounds(_ contours:[[InkPoint]])->CGRect {
        contours.reduce(CGRect.null){r,points in points.reduce(r){$0.union(CGRect(origin:$1.cgPoint,size:.zero))}}
    }
    static func path(_ contours:[[InkPoint]])->CGPath {
        let path=CGMutablePath()
        for points in contours where points.count>=3 {path.move(to:points[0].cgPoint);for p in points.dropFirst(){path.addLine(to:p.cgPoint)};path.closeSubpath()}
        return path
    }
    private static func mid(_ a:CGPoint,_ b:CGPoint)->CGPoint {CGPoint(x:(a.x+b.x)/2,y:(a.y+b.y)/2)}
    private static func error(_ p:CGPoint,_ a:CGPoint,_ b:CGPoint)->Double {
        let dx=b.x-a.x,dy=b.y-a.y,l=hypot(dx,dy)
        return l>1e-10 ? abs(dx*(p.y-a.y)-dy*(p.x-a.x))/l : hypot(p.x-a.x,p.y-a.y)
    }
    private static func quad(_ a:CGPoint,_ b:CGPoint,_ c:CGPoint,_ depth:Int,_ output:inout [InkPoint]) {
        if error(b,a,c)<0.015 || depth>=10 {output.append(InkPoint(c));return}
        let ab=mid(a,b),bc=mid(b,c),center=mid(ab,bc)
        quad(a,ab,center,depth+1,&output);quad(center,bc,c,depth+1,&output)
    }
    private static func cubic(_ a:CGPoint,_ b:CGPoint,_ c:CGPoint,_ d:CGPoint,_ depth:Int,_ output:inout [InkPoint]) {
        if max(error(b,a,d),error(c,a,d))<0.015 || depth>=10 {output.append(InkPoint(d));return}
        let ab=mid(a,b),bc=mid(b,c),cd=mid(c,d),left=mid(ab,bc),right=mid(bc,cd),center=mid(left,right)
        cubic(a,ab,left,center,depth+1,&output);cubic(center,right,cd,d,depth+1,&output)
    }
    // Closed quadratic midpoint interpolation, as in the upstream SVG rendering
    // examples. Store its flattened result once, rather than re-smoothing edits.
    static func smooth(_ outline:[InkPoint])->[InkPoint] {
        guard outline.count>=3 else{return outline}
        var result=[InkPoint(mid(outline.last!.cgPoint,outline[0].cgPoint))]
        for i in outline.indices {quad(result.last!.cgPoint,outline[i].cgPoint,mid(outline[i].cgPoint,outline[(i+1)%outline.count].cgPoint),0,&result)}
        if result.first==result.last {result.removeLast()};return result
    }
    static func contours(_ path:CGPath)->[[InkPoint]] {
        var result:[[InkPoint]]=[],current:[InkPoint]=[]
        func finish(){if current.last==current.first && current.count>1 {current.removeLast()};if current.count>=3{result.append(current)};current=[]}
        path.applyWithBlock {element in
            let e=element.pointee,p=e.points
            switch e.type {
            case .moveToPoint:finish();current=[InkPoint(p[0])]
            case .addLineToPoint:current.append(InkPoint(p[0]))
            case .addQuadCurveToPoint:if let a=current.last {quad(a.cgPoint,p[0],p[1],0,&current)}
            case .addCurveToPoint:if let a=current.last {cubic(a.cgPoint,p[0],p[1],p[2],0,&current)}
            case .closeSubpath:finish()
            @unknown default:break
            }
        };finish();return result
    }
    static func erase(_ stroke:InkStroke,center:CGPoint,radius:CGFloat)->[InkStroke] {
        let original=path(stroke.outlines!).normalized(),mask=CGPath(ellipseIn:CGRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2),transform:nil)
        guard !original.intersection(mask).isEmpty else{return [stroke]}
        let clipped=original.subtracting(mask),pieces=contours(clipped)
        if pieces.isEmpty {return []}
        func area(_ p:[InkPoint])->Double {abs(p.indices.reduce(0){sum,i in let q=p[(i+1)%p.count];return sum+p[i].x*q.y-q.x*p[i].y})/2}
        let areas=pieces.map(area)
        let parents=pieces.indices.map{i in pieces.indices.filter{$0 != i && areas[$0]>areas[i] && InkGeometry.contains(pieces[i][0].cgPoint,polygon:pieces[$0].map(\.cgPoint))}.min{areas[$0]<areas[$1]}}
        func depth(_ i:Int)->Int {var d=0,p=parents[i];while let j=p {d+=1;p=parents[j]};return d}
        return pieces.indices.filter{depth($0)%2==0}.map{i in
            let shape=[pieces[i]]+pieces.indices.filter{parents[$0]==i && depth($0)%2==1}.map{pieces[$0]}
            let region=path(shape),indices=stroke.points.indices.filter{region.contains(stroke.points[$0].cgPoint)}
            let p=indices.isEmpty ? [pieces[i][0]] : indices.map{stroke.points[$0]}
            let f=indices.isEmpty ? [1.0] : indices.map{stroke.widthFactors?[$0] ?? 1}
            return InkStroke(points:p,width:stroke.width,rgba:stroke.rgba,kind:stroke.kind,widthFactors:f,appearance:stroke.appearance,outlines:shape)
        }
    }
}

enum InkAnnotationCodec {
    static let metadataKey = PDFAnnotationKey(rawValue: "/LeafInkStroke")
    private struct Envelope: Codable { var schema: Int; var stroke: InkStroke }

    static func make(_ stroke: InkStroke) -> PDFAnnotation {
        precondition(stroke.isValid, "Invalid ink geometry")
        let bounds = stroke.bounds
        let annotation: PDFAnnotation
        if stroke.widthFactors != nil || stroke.outlines != nil {
            annotation = PressureInkAnnotation(stroke: stroke)
        } else {
            annotation = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        }
        annotation.color = NSColor(srgbRed: stroke.rgba[0], green: stroke.rgba[1],
                                   blue: stroke.rgba[2], alpha: stroke.rgba[3])
        let border = PDFBorder()
        border.lineWidth = CGFloat(stroke.width)
        annotation.border = border
        annotation.shouldPrint = true
        let path = NSBezierPath()
        path.lineWidth = CGFloat(stroke.width)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        let first = stroke.points[0]
        path.move(to: CGPoint(x: first.x - bounds.minX, y: first.y - bounds.minY))
        for p in stroke.points.dropFirst() {
            path.line(to: CGPoint(x: p.x - bounds.minX, y: p.y - bounds.minY))
        }
        if stroke.points.count == 1 || stroke.points.allSatisfy({ $0 == first }) {
            // A move-only path is invisible in several PDF readers. This tiny
            // round-capped segment keeps a tap visible without changing its model.
            path.line(to: CGPoint(x: first.x - bounds.minX + 0.02, y: first.y - bounds.minY))
        }
        annotation.add(path)
        annotation.setValue("LeafInk-\(stroke.id.uuidString)", forAnnotationKey: .name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(Envelope(schema: stroke.outlines != nil ? 4 : (stroke.appearance != nil ? 3 : (stroke.widthFactors == nil ? 1 : 2)), stroke: stroke)) {
            annotation.setValue(data.base64EncodedString(), forAnnotationKey: metadataKey)
        }
        return annotation
    }

    static func stroke(from annotation: PDFAnnotation) -> InkStroke? {
        guard annotation.type == "Ink",
              let encoded = annotation.value(forAnnotationKey: metadataKey) as? String,
              encoded.count <= 12_000_000,
              let data = Data(base64Encoded: encoded),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data),
              (1...4).contains(envelope.schema), envelope.stroke.isValid,
              (envelope.schema==4 ? envelope.stroke.appearance == .perfectFreehandV1 : (envelope.schema==3 ? envelope.stroke.appearance == .flowV1 : envelope.stroke.appearance == nil)),
              (envelope.schema != 1 || envelope.stroke.widthFactors == nil) else { return nil }
        // If another reader moved/resized the annotation without updating our
        // geometry, preserve it as foreign rather than editing the wrong place.
        let expected = envelope.stroke.bounds, actual = annotation.bounds
        guard [actual.minX - expected.minX, actual.minY - expected.minY,
               actual.width - expected.width, actual.height - expected.height].allSatisfy({ abs($0) < 0.01 }) else { return nil }
        guard let paths = annotation.paths, paths.count == 1,
              let border = annotation.border, abs(border.lineWidth - envelope.stroke.width) < 0.01 else { return nil }
        var expectedPoints = envelope.stroke.points
        if let first = expectedPoints.first,
           expectedPoints.count == 1 || expectedPoints.allSatisfy({ $0 == first }) {
            expectedPoints.append(InkPoint(x: first.x + 0.02, y: first.y))
        }
        let path = paths[0]
        guard path.elementCount == expectedPoints.count else { return nil }
        for i in 0..<path.elementCount {
            var points = [CGPoint](repeating: .zero, count: 3)
            let element = points.withUnsafeMutableBufferPointer { path.element(at: i, associatedPoints: $0.baseAddress) }
            guard element == (i == 0 ? .moveTo : .lineTo),
                  abs(points[0].x + actual.minX - expectedPoints[i].x) < 0.01,
                  abs(points[0].y + actual.minY - expectedPoints[i].y) < 0.01 else { return nil }
        }
        return envelope.stroke
    }
}

/// PDFKit serializes this drawing as the standard PDF appearance stream.
/// The ordinary InkList remains available alongside schema-2 editable geometry.
/// Other readers display the appearance without needing this subclass or app.
private final class PressureInkAnnotation: PDFAnnotation {
    let stroke: InkStroke
    init(stroke: InkStroke) {
        self.stroke = stroke
        super.init(bounds: stroke.bounds, forType: .ink, withProperties: nil)
    }
    required init?(coder: NSCoder) { fatalError("Created only from validated ink") }
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        InkRenderer.drawPressure(stroke, in: context, scale: 1, convert: { $0 })
    }
}

/// One screen renderer for active, committed, restored, erased, and moved ink.
/// NSView supplies the actual backing transform; no fixed Retina multiplier/cache.
enum InkRenderer {
    static func draw(_ stroke: InkStroke, scale: CGFloat, convert: (CGPoint) -> CGPoint) {
        guard let first = stroke.points.first else { return }
        if stroke.widthFactors != nil || stroke.outlines != nil, let context = NSGraphicsContext.current?.cgContext {
            drawPressure(stroke, in: context, scale: scale, convert: convert)
            return
        }
        guard let context=NSGraphicsContext.current?.cgContext else{return}
        let path=CGMutablePath();path.move(to:convert(first.cgPoint))
        for point in stroke.points.dropFirst() {path.addLine(to:convert(point.cgPoint))}
        if stroke.points.count==1 || stroke.points.allSatisfy({$0==first}) {path.addLine(to:convert(CGPoint(x:first.x+0.02,y:first.y)))}
        context.saveGState();context.setShouldAntialias(true)
        context.setStrokeColor(NSColor(srgbRed:stroke.rgba[0],green:stroke.rgba[1],blue:stroke.rgba[2],alpha:stroke.rgba[3]).cgColor)
        context.setLineWidth(CGFloat(stroke.width)*scale);context.setLineCap(.round);context.setLineJoin(.round)
        context.addPath(path);context.strokePath();context.restoreGState()
    }

    // Union of circles and their external tangent quadrilaterals. Pressure
    // changes cannot open cracks at turns; opacity is applied to the whole pen.
    static func drawPressure(_ stroke: InkStroke, in context: CGContext, scale: CGFloat,
                             convert: (CGPoint) -> CGPoint) {
        if let outlines=stroke.outlines {
            context.saveGState();context.setShouldAntialias(true)
            context.setFillColor(NSColor(srgbRed:stroke.rgba[0],green:stroke.rgba[1],blue:stroke.rgba[2],alpha:stroke.rgba[3]).cgColor)
            context.addPath(InkOutline.path(outlines.map{$0.map{InkPoint(convert($0.cgPoint))}}));context.fillPath();context.restoreGState();return
        }
        if stroke.appearance == .flowV1 {
            var mapped=stroke;mapped.points=stroke.points.map{InkPoint(convert($0.cgPoint))};mapped.width=stroke.width*scale
            let cache=InkPathCache();cache.sync(mapped);cache.draw(mapped,in:context,clip:context.boundingBoxOfClipPath)
            return
        }
        context.saveGState()
        context.setShouldAntialias(true)
        context.setFillColor(NSColor(srgbRed:stroke.rgba[0],green:stroke.rgba[1],
                                    blue:stroke.rgba[2],alpha:1).cgColor)
        // Separate small convex fills avoid Core Graphics' expensive winding
        // resolution for thousands of overlapping circles. A transparency group
        // applies opacity once for the uncommon translucent pen case.
        let grouped = stroke.rgba[3] < 1
        if grouped {
            context.setAlpha(stroke.rgba[3])
            context.beginTransparencyLayer(auxiliaryInfo:nil)
        }
        let clip = context.boundingBoxOfClipPath.insetBy(dx: -1, dy: -1)
        var previous: CGPoint?, priorRadius: CGFloat = 0
        for (i, point) in stroke.points.enumerated() {
            let p = convert(point.cgPoint), r = CGFloat(stroke.radius(at: i))*scale
            let disc = CGRect(x:p.x-r,y:p.y-r,width:2*r,height:2*r)
            if disc.intersects(clip) { context.fillEllipse(in: disc) }
            if let a = previous,
               disc.union(CGRect(x:a.x-priorRadius,y:a.y-priorRadius,width:2*priorRadius,height:2*priorRadius)).intersects(clip) {
                let dx=p.x-a.x, dy=p.y-a.y, length=hypot(dx,dy), dr=r-priorRadius
                if length > abs(dr) && length > 1e-10 {
                    let ux=dx/length, uy=dy/length, slope=dr/length
                    let normal=sqrt(max(0,1-slope*slope))
                    let nx = -slope*ux-normal*uy, ny = -slope*uy+normal*ux
                    let mx = -slope*ux+normal*uy, my = -slope*uy-normal*ux
                    context.move(to:CGPoint(x:a.x+nx*priorRadius,y:a.y+ny*priorRadius))
                    context.addLine(to:CGPoint(x:a.x+mx*priorRadius,y:a.y+my*priorRadius))
                    context.addLine(to:CGPoint(x:p.x+mx*r,y:p.y+my*r))
                    context.addLine(to:CGPoint(x:p.x+nx*r,y:p.y+ny*r))
                    context.closePath();context.fillPath()
                }
            }
            previous=p; priorRadius=r
        }
        if grouped { context.endTransparencyLayer() }
        context.restoreGState()
    }

}


/// Frozen 619d9fb comparison reference. Not the product's pen policy.
struct InkDirectBuilder {
    private var last: InkPoint
    private var factor: Double?
    private(set) var generatedCount=1
    var initialFactors: [Double]? { factor.map { [$0] } }
    init(point: InkPoint, pressure: Double? = nil) {
        last=point;factor=pressure.map(Self.widthFactor)
    }
    static func widthFactor(_ pressure: Double) -> Double {
        // Optional event pressure is a normalized forwarded value, not a claim
        // of calibrated Pencil force. Stable toolbar width is the default.
        guard pressure.isFinite else {return 1}
        return 0.9+0.2*max(0,min(1,pressure))
    }
    mutating func append(_ point: InkPoint, pressure: Double? = nil,
                         isRelease: Bool = false) -> (points: [InkPoint], factors: [Double]?) {
        guard point.x.isFinite,point.y.isFinite,point != last else {return ([],factor == nil ? nil : [])}
        last=point;generatedCount+=1
        if let old=factor {
            let next=isRelease ? old : pressure.map(Self.widthFactor) ?? old
            factor=next;return ([point],[next])
        }
        return ([point],nil)
    }
}

/// A change to the bounded provisional tail of canonical displayed geometry.
/// Raw events are kept separately by InkInputTrace, never replaced by these points.
struct InkTailUpdate {
    var removing: Int = 0
    var points: [InkPoint] = []
}
enum InkChange {
    case replaced(Set<UUID>)
    case tail(UUID, Int)
    case reset
}

/// Local cubic Hermite construction, with bounded deglitching and corner gates.
/// The newest actual endpoint is visible immediately. Only the previous interval
/// can settle when the next sample arrives; pen-up never refits a whole stroke.
/// Geometry is flattened once at creation, then shared by display/hit testing/PDF.
final class InkCurveBuilder {
    enum Policy { case curveOnly, natural }
    private let scale: Double
    private let policy: Policy
    private var anchor: InkPoint
    private var previousRaw: InkPoint
    private var latest: InkPoint
    private var timestamp: Double
    private var direction: InkPoint?
    private var precedingLength: Double = 0
    private var tailCount = 0
    private var intervals = 0
    private(set) var generatedCount = 1
    private(set) var maximumAdjustment = 0.0
    static let recipe = "natural-hermite-v1"

    init(point: InkPoint, timestamp: Double, scale: Double, policy: Policy = .natural) {
        anchor=point;previousRaw=point;latest=point;self.timestamp=timestamp
        self.scale=max(0.15,scale);self.policy=policy
    }
    private func vector(_ a:InkPoint,_ b:InkPoint)->InkPoint {InkPoint(x:b.x-a.x,y:b.y-a.y)}
    private func length(_ v:InkPoint)->Double {hypot(v.x,v.y)}
    private func unit(_ v:InkPoint)->InkPoint {let d=max(1e-12,length(v));return InkPoint(x:v.x/d,y:v.y/d)}
    private func add(_ a:InkPoint,_ v:InkPoint,_ k:Double=1)->InkPoint {InkPoint(x:a.x+v.x*k,y:a.y+v.y*k)}
    private func turn(_ a:InkPoint,_ b:InkPoint)->Double {
        let u=unit(a),v=unit(b);return acos(max(-1,min(1,u.x*v.x+u.y*v.y)))
    }
    func append(_ point:InkPoint,timestamp nextTime:Double,isRelease:Bool=false)->InkTailUpdate {
        guard point.x.isFinite,point.y.isFinite,abs(point.x)<=10_000_000,abs(point.y)<=10_000_000 else{return InkTailUpdate()}
        // Keep callback order even when upstream timestamp anchoring collapses time.
        guard point != latest else {timestamp=nextTime;return InkTailUpdate()}
        if intervals == 0 {
            latest=point;timestamp=nextTime;intervals=1;tailCount=1;generatedCount+=1
            return InkTailUpdate(points:[point])
        }
        let rawIn=vector(previousRaw,latest),rawOut=vector(latest,point)
        let l=length(rawIn),r=length(rawOut),angle=turn(rawIn,rawOut)
        let continuous=nextTime.isFinite && timestamp.isFinite && nextTime>=timestamp && nextTime-timestamp<=0.080
        let corner=angle>=Double.pi*0.28 || min(l,r)*scale<0.12 || max(l,r)*scale>12 || !continuous
        var settled=latest
        // Spatial, never velocity/pressure-derived. Protect first short strokes,
        // sharp turns, large sample gaps and tiny hooks. The point is not deleted.
        if policy == .natural,intervals>=2,!corner,angle<Double.pi*0.24,max(l,r)*scale<4 {
            let chord=vector(previousRaw,point),den=chord.x*chord.x+chord.y*chord.y
            if den>1e-12 {
                let t=max(0,min(1,(rawIn.x*chord.x+rawIn.y*chord.y)/den))
                let projection=add(previousRaw,chord,t),offset=vector(latest,projection)
                let d=length(offset),limit=min(0.18/scale,0.16*min(l,r))
                if d*scale<0.45 {settled=add(latest,offset,min(0.4,limit/max(d,1e-12)))}
            }
        }
        maximumAdjustment=max(maximumAdjustment,length(vector(latest,settled))*scale)
        let incoming=vector(anchor,settled),outgoing=vector(settled,point)
        let smoothDirection=unit(add(unit(incoming),unit(outgoing)))
        let endDirection=corner ? nil : smoothDirection
        let stable=segment(anchor,settled,startDirection:direction,endDirection:endDirection,
                           startLength:precedingLength,endLength:length(outgoing),allowCurve:continuous)
        let provisional=segment(settled,point,startDirection:endDirection,endDirection:nil,
                                startLength:length(incoming),endLength:0,allowCurve:continuous && !corner)
        let update=InkTailUpdate(removing:tailCount,points:stable+provisional)
        generatedCount += update.points.count-update.removing
        previousRaw=latest;latest=point;anchor=settled;timestamp=nextTime
        direction=endDirection;precedingLength=length(incoming);tailCount=provisional.count;intervals+=1
        // No special smoothing on release. A new release position is a real
        // endpoint; repeated release/interruption leaves visible geometry unchanged.
        return update
    }
    private func segment(_ a:InkPoint,_ b:InkPoint,startDirection:InkPoint?,endDirection:InkPoint?,
                         startLength:Double,endLength:Double,allowCurve:Bool)->[InkPoint] {
        let chord=vector(a,b),len=length(chord)
        guard allowCurve,len*scale>0.3,len*scale<12 else{return [b]}
        let u=unit(chord),normal=InkPoint(x:-u.y,y:u.x)
        func handle(_ d:InkPoint?,_ neighbor:Double)->InkPoint {
            guard let d else{return InkPoint(x:chord.x/3,y:chord.y/3)}
            let amount=min(len/3,neighbor>0 ? neighbor*0.45 : len/3)
            let v=InkPoint(x:d.x*amount,y:d.y*amount)
            let along=max(0,min(len/3,v.x*u.x+v.y*u.y))
            let across=max(-min(0.32/scale,len*0.20),min(min(0.32/scale,len*0.20),v.x*normal.x+v.y*normal.y))
            return InkPoint(x:u.x*along+normal.x*across,y:u.y*along+normal.y*across)
        }
        // Chord controls at a corner make the one-sided tangent match that side.
        let c1=startDirection == nil ? add(a,chord,1.0/3) : add(a,handle(startDirection,startLength))
        let c2=endDirection == nil ? add(b,chord,-1.0/3) : add(b,handle(endDirection,endLength),-1)
        var points:[InkPoint]=[]
        func mid(_ p:InkPoint,_ q:InkPoint)->InkPoint {InkPoint(x:(p.x+q.x)/2,y:(p.y+q.y)/2)}
        func flatten(_ p:InkPoint,_ q:InkPoint,_ s:InkPoint,_ t:InkPoint,_ depth:Int) {
            let v=vector(p,t),d=max(1e-12,length(v))
            let e=max(abs(v.x*(q.y-p.y)-v.y*(q.x-p.x)),abs(v.x*(s.y-p.y)-v.y*(s.x-p.x)))/d
            if e<=0.025/max(scale,1) || depth==5 {points.append(t);return}
            let pq=mid(p,q),qs=mid(q,s),st=mid(s,t),left=mid(pq,qs),right=mid(qs,st),center=mid(left,right)
            flatten(p,pq,left,center,depth+1);flatten(center,right,st,t,depth+1)
        }
        flatten(a,c1,c2,b,0);return points
    }
}

/// Streaming, corner-limited cubic B-spline pen. Raw events remain in the input
/// trace; these baked page-coordinate samples are the sole editable geometry.
/// A settled prefix never changes. The latest endpoint is always real, and only
/// the provisional last interval is replaced; release adds no global fit/taper.
final class InkFlowBuilder {
    struct Update { var removing=0; var points:[InkPoint]=[]; var factors:[Double]?=nil }
    private struct Sample {var p:InkPoint;var f:Double;var time:Double}
    static let recipe="bounded-bspline-pressure-v1"
    private let scale:Double
    private let pressureEnabled:Bool
    private var raw:[Sample]
    private var anchor:Sample
    private var anchorDirection:InkPoint?
    private var tailCount=0
    private var intervals=0
    private(set) var generatedCount=1
    var initialFactors:[Double]? {pressureEnabled ? [raw[0].f] : nil}
    init(point:InkPoint,timestamp:Double,scale:Double,pressure:Double?=nil) {
        self.scale=max(0.15,scale);pressureEnabled=pressure != nil
        let s=Sample(p:point,f:pressure.map(Self.widthFactor) ?? 1,time:timestamp)
        raw=[s];anchor=s
    }
    // Normalized tablet force, not velocity or purported calibrated Pencil force.
    // Gentle bounded range; no exaggerated hairline/full-width transitions.
    static func widthFactor(_ pressure:Double)->Double {
        0.70+0.70*pow(min(1,max(0,pressure)/0.45),0.60)
    }
    private func v(_ a:InkPoint,_ b:InkPoint)->InkPoint {InkPoint(x:b.x-a.x,y:b.y-a.y)}
    private func len(_ a:InkPoint)->Double {hypot(a.x,a.y)}
    private func mix(_ a:InkPoint,_ b:InkPoint,_ t:Double)->InkPoint {InkPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t)}
    private func settled(_ a:Sample,_ b:Sample,_ c:Sample)->(Sample,Bool) {
        let u=v(a.p,b.p),w=v(b.p,c.p),l=len(u),r=len(w)
        let cosine=(u.x*w.x+u.y*w.y)/max(1e-12,l*r)
        let corner=cosine<0.42 || min(l,r)*scale<0.18 || max(l,r)*scale>14 || b.time<a.time || c.time<b.time || b.time-a.time>0.08 || c.time-b.time>0.08
        if corner {return (b,true)}
        // B-spline knot is (A + 4B + C)/6. Bound displacement independently
        // of sample density; tightly written hooks cannot disappear in the fit.
        let q=InkPoint(x:(a.p.x+4*b.p.x+c.p.x)/6,y:(a.p.y+4*b.p.y+c.p.y)/6)
        let d=len(v(b.p,q)),limit=min(0.55/scale,min(l,r)*0.22)
        let p=mix(b.p,q,min(1,limit/max(d,1e-12)))
        return (Sample(p:p,f:(a.f+4*b.f+c.f)/6,time:b.time),false)
    }
    func append(_ p:InkPoint,timestamp:Double,pressure:Double?=nil,isRelease:Bool=false)->Update {
        guard p.x.isFinite,p.y.isFinite,abs(p.x)<=10_000_000,abs(p.y)<=10_000_000,p != raw.last!.p else {return Update()}
        let last=raw.last!
        // Injected mouse-up has zero pressure by convention; retain the last
        // measured force. A stationary pause never inflates a point into a blob.
        let f=pressureEnabled && !isRelease ? pressure.map(Self.widthFactor) ?? last.f : last.f
        let next=Sample(p:p,f:f,time:timestamp)
        if intervals==0 {raw.append(next);intervals=1;tailCount=1;generatedCount+=1;return Update(points:[p],factors:pressureEnabled ? [f] : nil)}
        let a=raw[raw.count-2],b=last
        let (k,corner)=settled(a,b,next)
        let stable=segment(anchor,k,start:anchorDirection,end:corner ? nil : v(a.p,next.p))
        let provisional=segment(k,next,start:corner ? nil : v(a.p,next.p),end:nil)
        let result=Update(removing:tailCount,points:stable.0+provisional.0,factors:pressureEnabled ? stable.1+provisional.1 : nil)
        generatedCount+=result.points.count-result.removing;tailCount=provisional.0.count
        anchor=k;anchorDirection=corner ? nil : v(a.p,next.p);raw.append(next);if raw.count>3 {raw.removeFirst()};intervals+=1
        return result
    }
    private func segment(_ a:Sample,_ b:Sample,start:InkPoint?,end:InkPoint?)->([InkPoint],[Double]) {
        let chord=v(a.p,b.p),length=len(chord)
        guard length*scale>0.2,length*scale<14,b.time>=a.time,b.time-a.time<=0.08 else{return ([b.p],[b.f])}
        // Short handles retain local direction without overshoot, reversal or
        // dependence on speed. Unlike the old fit, connected smooth intervals
        // share a tangent and settle to a bounded B-spline knot.
        func handle(_ d:InkPoint?)->InkPoint {
            guard let d,len(d)>1e-12 else {return InkPoint(x:chord.x/3,y:chord.y/3)}
            let n=len(d),ux=chord.x/length,uy=chord.y/length
            let along=max(0,min(length/3,(d.x*ux+d.y*uy)*length/(3*n)))
            let across=max(-length*0.32,min(length*0.32,(-d.x*uy+d.y*ux)*length/(3*n)))
            return InkPoint(x:ux*along-uy*across,y:uy*along+ux*across)
        }
        let h1=handle(start),h2=handle(end)
        let c1=InkPoint(x:a.p.x+h1.x,y:a.p.y+h1.y),c2=InkPoint(x:b.p.x-h2.x,y:b.p.y-h2.y)
        var points:[InkPoint]=[],factors:[Double]=[]
        func flatten(_ p:InkPoint,_ q:InkPoint,_ s:InkPoint,_ t:InkPoint,_ lo:Double,_ hi:Double,_ depth:Int) {
            let d=v(p,t),l=max(1e-12,len(d)),e=max(abs(d.x*(q.y-p.y)-d.y*(q.x-p.x)),abs(d.x*(s.y-p.y)-d.y*(s.x-p.x)))/l
            if e<=0.025/max(scale,1) || depth==5 {points.append(t);factors.append(a.f+(b.f-a.f)*hi);return}
            let pq=mix(p,q,0.5),qs=mix(q,s,0.5),st=mix(s,t,0.5),left=mix(pq,qs,0.5),right=mix(qs,st,0.5),center=mix(left,right,0.5),mid=(lo+hi)/2
            flatten(p,pq,left,center,lo,mid,depth+1);flatten(center,right,st,t,mid,hi,depth+1)
        }
        flatten(a.p,c1,c2,b.p,0,1,0);return(points,factors)
    }
}

/// Canonical variable-radius swept discs. External tangents match erasure's
/// interpolated radius. Normalize small cached blocks once; one fill prevents
/// repeated edge compositing at joins, backtracking and intersections.
enum InkBrush {
    static func exterior(_ stroke:InkStroke,range:ClosedRange<Int>)->CGPath {
        let path=CGMutablePath()
        for i in range {
            let p=stroke.points[i].cgPoint,r=CGFloat(stroke.radius(at:i))
            path.move(to:CGPoint(x:p.x+r,y:p.y));path.addArc(center:p,radius:r,startAngle:0,endAngle:2 * .pi,clockwise:false);path.closeSubpath()
            if i>range.lowerBound {
                let a=stroke.points[i-1].cgPoint,ar=CGFloat(stroke.radius(at:i-1))
                let dx=p.x-a.x,dy=p.y-a.y,l=hypot(dx,dy),dr=r-ar
                if l>abs(dr),l>1e-10 {
                    let ux=dx/l,uy=dy/l,s=dr/l,n=sqrt(max(0,1-s*s))
                    let nx = -s*ux-n*uy,ny = -s*uy+n*ux,mx = -s*ux+n*uy,my = -s*uy-n*ux
                    path.move(to:CGPoint(x:a.x+nx*ar,y:a.y+ny*ar))
                    path.addLine(to:CGPoint(x:a.x+mx*ar,y:a.y+my*ar))
                    path.addLine(to:CGPoint(x:p.x+mx*r,y:p.y+my*r))
                    path.addLine(to:CGPoint(x:p.x+nx*r,y:p.y+ny*r));path.closeSubpath()
                }
            }
        }
        // Existing macOS 13 minimum. Opposite contour winding must be resolved
        // as a union, not an even-odd fill that punches holes at crossings.
        if #available(macOS 13.0,*) {return path.normalized()}
        return path
    }
}

/// Bounded path blocks, not a retained copy of the growing stroke point buffer.
/// Only the block containing a changed tail and subsequent blocks are rebuilt.
/// Lazily cache the uniform swept-disc exterior at high raster density. Round caps
/// and joins have the same envelope as standard PDF Ink and eraser geometry.
/// New pressure ink uses 32-segment union exteriors; legacy pressure retains its
/// original painter. All visible new exteriors fill once, including crossings.
/// No blur, velocity width or release refit.
final class InkPathCache {
    private final class Block {let path:CGPath;let bounds:CGRect;var exterior:CGPath?;var prefixBounds=CGRect.null
        init(path:CGPath,bounds:CGRect) {self.path=path;self.bounds=bounds}
    }
    private var blocks:[Block]=[]
    private var count=0
    private var dirtyFrom:Int?
    private(set) var rebuiltPoints=0
    private(set) var bounds=CGRect.null
    private var blockSize=128
    private var outlineBlocks=false
    func invalidate(from index:Int) {dirtyFrom=min(dirtyFrom ?? index,index)}
    func sync(_ stroke:InkStroke) {
        if let outlines=stroke.outlines {
            if !outlineBlocks {blocks=[];count=0;dirtyFrom=0;outlineBlocks=true}
            if count != outlines.count {invalidate(from:max(0,min(count,outlines.count)-1))}
            guard let from=dirtyFrom else{return}
            let first=max(0,min(from,blocks.count))
            if first<blocks.count {blocks.removeSubrange(first...)}
            for contour in outlines.dropFirst(first) {
                let path=InkOutline.path([contour]),block=Block(path:path,bounds:path.boundingBoxOfPath.insetBy(dx:-1,dy:-1))
                block.exterior=path;block.prefixBounds=(blocks.last?.prefixBounds ?? .null).union(block.bounds)
                blocks.append(block);rebuiltPoints+=contour.count
            }
            count=outlines.count;dirtyFrom=nil;bounds=blocks.last?.prefixBounds ?? .null;return
        }
        if count != stroke.points.count {invalidate(from:max(0,min(count,stroke.points.count)-1))}
        guard let from=dirtyFrom else{return}
        blockSize=stroke.widthFactors == nil ? 128 : 32
        let first=max(0,(from-1)/blockSize)
        if first<blocks.count {blocks.removeSubrange(first...)}
        if !stroke.points.isEmpty {
            for start in stride(from:first*blockSize,to:max(1,stroke.points.count-1),by:blockSize) {
                let end=min(stroke.points.count-1,start+blockSize)
                let path=CGMutablePath();path.move(to:stroke.points[start].cgPoint)
                for i in (start+1)..<(end+1) {path.addLine(to:stroke.points[i].cgPoint)}
                if stroke.points.count==1 {path.addLine(to:CGPoint(x:stroke.points[start].x+0.02,y:stroke.points[start].y))}
                let radius=stroke.width * (stroke.widthFactors?[start...end].max() ?? 1)/2
                let block=Block(path:path,bounds:path.boundingBoxOfPath.insetBy(dx:-radius-1,dy:-radius-1))
                if stroke.widthFactors != nil {block.exterior=InkBrush.exterior(stroke,range:start...end)}
                block.prefixBounds=(blocks.last?.prefixBounds ?? .null).union(block.bounds)
                blocks.append(block)
                rebuiltPoints += end-start+1
            }
        }
        count=stroke.points.count;dirtyFrom=nil
        bounds=blocks.last?.prefixBounds ?? .null
    }
    func draw(_ stroke:InkStroke,in context:CGContext,clip:CGRect) {
        context.saveGState();context.setShouldAntialias(true)
        let color=NSColor(srgbRed:stroke.rgba[0],green:stroke.rgba[1],blue:stroke.rgba[2],alpha:stroke.rgba[3]).cgColor
        // At small raster scales CG's native stroke is cheaper. At high density
        // its repeated join expansion dominates; reuse the identical exterior.
        let exterior=stroke.outlines != nil || stroke.widthFactors != nil || hypot(context.ctm.a,context.ctm.b)>=1.5
        context.beginPath()
        for block in blocks where block.bounds.intersects(clip) {
            if exterior {
                if block.exterior==nil {block.exterior=block.path.copy(strokingWithWidth:stroke.width,lineCap:.round,lineJoin:.round,miterLimit:10)}
                context.addPath(block.exterior!)
            } else {context.addPath(block.path)}
        }
        if exterior {context.setFillColor(color);context.fillPath()}
        else {context.setStrokeColor(color);context.setLineWidth(stroke.width);context.setLineCap(.round);context.setLineJoin(.round);context.strokePath()}
        context.restoreGState()
    }
}

/// Page-coordinate spatial buckets. Transform/scroll never rebuild this index.
/// Structure changes reindex; a pen tail replaces just its occupied buckets.
final class InkPageIndex {
    private var buckets:[Int:Set<UUID>]=[:]
    private var membership:[UUID:Set<Int>]=[:]
    private var bounds:[UUID:CGRect]=[:]
    private(set) var positions:[UUID:Int]=[:]
    private var broad=Set<UUID>()
    private let cell:CGFloat=64
    private func cells(_ rect:CGRect)->Set<Int> {
        guard !rect.isNull,rect.width<4096,rect.height<4096 else{return []}
        let x0=Int(floor(rect.minX/cell)),x1=Int(floor(rect.maxX/cell))
        let y0=Int(floor(rect.minY/cell)),y1=Int(floor(rect.maxY/cell))
        guard (x1-x0+1)*(y1-y0+1)<=1024 else{return []}
        return Set((y0...y1).flatMap{ y in (x0...x1).map{x in (y &* 73856093) ^ (x &* 19349663)}})
    }
    func invalidate(_ ids:Set<UUID>) {for id in ids {bounds.removeValue(forKey:id)}}
    func clear() {buckets.removeAll();membership.removeAll();bounds.removeAll();positions.removeAll();broad.removeAll()}
    func reset(_ strokes:[InkStroke]) {
        let retained=bounds
        clear()
        for (i,stroke) in strokes.enumerated() {positions[stroke.id]=i;update(stroke.id,bounds:retained[stroke.id] ?? stroke.bounds)}
    }
    func update(_ id:UUID,bounds rect:CGRect) {
        let next=cells(rect),old=membership[id] ?? []
        for key in old.subtracting(next) {buckets[key]?.remove(id);if buckets[key]?.isEmpty==true {buckets.removeValue(forKey:key)}}
        for key in next.subtracting(old) {buckets[key,default:[]].insert(id)}
        membership[id]=next;bounds[id]=rect
        if next.isEmpty {broad.insert(id)} else {broad.remove(id)}
    }
    func candidates(in rect:CGRect)->[Int] {
        let keys=cells(rect)
        let ids=keys.isEmpty ? Set(positions.keys) : keys.reduce(broad){$0.union(buckets[$1] ?? [])}
        return ids.filter{bounds[$0]?.intersects(rect)==true}.compactMap{positions[$0]}.sorted()
    }
}

/// Opt-in per-stroke local evidence; never stores document text or predicted points.
/// Event timestamp is upstream-assigned, not necessarily the Pencil sample time.
struct InkInputSample: Codable {
    var point: InkPoint
    var rawPoint: InkPoint
    var timestamp: Double
    var received: Double
    var handled: Double
    var type: UInt
    var subtype: Int16
    var pressure: Float
    var tablet: Bool
    var windowPoint: InkPoint? = nil
    var quartzPoint: InkPoint? = nil
    var deviceID: Int64? = nil
    // PadInk places low 32-bit gesture/sequence IDs in CGEvent userData.
    // These correlate with upstream diagnostics, not with a device timestamp.
    var forwardedGesture: UInt32? = nil
    var forwardedSequence: UInt32? = nil
    var submitted: Double? = nil
    // Exact force consumed by the engine; older traces retain their AppKit field.
    var nativePressure: Double? = nil
}
struct InkDrawCallback: Codable {
    var throughSample: Int
    var started: Double
    var completed: Double
}
struct InkInputTrace: Codable {
    var id: UUID
    var scale: Double
    var width: Double
    var kind: InkKind
    var samples: [InkInputSample] = []
    var displayedThrough: [Double] = []
    var interrupted = false
    var finished: Double?
    var pageIndex: Int?
    var mouseCoalescingEnabled: Bool?
    var penResponse: String?
    var captureVersion: Int? = nil
    var drawCallbacks: [InkDrawCallback]? = nil
    private static let writer = DispatchQueue(label: "Ecru.input-evidence", qos: .utility)
    func save() {
        guard let directory = EcruEnvironment.value("ECRU_INPUT_TRACE_DIR") else { return }
        let trace = self
        Self.writer.async {
            do {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(trace).write(to: url.appendingPathComponent("\(trace.id).json"), options: .atomic)
            } catch { NSLog("Ecru input trace failed: %@", error.localizedDescription) }
        }
    }
}
