import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers

struct PageImage: Codable, Equatable {
    var id = UUID()
    var page: Int
    var asset: String
    var rect: CGRect
    // Normalized source coordinates, lower-left origin. Source is immutable.
    var crop = CGRect(x:0,y:0,width:1,height:1)
    var rotation: Double = 0
    var locked = false
    var transform: CGAffineTransform {
        CGAffineTransform(translationX:rect.midX,y:rect.midY).rotated(by:rotation)
    }
    var corners: [CGPoint] {
        [CGPoint(x:-rect.width/2,y:-rect.height/2),CGPoint(x:rect.width/2,y:-rect.height/2),CGPoint(x:rect.width/2,y:rect.height/2),CGPoint(x:-rect.width/2,y:rect.height/2)].map{$0.applying(transform)}
    }
    var bounds: CGRect { corners.reduce(CGRect.null){$0.union(CGRect(origin:$1,size:.zero))} }
    func contains(_ point:CGPoint)->Bool {
        CGRect(x:-rect.width/2,y:-rect.height/2,width:rect.width,height:rect.height).contains(point.applying(transform.inverted()))
    }
    func sourcePoint(_ point:CGPoint)->CGPoint {
        let p=point.applying(transform.inverted())
        return CGPoint(x:crop.minX+(p.x/rect.width+0.5)*crop.width,y:crop.minY+(p.y/rect.height+0.5)*crop.height)
    }
    func cropped(to region:CGRect)->PageImage {
        var result=self
        let next=region.intersection(crop)
        guard !next.isNull,next.width>=0.001,next.height>=0.001,next.width*rect.width/crop.width>=0.1,next.height*rect.height/crop.height>=0.1 else{return self}
        let dx=((next.midX-crop.minX)/crop.width-0.5)*rect.width
        let dy=((next.midY-crop.minY)/crop.height-0.5)*rect.height
        let center=CGPoint(x:dx,y:dy).applying(transform)
        result.rect=CGRect(x:center.x-rect.width*next.width/crop.width/2,y:center.y-rect.height*next.height/crop.height/2,width:rect.width*next.width/crop.width,height:rect.height*next.height/crop.height)
        result.crop=next;return result
    }
    var valid:Bool {
        [rect.minX,rect.minY,rect.width,rect.height,rotation,crop.minX,crop.minY,crop.width,crop.height].allSatisfy{$0.isFinite && abs($0)<1e7} && rect.width>=0.1 && rect.height>=0.1 && crop.width>=0.001 && crop.height>=0.001 && crop.minX>=0 && crop.minY>=0 && crop.maxX<=1.000001 && crop.maxY<=1.000001
    }
}
struct AnnotationGroup: Codable, Equatable { var id = UUID(); var members: [UUID] }

extension AnnotationStore {
    var validObjects:Bool {
        let ids=allMarkIDs
        return (images.isEmpty && groups.isEmpty && objectOrder == nil || minimumReader>=5) &&
        images.allSatisfy{$0.valid && pages.indices.contains($0.page) && imageAssets?[$0.asset] != nil} &&
        (imageAssets ?? [:]).allSatisfy{ $0.value.count<=24*1024*1024 && AnnotationPDF.hash($0.value)==$0.key && ImageImport.pixelSize($0.value) != nil } &&
        Set(groups.map(\.id)).count==groups.count && groups.allSatisfy{$0.members.count>=2 && Set($0.members).count==$0.members.count && Set($0.members).isSubset(of:ids) && Set($0.members.compactMap{pageIndex(for:$0)}).count==1} &&
        Set(groups.flatMap(\.members)).count==groups.flatMap(\.members).count &&
        (objectOrder.map{Set($0).count==$0.count && Set($0).isSubset(of:ids)} ?? true)
    }
    func pageIndex(for id:UUID)->Int? {
        if let image=images.first(where:{$0.id==id}) {return image.page}
        if let mark=marks.first(where:{$0.id==id}) {return mark.anchor.page}
        return ink.firstIndex(where:{$0.contains(where:{$0.id==id})})
    }
    func orderedIDs(on page:Int)->[UUID] {
        let defaults=images.filter{$0.page==page}.map(\.id)+(ink.indices.contains(page) ? ink[page].map(\.id):[])
        let known=Set(defaults), explicit=(objectOrder ?? []).filter{known.contains($0)}
        let selected=Set(explicit);return explicit+defaults.filter{!selected.contains($0)}
    }
    func expanded(_ ids:Set<UUID>)->Set<UUID> {
        ids.union(groups.filter{!ids.isDisjoint(with:$0.members)}.flatMap(\.members))
    }
    var movableObjectIDs:Set<UUID> {Set(ink.flatMap{$0.map(\.id)}+images.map(\.id))}
    func movableSelection(_ ids:Set<UUID>)->Set<UUID> {
        let movable=movableObjectIDs
        return expanded(ids.intersection(movable)).intersection(movable)
    }
}

