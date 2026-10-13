import AppKit
import PDFKit
import Darwin

@main enum ComplexPDFWindowTests {
    static var checks=0
    static func check(_ ok:Bool,_ message:String) { precondition(ok,message);checks+=1;print("PASS: "+message) }
    // Explicit opt-in only: this part displays actual native password dialogs.
    static func passwordDialogs(_ root:URL,_ delegate:AppDelegate) throws {
        NSApp.setActivationPolicy(.regular)
        let url=root.appendingPathComponent(".build/complex-pdf/fixtures/password.pdf")
        let original=try Data(contentsOf:url)
        func response(_ secret:String?,_ code:NSApplication.ModalResponse,then next:(()->Void)?=nil) {
            let timer=Timer(timeInterval:0.25,repeats:false) { _ in
                guard let window=NSApp.modalWindow else {preconditionFailure("Expected password dialog")}
                func fields(_ view:NSView)->[NSSecureTextField] { (view as? NSSecureTextField).map{[$0]} ?? view.subviews.flatMap(fields) }
                let secure=fields(window.contentView!)
                check(secure.count == 1,"password dialog uses native secure field")
                secure[0].stringValue=secret ?? ""
                next?();NSApp.stopModal(withCode:code)
            }
            RunLoop.main.add(timer,forMode:.common)
        }
        func waitUntil(_ condition:()->Bool) {
            let deadline=Date().addingTimeInterval(10)
            while !condition() && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
            check(condition(),"asynchronous open/password decision completes")
        }
        response(nil,.alertSecondButtonReturn);delegate.open(url)
        waitUntil{!delegate.isDocumentOpening(url)}
        check(delegate.readers.isEmpty,"password cancellation opens no document")
        response("wrong",.alertFirstButtonReturn) { response("reader-secret",.alertFirstButtonReturn) }
        delegate.open(url)
        waitUntil{!delegate.isDocumentOpening(url)}
        check(delegate.readers.count == 1 && delegate.readers[0].session.annotationReadOnly,"native password error retries to unlocked read-only reader")
        delegate.readers.first?.window?.close()
        check(try Data(contentsOf:url)==original,"password dialog flow does not write source")
    }
    static func main() throws {
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited)
        let delegate=AppDelegate();AppDelegate.shared=delegate
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let dir=root.appendingPathComponent(".build/complex-pdf/window-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        setenv("ECRU_DATA_DIR",dir.path,1)
        for name in ["signed","password","restricted","xfa-static","active"] {
            let url=root.appendingPathComponent(".build/complex-pdf/fixtures/"+name+".pdf"),original=try Data(contentsOf:url)
            let session=try DocumentSession.open(url:url,password:name == "password" ? "reader-secret" : nil)
            let reader=ReaderWindow(session:session,installInputMonitor:{_,_ in NSObject()},removeInputMonitor:{_ in})
            check(reader.canvas.tool == .select,name+" defaults to reading selection")
            reader.selectTool(.pen);check(reader.canvas.tool == .select,name+" disabled pen cannot activate")
            check(reader.window?.subtitle.contains("只读") == true,name+" native window read-only state")
            for action in [reader.saveDocument,reader.saveDocumentAs] {
                action()
                check(reader.window?.attachedSheet != nil,name+" save command presents restriction before writing")
                if let sheet=reader.window?.attachedSheet {
                    func text(_ view:NSView)->[String] {
                        (view as? NSTextField).map{[$0.stringValue]} ?? view.subviews.flatMap(text)
                    }
                    check(text(sheet.contentView!).contains(session.capabilities.summary),name+" dialog explains actual restriction")
                    reader.window?.endSheet(sheet,returnCode:.abort)
                    RunLoop.current.run(until:Date().addingTimeInterval(0.02))
                }
            }
            let page=session.document.page(at:1)!;reader.navigate(to:PDFDestination(page:page,at:CGPoint(x:0,y:100)))
            check(reader.pdfView.document === session.document,name+" native PDFView is bound")
            check(reader.windowShouldClose(reader.window!),name+" read-only close does not need save")
            reader.disconnectInputAndViews();reader.window?.close()
            check(try Data(contentsOf:url)==original,name+" window lifecycle leaves file unchanged")
        }
        let session=try DocumentSession.open(url:root.appendingPathComponent(".build/complex-pdf/fixtures/acroform.pdf"))
        let reader=ReaderWindow(session:session,installInputMonitor:{_,_ in NSObject()},removeInputMonitor:{_ in})
        check(session.document.page(at:0)!.annotations.first{$0.type == "Widget"}?.isReadOnly == true,"native field editing disabled while annotations remain editable")
        reader.selectTool(.pen);check(reader.canvas.tool == .pen,"ordinary AcroForm annotation tools stay enabled")
        reader.disconnectInputAndViews();reader.window?.close()
        // A page copy can still belong to the live document. Rotation during
        // static export must never notify its thumbnail view/page observers.
        for name in ["active-rotated","xfa-static","combined"] {
            let source=root.appendingPathComponent(".build/complex-pdf/fixtures/"+name+".pdf")
            let original=try Data(contentsOf:source),session=try DocumentSession.open(url:source)
            let reader=ReaderWindow(session:session,installInputMonitor:{_,_ in NSObject()},removeInputMonitor:{_ in})
            reader.toggleSidebar()
            reader.window?.contentView?.layoutSubtreeIfNeeded()
            let rotations=(0..<session.document.pageCount).map{session.document.page(at:$0)!.rotation}
            var livePageNotifications=0
            let observer=NotificationCenter.default.addObserver(forName:nil,object:nil,queue:.main) { note in
                if let page=note.object as? PDFPage,page.document === session.document {livePageNotifications+=1}
            }
            let copy=dir.appendingPathComponent(name+"-window-static.pdf")
            try session.createStaticAnnotationCopy(to:copy)
            NotificationCenter.default.removeObserver(observer)
            check(livePageNotifications == 0,name+" static conversion does not notify live page observers")
            check(rotations == (0..<session.document.pageCount).map{session.document.page(at:$0)!.rotation},name+" live page rotations unchanged")
            let reopened=try DocumentSession.open(url:copy)
            check(reopened.capabilities.mode == .annotationCopy && reopened.capabilities.canEdit,name+" window-created static copy reopens editable")
            check(try Data(contentsOf:source)==original,name+" window conversion leaves original file unchanged")
            reader.disconnectInputAndViews();reader.window?.close()
        }
        if ProcessInfo.processInfo.environment["ECRU_PASSWORD_DIALOG_TEST"] == "1" { try passwordDialogs(root,delegate) }
        print("\(checks) native hidden-window compatibility checks passed")
    }
}
