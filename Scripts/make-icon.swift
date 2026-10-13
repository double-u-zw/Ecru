import AppKit

// Packaging only: preserve the current master pixels. Clip the exterior
// white background with a native continuous-corner path; never redraw the mark.
let source=URL(fileURLWithPath:CommandLine.arguments[1])
let destination=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
guard let image=NSImage(contentsOf:source) else {fatalError("Missing icon master")}
let tile=NSRect(x:104,y:166,width:1016,height:1032)
guard let representation=NSBitmapImageRep(data:try Data(contentsOf:source)),
      representation.pixelsWide==1254,representation.pixelsHigh==1254 else {
    fatalError("Expected the approved 1254-square book/ribbon master")
}
image.size=NSSize(width:1254,height:1254)
try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
func png(_ size:Int)->Data {
    let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    let scale=CGFloat(size)*0.8125/tile.height
    let origin=NSPoint(x:(CGFloat(size)-tile.width*scale)/2,y:(CGFloat(size)-tile.height*scale)/2)
    let context=NSGraphicsContext.current!.cgContext
    context.translateBy(x:origin.x,y:origin.y)
    context.scaleBy(x:scale,y:scale)
    context.translateBy(x:-tile.minX,y:-tile.minY)
    let path=NSBezierPath()
    func p(_ x:CGFloat,_ y:CGFloat)->NSPoint {NSPoint(x:tile.minX+x*tile.width,y:tile.minY+y*tile.height)}
    path.move(to:p(0.29,1));path.line(to:p(0.71,1))
    path.curve(to:p(1,0.71),controlPoint1:p(0.93,1),controlPoint2:p(1,0.93))
    path.line(to:p(1,0.29))
    path.curve(to:p(0.71,0),controlPoint1:p(1,0.07),controlPoint2:p(0.93,0))
    path.line(to:p(0.29,0))
    path.curve(to:p(0,0.29),controlPoint1:p(0.07,0),controlPoint2:p(0,0.07))
    path.line(to:p(0,0.71))
    path.curve(to:p(0.29,1),controlPoint1:p(0,0.93),controlPoint2:p(0.07,1))
    path.close();path.addClip()
    image.draw(in:NSRect(x:0,y:0,width:1254,height:1254))
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using:.png,properties:[:])!
}
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        try png(size*scale).write(to:destination.appendingPathComponent("icon_\(size)x\(size)"+(scale==2 ? "@2x":"")+".png"))
    }
}
