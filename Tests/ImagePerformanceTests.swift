import AppKit
import PDFKit
import ImageIO
import Darwin
/// Synthetic rendering benchmark, not a claim about live Pencil latency.
@main enum ImagePerformanceTests {
 static func main()throws {
  let start=ProcessInfo.processInfo.systemUptime
  let context=CGContext(data:nil,width:5000,height:3000,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.displayP3)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:5000,height:3000))
  for row in 0..<100 {context.setFillColor(NSColor.systemBlue.cgColor);context.fill(CGRect(x:100,y:row*25,width:4400,height:2))}
  let raw=NSMutableData(),destination=CGImageDestinationCreateWithData(raw,"public.png" as CFString,1,nil)!
  CGImageDestinationAddImage(destination,context.makeImage()!,nil);guard CGImageDestinationFinalize(destination) else{fatalError("encoder")}
  let data=try ImageImport.normalize(raw as Data),key=AnnotationPDF.hash(data)
  guard ImageImport.pixelSize(data)==CGSize(width:5000,height:3000) else{fatalError("resolution loss")}
  let imported=ProcessInfo.processInfo.systemUptime
  let display=CGContext(data:nil,width:1200,height:1600,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  for _ in 0..<40 {
   display.clear(CGRect(x:0,y:0,width:1200,height:1600))
   for n in 0..<12 {
    let image=PageImage(page:0,asset:key,rect:CGRect(x:(n%3)*390,y:(n/3)*380,width:380,height:228))
    ImageRenderer.draw(image,data:data,in:display,maximumDimension:1024)
   }
  }
  let drawn=ProcessInfo.processInfo.systemUptime
  var usage=rusage();getrusage(RUSAGE_SELF,&usage)
  let full=ImageRenderCache.shared.image(data,key:key)!
  guard full.width==5000,full.height==3000,AnnotationPDF.hash(data)==key else{fatalError("source replaced")}
  print(String(format:"15 MP source normalized in %.3f s; 12-image page x 40 frames rendered in %.3f s (%.2f ms/frame); peak RSS %.1f MiB; source bytes %d, source remains 5000x3000",imported-start,drawn-imported,(drawn-imported)*1000/40,Double(usage.ru_maxrss)/1048576,data.count))
 }
}
