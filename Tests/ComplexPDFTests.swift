import AppKit
import PDFKit
import CryptoKit
import Darwin

@main enum ComplexPDFTests {
    static var checks=0
    static func check(_ ok:Bool,_ label:String) { checks+=1; guard ok else { fatalError("FAIL: "+label) }; print("PASS: "+label);fflush(stdout) }
    static func save(_ s:DocumentSession,to url:URL?=nil)->Result<SaveOutcome,Error> {
        var result:Result<SaveOutcome,Error>?
        s.save(to:url) { result=$0 }
        let limit=Date().addingTimeInterval(20)
        while result == nil && Date()<limit { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        check(result != nil,"save completes");return result!
    }
    static func render(_ p:PDFPage,to url:URL) throws {
        let image=p.thumbnail(of:CGSize(width:612,height:792),for:.cropBox)
        guard let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else {fatalError("render")}
        try png.write(to:url)
    }
    static func main() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let fixtures=root.appendingPathComponent(".build/complex-pdf/fixtures")
        let dir=root.appendingPathComponent(".build/complex-pdf/run-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        setenv("ECRU_DATA_DIR",dir.appendingPathComponent("data").path,1)
        let sample=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:240,pixelsHigh:160,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        for y in 0..<160 {for x in 0..<240 {sample.setColor(NSColor.systemBlue.withAlphaComponent(x<20 ? 0:0.7),atX:x,y:y)}}
        let picture=try ImageImport.normalize(sample.representation(using:.png,properties:[:])!)
        for name in ["ordinary","rotated","acroform","attachments","form-attachments","false-signature-label","unused-zero-offset","xref-missing-self"] {
            let url=dir.appendingPathComponent(name+".pdf");try FileManager.default.copyItem(at:fixtures.appendingPathComponent(name+".pdf"),to:url)
            let original=try Data(contentsOf:url);let s=try DocumentSession.open(url:url)
            check(s.capabilities.mode == .fullEditing && !s.annotationReadOnly,name+" full editing")
            check(!s.document.findString("compatibility",withOptions:[]).isEmpty,name+" search")
            try render(s.document.page(at:0)!,to:dir.appendingPathComponent(name+"-before.png"))
            let id=s.addRegion(page:s.document.page(at:0)!,rect:CGRect(x:40,y:400,width:120,height:40))!
            s.editBody(id,markdown:"Synthetic **note** $x^2$");s.finishAction()
            let p=s.document.page(at:0)!
            let stroke=InkStroke(points:[InkPoint(x:50,y:300),InkPoint(x:150,y:320)],width:3,rgba:[0,0,1,1],kind:.pen)
            check(s.beginInkAction("synthetic ink"),"ink transaction");s.replaceInk(on:p,ids:[],with:[stroke]);s.finishAction()
            s.undo();check(s.inkStrokes(on:p).isEmpty,"undo ink");s.redo();check(s.inkStrokes(on:p)==[stroke],"redo ink")
            _=try s.insertImage(picture,on:p,rect:CGRect(x:200,y:420,width:120,height:80))
            let recovered=try DocumentSession.open(url:url);try recovered.restoreRecovery(s.recoverableRecord!)
            check(recovered.annotations==s.annotations,name+" crash recovery")
            check(try Data(contentsOf:url)==original,name+" source unchanged before save")
            _=try save(s).get()
            let saved=try Data(contentsOf:url)
            check(PDFPagePreservation.validate(original,saved:saved,removing:Array(repeating:[],count:2)),name+" entire original object graph preserved")
            let reopened=try DocumentSession.open(url:url)
            check(reopened.annotations==s.annotations && !reopened.annotationReadOnly,name+" model reopens editable")
            check(!reopened.document.findString("compatibility",withOptions:[]).isEmpty,name+" search after save")
            try render(reopened.document.page(at:0)!,to:dir.appendingPathComponent(name+"-after.png"))
            let copy=dir.appendingPathComponent(name+"-save-as.pdf");_=try save(reopened,to:copy).get()
            check(try Data(contentsOf:url)==saved,name+" save-as leaves source unchanged")
            // Subsequent save must replace managed slots, retaining foreign widgets/attachments.
            let next=try DocumentSession.open(url:copy);next.editBody(id,markdown:"Updated note");next.finishAction();_=try save(next).get()
            check(try DocumentSession.open(url:copy).annotations.notes.first?.markdown=="Updated note",name+" second save")
        }
        for name in ["password","password-rc4"] {
            let url=fixtures.appendingPathComponent(name+".pdf")
            do {_=try DocumentSession.open(url:url);check(false,"password required")}catch DocumentSessionError.passwordRequired {check(true,name+" password required")}
            do {_=try DocumentSession.open(url:url,password:"wrong");check(false,"wrong password rejected")}catch DocumentSessionError.incorrectPassword {check(true,name+" wrong password retry")}
            let s=try DocumentSession.open(url:url,password:"reader-secret")
            check(s.capabilities.features & 1 != 0 && s.annotationReadOnly && !s.document.isLocked,name+" unlocked read-only")
            check(!s.document.findString("compatibility",withOptions:[]).isEmpty,name+" unlocked search")
            try render(s.document.page(at:0)!,to:dir.appendingPathComponent(name+".png"))
        }
        for name in ["password","restricted","signed","xfa-static","active","automatic-uri","active-rotated","portfolio","combined"] {
            let url=fixtures.appendingPathComponent(name+".pdf"),original=try Data(contentsOf:url)
            let s=try DocumentSession.open(url:url,password:name == "password" ? "reader-secret" : nil)
            check(s.annotationReadOnly && !s.capabilities.canEdit && !s.isModified,name+" read-only clean")
            check(!s.document.findString("compatibility",withOptions:[]).isEmpty,name+" read-only search")
            check(!s.beginAction("blocked") && !s.beginInkAction("blocked") && s.addRegion(page:s.document.page(at:0)!,rect:CGRect(x:20,y:20,width:30,height:30)) == nil,name+" mutations blocked")
            do {_=try s.insertImage(picture,on:s.document.page(at:0)!,rect:CGRect(x:30,y:30,width:100,height:60));check(false,name+" image mutation blocked")}catch{check(s.annotations.images.isEmpty,name+" image mutation blocked")}
            s.undo();s.redo();s.checkpointRecovery();check(!s.isModified && s.recoverableRecord == nil,name+" no new recovery")
            if case .success=save(s) {check(false,"protected save rejected")};if case .success=save(s,to:dir.appendingPathComponent("blocked-"+name+".pdf")){check(false,"protected save-as rejected")}
            check(!FileManager.default.fileExists(atPath:dir.appendingPathComponent("blocked-"+name+".pdf").path),name+" no write on save-as")
            let copy=dir.appendingPathComponent(name+"-static.pdf")
            if s.capabilities.canCreateStaticCopy {
                try s.createStaticAnnotationCopy(to:copy);let c=try DocumentSession.open(url:copy)
                check(c.capabilities.mode == .annotationCopy && c.capabilities.canEdit && c.capabilities.features == 0,name+" inert static copy editable")
                check(!c.document.findString("compatibility",withOptions:[]).isEmpty,name+" static copy searchable")
                try render(c.document.page(at:0)!,to:dir.appendingPathComponent(name+"-copy.png"))
                let id=c.addRegion(page:c.document.page(at:0)!,rect:CGRect(x:30,y:350,width:40,height:40))!;c.editBody(id,markdown:"Copy note");c.finishAction();_=try save(c).get()
                check(try DocumentSession.open(url:copy).annotations.notes.first?.markdown=="Copy note",name+" static copy save/reopen")
                do {try s.createStaticAnnotationCopy(to:url);check(false,"copy must not overwrite")}catch {check(true,"copy overwrite blocked")}
            } else {do {try s.createStaticAnnotationCopy(to:copy);check(false,"unsupported copy rejected")}catch {check(true,name+" no permission/signature bypass")}}
            try render(s.document.page(at:0)!,to:dir.appendingPathComponent(name+".png"))
            check(try Data(contentsOf:url)==original,name+" original byte immutability")
        }
        for name in ["damaged","truncated"] {do{_=try DocumentSession.open(url:fixtures.appendingPathComponent(name+".pdf"));check(false,"damaged rejection")}catch{check(true,name+" safely rejected")}}
        for name in ["referenced-zero-offset","nested-zero-offset","array-zero-offset","indirect-array-zero-offset","trailer-zero-offset","orphan-reference-zero-offset","mixed-zero-offset","duplicate-keys","invalid-token","recoverable-xref","xref-mixed-warning","xref-wrong-size"] {
            let url=fixtures.appendingPathComponent(name+".pdf"),original=try Data(contentsOf:url)
            let s=try DocumentSession.open(url:url)
            check(s.capabilities.features & 256 != 0 && s.annotationReadOnly,name+" remains structurally protected")
            check(!s.beginInkAction("blocked"),name+" original cannot be edited")
            let ordinary=try Data(contentsOf:fixtures.appendingPathComponent("ordinary.pdf"))
            check(PDFPagePreservation.preserve(original,in:ordinary,removing:[[],[]]) == nil,name+" native writer refuses damage")
            if case .success=save(s) {check(false,name+" save rejected")}
            check(s.capabilities.canCreateStaticCopy,name+" offers general visible-page fallback")
            let copy=dir.appendingPathComponent(name+"-static.pdf")
            try s.createStaticAnnotationCopy(to:copy)
            let editable=try DocumentSession.open(url:copy)
            check(editable.capabilities.mode == .annotationCopy && !editable.annotationReadOnly,name+" verified copy editable")
            check(!editable.document.findString("compatibility",withOptions:[]).isEmpty,name+" copy retains searchable text")
            let note=editable.addRegion(page:editable.document.page(at:0)!,rect:CGRect(x:30,y:350,width:40,height:40))!
            editable.editBody(note,markdown:"Compatibility fallback note");editable.finishAction();_=try save(editable).get()
            check(try DocumentSession.open(url:copy).annotations.notes.first?.markdown=="Compatibility fallback note",name+" fallback saves and reopens")
            do {try s.createStaticAnnotationCopy(to:url);check(false,name+" copy must not overwrite original")}catch {check(true,name+" original overwrite rejected")}
            do {try s.createStaticAnnotationCopy(to:copy);check(false,name+" copy must not overwrite existing file")}catch {check(true,name+" existing copy overwrite rejected")}
            check(try Data(contentsOf:url)==original,name+" source unchanged")
        }
        for flags:UInt32 in [1|256,2|256,128|256] {
            check(!PDFCapabilities.assess(flags,allowsCommenting:true,allowsPrinting:true).canCreateStaticCopy,"structural fallback retains encryption/signature/rights restriction \(flags)")
        }
        check(!PDFCapabilities.assess(256,allowsCommenting:false,allowsPrinting:true).canCreateStaticCopy,"structural fallback retains annotation permission")
        check(!PDFCapabilities.assess(256,allowsCommenting:true,allowsPrinting:false).canCreateStaticCopy,"structural fallback retains printing permission")
        for (source,tampered) in [("acroform","tampered-form"),("attachments","tampered-attachment")] {
            let original=try Data(contentsOf:fixtures.appendingPathComponent(source+".pdf")),changed=try Data(contentsOf:fixtures.appendingPathComponent(tampered+".pdf"))
            check(!PDFPagePreservation.validate(original,saved:changed,removing:[[],[]]),source+" rejects damaged field/attachment objects despite renderable PDF")
        }
        // Protected documents retain older recovery data even through close/discard.
        let signed=fixtures.appendingPathComponent("signed.pdf"),source=try Data(contentsOf:signed)
        let record=RecoveryRecord(version:1,sourcePath:signed.path,originalFingerprint:"synthetic",pdfData:source,revision:UUID(),updatedAt:Date())
        let hash=SHA256.hash(data:Data(signed.path.utf8)).map{String(format:"%02x",$0)}.joined()
        let recordURL=dir.appendingPathComponent("data/Recovery/"+hash+".json");try FileManager.default.createDirectory(at:recordURL.deletingLastPathComponent(),withIntermediateDirectories:true)
        let draft=try JSONEncoder().encode(record);try draft.write(to:recordURL)
        let s=try DocumentSession.open(url:signed)
        do{try s.restoreRecovery(record);check(false,"protected restore rejected")}catch{check(true,"protected recovery restore rejected")}
        check(try s.discardRecovery() && Data(contentsOf:recordURL)==draft,"protected close preserves previous recovery")
        print("\(checks) complex PDF checks passed. Artifacts: \(dir.path)")
    }
}
