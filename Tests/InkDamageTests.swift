import AppKit
import PDFKit

@main enum InkDamageTests {
    static func main() throws {
        _ = NSApplication.shared
        let points = (0..<1500).map { InkPoint(x: Double($0 % 300)+10, y: Double($0)/5+15+sin(Double($0)/12)*9) }
        let factors = points.indices.map { 0.65 + 0.3 * sin(Double($0)/17) }
        let stroke = InkStroke(points: points, width: 5, rgba: [0.1,0.3,0.9,0.6], kind: .pen, widthFactors: factors)
        let full = CGRect(x: 0, y: 0, width: 350, height: 350)
        func render(tiled: Bool) -> Data {
            let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:350,pixelsHigh:350,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:1400,bitsPerPixel:32)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:image)
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.clear(full)
            for y in stride(from: 0, to: 350, by: tiled ? 25 : 350) {
                ctx.saveGState(); ctx.clip(to: CGRect(x:0,y:y,width:350,height:tiled ? 25 : 350))
                InkRenderer.draw(stroke,scale:1,convert:{$0}); ctx.restoreGState()
            }
            NSGraphicsContext.restoreGraphicsState()
            return Data(bytes: image.bitmapData!, count: 490000)
        }
        let fullImage = render(tiled:false), tiles = render(tiled:true)
        let error = zip(fullImage,tiles).reduce(0) { $0 + abs(Int($1.0)-Int($1.1)) }
        precondition(error <= 20, "Damage rendering changes pressure/opacity pixels: \(error)")
        print("PASS: tiled/full pressure RGBA absolute difference: \(error) / 490000 bytes (rounding tolerance 20)")
    }
}
