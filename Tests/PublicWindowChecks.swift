import AppKit
import PDFKit
import Darwin

/// Reproducible public UI regression: synthetic PDFs and an isolated data directory.
/// Compiled only into a test executable, never into Ecru.app.
enum UITestDriver {
    static var checks:[String]=[]
    static func expect(_ condition:Bool,_ text:String) throws {
        guard condition else {throw DocumentSessionError.io("UI CHECK FAILED: "+text)}
        checks.append(text);print("PASS: "+text);fflush(stdout)
    }
    static func settle(_ r:ReaderWindow) {
        r.window?.contentView?.layoutSubtreeIfNeeded();r.pdfView.layoutDocumentView()
        RunLoop.current.run(until:Date().addingTimeInterval(0.25))
    }
    static func drag(_ r:ReaderWindow,_ points:[CGPoint]) {
        let page=r.session.document.page(at:0)!
        for (i,p) in (points+[points.last!]).enumerated() {
            let type:NSEvent.EventType=i==0 ? .leftMouseDown : i==points.count ? .leftMouseUp : .leftMouseDragged
            let location=r.pdfView.convert(r.pdfView.convert(p,from:page),to:nil)
            let event=NSEvent.mouseEvent(with:type,location:location,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime+Double(i)/120,windowNumber:r.window!.windowNumber,context:nil,eventNumber:i,clickCount:1,pressure:1)!
            r.window!.sendEvent(event)
        }
    }
    static func run(input:URL,output:URL) {
        AppDelegate.shared.open(input);NSApp.activate(ignoringOtherApps:true)
        Timer.scheduledTimer(withTimeInterval:1,repeats:false) { _ in
            do {
                let r=AppDelegate.shared.activeReader!
                r.window?.makeKeyAndOrderFront(nil);settle(r)
                try expect(NSApp.isActive && r.window?.isKeyWindow == true,"native reader activates")
                try expect(r.window?.title==input.lastPathComponent && r.window?.subtitle=="","filename is the only window title")
                r.pdfView.autoScales=false;r.pdfView.scaleFactor=1;settle(r)
                let scroll=r.pdfView.documentView!.enclosingScrollView!
                let clip=scroll.contentView
                clip.scroll(to:NSPoint(x:0,y:scroll.documentView!.bounds.height-clip.bounds.height))
                scroll.reflectScrolledClipView(clip);settle(r)
                try expect(r.testPageField.stringValue==String(r.session.document.pageCount),"page indicator follows scrolling to the last page")
                clip.scroll(to:.zero);scroll.reflectScrolledClipView(clip);settle(r)
                try expect(r.testPageField.stringValue=="1","page indicator follows scrolling back to the first page")
                r.pdfView.go(to:r.session.document.page(at:1)!);settle(r)
                try expect(r.testPageField.stringValue=="2","page indicator follows a PDF page jump")
                r.pdfView.go(to:r.session.document.page(at:0)!);settle(r)
                for appearance in [NSAppearance.Name.aqua,.darkAqua] {
                    r.window?.appearance=NSAppearance(named:appearance)
                    for width in [820,1160,1440] {
                        r.window?.setFrame(NSRect(x:40,y:40,width:width,height:750),display:true);settle(r)
                        for tool in ReaderTool.allCases {
                            r.testSelectTool(tool);settle(r)
                            try expect(r.testInterfaceIssues.isEmpty,"\(appearance.rawValue) \(width) \(tool.title): centered title, visible controls, no overlap")
                        }
                    }
                }
                for screen in NSScreen.screens {
                    let visible=screen.visibleFrame
                    r.window?.setFrame(NSRect(x:visible.minX+20,y:visible.minY+20,width:min(1160,visible.width-40),height:min(750,visible.height-40)),display:true);settle(r)
                    try expect(r.testInterfaceIssues.isEmpty,"available display: toolbar survives screen placement and backing scale \(screen.backingScaleFactor)")
                }
                r.window?.appearance=nil;r.window?.setFrame(NSRect(x:40,y:40,width:1160,height:830),display:true)
                let page=r.session.document.page(at:0)!
                r.navigate(to:PDFDestination(page:page,at:CGPoint(x:0,y:792)))
                r.pdfView.autoScales=false;r.pdfView.scaleFactor=0.8;settle(r)
                r.testChooseZoom("200%");settle(r)
                try expect(abs(r.pdfView.scaleFactor-2)<0.001,"zoom preset enlarges the PDF to 200 percent")
                r.testChooseZoom("100%");settle(r)
                try expect(abs(r.pdfView.scaleFactor-1)<0.001,"zoom preset returns to 100 percent")
                let zoomCenter=r.canvas.convert(CGPoint(x:r.canvas.bounds.midX,y:r.canvas.bounds.midY),to:nil)
                let initialZoom=r.pdfView.scaleFactor
                for _ in 0..<120 {r.canvas.zoomPDF(logDelta:0.001,from:zoomCenter,to:zoomCenter)}
                try expect(abs(r.pdfView.scaleFactor/initialZoom-exp(0.12))<0.001 && r.testZoomMenuTitles.count<=9,"continuous zoom changes scale without accumulating percentage menu entries")
                r.testChooseZoom("适合宽度");settle(r)
                try expect(r.pdfView.autoScales,"fit width remains selectable after continuous zoom")
                r.testChooseZoom("适合页面");settle(r)
                try expect(!r.pdfView.autoScales && r.pdfView.scaleFactor>0 && r.testZoomMenuTitles.prefix(2)==["适合宽度","适合页面"],"fit page retains its preset and changes scale")
                r.pdfView.autoScales=false;r.pdfView.scaleFactor=0.8;settle(r)
                r.testSelectTool(.pen)
                drag(r,(0...70).map{CGPoint(x:120+Double($0)*2,y:360)})
                try expect(r.session.inkStrokes(on:page).count==1,"Google Ink writes one reversible stroke")
                r.undoAction();try expect(r.session.inkStrokes(on:page).isEmpty,"undo removes ink")
                r.redoAction();try expect(r.session.inkStrokes(on:page).count==1,"redo restores ink")
                r.testSelectTool(.eraser);drag(r,[CGPoint(x:190,y:360)])
                try expect(r.session.inkStrokes(on:page).count==2,"local eraser splits an editable stroke")
                let fragment=r.session.inkStrokes(on:page).min{$0.bounds.midX<$1.bounds.midX}!
                let box=fragment.bounds.insetBy(dx:-3,dy:-3)
                r.testSelectTool(.lasso);drag(r,[CGPoint(x:box.minX,y:box.minY),CGPoint(x:box.maxX,y:box.minY),CGPoint(x:box.maxX,y:box.maxY),CGPoint(x:box.minX,y:box.maxY),CGPoint(x:box.minX,y:box.minY)])
                try expect(r.canvas.selectedIDs==Set([fragment.id]),"lasso selects only one fragment")
                let id=r.canvas.selectedIDs.first!,old=r.session.inkStrokes(on:page).first{$0.id==id}!.points[0]
                drag(r,[CGPoint(x:140,y:360),CGPoint(x:165,y:385)])
                let moved=r.session.inkStrokes(on:page).first{$0.id==id}!.points[0]
                try expect(abs(moved.x-old.x-25)<0.01,"lasso moves selected ink")
                r.testSelectTool(.pen)
                r.testSearch("Ecru");try expect(r.testResultCount>0 && r.canvas.tool == .pen,"search preserves the active tool")
                r.hideSearch();settle(r)
                r.testSelectTool(.select)
                let selection=page.selection(for:NSRange(location:0,length:12))!
                r.pdfView.setCurrentSelection(selection,animate:false);r.selectionChanged();r.addNoteFromSelection()
                r.noteCard.startEditing();r.noteCard.editor.insertText("Public regression **note**: $x^2$",replacementRange:NSRange(location:0,length:0));r.noteCard.commit();settle(r)
                try expect(r.session.annotations.notes.count==1,"anchored Markdown note commits")
                r.noteCard.dismiss()
                // Save As refreshes the visible title and document proxy together.
                let renamed=output.deletingLastPathComponent().appendingPathComponent("Research notes - a deliberately long document title for toolbar truncation.pdf")
                var saved:Result<SaveOutcome,Error>?
                r.session.save(to:renamed){saved=$0}
                let deadline=Date().addingTimeInterval(15)
                while saved==nil && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
                guard let saved else {throw DocumentSessionError.io("Save timed out")};_ = try saved.get();settle(r)
                r.window?.setFrame(NSRect(x:40,y:40,width:820,height:592),display:true);settle(r)
                try expect(r.window?.title==renamed.lastPathComponent && r.window?.subtitle=="" && r.window?.representedURL==renamed && r.testInterfaceIssues.isEmpty,"Save As updates a long centered filename without version or overlap")
                let reopened=try DocumentSession.open(url:renamed)
                try expect(reopened.inkStrokes(on:reopened.document.page(at:0)!).count==2 && reopened.annotations.notes.count==1,"PDF alone reopens editable ink and notes")
                let runtime=InkRuntimeReport.configuration
                try expect(runtime["sourceSHA256"] as? String=="72c5687901ca5e19cc66b9918412b6fd921869a8d9671710ccc506e179b0abfe","frozen Google Ink position model is unchanged")
                let versionData=try Data(contentsOf:URL(fileURLWithPath:"Scripts/Info.plist"))
                let versionInfo=try PropertyListSerialization.propertyList(from:versionData,format:nil) as! [String:Any]
                try expect(runtime["build"] as? Int==Int(versionInfo["CFBundleVersion"] as! String) && runtime["version"] as? String==versionInfo["EcruReleaseVersion"] as? String,"executing native archive matches the source release version")
                #if arch(x86_64)
                let executingArchitecture="x86_64"
                #else
                let executingArchitecture="arm64"
                #endif
                var translated:Int32=0,size=MemoryLayout<Int32>.size
                _ = sysctlbyname("sysctl.proc_translated",&translated,&size,nil,0)
                let report:[String:Any]=["passed":checks.count,"checks":checks,"error":NSNull(),"architecture":executingArchitecture,"rosetta":translated==1,"displayCount":NSScreen.screens.count]
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output)
                NSApp.terminate(nil)
            } catch {
                fputs("\(error)\n",stderr);exit(1)
            }
        }
    }
}
