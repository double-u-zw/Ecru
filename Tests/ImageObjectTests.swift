import AppKit
import PDFKit
import ImageIO
import Darwin

@main enum ImageObjectTests {
    static var checks=0
    static func check(_ condition:@autoclosure ()->Bool,_ message:String){guard condition() else{print("FAIL: "+message);fflush(stdout);exit(1)};checks += 1;print("PASS: "+message);fflush(stdout)}
    static func fixture(_ url:URL)throws {
        let data=NSMutableData(),context=CGContext(consumer:CGDataConsumer(data:data)!,mediaBox:nil,nil)!
        context.beginPDFPage([kCGPDFContextMediaBox as String:NSValue(rect:CGRect(x:0,y:0,width:612,height:792))] as CFDictionary)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:context,flipped:false)
        ("Ecru editable image test - original selectable text" as NSString).draw(at:CGPoint(x:45,y:720),withAttributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.black])
        NSGraphicsContext.restoreGraphicsState();context.endPDFPage();context.closePDF();try (data as Data).write(to:url)
    }
    static func source()->Data {
        let c=CGContext(data:nil,width:1200,height:800,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.displayP3)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(NSColor.systemOrange.cgColor);c.fill(CGRect(x:60,y:60,width:1080,height:680))
        c.setFillColor(NSColor.systemBlue.withAlphaComponent(0.5).cgColor);c.fill(CGRect(x:150,y:200,width:900,height:200))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:false)
        ("Screenshot: E = mc² · 1234567890\nSmall text remains at original source resolution" as NSString).draw(at:CGPoint(x:100,y:540),withAttributes:[.font:NSFont.systemFont(ofSize:24),.foregroundColor:NSColor.black]);NSGraphicsContext.restoreGraphicsState()
        let data=NSMutableData(),destination=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,c.makeImage()!,nil);check(CGImageDestinationFinalize(destination),"transparent wide-gamut screenshot fixture");return data as Data
    }
    static func save(_ session:DocumentSession,to target:URL?=nil)throws {
        var result:Result<SaveOutcome,Error>?
        session.save(to:target){result=$0};let deadline=Date().addingTimeInterval(30)
        while result==nil && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
        guard let result else{fatalError("save timeout")};_ = try result.get()
    }
    static func send(_ reader:ReaderWindow,_ type:NSEvent.EventType,_ p:CGPoint) {
        let page=reader.session.document.page(at:0)!,point=reader.pdfView.convert(reader.pdfView.convert(p,from:page),to:nil)
        let e=NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:reader.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        if type == .leftMouseDown {reader.canvas.mouseDown(with:e)} else if type == .leftMouseDragged {reader.canvas.mouseDragged(with:e)} else {reader.canvas.mouseUp(with:e)}
    }
    static func formats(_ normalized:Data)throws {
        let image=ImageRenderCache.shared.image(normalized,key:AnnotationPDF.hash(normalized))!
        for type in ["public.jpeg","public.tiff","public.heic"] {
            let encoded=NSMutableData();guard let destination=CGImageDestinationCreateWithData(encoded,type as CFString,1,nil) else{fatalError("missing encoder: "+type)}
            CGImageDestinationAddImage(destination,image,nil);check(CGImageDestinationFinalize(destination),"ImageIO encoder supports \(type)")
            let converted=try ImageImport.normalize(encoded as Data)
            check(ImageImport.pixelSize(converted)==CGSize(width:1200,height:800),"\(type) import keeps full source pixel dimensions")
        }
        let pixels:[UInt16]=[65535,0,0,65535,65535,65535,65535,65535]
        let bytes=pixels.withUnsafeBytes{Data($0)}
        let deep=CGImage(width:2,height:1,bitsPerComponent:16,bitsPerPixel:64,bytesPerRow:16,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder16Little.rawValue),provider:CGDataProvider(data:bytes as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        let data=NSMutableData(),dest=CGImageDestinationCreateWithData(data,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(dest,deep,nil);check(CGImageDestinationFinalize(dest),"16-bit PNG fixture")
        let eight=try ImageImport.normalize(data as Data),decoded=ImageRenderCache.shared.image(eight,key:AnnotationPDF.hash(eight))!
        check(decoded.bitsPerComponent==8 && decoded.colorSpace?.name==CGColorSpace.sRGB && decoded.width==2,"deep-color input consistently converts once to 8-bit SDR sRGB")
        let board=NSPasteboard(name:NSPasteboard.Name("EcruImageTests-"+UUID().uuidString))
        defer{board.releaseGlobally()}
        board.setString("https://example.com/screenshot.png",forType:.URL)
        check(!ImageImport.canRead(board) && ImageImport.data(from:board)==nil,"clipboard web URL cannot trigger any network image import")
        board.clearContents();board.setData(normalized,forType:.png)
        check(ImageImport.canRead(board) && ImageImport.data(from:board)==normalized,"screenshot PNG pasteboard data is recognized exactly")
        board.clearContents();let tiff=NSMutableData(),writer=CGImageDestinationCreateWithData(tiff,"public.tiff" as CFString,1,nil)!;CGImageDestinationAddImage(writer,image,nil);_ = CGImageDestinationFinalize(writer);board.setData(tiff as Data,forType:.tiff)
        check(ImageImport.canRead(board) && ImageImport.data(from:board) != nil,"macOS TIFF clipboard image is recognized")
    }
    static func coordinates(_ root:URL,_ normalized:Data)throws {
        for rotation in [0,90,180,270] {
            let url=root.appendingPathComponent("rotation-\(rotation).pdf");try fixture(url)
            let document=PDFDocument(url:url)!;document.page(at:0)!.rotation=rotation;check(document.write(to:url),"rotated synthetic PDF fixture \(rotation)°")
            let session=try DocumentSession.open(url:url),page=session.document.page(at:0)!,reader=ReaderWindow(session:session,installInputMonitor:{_,_ in 1},removeInputMonitor:{_ in})
            reader.pdfView.autoScales=false
            let id=try session.insertImage(normalized,on:page,rect:CGRect(x:100,y:300,width:180,height:120))
            for zoom in [0.5,1.0,2.0,4.0] {
                reader.pdfView.scaleFactor=zoom;reader.pdfView.layoutDocumentView();reader.canvas.setTool(.select);reader.canvas.selectObjects([id],on:page)
                let before=session.annotations.images[0].rect
                let p=CGPoint(x:before.midX,y:before.midY),q=CGPoint(x:p.x+12,y:p.y+8)
                send(reader,.leftMouseDown,p);send(reader,.leftMouseDragged,q);send(reader,.leftMouseUp,q)
                let after=session.annotations.images[0].rect
                check(abs(after.minX-before.minX-12)<0.02 && abs(after.minY-before.minY-8)<0.02,"image moves exactly in PDF space at \(rotation)° / \(zoom)x")
                session.undo()
            }
            try save(session);let reopened=try DocumentSession.open(url:url)
            check(!reopened.annotationReadOnly && reopened.annotations.images==session.annotations.images,"rotated page save/reopen \(rotation)°")
            reader.disconnectInputAndViews()
        }
    }
    static func main()throws {
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let delegate=AppDelegate();AppDelegate.shared=delegate
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/image-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);setenv("ECRU_DATA_DIR",root.appendingPathComponent("drafts").path,1)
        let url=root.appendingPathComponent("images.pdf");try fixture(url)
        let session=try DocumentSession.open(url:url),page=session.document.page(at:0)!,reader=ReaderWindow(session:session,installInputMonitor:{_,_ in 1},removeInputMonitor:{_ in})
        reader.pdfView.autoScales=false;reader.pdfView.scaleFactor=1;reader.pdfView.layoutDocumentView()
        let canvas=reader.canvas,raw=source(),normalized=try ImageImport.normalize(raw),key=AnnotationPDF.hash(normalized)
        try formats(normalized);try coordinates(root,normalized)
        let image=ImageRenderCache.shared.image(normalized,key:key)!
        check(image.width==1200 && image.height==800 && image.bitsPerComponent==8 && image.colorSpace?.name==CGColorSpace.sRGB,"full-resolution 8-bit sRGB normalization")
        let alphaContext=CGContext(data:nil,width:1200,height:800,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        alphaContext.draw(image,in:CGRect(x:0,y:0,width:1200,height:800));check(alphaContext.data!.assumingMemoryBound(to:UInt8.self)[3]==0,"transparent source alpha retained")
        let id=try session.insertImage(normalized,on:page,rect:CGRect(x:100,y:300,width:300,height:200))
        check(session.annotations.valid() && session.annotations.minimumReader==5,"image canonical model validates")
        let original=session.annotations.images[0]
        session.undo();check(session.annotations.images.isEmpty,"image insertion undo");session.redo();check(session.annotations.images==[original],"image insertion redo")
        canvas.selectObjects([id],on:page);canvas.setTool(.select);canvas.selectObjects([id],on:page)
        send(reader,.leftMouseDown,CGPoint(x:200,y:400));send(reader,.leftMouseDragged,CGPoint(x:225,y:430));send(reader,.leftMouseUp,CGPoint(x:225,y:430))
        check(session.annotations.images[0].rect.origin==CGPoint(x:125,y:330),"native selection moves images in PDF coordinates")
        session.undo();check(session.annotations.images==[original],"image move undo")
        canvas.selectObjects([id],on:page);send(reader,.leftMouseDown,CGPoint(x:400,y:500));send(reader,.leftMouseDragged,CGPoint(x:460,y:540));send(reader,.leftMouseUp,CGPoint(x:460,y:540))
        let resized=session.annotations.images[0];check(abs(resized.rect.width/resized.rect.height-1.5)<1e-8 && resized.rect.width>300,"corner scaling keeps source aspect")
        session.undo();canvas.selectObjects([id],on:page);canvas.beginCrop(nil)
        send(reader,.leftMouseDown,CGPoint(x:160,y:340));send(reader,.leftMouseDragged,CGPoint(x:340,y:460));send(reader,.leftMouseUp,CGPoint(x:340,y:460));canvas.commitCrop(nil)
        check(abs(session.annotations.images[0].crop.width-0.6)<1e-8 && session.annotations.imageAssets?[key]==normalized,"non-destructive drag crop retains exact source bytes")
        canvas.resetCrop(nil);check(AnnotationPDF.close(session.annotations.images[0].rect,original.rect) && session.annotations.images[0].crop==original.crop,"crop reset restores full image geometry")
        canvas.rotateObjects(nil);check(abs(session.annotations.images[0].rotation-Double.pi/2)<1e-8,"image rotation commits into undo history")
        session.undo();canvas.setTool(.pen)
        let before=session.annotations.images
        send(reader,.leftMouseDown,CGPoint(x:150,y:400));send(reader,.leftMouseDragged,CGPoint(x:300,y:400));send(reader,.leftMouseUp,CGPoint(x:300,y:400))
        check(session.annotations.images==before && session.inkStrokes(on:page).count==1,"pen writes above image without moving it")
        let ink=session.inkStrokes(on:page)[0]
        check(session.annotations.orderedIDs(on:0)==[id,ink.id],"default image-under-ink stacking")
        canvas.setTool(.eraser);send(reader,.leftMouseDown,CGPoint(x:200,y:400));send(reader,.leftMouseUp,CGPoint(x:200,y:400))
        check(session.annotations.images==before && session.inkStrokes(on:page) != [ink],"eraser changes only Ecru ink");session.undo()
        canvas.setTool(.lasso)
        for (i,p) in [CGPoint(x:80,y:280),CGPoint(x:420,y:280),CGPoint(x:420,y:520),CGPoint(x:80,y:520),CGPoint(x:80,y:280)].enumerated(){send(reader,i==0 ? .leftMouseDown:.leftMouseDragged,p)}
        send(reader,.leftMouseUp,CGPoint(x:80,y:280));check(canvas.selectedIDs==[id,ink.id],"lasso selects image and ink together")
        canvas.groupSelection(nil);check(session.annotations.groups.count==1,"mixed object grouping")
        canvas.setTool(.select);canvas.selectObjects([id],on:page);check(canvas.selectedIDs==[id,ink.id],"selecting group member expands selection")
        send(reader,.leftMouseDown,CGPoint(x:250,y:420));send(reader,.leftMouseDragged,CGPoint(x:260,y:430));send(reader,.leftMouseUp,CGPoint(x:260,y:430))
        check(session.annotations.images[0].rect.minX==110 && session.inkStrokes(on:page)[0].points==ink.translated(dx:10,dy:10).points && session.annotations.groups.count==1,"group movement preserves relative geometry and membership")
        session.undo();canvas.selectObjects([id],on:page);canvas.ungroupSelection(nil);check(session.annotations.groups.isEmpty,"ungroup mixed objects");session.undo()
        let copyPacket=ObjectClipboard(ink:[ink],images:session.annotations.images,marks:[],assets:session.annotations.imageAssets!,groups:session.annotations.groups,order:session.annotations.orderedIDs(on:0))
        let copied=try session.pasteObjects(copyPacket,on:page,center:CGPoint(x:350,y:230))
        check(copied.count==2 && session.annotations.groups.count==2 && session.annotations.imageAssets?.count==1,"object copy/paste remaps IDs and groups while sharing immutable source")
        session.undo();check(session.annotations.groups.count==1 && session.annotations.images.count==1,"mixed object paste undo is atomic")
        session.groupObjects([id,ink.id],ungroup:true);canvas.selectObjects([id],on:page);canvas.bringToFront(nil)
        check(session.annotations.orderedIDs(on:0).last==id,"explicit image layer change is canonical");session.undo();session.undo()
        canvas.selectObjects([id],on:page);canvas.toggleImageLock(nil)
        let lockRect=session.annotations.images[0].rect
        send(reader,.leftMouseDown,CGPoint(x:230,y:420));send(reader,.leftMouseDragged,CGPoint(x:250,y:450));send(reader,.leftMouseUp,CGPoint(x:250,y:450))
        check(session.annotations.images[0].rect==lockRect && session.annotations.images[0].locked,"locked grouped image cannot move via selection")
        canvas.toggleImageLock(nil)
        try save(session)
        let reopened=try DocumentSession.open(url:url)
        check(!reopened.annotationReadOnly && reopened.annotations==session.annotations,"standard PDF save reopens with exact editable images, ink and groups")
        let standard=PDFDocument(url:url)!,stamp=standard.page(at:0)!.annotations.first{$0.type=="Stamp"}!
        check(stamp.hasAppearanceStream && standard.string?.contains("original selectable text")==true,"standard Stamp appearance and original text retained")
        let originalFile=root.appendingPathComponent("source.png");try raw.write(to:originalFile);try FileManager.default.removeItem(at:originalFile)
        check(ImageRenderCache.shared.image(reopened.annotations.imageAssets![key]!,key:key) != nil,"embedded source remains independent of deleted source file")
        reopened.groupObjects([id,ink.id],ungroup:true)
        check(reopened.beginInkAction("edit reopened image"),"reopened image starts transaction")
        let secondPage=reopened.document.page(at:0)!
        var changed=reopened.annotations.images[0];changed=changed.cropped(to:CGRect(x:0.2,y:0.1,width:0.6,height:0.8));changed.rotation=Double.pi/2
        reopened.replaceObjects(on:secondPage,ids:[id],ink:[],images:[changed]);reopened.finishAction();try save(reopened)
        let twice=try DocumentSession.open(url:url);check(!twice.annotationReadOnly && twice.annotations==reopened.annotations && twice.annotations.imageAssets?[key]==normalized,"second edit/save/reopen preserves crop, rotation and immutable pixels")
        let fresh=try DocumentSession.open(url:url),page2=fresh.document.page(at:0)!
        _=try fresh.insertImage(normalized,on:page2,rect:CGRect(x:30,y:30,width:180,height:120))
        guard let record=fresh.recoverableRecord else{fatalError("missing recovery")}
        let recovery=try DocumentSession.open(url:url);try recovery.restoreRecovery(record)
        check(recovery.annotations==fresh.annotations && record.version==7,"image draft recovery includes source, geometry and group metadata")
        let readonly=root.appendingPathComponent("readonly.pdf");try fixture(readonly);try FileManager.default.setAttributes([.posixPermissions:0o444],ofItemAtPath:readonly.path)
        let locked=try DocumentSession.open(url:readonly)
        do {_=try locked.insertImage(normalized,on:locked.document.page(at:0)!,rect:original.rect);check(false,"readonly blocked")}catch{check(locked.annotations.images.isEmpty && !locked.isModified,"filesystem readonly image insertion blocked without dirty state")}
        let localClipboard=NSPasteboard(name:NSPasteboard.Name("EcruPasteTests-"+UUID().uuidString));localClipboard.setData(raw,forType:.png)
        canvas.setTool(.pen)
        let imageCount=session.annotations.images.count;canvas.pasteFromPasteboard(localClipboard)
        let pasteDeadline=Date().addingTimeInterval(10)
        while session.annotations.images.count==imageCount && Date()<pasteDeadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
        localClipboard.releaseGlobally()
        check(session.annotations.images.count==imageCount+1,"clipboard paste decodes in background and inserts canonical image")
        check(canvas.tool == .select && canvas.selectedImages.count==1,"insert automatically enters selection")
        let savedColors=canvas.colors,savedWidths=canvas.widths;canvas.completeImageEditing()
        check(canvas.tool == .pen && canvas.colors==savedColors && canvas.widths==savedWidths,"complete adjustment restores prior pen and its parameters")
        var shape=InkShape(kind:.rectangle,controls:[InkPoint(x:50,y:100),InkPoint(x:150,y:100),InkPoint(x:150,y:180),InkPoint(x:50,y:180)],fill:[0.1,0.2,0.8,0.2],originalPoints:[InkPoint(x:50,y:100),InkPoint(x:150,y:180)],originalOutlines:[])
        var stroke=InkStroke(points:shape.points,width:2,rgba:[0.1,0.2,0.8,1],kind:.pen);stroke.shape=shape
        check(shape.effectiveFillMode == .custom && stroke.requiredReader==4,"legacy fill remains exact custom appearance, reader 4")
        check(session.beginInkAction("legacy shape"),"legacy shape transaction");session.replaceInk(on:page,ids:[],with:[stroke]);session.finishAction()
        canvas.setTool(.select);canvas.selectObjects([stroke.id],on:page)
        let defaultsFill=canvas.shapeFill,defaultsFollow=canvas.shapeFillFollowsPen,defaultColor=canvas.colors[.pen]
        canvas.editSelectedShapes(fill:NSColor.systemGreen.withAlphaComponent(0.37));canvas.editSelectedShapes(border:.systemRed)
        check(session.inkStrokes(on:page).last!.shape!.fill![3]==0.37 && canvas.shapeFill==defaultsFill && canvas.shapeFillFollowsPen==defaultsFollow && canvas.colors[.pen]==defaultColor,"selected custom fill and border edit without changing drawing defaults")
        canvas.editSelectedShapes(fill:NSColor.systemBlue.withAlphaComponent(0.2),fillMatchesBorder:true);canvas.editSelectedShapes(border:.systemPurple)
        stroke=session.inkStrokes(on:page).last!;shape=stroke.shape!
        check(shape.fill!.prefix(3)==stroke.rgba.prefix(3) && shape.fill![3]==0.2 && shape.effectiveFillMode == .border,"follow border uses each shape RGB and independent alpha")
        var second=stroke;second.id=UUID();second=second.translated(dx:200,dy:0)
        check(session.beginInkAction("second shape"),"multi-shape setup");session.replaceInk(on:page,ids:[],with:[second]);session.finishAction()
        canvas.selectObjects([stroke.id,second.id],on:page);canvas.editSelectedShapes(fill:NSColor.systemGreen.withAlphaComponent(0.41))
        check(canvas.selectedShapes.count==2 && canvas.selectedShapes.allSatisfy{$0.shape?.effectiveFillMode == .custom && $0.shape?.fill?.last==0.41},"multi-selection fill updates every selected shape")
        let filled=canvas.selectedShapes;canvas.editSelectedShapes(removeFill:true)
        check(canvas.selectedShapes.allSatisfy{$0.shape?.fill==nil && $0.shape?.effectiveFillMode == InkShape.FillMode.none},"explicit no-fill mode applies to multiple shapes")
        session.undo();check(canvas.selectedShapes==filled,"multi-shape fill change undoes atomically")
        let fillURL=root.appendingPathComponent("fill-and-images.pdf");try save(session,to:fillURL);let shapes=try DocumentSession.open(url:fillURL)
        check(!shapes.annotationReadOnly && shapes.annotations==session.annotations,"fill mode, RGB, opacity and mixed objects survive final save/reopen")
        reader.disconnectInputAndViews();withExtendedLifetime(delegate){}
        print("\(checks) image/fill checks passed. Artifacts: \(root.path)")
    }
}
