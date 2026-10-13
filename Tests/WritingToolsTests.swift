import AppKit
import PDFKit
import Darwin

/// Native objects are passed directly to a hidden reader. No OS event injection.
@main enum WritingToolsTests {
    static var checks=0
    static func check(_ condition:@autoclosure ()->Bool,_ title:String) {
        guard condition() else {print("FAIL: "+title);fflush(stdout);exit(1)}
        checks+=1;print("PASS: "+title);fflush(stdout)
    }
    static func apply(_ u:InkOutlineUpdate,_ s:inout InkStroke) {
        s.points.removeLast(u.removing);s.points+=u.points;s.widthFactors!.removeLast(u.removing);s.widthFactors!+=u.factors
        s.outlines!.removeLast(u.removingOutlines);s.outlines!+=u.outlines
    }
    static func pressureStroke(_ pressure:(Int)->Double?,sensitivity:Double=0.65)->InkStroke {
        let p=InkPoint(x:30,y:300),b=GoogleInkPenBuilder(point:p,width:4,pressure:pressure(0),timestamp:0,sensitivity:sensitivity)
        var s=InkStroke(points:[p],width:4,rgba:[0.1,0.2,0.7,0.6],kind:.pen,widthFactors:b.initialFactors,appearance:.perfectFreehandV1,outlines:b.initialOutlines)
        for i in 1...240 {apply(b.append(InkPoint(x:30+Double(i),y:300),pressure:pressure(i),isRelease:false,timestamp:Double(i)/240),&s)}
        apply(b.append(s.points.last!,pressure:0,isRelease:true,timestamp:2),&s);return s
    }
    static func diameter(_ stroke:InkStroke,_ x:Double)->Double {
        let shape=InkOutline.path(stroke.outlines!)
        var y:[Double]=[]
        for i in 0...1600 {let v=296+Double(i)/200;if shape.contains(CGPoint(x:x,y:v)){y.append(v)}}
        return (y.last ?? 0)-(y.first ?? 0)
    }
    static func geometry() {
        let low=pressureStroke({_ in 0.02}),high=pressureStroke({_ in 1}),fixed=pressureStroke({_ in nil})
        check(low.isValid && high.isValid && fixed.isValid,"real-pressure and mouse modes produce valid Google Ink contours")
        check(diameter(high,150)>diameter(low,150)*1.5,"strong contact is visibly thicker than light contact")
        let ramp=pressureStroke({Double($0)/240})
        let widths=(50...250).map{diameter(ramp,Double($0))}
        check(widths.max()!-widths.min()!>1,"pressure changes continuously inside a single stroke")
        check(zip(widths,widths.dropFirst()).allSatisfy{abs($0-$1)<0.12},"continuous pressure has no abrupt width jumps")
        check(abs(diameter(fixed,100)-4)<0.08 && abs(diameter(fixed,200)-4)<0.08,"mouse mode uses fixed base width and no simulated pressure")
        let sensitive=pressureStroke({_ in 1},sensitivity:1),restrained=pressureStroke({_ in 1},sensitivity:0.1)
        check(diameter(sensitive,150)>diameter(restrained,150),"sensitivity setting changes brush response without position modeling changes")
        for angle in [0.1,0.5,1.0,Double.pi/2] {
            for azimuth in [0.0,0.8,1.7,2.6] {
                let z=sin(angle),m=cos(angle),x=atan2(m*cos(azimuth),z)/(Double.pi/2),y = -atan2(m*sin(azimuth),z)/(Double.pi/2)
                check(abs(NativePenInput.altitude(tiltX:x,tiltY:y)!-angle)<1e-5,"PadInk tilt inversion preserves altitude independently of azimuth")
            }
        }
        let radii=(0...90).map {EraserSizeResponse.radius(base:10,altitude:Double($0)*Double.pi/180)}
        check(zip(radii,radii.dropFirst()).allSatisfy{$0 >= $1 && abs($0-$1)<0.5},"eraser size changes continuously as Pencil stands upright")
        check(EraserSizeResponse.radius(base:10,altitude:nil)==10 && EraserSizeResponse.radius(base:64,altitude:0)==48,"missing tilt retains fixed eraser and tilt has a bounded maximum")
        check(NativePenInput.altitude(tiltX:.nan,tiltY:0)==nil,"invalid tilt is unavailable rather than pressure-derived")
        func sampled(_ vertices:[InkPoint])->[InkPoint] {
            var p:[InkPoint]=[]
            for (a,b) in zip(vertices,vertices.dropFirst()) {for i in 0..<24 {let t=Double(i)/24;p.append(InkPoint(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t))}}
            p.append(vertices.last!);return p
        }
        func test(_ kind:InkShape.Kind,_ p:[InkPoint]) {
            let stroke=InkStroke(points:p,width:2,rgba:[0,0,1,1],kind:.pen)
            let recognized=ShapeRecognition.recognize(stroke,scale:1)
            check(recognized?.kind==kind,"hold recognizes \(kind.rawValue) conservatively")
            var s=stroke;s.shape=recognized;s.points=recognized!.points
            check(s.isValid && InkAnnotationCodec.stroke(from:InkAnnotationCodec.make(s))==s,"\(kind.rawValue) editable shape codec roundtrip")
            check(s.translated(dx:10,dy:20).isValid,"\(kind.rawValue) moves as one editable object")
        }
        test(.line,sampled([InkPoint(x:40,y:100),InkPoint(x:200,y:102)]))
        test(.arrow,sampled([InkPoint(x:40,y:100),InkPoint(x:200,y:100),InkPoint(x:176,y:86),InkPoint(x:200,y:100),InkPoint(x:176,y:114)]))
        for (kind,rx,ry) in [(InkShape.Kind.circle,60.0,60.0),(.ellipse,90.0,45.0)] {
            test(kind,(0...128).map {i in let t=Double(i)*2*Double.pi/128;return InkPoint(x:180+rx*cos(t),y:400+ry*sin(t))})
        }
        test(.square,sampled([InkPoint(x:50,y:100),InkPoint(x:150,y:100),InkPoint(x:150,y:200),InkPoint(x:50,y:200),InkPoint(x:50,y:100)]))
        test(.rectangle,sampled([InkPoint(x:50,y:100),InkPoint(x:210,y:100),InkPoint(x:210,y:200),InkPoint(x:50,y:200),InkPoint(x:50,y:100)]))
        test(.triangle,sampled([InkPoint(x:50,y:100),InkPoint(x:170,y:100),InkPoint(x:110,y:200),InkPoint(x:50,y:100)]))
        test(.diamond,sampled([InkPoint(x:50,y:150),InkPoint(x:110,y:100),InkPoint(x:170,y:150),InkPoint(x:110,y:200),InkPoint(x:50,y:150)]))
        for p in [[InkPoint(x:0,y:0),InkPoint(x:40,y:0),InkPoint(x:0,y:0),InkPoint(x:40,y:40)],(0...128).map {i in let t=Double(i)*2*Double.pi/128;return InkPoint(x:80*sin(t),y:40*sin(2*t))}] {
            check(ShapeRecognition.recognize(InkStroke(points:p,width:2,rgba:[0,0,0,1],kind:.pen),scale:1)==nil,"backtracking handwriting and figure-eight are not shapes")
        }
    }
    static func feedback(_ root:URL) throws {
        #if ECRU_PRIVATE_CORPUS
        let strokes=try JSONDecoder().decode([InkStroke].self,from:Data(contentsOf:URL(fileURLWithPath:"Tests/Fixtures/pencil-shape-feedback.json")))
        for (i,stroke) in strokes.enumerated() {
            let shape=ShapeRecognition.recognize(stroke,scale:1.4)
            check(shape?.kind == (i==0 ? .triangle:.circle),"real Pencil feedback trajectory \(i+1) fits its intended closed shape")
        }
        #endif
        let sparse=InkStroke(points:[InkPoint(x:30,y:90),InkPoint(x:180,y:91)],width:2,rgba:[0,0,1,1],kind:.pen)
        check(ShapeRecognition.recognize(sparse,scale:1)?.kind == .line,"fast two-sample line can snap without four input events")
        let url=root.appendingPathComponent("punctuation.pdf")
        try FileManager.default.copyItem(at:URL(fileURLWithPath:"Tests/Fixtures/text-range-punctuation.pdf"),to:url)
        let session=try DocumentSession.open(url:url),page=session.document.page(at:0)!
        let text=(page.string ?? "") as NSString,range=text.range(of:"Draw a thin pen stroke, a translucent marker stroke, then undo / redo.")
        check(range.location != NSNotFound,"exact reported line exists in synthetic feedback PDF")
        let selection=page.selection(for:range)!,color=NSColor.systemYellow.withAlphaComponent(0.45)
        let foreign=session.annotations.marks.filter{$0.textEditable==false}
        for i in 0..<6 {
            session.addTextSelection(selection,color:color,withNote:false)
            check(session.annotations.marks.filter{$0.textEditable==true}.count == (i%2==0 ? 1:0),"line-ending punctuation toggles without accumulating fragments on operation \(i+1)")
        }
        let period=page.selection(for:NSRange(location:range.location+range.length-1,length:1))!
        session.addTextSelection(period,color:color,withNote:false)
        check(session.annotations.marks.first{$0.textEditable==true}!.textSpan!.length==1,"PDFKit newline expansion is excluded from saved punctuation span")
        let before=session.annotations
        session.addTextSelection(period,color:color,withNote:false)
        check(session.annotations.marks.filter{$0.textEditable==true}.isEmpty,"same single punctuation highlight cancels completely")
        session.undo();check(session.annotations==before,"punctuation toggle undo restores exact original annotation")
        session.redo();check(session.annotations.marks.filter{$0.textEditable==true}.isEmpty,"punctuation redo leaves no newline artifact")
        check(session.annotations.marks.filter{$0.textEditable==false}==foreign,"feedback correction preserves foreign highlights")
        session.addTextSelection(selection,color:color,withNote:false)
        let full=session.annotations.marks.first{$0.textEditable==true}!
        session.addTextSelection(period,color:color,withNote:false)
        check(!session.annotations.marks.filter{$0.textEditable==true}.contains{$0.anchor.bounds.maxX>=full.anchor.bounds.maxX-0.01},"partial subtraction of final punctuation preserves only preceding text")
        try save(session);let reopened=try DocumentSession.open(url:url)
        check(!reopened.annotationReadOnly && reopened.annotations==session.annotations,"punctuation fragments survive validated save and reopen")
        let reopenedPage=reopened.document.page(at:0)!,end=range.location+range.length-1
        let punctuation=reopenedPage.selection(for:NSRange(location:end,length:1))!
        reopened.addTextSelection(punctuation,color:color,withNote:false)
        var record=reopened.recoverableRecord!,model=record.annotations!
        let mark=model.marks.first{$0.textEditable==true && $0.textSpan?.location==end}!
        model.marks.removeAll{$0.id==mark.id}
        for _ in 0..<15 {var duplicate=mark;duplicate.id=UUID();duplicate.textSpan=TextSpan(location:end,length:2);model.marks.append(duplicate)}
        record.annotations=model;try reopened.restoreRecovery(record)
        let recoveredPage=reopened.document.page(at:0)!
        reopened.addTextSelection(recoveredPage.selection(for:NSRange(location:end,length:1))!,color:color,withNote:false)
        check(!reopened.annotations.marks.contains{$0.textEditable==true && $0.textSpan?.location==end},"existing fifteen legacy newline-expanded duplicates cancel together")
        check(reopened.annotations.marks.filter{$0.textEditable==false}==foreign,"repairing old duplicate stack preserves external annotations")

    }
    static func save(_ session:DocumentSession) throws {
        var result:Result<SaveOutcome,Error>?
        session.save{result=$0};let deadline=Date().addingTimeInterval(20)
        while result == nil && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
        guard let result else{fatalError("save timeout")};_ = try result.get()
    }
    static func fixture(_ url:URL) throws {
        let data=NSMutableData();let context=CGContext(consumer:CGDataConsumer(data:data)!,mediaBox:nil,nil)!
        for i in 0..<2 {
            context.beginPDFPage([kCGPDFContextMediaBox as String:NSValue(rect:CGRect(x:0,y:0,width:612,height:792))] as CFDictionary)
            let ns=NSGraphicsContext(cgContext:context,flipped:false);NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=ns
            ("Writing tools page \(i+1)\nAlpha beta gamma delta epsilon\nSecond line for overlap testing" as NSString).draw(at:CGPoint(x:50,y:620),withAttributes:[.font:NSFont.systemFont(ofSize:16),.foregroundColor:NSColor.black])
            NSGraphicsContext.restoreGraphicsState();context.endPDFPage()
        };context.closePDF();try (data as Data).write(to:url)
    }
    static func highlight(_ root:URL) throws {
        let url=root.appendingPathComponent("highlight.pdf");try fixture(url)
        let foreign=PDFDocument(url:url)!,fp=foreign.page(at:0)!,fr=fp.selection(for:NSRange(location:0,length:5))!.bounds(for:fp)
        let fa=PDFAnnotation(bounds:fr,forType:.highlight,withProperties:nil);fa.color = .systemPurple;fa.contents="External comment";fp.addAnnotation(fa);check(foreign.write(to:url),"external highlight fixture created")
        let session=try DocumentSession.open(url:url),p=session.document.page(at:0)!
        let foreignID=session.annotations.marks.first!.id
        func selection(_ location:Int,_ length:Int)->PDFSelection {p.selection(for:NSRange(location:location,length:length))!}
        func coverage()->[Int:[Double]] {
            var result:[Int:[Double]]=[:]
            for mark in session.annotations.marks where mark.textEditable != false {if let span=mark.textSpan {for i in span.location..<span.location+span.length {result[i]=mark.rgba}}};return result
        }
        let blue=NSColor.systemBlue.withAlphaComponent(0.45),red=NSColor.systemRed.withAlphaComponent(0.45)
        session.addTextSelection(selection(0,18),color:blue,withNote:false)
        check(!coverage().isEmpty,"unhighlighted selected text gains editable highlight")
        let first=session.annotations;session.addTextSelection(selection(0,18),color:blue,withNote:false)
        check(coverage().isEmpty,"same color and full range toggles highlight off")
        check(session.annotations.marks.contains{$0.id==foreignID && $0.contents=="External comment"},"foreign PDF highlight remains untouched")
        session.undo();check(session.annotations==first,"toggle undo restores complete model")
        session.redo();check(coverage().isEmpty,"toggle redo removes highlight again")
        session.addTextSelection(selection(0,18),color:blue,withNote:false)
        let before=coverage();session.addTextSelection(selection(5,6),color:blue,withNote:false)
        let after=coverage()
        check((5..<11).allSatisfy{after[$0]==nil} && before.keys.filter{!(5..<11).contains($0)}.allSatisfy{after[$0]==before[$0]},"partial toggle subtracts only selected characters")
        session.addTextSelection(selection(5,6),color:red,withNote:false)
        let redRGB=red.usingColorSpace(.sRGB)!
        check((5..<11).filter{before[$0] != nil}.allSatisfy{abs(coverage()[$0]![0]-redRGB.redComponent)<0.005},"overlap replaces color instead of stacking")
        let bodyID=session.annotateMarks([session.annotations.marks.first{$0.textEditable==true}!.id])!
        session.editBody(bodyID,markdown:"Body must survive toggles");session.finishAction()
        session.addTextSelection(selection(0,18),color:red,withNote:false)
        check(session.annotations.notes.first{$0.id==bodyID}!.markdown=="Body must survive toggles" && !session.annotations.notes.first{$0.id==bodyID}!.links.isEmpty,"color replacement preserves attached note body and links")
        session.addTextSelection(selection(0,18),color:red,withNote:false)
        check(session.annotations.notes.first{$0.id==bodyID}!.markdown=="Body must survive toggles","cancel never deletes attached note content")
        let cross=PDFSelection(document:session.document)
        for page in (0..<2).map({session.document.page(at:$0)!}) {cross.add(page.selection(for:NSRange(location:0,length:min(70,page.numberOfCharacters)))!)}
        session.addTextSelection(cross,color:blue,withNote:false)
        check(Set(session.annotations.marks.filter{$0.textEditable==true}.map{ $0.anchor.page })==[0,1],"multi-line and cross-page highlight retains text ranges")
        try save(session);let reopened=try DocumentSession.open(url:url)
        check(!reopened.annotationReadOnly && reopened.annotations==session.annotations,"highlight ranges and detached bodies survive validated PDF save/reopen")
        reopened.addTextSelection(reopened.document.page(at:0)!.selection(for:NSRange(location:0,length:18))!,color:blue,withNote:false)
        check(reopened.annotations.valid(),"reopened ranges remain editable after PDF text extraction")
    }
    static func event(_ reader:ReaderWindow,_ type:NSEvent.EventType,_ p:CGPoint,tilt:Double?=nil,phase:Int64?=nil)->NSEvent {
        let page=reader.session.document.page(at:0)!,point=reader.pdfView.convert(reader.pdfView.convert(p,from:page),to:nil)
        var event=NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:reader.window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        if let tilt,let cg=event.cgEvent {
            cg.setIntegerValueField(.mouseEventSubtype,value:1);cg.setIntegerValueField(.tabletEventDeviceID,value:0x5049)
            cg.setDoubleValueField(.tabletEventPointPressure,value:0.4);cg.setDoubleValueField(.tabletEventTiltX,value:tilt);cg.setDoubleValueField(.tabletEventTiltY,value:0);cg.setIntegerValueField(.tabletEventPointZ,value:phase ?? 0)
            event=NSEvent(cgEvent:cg)!
            check(abs(NativePenInput.altitude(from:event)!-(Double.pi/2-tilt*Double.pi/2))<5e-4,"genuine tablet event fields carry tilt independent of pressure")
        }
        return event
    }

