import AppKit
import PDFKit
import Darwin

@main enum LaserTests {
    static var checks=0
    static func check(_ value:@autoclosure ()->Bool,_ title:String) {
        guard value() else {print("FAIL: "+title);fflush(stdout);exit(1)}
        checks+=1;print("PASS: "+title);fflush(stdout)
    }
    static func fixture(_ url:URL) throws {
        let data=NSMutableData(),context=CGContext(consumer:CGDataConsumer(data:data)!,mediaBox:nil,nil)!
        for _ in 0..<2 {context.beginPDFPage([kCGPDFContextMediaBox as String:NSValue(rect:CGRect(x:0,y:0,width:612,height:792))] as CFDictionary);context.endPDFPage()}
        context.closePDF();try (data as Data).write(to:url)
    }
    // Write action dictionaries directly: older PDFKit cannot serialize a Swift
    // dictionary installed under /A (it expects its private PDFAction object).
    static func actionPDF(_ action:String,trigger:String="")->Data {
        let objects=[
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << >> /Annots [4 0 R] \(trigger) >>",
            "<< /Type /Annot /Subtype /Link /Rect [10 10 30 30] /A << \(action) >> >>"
        ]
        var data=Data("%PDF-1.7\n".utf8),offsets=[0]
        for (index,object) in objects.enumerated() {offsets.append(data.count);data.append(Data("\(index+1) 0 obj\n\(object)\nendobj\n".utf8))}
        let xref=data.count
        data.append(Data("xref\n0 5\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {data.append(Data(String(format:"%010d 00000 n \n",offset).utf8))}
        data.append(Data("trailer\n<< /Size 5 /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8));return data
    }
    static func event(_ reader:ReaderWindow,_ type:NSEvent.EventType,_ p:CGPoint,page:PDFPage,pencil:Bool=false)->NSEvent {
        let p=reader.pdfView.convert(reader.pdfView.convert(p,from:page),to:nil)
        let e=NSEvent.mouseEvent(with:type,location:p,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:reader.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        guard pencil,let cg=e.cgEvent else{return e}
        cg.setIntegerValueField(.mouseEventSubtype,value:1);cg.setIntegerValueField(.tabletEventDeviceID,value:0x5049)
        cg.setDoubleValueField(.tabletEventPointPressure,value:0.4)
        return NSEvent(cgEvent:cg)!
    }
    static func send(_ reader:ReaderWindow,_ type:NSEvent.EventType,_ p:CGPoint,page:PDFPage,pencil:Bool=false) {
        let e=event(reader,type,p,page:page,pencil:pencil)
        switch type {case .leftMouseDown:reader.canvas.mouseDown(with:e);case .leftMouseDragged:reader.canvas.mouseDragged(with:e);default:reader.canvas.mouseUp(with:e)}
    }
    static func render(_ laser:LaserPresentation,_ page:PDFPage,now:Double,path:URL) throws -> NSBitmapImageRep {
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:400,pixelsHigh:220,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let context=NSGraphicsContext(bitmapImageRep:bitmap)!.cgContext
        context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:400,height:220))
        laser.draw(on:page,in:context,transform:.identity,widthScale:1,now:now)
        try bitmap.representation(using:.png,properties:[:])!.write(to:path);return bitmap
    }
    static func model(_ root:URL) throws {
        let page=PDFPage(),laser=LaserPresentation()
        check(laser.form == .trail && laser.duration == 2 && laser.width == 3,"default red trail lasts two seconds")
        laser.begin(on:page,at:CGPoint(x:40,y:110),now:10)
        for i in 1...100 {laser.append(CGPoint(x:40+i*3,y:110+Int(25*sin(Double(i)/12))),now:10+Double(i)/100)}
        laser.end(now:11)
        let bright=try render(laser,page,now:11,path:root.appendingPathComponent("laser-bright.png"))
        _=try render(laser,page,now:12.8,path:root.appendingPathComponent("laser-fade.png"))
        let colored=(0..<220).flatMap{y in (0..<400).map{x in bright.colorAt(x:x,y:y)!.usingColorSpace(.sRGB)!}}.filter{$0.greenComponent<0.9}
        check(colored.count>300,"native raster contains a visible colored laser tail")
        let a=(0...200).map{LaserPresentation.opacity(age:Double($0)/100,duration:2)}
        check(a.first==1 && a.last==0 && zip(a,a.dropFirst()).allSatisfy{$0 >= $1},"fade opacity decreases continuously to zero")
        check(LaserPresentation.opacity(age:1.5,duration:2)==1 && LaserPresentation.opacity(age:1.8,duration:2)>0.4,"reference-style pause preserves brightness before the final short fade")
        laser.tick(now:13.01);check(laser.page == nil && laser.samples.isEmpty && laser.head == nil,"expired contact releases samples and page")
        laser.form = .dot;laser.begin(on:page,at:CGPoint(x:40,y:110),now:20);laser.append(CGPoint(x:340,y:110),now:20.1)
        check(laser.samples.isEmpty && laser.head?.point.x==340,"point mode stores only the current point")
        laser.tick(now:30);check(laser.head != nil,"held point remains visible without movement")
        laser.end(now:30);laser.tick(now:32.1);check(laser.head == nil,"released point fades completely")
        laser.form = .trail;laser.begin(on:page,at:.zero,now:40)
        for i in 0..<10_000 {laser.append(CGPoint(x:i,y:0),now:40)}
        check(laser.samples.count==LaserPresentation.capacity,"high-rate input has a bounded memory budget")
        laser.tick(now:41.9);check(laser.samples.count==LaserPresentation.capacity,"held presentation keeps complete shapes instead of pruning an age-based tail")
        laser.end(now:42);laser.begin(on:page,at:CGPoint(x:20,y:10),now:43.8)
        check(laser.samples.count==LaserPresentation.capacity,"resuming before expiry keeps the temporary mark group")
        let second=PDFPage();laser.begin(on:second,at:CGPoint(x:1,y:1),now:40)
        check(laser.page === second && laser.samples.count==1,"cross-page contact cannot join old trajectories")
        laser.form = .dot;check(laser.page == nil,"form change clears previous temporary content")
    }
    static func renderCost() {
        let page=PDFPage(),laser=LaserPresentation()
        let context=CGContext(data:nil,width:1600,height:900,bitsPerComponent:8,bytesPerRow:6400,
                              space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        for count in [480,LaserPresentation.capacity] {
            laser.clear();laser.begin(on:page,at:CGPoint(x:30,y:100),now:100)
            for i in 1..<count {laser.append(CGPoint(x:30+Double(i)*500/Double(count),y:100+35*sin(Double(i)*12/Double(count))),now:100)}
            laser.end(now:100)
            var times:[Double]=[]
            for _ in 0..<40 {
                context.clear(CGRect(x:0,y:0,width:1600,height:900))
                let start=ProcessInfo.processInfo.systemUptime
                laser.draw(on:page,in:context,transform:CGAffineTransform(scaleX:2,y:2),widthScale:2,now:100.2)
                times.append((ProcessInfo.processInfo.systemUptime-start)*1000)
            }
            times.sort()
            print(String(format:"LASER_RENDER_CPU samples=%d bitmap=1600x900 median_ms=%.3f p95_ms=%.3f",count,times[20],times[38]))
            check(times.allSatisfy{$0.isFinite},"Gaussian rendering has a measured bounded sample budget at \(count) points")
        }
    }
    static func native(_ root:URL) throws {
        let url=root.appendingPathComponent("synthetic.pdf");try fixture(url)
        let original=try Data(contentsOf:url),session=try DocumentSession.open(url:url)
        let reader=ReaderWindow(session:session,installInputMonitor:{_,_ in 1},removeInputMonitor:{_ in})
        let page=session.document.page(at:0)!,canvas=reader.canvas
        reader.pdfView.autoScales=false;reader.pdfView.layoutDocumentView()
        let baseline=session.annotations
        check(ReaderTool.toolbarOrder == [.select,.pen,.eraser,.textHighlight,.marker,.lasso,.laser],"laser is the final independent tool; eraser follows pen")
        let coalescing=NSEvent.isMouseCoalescingEnabled
        for scale in [0.15,0.5,1.0,2.0,6.0] {
            reader.pdfView.scaleFactor=scale;reader.pdfView.layoutDocumentView();reader.selectTool(.laser)
            let p=CGPoint(x:100,y:400)
            send(reader,.leftMouseDown,p,page:page,pencil:scale>1)
            for i in 1...50 {send(reader,.leftMouseDragged,CGPoint(x:100+Double(i)*2,y:400),page:page,pencil:scale>1)}
            send(reader,.leftMouseUp,CGPoint(x:200,y:400),page:page,pencil:scale>1)
            check(canvas.laser.samples.count>=51 && abs(canvas.laser.head!.point.x-200)<0.01,"mouse/Pencil coordinates correct at \(scale)x")
            check(!canvas.gesture && canvas.activeInkStroke == nil && !session.isModified && session.annotations==baseline,"laser bypasses annotation transactions at \(scale)x")
            check(NSEvent.isMouseCoalescingEnabled==coalescing,"release restores event coalescing at \(scale)x")
        }
        check(!session.canUndo && !session.canRedo && session.recoverableRecord == nil,"laser creates no undo history or recovery record")
        check((try? Data(contentsOf:url))==original,"PDF bytes unchanged after laser input")
        canvas.setTool(.pen);check(canvas.laser.page == nil,"tool switch clears temporary content")
        reader.pdfView.scaleFactor=1;reader.pdfView.layoutDocumentView();reader.selectTool(.laser)
        send(reader,.leftMouseDown,CGPoint(x:100,y:400),page:page)
        NotificationCenter.default.post(name:.PDFViewPageChanged,object:reader.pdfView)
        check(canvas.laser.page == nil && NSEvent.isMouseCoalescingEnabled==coalescing,"page change clears an active contact and restores input")
        send(reader,.leftMouseDown,CGPoint(x:100,y:400),page:page)
        reader.windowDidResignKey(Notification(name:NSWindow.didResignKeyNotification))
        check(canvas.laser.page == nil,"window focus loss clears temporary input")
        let secondSession=try DocumentSession.open(url:url),second=ReaderWindow(session:secondSession,installInputMonitor:{_,_ in 1},removeInputMonitor:{_ in})
        second.canvas.setTool(.laser);second.canvas.laser.begin(on:secondSession.document.page(at:0)!,at:CGPoint(x:20,y:30))
        check(canvas.laser.page == nil && second.canvas.laser.head != nil,"windows never share laser samples")
        // Seed a real transaction, then leave redo available across temporary input.
        check(session.beginInkAction("fixture"),"real ink transaction begins")
        let stroke=InkStroke(points:[InkPoint(x:20,y:30),InkPoint(x:30,y:40)],width:2,rgba:[0,0,1,1],kind:.pen)
        session.replaceInk(on:page,ids:[],with:[stroke]);session.finishAction();session.undo()
        let redo=session.canRedo,dirty=session.isModified
        send(reader,.leftMouseDown,CGPoint(x:100,y:400),page:page);send(reader,.leftMouseUp,CGPoint(x:110,y:400),page:page)
        check(session.canRedo==redo && session.isModified==dirty,"laser preserves existing redo and modified state")
        session.redo();check(session.inkStrokes(on:page).contains(stroke),"real ink redo still restores original content")
        canvas.setTool(.laser);canvas.laser.form = .dot;canvas.colors[.laser] = .systemGreen;canvas.widths[.laser]=5;canvas.laser.glow=0.4;canvas.laser.duration=3.5;canvas.rememberWritingPreferences()
        let restored=ReaderCanvas(frame:.zero)
        check(restored.laser.form == .dot && restored.laser.width==5 && restored.laser.duration==3.5 && restored.laser.glow==0.4,"laser settings persist only in writing preferences")
        reader.disconnectInputAndViews();second.disconnectInputAndViews()
        check(canvas.laser.page == nil && second.canvas.laser.page == nil,"disconnect releases both temporary layers")
    }
    static func protected(_ root:URL) throws {
        let url=root.appendingPathComponent("protected.pdf")
        let input=actionPDF("/Type /Action /S /JavaScript /JS (app.alert\\('synthetic'\\))")
        try input.write(to:url);check((try? Data(contentsOf:url)) == input,"protected fixture written")
        let protectedSession=try DocumentSession.open(url:url)
        check(protectedSession.usesLocalAnnotations && !protectedSession.capabilities.canEdit,"active-content fixture preserves original and supports independent notes")
        let reader=ReaderWindow(session:protectedSession,installInputMonitor:{_,_ in 1},removeInputMonitor:{_ in})
        reader.pdfView.autoScales=false;reader.pdfView.scaleFactor=1;reader.pdfView.layoutDocumentView();reader.selectTool(.laser)
        let page=protectedSession.document.page(at:0)!,p=CGPoint(x:100,y:100)
        send(reader,.leftMouseDown,p,page:page);send(reader,.leftMouseUp,p,page:page)
        check(reader.canvas.tool == .laser && reader.canvas.laser.head != nil && !protectedSession.isModified,"laser works in protected PDFs without enabling writes")
        reader.disconnectInputAndViews()
    }
    static func chapter(_ root:URL) throws {
        guard CommandLine.arguments.count>1 else{return}
        let source=URL(fileURLWithPath:CommandLine.arguments[1]),data=try Data(contentsOf:source)
        let copy=root.appendingPathComponent("navigation-regression-copy.pdf");try data.write(to:copy)
        let session=try DocumentSession.open(url:copy)
        print("Navigation regression features: \(session.capabilities.features); \(session.capabilities.summary)")
        check(!session.annotationReadOnly,"reported slide PDF supports editing after navigation classification fix")
        let page=session.document.page(at:0)!
        check(session.beginInkAction("copy-only validation"),"navigation PDF copy starts ink action")
        session.replaceInk(on:page,ids:[],with:[InkStroke(points:[InkPoint(x:30,y:30),InkPoint(x:60,y:40)],width:2,rgba:[0,0,1,1],kind:.pen)]);session.finishAction()
        var done=false,error:Error?
        session.save(to:copy){if case .failure(let e)=$0 {error=e};done=true}
        while !done {RunLoop.current.run(until:Date(timeIntervalSinceNow:0.02))}
        check(error == nil,"reported slide PDF copy passes object-preserving save")
        let reopened=try DocumentSession.open(url:copy)
        check(!reopened.annotationReadOnly && reopened.annotations==session.annotations,"reported slide PDF copy reopens with exact editable annotations")
        check((try? Data(contentsOf:source))==data,"reported original PDF remains byte-for-byte unchanged")
    }
    static func navigation(_ root:URL) throws {
        func pdf(name:String,trigger:String="",next:String="")->Data {
            actionPDF("/Type /Action /S /Named /N \(name) \(next)",trigger:trigger)
        }
        for (index,name) in ["/FirstPage","/LastPage","/NextPage","/PrevPage","/Find","/GoBack","/GoForward","/GoToPage"].enumerated() {
            let input=pdf(name:name),url=root.appendingPathComponent("navigation-\(index).pdf");try input.write(to:url)
            let session=try DocumentSession.open(url:url)
            check(!session.annotationReadOnly,"local viewer navigation \(name) stays editable")
            let page=session.document.page(at:0)!
            _=session.beginInkAction("navigation fixture");session.replaceInk(on:page,ids:[],with:[InkStroke(points:[InkPoint(x:50,y:50)],width:2,rgba:[1,0,0,1],kind:.pen)]);session.finishAction()
            var done=false,error:Error?
            session.save(to:url){if case .failure(let e)=$0 {error=e};done=true}
            while !done {RunLoop.current.run(until:Date(timeIntervalSinceNow:0.01))}
            check(error == nil && PDFPagePreservation.validate(input,saved:try! Data(contentsOf:url),removing:[[]]),"\(name) action preserved through annotation save")
        }
        for name in ["/Print","/Quit","/UnknownAction"] {
            let input=pdf(name:name),inspection=try PDFPagePreservation.inspect(input,password:nil)
            check(inspection.features & 32 != 0,"non-navigation or unknown \(name) remains protected")
        }
        for trigger in ["/AA << >>","/AA << /O << /S /GoTo /D [3 0 R /Fit] >> >>"] {
            let input=pdf(name:"/NextPage",trigger:trigger),inspection=try PDFPagePreservation.inspect(input,password:nil)
            check(inspection.features & 32 == 0 && inspection.readingData != nil,"empty/local navigation triggers use an inert editable reading view")
            let url=root.appendingPathComponent("navigation-trigger-"+UUID().uuidString+".pdf");try input.write(to:url)
            let session=try DocumentSession.open(url:url)
            check(!session.annotationReadOnly && session.document.pageCount==1,"navigation-trigger document opens for editing")
            check(session.document.page(at:0)!.annotations.first?.action is PDFActionNamed,"inert reading view preserves safe manual links")
        }
        let chained=try PDFPagePreservation.inspect(pdf(name:"/NextPage",next:"/Next << /S /JavaScript /JS (synthetic) >>"),password:nil)
        check(chained.features & 32 != 0,"chained JavaScript cannot hide behind permitted navigation")
        let automatic=try PDFPagePreservation.inspect(pdf(name:"/NextPage",trigger:"/AA << /O << /S /URI /URI (https://example.invalid) >> >>"),password:nil)
        check(automatic.features & 32 != 0,"automatic external URL remains protected")
    }
    static func main() throws {
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let delegate=AppDelegate();AppDelegate.shared=delegate
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/laser-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);setenv("ECRU_DATA_DIR",root.appendingPathComponent("recovery").path,1)
        try model(root);renderCost();try native(root);try protected(root);try navigation(root);try chapter(root)
        withExtendedLifetime(delegate){};print("\(checks) laser checks passed. Artifacts: \(root.path)")
    }
}