/// Full-resolution import, deterministic SDR conversion once. Display caches never
/// replace the embedded source. EXIF orientation is applied without downsampling.
enum ImageImport {
    static let types:[NSPasteboard.PasteboardType] = [.png,.tiff,NSPasteboard.PasteboardType("public.jpeg"),NSPasteboard.PasteboardType("public.heic"),NSPasteboard.PasteboardType("public.heif"),.fileURL]
    static func pixelSize(_ data:Data)->CGSize? {
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [String:Any],let w=props[kCGImagePropertyPixelWidth as String] as? Int,let h=props[kCGImagePropertyPixelHeight as String] as? Int,w>0,h>0,w<=32768,h<=32768,w*h<=40_000_000 else{return nil}
        return CGSize(width:w,height:h)
    }
    static func canRead(_ pasteboard:NSPasteboard)->Bool {
        if pasteboard.availableType(from:types.filter{$0 != .fileURL}) != nil {return true}
        if let urls=pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],let url=urls.first,let type=try? url.resourceValues(forKeys:[.contentTypeKey]).contentType {return type.conforms(to:.image)}
        return false
    }
    static func data(from pasteboard:NSPasteboard)->Data? {
        for type in types where type != .fileURL {if let data=pasteboard.data(forType:type){return data}}
        // File URLs only. Never fetch network URLs or HTML image references.
        if let urls=pasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL],let url=urls.first,let type=try? url.resourceValues(forKeys:[.contentTypeKey]).contentType,type.conforms(to:.image) {return try? Data(contentsOf:url,options:.mappedIfSafe)}
        return nil
    }
    static func normalize(_ data:Data)throws->Data {
        guard data.count<=96*1024*1024,let source=CGImageSourceCreateWithData(data as CFData,nil),
              let props=CGImageSourceCopyPropertiesAtIndex(source,CGImageSourceGetPrimaryImageIndex(source),nil) as? [String:Any],
              let w=props[kCGImagePropertyPixelWidth as String] as? Int,let h=props[kCGImagePropertyPixelHeight as String] as? Int,w>0,h>0,w<=32768,h<=32768,w*h<=40_000_000 else {throw DocumentSessionError.unsupported("图片超过 4000 万像素或格式无法读取")}
        // Thumbnail API applies orientation; max size equals full source dimensions.
        let options:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:max(w,h),kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceShouldCacheImmediately:true]
        guard let image=CGImageSourceCreateThumbnailAtIndex(source,CGImageSourceGetPrimaryImageIndex(source),options as CFDictionary),
              let context=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else {throw DocumentSessionError.serialize}
        // Standard dynamic range, 8-bit sRGB. Wide gamut is color-converted;
        // HDR gain maps are deliberately omitted, extended values clipped to SDR.
        context.setRenderingIntent(.relativeColorimetric);context.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        let out=NSMutableData()
        guard let converted=context.makeImage(),let destination=CGImageDestinationCreateWithData(out,UTType.png.identifier as CFString,1,nil) else{throw DocumentSessionError.serialize}
        CGImageDestinationAddImage(destination,converted,nil)
        guard CGImageDestinationFinalize(destination),out.length<=24*1024*1024 else{throw DocumentSessionError.unsupported("无损图片超过 24 MiB；请裁减源图片后再插入")}
        return out as Data
    }
}

