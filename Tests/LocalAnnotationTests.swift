import AppKit
import PDFKit
import CryptoKit

@main enum LocalAnnotationTests {
    static var checks=0
    static func check(_ ok:Bool,_ message:String) {precondition(ok,message);checks+=1;print("PASS: "+message);fflush(stdout)}
    static func save(_ s:DocumentSession) throws {
        var result:Result<SaveOutcome,Error>?
        s.save{result=$0};while result==nil {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
        _=try result!.get()
    }
    static func main() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        if CommandLine.arguments.count>1 {
            let file=URL(fileURLWithPath:CommandLine.arguments[1])
            let s=try DocumentSession.open(url:file)
            check(s.usesLocalAnnotations && s.annotations.notes.first?.markdown=="Shared **note**","fresh process automatically opens durable notes")
            check(s.annotations.ink[0].count==1 && s.annotations.images.count==1,"fresh process restores ink and image asset")
            return
        }
        let dir=root.appendingPathComponent(".build/local-annotations/run-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        setenv("ECRU_DATA_DIR",dir.appendingPathComponent("data").path,1)
        let names=["mixed-zero-offset","duplicate-keys","recoverable-xref","active","active-rotated","signed","password","restricted","print-denied"]
        for name in names {
            let file=dir.appendingPathComponent(name+".pdf")
            try FileManager.default.copyItem(at:root.appendingPathComponent(".build/complex-pdf/fixtures/"+name+".pdf"),to:file)
            let original=try Data(contentsOf:file)
            let s=try DocumentSession.open(url:file,password:name=="password" ? "reader-secret":nil)
            check(s.usesLocalAnnotations && !s.annotationReadOnly,name+" can annotate without rewriting original")
            let p=s.document.page(at:0)!
            let id=s.addRegion(page:p,rect:CGRect(x:40,y:400,width:90,height:30))!
            s.editBody(id,markdown:"Shared **note**");s.finishAction()
            let stroke=InkStroke(points:[InkPoint(x:50,y:300),InkPoint(x:150,y:320)],width:3,rgba:[0,0,1,1],kind:.pen)
            check(s.beginInkAction("local ink"),name+" ink starts")
            s.replaceInk(on:p,ids:[],with:[stroke]);s.finishAction()
            s.undo();check(s.inkStrokes(on:p).isEmpty,name+" undo")
            s.redo();check(s.inkStrokes(on:p)==[stroke],name+" redo")
            if name=="mixed-zero-offset" {
                let pixels=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:32,pixelsHigh:32,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
                for y in 0..<32 {for x in 0..<32 {pixels.setColor(.systemBlue,atX:x,y:y)}}
                let image=try ImageImport.normalize(pixels.representation(using:.png,properties:[:])!)
                _=try s.insertImage(image,on:p,rect:CGRect(x:200,y:400,width:60,height:60))
            }
            try save(s)
            check(!s.isModified,name+" durable save is clean")
            let expected=s.annotations
            let next=try DocumentSession.open(url:file,password:name=="password" ? "reader-secret":nil)
            check(next.usesLocalAnnotations && next.annotations==expected,name+" reopens exact local model")
            check(next.recoverableRecord==nil && next.discardRecovery(),name+" ordinary close keeps permanent notes")
            check(try DocumentSession.open(url:file,password:name=="password" ? "reader-secret":nil).annotations==expected,name+" notes survive close cleanup")
            let share=dir.appendingPathComponent(name+"-shared.pdf")
            if name=="print-denied" {
                do {try next.exportLocalAnnotations(to:share);check(false,"printing restriction bypass")}catch {check(!FileManager.default.fileExists(atPath:share.path),"export respects printing restriction")}
            } else {
                try next.exportLocalAnnotations(to:share)
                let plain=PDFDocument(url:share)!
                check(!plain.isEncrypted && plain.pageCount==s.document.pageCount,name+" recipient opens standard PDF")
                let projections=(0..<plain.pageCount).flatMap{plain.page(at:$0)!.annotations}
                check(projections.contains{$0.contents=="Shared **note**"},name+" standard PDF comment contains note text")
                check(projections.contains{InkAnnotationCodec.stroke(from:$0)==stroke},name+" standard PDF contains ink projection")
                let editable=try DocumentSession.open(url:share)
                check(!editable.usesLocalAnnotations && !editable.annotationReadOnly && editable.annotations.notes.first?.markdown=="Shared **note**",name+" recipient needs no local store")
                check(editable.annotations.images.count==s.annotations.images.count,name+" exported image is self-contained")
                check(editable.annotations.notes.first?.locationUncertain==false,name+" exported note location remains valid")
                do {try next.exportLocalAnnotations(to:share);check(false,"overwrite existing share")}catch {check(true,"existing export protected")}
            }
            check(try Data(contentsOf:file)==original,name+" original bytes unchanged")
            if name=="mixed-zero-offset" {
                let child=Process();child.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);child.arguments=[file.path]
                try child.run();child.waitUntilExit();check(child.terminationStatus==0,"independent restart restores notes")
                // Changed source bytes select a different notebook; old notes remain preserved.
                try (original+Data("\n% external change\n".utf8)).write(to:file)
                check(try DocumentSession.open(url:file).annotations.notes.isEmpty,"external file change does not misapply old notes")
                try original.write(to:file)
                check(try DocumentSession.open(url:file).annotations==expected,"matching source recovers preserved notebook")
                // Undo back to a previously saved revision must supersede an in-flight save.
                let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
                s.recoveryWriteHook={entered.signal();release.wait()}
                s.editBody(id,markdown:"Temporary note");s.finishAction()
                check(entered.wait(timeout:.now()+3) == .success,"autosave worker entered")
                s.recoveryWriteHook=nil;s.undo();release.signal();try save(s)
                check(try DocumentSession.open(url:file).annotations==expected,"undo supersedes queued autosave")
                s.recoveryStageHook={stage in if stage=="before-head" {throw POSIXError(.ENOSPC)}}
                s.editBody(id,markdown:"Uncommitted note");s.finishAction()
                do {try save(s);check(false,"disk-full save should fail")}catch {check(s.isModified,"disk-full keeps dirty notes in memory")}
                check(try DocumentSession.open(url:file).annotations==expected,"failed save leaves last complete notebook")
                s.recoveryStageHook=nil;try save(s)
                check(try DocumentSession.open(url:file).annotations.notes.first?.markdown=="Uncommitted note","retry durably saves retained notes")
                let concurrent=try DocumentSession.open(url:file)
                concurrent.editBody(id,markdown:"Other window note");concurrent.finishAction();try save(concurrent)
                s.editBody(id,markdown:"Conflicting note");s.finishAction()
                do {try save(s);check(false,"concurrent overwrite must fail")}catch {check(s.isModified,"concurrent conflict retains editable notes")}
                check(try DocumentSession.open(url:file).annotations.notes.first?.markdown=="Other window note","another window's durable notes never overwritten")
                let rescue=dir.appendingPathComponent("conflict-rescue.pdf")
                try s.exportLocalAnnotations(to:rescue)
                check(try DocumentSession.open(url:rescue).annotations.notes.first?.markdown=="Conflicting note","sharing can rescue edits despite local-store conflict")
                check(s.discardUnsavedChanges(),"explicit discard can close after rescuing conflicted notes")
                check(try DocumentSession.open(url:file).annotations.notes.first?.markdown=="Other window note","discard never deletes another window's notes")
            }
        }
        for readonly in [false,true] {
            let file=dir.appendingPathComponent(readonly ? "readonly-source.pdf":"serializer-failure.pdf")
            try FileManager.default.copyItem(at:root.appendingPathComponent(".build/complex-pdf/fixtures/ordinary.pdf"),to:file)
            let original=try Data(contentsOf:file)
            if readonly {chmod(file.path,0o444)}
            let session=try DocumentSession.open(url:file)
            check(session.usesLocalAnnotations==readonly,"filesystem permissions select independent notes")
            let id=session.addRegion(page:session.document.page(at:0)!,rect:CGRect(x:40,y:350,width:60,height:30))!
            session.editBody(id,markdown:"Fallback note");session.finishAction()
            if !readonly {
                let exported=dir.appendingPathComponent("normal-share.pdf")
                try session.exportAnnotatedPDF(to:exported)
                check(session.fileURL==file && session.isModified,"normal sharing leaves current source and unsaved state intact")
                check(try DocumentSession.open(url:exported).annotations.notes.first?.markdown=="Fallback note","normal share is self-contained PDF")
                session.saveDataProvider={nil}
            }
            try save(session)
            check(session.usesLocalAnnotations,"failed PDF export switches to durable independent notes")
            check(try Data(contentsOf:file)==original,"fallback never changes original PDF")
            check(try DocumentSession.open(url:file).annotations.notes.first?.markdown=="Fallback note","fallback reopens saved notes automatically")
            if readonly {chmod(file.path,0o644)}
        }
        let clockFile=dir.appendingPathComponent("clock-store.json")
        let clockSource=dir.appendingPathComponent("readonly-source.pdf")
        let clockSession=try DocumentSession.open(url:clockSource)
        let base=try Data(contentsOf:clockSource)
        let fingerprint=SHA256.hash(data:base).map{String(format:"%02x",$0)}.joined()
        let store=RecoveryStore(),firstRevision=UUID()
        let first=RecoveryRecord(version:3,sourcePath:clockSource.path,originalFingerprint:fingerprint,pdfData:base,revision:firstRevision,updatedAt:Date().addingTimeInterval(3600),annotations:clockSession.annotations,independentStore:true)
        try store.commit(first,to:clockFile,isCurrent:{true})
        var changed=clockSession.annotations;changed.notes[0].markdown="After clock rollback"
        let second=RecoveryRecord(version:3,sourcePath:clockSource.path,originalFingerprint:fingerprint,pdfData:base,revision:UUID(),updatedAt:Date(),annotations:changed,independentStore:true,independentBaseRevision:firstRevision)
        try store.commit(second,to:clockFile,isCurrent:{true})
        check(try RecoveryStore.read(clockFile).annotations?.notes.first?.markdown=="After clock rollback","clock rollback cannot silently discard independent notes")
        print("\(checks) local annotation checks passed. Artifacts: \(dir.path)")
    }
}
