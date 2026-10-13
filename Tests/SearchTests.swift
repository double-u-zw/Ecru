import AppKit
import PDFKit
import CoreText
import Darwin

@main enum SearchTests {
    static var checks=0
    static func check(_ value:Bool,_ message:String) {checks+=1;if !value{fputs("FAIL: \(message)\n",stderr);exit(1)};print("PASS: "+message)}
    static func pdf(_ pages:[String?],width:CGFloat=612)->Data {
        let data=NSMutableData()
        let context=CGContext(consumer:CGDataConsumer(data:data)!,mediaBox:nil,nil)!
        for text in pages {
            var box=CGRect(x:0,y:0,width:width,height:792)
            context.beginPDFPage([kCGPDFContextMediaBox as String:Data(bytes:&box,count:MemoryLayout<CGRect>.size)] as CFDictionary)
            if let text {
                for row in 0..<30 {
                    context.textPosition=CGPoint(x:20,y:750-row*22)
                    let line=CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):CTFontCreateWithName("PingFang SC" as CFString,12,nil)]))
                    CTLineDraw(line,context)
                }
            } else {context.setFillColor(CGColor(gray:0.7,alpha:1));context.fill(CGRect(x:20,y:20,width:100,height:100))}
            context.endPDFPage()
        }
        context.closePDF();return data as Data
    }
    static func wait(_ condition:()->Bool) {
        let deadline=Date().addingTimeInterval(20)
        while !condition() && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
        check(condition(),"asynchronous operation completes within deadline")
    }
    static func main()throws {
        _ = NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        AppDelegate.shared=AppDelegate()
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/search-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);setenv("ECRU_DATA_DIR",root.appendingPathComponent("data").path,1)
        let bytes=pdf(Array(repeating:"needle alpha beta 中文搜索",count:420)),url=root.appendingPathComponent("long.pdf")
        try bytes.write(to:url)
        let session=try DocumentSession.open(url:url),reader=ReaderWindow(session:session)
        AppDelegate.shared.readers=[reader]
        let expected=session.document.findString("needle",withOptions:[.caseInsensitive]).count
        reader.testStartSearch("needle");reader.testStartSearch("alpha");reader.testStartSearch("needle")
        wait{reader.testSearchFinished}
        check(reader.testSearchTotal==expected && expected==12600,"continuous typing returns exact current query count")
        check(reader.testResultCount==PDFSearchCoordinator.resultLimit,"retained matches have a bounded display budget")
        reader.testMatch(0)
        check(reader.pdfView.highlightedSelections?.first?.string=="needle","worker ranges map to the displayed document's exact selection")
        reader.testSearch("中文搜索")
        check(reader.testSearchTotal==12600,"committed Chinese query returns correct results")
        reader.window?.makeFirstResponder(reader.testSearchField)
        guard let editor=reader.testSearchField.currentEditor() as? NSTextView else{fatalError("native search field editor unavailable")}
        editor.setMarkedText("完全不存在",selectedRange:NSRange(location:5,length:0),replacementRange:NSRange(location:0,length:editor.string.utf16.count))
        check(editor.hasMarkedText(),"native field editor carries an IME marked range")
        reader.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:reader.testSearchField))
        RunLoop.current.run(until:Date().addingTimeInterval(0.25))
        check(reader.testSearchTotal==12600,"ReaderWindow suppresses composed intermediate queries")
        editor.unmarkText()
        reader.controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:reader.testSearchField))
        wait{reader.testSearchFinished}
        check(reader.testSearchTotal==0,"unmarked Chinese text starts the committed query")
        reader.testStartSearch("alpha");reader.hideSearch();reader.testStartSearch("beta");wait{reader.testSearchFinished}
        check(reader.testSearchTotal==12600,"cancel then immediate search has no stale callback contamination")

        let engine=PDFSearchCoordinator();engine.configure(data:bytes,identity:UUID())
        var callbacks=0,done=false,gap=0.0,last=ProcessInfo.processInfo.systemUptime
        let timer=Timer(timeInterval:0.005,repeats:true){_ in let now=ProcessInfo.processInfo.systemUptime;gap=max(gap,(now-last)*1000);last=now};RunLoop.main.add(timer,forMode:.common)
        engine.search("needle",delay:0){progress in callbacks+=1;done=progress.finished}
        wait{done};timer.invalidate()
        check(callbacks>1,"results arrive progressively")
        check(gap<150,"large result collection leaves the main RunLoop responsive")
        let crowded=pdf([String(repeating:"needle ",count:400)],width:32000)
        let crowdedCount=PDFDocument(data:crowded)!.findString("needle",withOptions:[.caseInsensitive]).count
        check(crowdedCount>PDFSearchCoordinator.resultLimit,"single-page fixture has more matches than the result budget")
        engine.configure(data:crowded,identity:UUID());done=false;var retainedMatches=0
        engine.search("needle",delay:0){progress in
            retainedMatches += progress.matches.count
            if progress.finished{print("Single-page counts: \(progress.total) / \(crowdedCount)");check(progress.total==crowdedCount && progress.limited,"single-page many-match search preserves exact total with bounded collection");done=true}
        }
        wait{done}
        check(retainedMatches==PDFSearchCoordinator.resultLimit,"single-page search retains only the documented result budget")
        var compositionCallbacks=0
        engine.search("中",composing:true,delay:0){_ in compositionCallbacks+=1}
        RunLoop.current.run(until:Date().addingTimeInterval(0.25))
        check(compositionCallbacks==0,"marked IME input starts no partial query")
        // Use the known editable fixture for concurrent save/search. The large
        // CoreText stress sample may intentionally trigger conservative PDF protection.
        let editableURL=root.appendingPathComponent("editable.pdf")
        try FileManager.default.copyItem(at:URL(fileURLWithPath:"output/pdf/reader-test-original.pdf"),to:editableURL)
        let editable=try DocumentSession.open(url:editableURL)
        let editReader=ReaderWindow(session:editable,installInputMonitor:{_,_ in 1},removeInputMonitor:{_ in})
        AppDelegate.shared.readers.append(editReader)
        let matchCount=editable.document.findString("Ecru",withOptions:[.caseInsensitive]).count
        check(matchCount>0 && editable.beginInkAction("concurrent edit"),"edit remains available during search")
        editable.replaceInk(on:editable.document.page(at:0)!,ids:[],with:[InkStroke(points:[InkPoint(x:20,y:500),InkPoint(x:40,y:510)],width:1.6,rgba:[0,0,1,1],kind:.pen)]);editable.finishAction()
        editReader.testStartSearch("Ecru");var saved=false
        let saveStart=ProcessInfo.processInfo.systemUptime
        editable.save(to:root.appendingPathComponent("saved.pdf")){result in check((try? result.get()) != nil,"detached save validates while search runs");saved=true}
        check((ProcessInfo.processInfo.systemUptime-saveStart)*1000<100,"save captures values without blocking main PDF export")
        wait{saved && editReader.testSearchFinished}
        check(editReader.testSearchTotal==matchCount,"concurrent saved annotations do not change text matches")
        editReader.disconnectInputAndViews()
        let opener=DocumentOpenCoordinator();var opened=false
        let openStart=ProcessInfo.processInfo.systemUptime
        opener.open(editableURL){result in
            check(Thread.isMainThread,"prepared session ownership is delivered on main")
            check((try? result.get().document.pageCount)==editable.document.pageCount,"background open retains full document validation and page count")
            opened=true
        }
        check((ProcessInfo.processInfo.systemUptime-openStart)*1000<100,"open submission does not perform synchronous PDF checks")
        wait{opened}
        opener.open(url){_ in check(false,"cancelled loader must not reopen a closed application")}
        opener.cancelAll();opened=false
        opener.open(editableURL){result in check((try? result.get()) != nil,"new open works immediately after loader cancellation");opened=true}
        wait{opened}
        let invalid=root.appendingPathComponent("invalid.pdf");try Data("not a PDF".utf8).write(to:invalid)
        opened=false
        opener.open(invalid){result in if case .failure=result {check(true,"invalid PDF errors remain explicit on main")}else{check(false,"invalid PDF must fail")};opened=true}
        wait{opened}
        reader.window?.title="Private-test-document-987.pdf"
        InkRuntimeReport.record(window:reader.window,penDown:true)
        InkRuntimeReport.flush()
        wait{FileManager.default.fileExists(atPath:InkRuntimeReport.receiptURL.path)}
        let receipt=try String(contentsOf:InkRuntimeReport.receiptURL)
        check(!receipt.contains("Private-test-document-987.pdf") && !receipt.contains(root.path) && !receipt.contains("windowTitle"),"default runtime receipt omits titles, filenames and document paths")
        let diagnostics=root.appendingPathComponent("diagnostics");try FileManager.default.createDirectory(at:diagnostics,withIntermediateDirectories:true)
        for i in 0..<30 {let path=diagnostics.appendingPathComponent("\(i).json");try Data("{}".utf8).write(to:path);if i<10{try FileManager.default.setAttributes([.modificationDate:Date().addingTimeInterval(-8*86400)],ofItemAtPath:path.path)}}
        try Data("preserved".utf8).write(to:diagnostics.appendingPathComponent("unrelated.pdf"))
        InkRuntimeReport.cleanup(at:diagnostics)
        check(try FileManager.default.contentsOfDirectory(at:diagnostics,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}.count<=16,"runtime diagnostic retention has a bounded process count")
        InkRuntimeReport.cleanup(at:diagnostics,clear:true)
        check(try FileManager.default.contentsOfDirectory(at:diagnostics,includingPropertiesForKeys:nil).map(\.lastPathComponent)==["unrelated.pdf"],"explicit diagnostic cleanup preserves unrelated documents")
        let scan=pdf(Array(repeating:nil,count:15));engine.configure(data:scan,identity:UUID());done=false
        engine.search("needle",delay:0){progress in if progress.finished{check(progress.availability == .unsearchable && progress.total==0,"fully inspected scan has explicit unsearchable state");done=true}}
        wait{done}
        engine.configure(data:pdf([nil,"needle",nil]),identity:UUID());done=false
        engine.batchHook={Thread.sleep(forTimeInterval:0.09)}
        var observedUnknown=false
        engine.search("needle",delay:0){progress in
            if !progress.finished && progress.availability == .unknown {observedUnknown=true}
            if progress.finished{check(progress.availability == .searchable && progress.total==30,"mixed scan/text remains searchable after cache invalidation");done=true}
        }
        wait{done}
        check(observedUnknown,"uninspected later pages cannot be prematurely labeled unsearchable")
        engine.batchHook=nil
        done=false;engine.search("absent",delay:0){progress in if progress.finished{check(progress.availability == .searchable && progress.total==0,"no match does not mean no searchable text");done=true}};wait{done}
        reader.testStartSearch("needle");reader.disconnectInputAndViews()
        let count=reader.testResultCount;RunLoop.current.run(until:Date().addingTimeInterval(0.5))
        check(reader.testResultCount==count && reader.disconnected,"closed window rejects pending search callbacks")
        // Identity changes invalidate both availability and pending matches.
        engine.search("needle",delay:0){_ in check(false,"old document callback")}
        engine.configure(data:scan,identity:UUID());done=false
        engine.search("needle",delay:0){progress in if progress.finished{check(progress.total==0,"replacement document cannot receive old results");done=true}};wait{done}
        let privateGraph=PDFDocument(data:bytes)!
        check(privateGraph.findString("needle",withOptions:[.caseInsensitive]).count==session.document.findString("needle",withOptions:[.caseInsensitive]).count,"search leaves active PDF contents unchanged")
        print("\(checks) search checks passed; main RunLoop max gap \(gap) ms. Synthetic input; physical IME/hardware acceptance remains manual.")
    }
}