/// Bounded decoded-image cache shared by page rendering and PDF appearance export.
final class ImageRenderCache {
    static let shared=ImageRenderCache()
    private let cache=NSCache<NSString,ImageBox>()
    init(){cache.totalCostLimit=192*1024*1024}
    private final class ImageBox:NSObject {let image:CGImage;init(_ image:CGImage){self.image=image}}
    func image(_ data:Data,key:String,maximumDimension:Int?=nil)->CGImage? {
        let cacheKey=key+(maximumDimension.map{".\($0)"} ?? ".source")
        if let cached=cache.object(forKey:cacheKey as NSString){return cached.image}
        guard let source=CGImageSourceCreateWithData(data as CFData,nil) else{return nil}
        let decoded:CGImage?
        if let maximumDimension {
            decoded=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:maximumDimension,kCGImageSourceShouldCacheImmediately:true] as CFDictionary)
        } else {decoded=CGImageSourceCreateImageAtIndex(source,0,[kCGImageSourceShouldCacheImmediately:true] as CFDictionary)}
        guard let image=decoded else{return nil}
        cache.setObject(ImageBox(image),forKey:cacheKey as NSString,cost:image.bytesPerRow*image.height);return image
    }
}
enum ImageRenderer {
    static func draw(_ object:PageImage,data:Data,in context:CGContext,maximumDimension:Int?=nil) {
        guard let image=ImageRenderCache.shared.image(data,key:object.asset,maximumDimension:maximumDimension) else{return}
        context.saveGState();context.concatenate(object.transform)
        context.clip(to:CGRect(x:-object.rect.width/2,y:-object.rect.height/2,width:object.rect.width,height:object.rect.height))
        context.interpolationQuality = .high
        context.draw(image,in:CGRect(x:-object.rect.width/2-object.crop.minX*object.rect.width/object.crop.width,y:-object.rect.height/2-object.crop.minY*object.rect.height/object.crop.height,width:object.rect.width/object.crop.width,height:object.rect.height/object.crop.height))
        context.restoreGState()
    }
}
final class ImagePDFAnnotation:PDFAnnotation {
    static let imageKey=PDFAnnotationKey(rawValue:"/EcruImageGeometry")
    let object:PageImage
    let data:Data
    init(_ object:PageImage,data:Data) {
        self.object=object;self.data=data
        super.init(bounds:object.bounds,forType:.stamp,withProperties:nil)
        color = .clear;contents="Ecru image";shouldPrint=true
        setValue(object.id.uuidString,forAnnotationKey:AnnotationPDF.markKey)
        setValue(String(decoding:try! JSONEncoder().encode(object),as:UTF8.self),forAnnotationKey:Self.imageKey)
    }
    required init?(coder:NSCoder){fatalError()}
    override func draw(with box:PDFDisplayBox,in context:CGContext){ImageRenderer.draw(object,data:data,in:context)}
    static func compatible(_ object:PageImage,_ annotation:PDFAnnotation)->Bool {
        guard annotation.type=="Stamp",annotation.shouldDisplay,annotation.shouldPrint,AnnotationPDF.close(annotation.bounds,object.bounds),let raw=annotation.value(forAnnotationKey:imageKey) as? String,let saved=try? JSONDecoder().decode(PageImage.self,from:Data(raw.utf8)) else{return false}
        return saved==object && annotation.hasAppearanceStream
    }
}

struct ObjectClipboard:Codable {
    static let type=NSPasteboard.PasteboardType("local.ecru.editable-objects.v1")
    var ink:[InkStroke]
    var images:[PageImage]
    var marks:[PageMark]
    var assets:[String:Data]
    var groups:[AnnotationGroup]
    var order:[UUID]
}
extension InkStroke {
    func applying(_ transform:CGAffineTransform)->InkStroke {
        var s=self
        func point(_ p:InkPoint)->InkPoint {InkPoint(p.cgPoint.applying(transform))}
        s.points=s.points.map(point);s.outlines=s.outlines?.map{$0.map(point)}
        if var shape=s.shape {shape.controls=shape.controls.map(point);shape.originalPoints=shape.originalPoints.map(point);shape.originalOutlines=shape.originalOutlines.map{$0.map(point)};s.shape=shape;s.points=shape.points};return s
    }
}