    static func send(_ reader:ReaderWindow,_ type:NSEvent.EventType,_ p:CGPoint) {
        let e=event(reader,type,p)
        if type == .leftMouseDown {reader.canvas.mouseDown(with:e)} else if type == .leftMouseDragged {reader.canvas.mouseDragged(with:e)} else {reader.canvas.mouseUp(with:e)}
    }
    static func canvas(_ root:URL) throws {
        let url=root.appendingPathComponent("canvas.pdf");try fixture(url)
        let session=try DocumentSession.open(url:url),reader=ReaderWindow(session:session,installInputMonitor:{_,_ in 1},removeInputMonitor:{_ in})
        reader.pdfView.autoScales=false;reader.pdfView.scaleFactor=1;reader.pdfView.layoutDocumentView()
        let canvas=reader.canvas,page=session.document.page(at:0)!
        for zoom in [0.5,1.0,2.0,4.0] {
            reader.pdfView.scaleFactor=zoom;reader.pdfView.layoutDocumentView();canvas.setTool(.pen)
            send(reader,.leftMouseDown,CGPoint(x:70,y:300))
            for i in 1...30 {send(reader,.leftMouseDragged,CGPoint(x:70+Double(i)*4,y:300))}
            let freehand=canvas.activeInkStroke!
            canvas.recognizeHeldShape();check(canvas.activeInkStroke?.shape?.kind == .line,"hold preview snaps line at \(zoom)x PDF zoom")
            send(reader,.leftMouseDragged,CGPoint(x:220,y:310));send(reader,.leftMouseUp,CGPoint(x:220,y:310))
            let shaped=session.inkStrokes(on:page).last!
            check(shaped.shape != nil && shaped.points.last!.x>210,"contact movement resizes preview and up commits editable shape")
            session.undo();check(!session.inkStrokes(on:page).contains{$0.id==shaped.id},"entire shape gesture undoes once")
            session.redo();check(session.inkStrokes(on:page).last==shaped,"shape redo restores the confirmed preview")
            canvas.setTool(.select);send(reader,.leftMouseDown,shaped.points[0].cgPoint);send(reader,.leftMouseUp,shaped.points[0].cgPoint)
            check(canvas.selectedShapes.count==1,"native selection exposes shape editing controls")
            canvas.editSelectedShapes(width:3,border:.systemRed)
            check(session.inkStrokes(on:page).last!.width==3,"selected shape border width can change after drawing")
            canvas.editSelectedShapes(restore:true)
            check(session.inkStrokes(on:page).last!.points==freehand.points && session.inkStrokes(on:page).last!.outlines==freehand.outlines,"restore hand-drawn contour preserves original Google Ink geometry")
            session.undo();session.undo();canvas.clearSelection()
        }
        canvas.setTool(.pen);canvas.shapeFill=NSColor.systemGreen.withAlphaComponent(0.22)
        let shape=InkShape(kind:.rectangle,controls:[InkPoint(x:100,y:400),InkPoint(x:220,y:400),InkPoint(x:220,y:490),InkPoint(x:100,y:490)],fill:[0.2,0.7,0.3,0.22],originalPoints:[InkPoint(x:100,y:400),InkPoint(x:220,y:490)],originalOutlines:[])
        let filled=InkStroke(points:shape.points,width:3,rgba:[0.1,0.2,0.8,0.8],kind:.pen,shape:shape)
        check(session.beginInkAction("shape fixture"),"shape action starts");session.replaceInk(on:page,ids:[],with:[filled]);session.finishAction()
        let erased=InkGeometry.erase(filled,center:CGPoint(x:150,y:450),radius:8)
        check(erased.allSatisfy(\.isValid) && !erased.isEmpty && erased != [filled],"local eraser removes actual filled geometry")
        check(erased.filter{$0.rgba==shape.fill!}.allSatisfy{!InkOutline.path($0.outlines!).contains(CGPoint(x:150,y:450))},"filled shape erasure leaves a real hole rather than a white cover")
        canvas.setTool(.select);send(reader,.leftMouseDown,CGPoint(x:120,y:420));send(reader,.leftMouseUp,CGPoint(x:120,y:420))
        canvas.editSelectedShapes(fill:NSColor.systemOrange.withAlphaComponent(0.4));check(session.inkStrokes(on:page).last!.shape!.fill![3]==0.4,"selected fill alpha changes independently of the border")
        try save(session);let reopened=try DocumentSession.open(url:url)
        check(!reopened.annotationReadOnly && reopened.inkStrokes(on:reopened.document.page(at:0)!)==session.inkStrokes(on:page),"all geometric shapes and pressure appearance survive safe save and reopen")
        canvas.clearSelection();canvas.setTool(.eraser);send(reader,.leftMouseDown,CGPoint(x:150,y:450));check(canvas.tool == .eraser,"eraser stays active throughout contact")
        canvas.finishInterruptedInput();check(canvas.tool == .eraser,"focus or connection interruption cannot auto-return to pen")
        session.undo();canvas.setTool(.eraser);send(reader,.leftMouseDown,CGPoint(x:150,y:450));send(reader,.leftMouseUp,CGPoint(x:150,y:450));check(canvas.tool == .pen,"completed erase returns to prior pen settings")
        session.undo();canvas.automaticPenReturn=false;canvas.setTool(.eraser);send(reader,.leftMouseDown,CGPoint(x:150,y:450));send(reader,.leftMouseUp,CGPoint(x:150,y:450));check(canvas.tool == .eraser,"disabled auto-return supports repeated erasing")
        let cg=CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:.zero,mouseButton:.left)!
        cg.setIntegerValueField(.mouseEventSubtype,value:1);cg.setIntegerValueField(.tabletEventDeviceID,value:0x5049)
        for terminal in [Int64(0),0x50490004,0x50490003] {
            cg.setIntegerValueField(.tabletEventPointZ,value:terminal)
            check(NativePenInput.completedContact(NSEvent(cgEvent:cg)!) == (terminal==0x50490003),"only explicit PadInk real lift permits eraser auto-return")
        }
        session.undo();canvas.automaticPenReturn=true;canvas.setTool(.eraser)
        let down=event(reader,.leftMouseDown,CGPoint(x:150,y:450),tilt:0,phase:0x50490001)
        canvas.mouseDown(with:down);let upright=canvas.effectiveEraserRadius
        canvas.mouseDragged(with:event(reader,.leftMouseDragged,CGPoint(x:150,y:450),tilt:0.7,phase:0x50490002))
        let slanted=canvas.effectiveEraserRadius
        check(slanted>upright && slanted<=48,"real native tilt fields change actual erasing radius during contact")
        for _ in 0..<8 {canvas.mouseDragged(with:event(reader,.leftMouseDragged,CGPoint(x:150,y:450),tilt:0,phase:0x50490002))}
        check(canvas.effectiveEraserRadius<slanted && abs(canvas.effectiveEraserRadius-upright)<0.02,"returning Pencil upright smoothly restores a smaller eraser")
        canvas.mouseUp(with:event(reader,.leftMouseUp,CGPoint(x:150,y:450),tilt:0,phase:0x50490004))
        check(canvas.tool == .eraser,"PadInk cancellation up cannot auto-return even after actual erasure")
        session.undo();canvas.setTool(.eraser)
        canvas.mouseDown(with:event(reader,.leftMouseDown,CGPoint(x:150,y:450),tilt:0,phase:0x50490001))
        canvas.mouseUp(with:event(reader,.leftMouseUp,CGPoint(x:150,y:450),tilt:0,phase:0x50490003))
        check(canvas.tool == .pen,"explicit real PadInk lift returns to pen after contact ends")
        session.undo();canvas.setTool(.eraser);send(reader,.leftMouseDown,CGPoint(x:400,y:450));send(reader,.leftMouseUp,CGPoint(x:400,y:450))
        check(canvas.tool == .eraser,"an empty accidental click cannot auto-return to pen")
        canvas.setTool(.lasso)
        for (i,p) in [CGPoint(x:80,y:380),CGPoint(x:240,y:380),CGPoint(x:240,y:510),CGPoint(x:80,y:510),CGPoint(x:80,y:380)].enumerated() {send(reader,i==0 ? .leftMouseDown:.leftMouseDragged,p)}
        send(reader,.leftMouseUp,CGPoint(x:80,y:380))
        check(canvas.selectedShapes.count==1,"lasso selects a filled shape as one editable object")
        canvas.editSelectedShapes(width:4,fill:NSColor.systemPurple.withAlphaComponent(0.25))
        check(session.inkStrokes(on:page).last!.shape != nil && session.inkStrokes(on:page).last!.width==4,"lasso style edits preserve editable shape identity")
        send(reader,.leftMouseDown,CGPoint(x:130,y:440));send(reader,.leftMouseDragged,CGPoint(x:140,y:450));send(reader,.leftMouseUp,CGPoint(x:140,y:450))
        check(session.inkStrokes(on:page).last!.shape!.controls[0].x==110,"lasso movement translates shape controls and original hand drawing together")
        session.undo();session.undo();canvas.clearSelection()
        canvas.widths[.pen]=2.35;canvas.colors[.pen]=NSColor.systemPink.withAlphaComponent(0.72);canvas.rememberWritingPreferences(color:canvas.colors[.pen])
        let fresh=ReaderCanvas(frame:.zero)
        check(fresh.widths[.pen]==2.35 && fresh.colors[.pen]==canvas.colors[.pen] && fresh.recentColors.first==canvas.colors[.pen],"continuous width, tool color and recent color persist independently")
        canvas.shapeFillFollowsPen=true;canvas.shapeFill=NSColor.systemOrange.withAlphaComponent(0.2)
        canvas.colors[.pen]=NSColor.systemPurple;canvas.rememberWritingPreferences()
        let fill=canvas.effectiveShapeFill!.usingColorSpace(.sRGB)!,pen=canvas.colors[.pen]!.usingColorSpace(.sRGB)!
        check(fill.redComponent==pen.redComponent && fill.greenComponent==pen.greenComponent && fill.blueComponent==pen.blueComponent && fill.alphaComponent==0.2,"following fill takes current pen RGB and independent opacity")
        let restored=ReaderCanvas(frame:.zero)
        check(restored.shapeFillFollowsPen && restored.effectiveShapeFill==canvas.effectiveShapeFill,"follow-pen fill mode persists with its opacity")
        reader.disconnectInputAndViews()
    }
    static func anchoredSelection(_ root:URL)throws {
        let url=root.appendingPathComponent("fixed-anchors.pdf");try fixture(url)
        let session=try DocumentSession.open(url:url),reader=ReaderWindow(session:session,installInputMonitor:{_,_ in 1},removeInputMonitor:{_ in})
        let page=session.document.page(at:0)!,canvas=reader.canvas
        if let selection=page.selection(for:NSRange(location:0,length:4)) {_ = session.addTextSelection(selection,withNote:true)}
        _ = session.addRegion(page:page,rect:CGRect(x:100,y:400,width:60,height:30))
        let stroke=InkStroke(points:[InkPoint(x:150,y:430),InkPoint(x:200,y:450)],width:2,rgba:[0,0,1,1],kind:.pen)
        check(session.beginInkAction("movable ink"),"anchored selection fixture starts")
        session.replaceInk(on:page,ids:[],with:[stroke]);session.finishAction()
        let marks=session.annotations.marks,notes=session.annotations.notes,markIDs=Set(marks.map(\.id))
        check(marks.contains{$0.kind == .highlight} && marks.contains{$0.kind == .region},"fixture contains text highlight and region anchor")
        canvas.selectObjects(markIDs,on:page)
        check(canvas.selectedIDs.isEmpty,"fixed text/region anchors cannot be selected as movable objects")
        canvas.selectObjects(markIDs.union([stroke.id]),on:page)
        check(canvas.selectedIDs==[stroke.id],"mixed selection keeps only movable ink")
        canvas.rotateObjects(nil)
        check(session.annotations.marks==marks && session.annotations.notes==notes,"object rotation preserves text ranges, geometry and note anchors")
        session.undo();canvas.clearSelection();canvas.setTool(.lasso)
        let polygon=[CGPoint(x:10,y:10),CGPoint(x:600,y:10),CGPoint(x:600,y:780),CGPoint(x:10,y:780),CGPoint(x:10,y:10)]
        for (i,p) in polygon.enumerated(){send(reader,i==0 ? .leftMouseDown:.leftMouseDragged,p)}
        send(reader,.leftMouseUp,polygon.last!)
        check(canvas.selectedIDs==[stroke.id],"native lasso excludes enclosed highlights and region anchors")
        send(reader,.leftMouseDown,CGPoint(x:160,y:440));send(reader,.leftMouseDragged,CGPoint(x:180,y:460));send(reader,.leftMouseUp,CGPoint(x:180,y:460))
        check(session.inkStrokes(on:page)[0].points != stroke.points,"lasso still moves actual ink")
        check(session.annotations.marks==marks && session.annotations.notes==notes,"lasso move preserves text highlight and annotation anchors exactly")
        session.groupObjects(markIDs.union([stroke.id]))
        check(session.annotations.groups.isEmpty,"new groups cannot make fixed anchors indirectly movable")
        let legacyGroup=AnnotationGroup(members:[stroke.id,marks[0].id])
        var model=session.annotations;model.groups=[legacyGroup]
        check(model.movableSelection([stroke.id])==[stroke.id],"legacy mixed groups exclude fixed anchors during expansion")
        let pasteboard=NSPasteboard.withUniqueName();defer{pasteboard.releaseGlobally()}
        canvas.copyObjects(to:pasteboard)
        let clipboard=try JSONDecoder().decode(ObjectClipboard.self,from:pasteboard.data(forType:ObjectClipboard.type)!)
        check(clipboard.marks.isEmpty,"object clipboard does not detach text ranges or region anchors")
        try save(session)
        let reopened=try DocumentSession.open(url:url)
        check(reopened.annotations.marks==marks && reopened.annotations.notes==notes,"fixed anchors survive save/reopen after object movement")
        reader.disconnectInputAndViews()
    }

    static func main() throws {
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let delegate=AppDelegate();AppDelegate.shared=delegate
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/writing-tools-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);setenv("ECRU_DATA_DIR",root.appendingPathComponent("recovery").path,1)
        geometry();try feedback(root);try highlight(root);try canvas(root);try anchoredSelection(root);withExtendedLifetime(delegate) {}
        print("\(checks) writing-tool regression checks passed. Hardware acceptance remains manual.")
    }
}
