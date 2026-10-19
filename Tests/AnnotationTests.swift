import AppKit
import PDFKit
import Darwin

@main enum AnnotationTests {
    static var checks=0
    static func check(_ b: @autoclosure ()->Bool,_ s:String) { checks+=1; if !b(){fatalError("FAIL: "+s)}; print("PASS: "+s); fflush(stdout) }
    static func save(_ s:DocumentSession) throws {
        var result:Result<SaveOutcome,Error>?
        s.save {result=$0}; let limit=Date().addingTimeInterval(15)
        while result == nil && Date()<limit { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        if case .failure = result!, EcruEnvironment.value("ECRU_TEST_DIAGNOSTICS") == "1" {
            let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
            try? Data(contentsOf:s.fileURL).write(to:root.appendingPathComponent(".build/pdf-save-annotation-original.pdf"))
            try? s.portableDocument()?.dataRepresentation()?.write(to:root.appendingPathComponent(".build/pdf-save-annotation-export.pdf"))
        }
        _ = try result!.get()
    }
    static func main() throws {
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
        let dir=root.appendingPathComponent(".build/annotation-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        setenv("ECRU_DATA_DIR",dir.appendingPathComponent("data").path,1)
        let url=dir.appendingPathComponent("notes.pdf")
        try FileManager.default.copyItem(at:root.appendingPathComponent("output/pdf/reader-test-original.pdf"),to:url)
        let original=try Data(contentsOf:url)
        let s=try DocumentSession.open(url:url)
        let page=s.document.page(at:0)!
        let id=s.addRegion(page:page,rect:CGRect(x:30,y:50,width:160,height:70))!
        let body="# 定理解释\n\n中文 **证明** $\\int_0^1 x^2 dx$\n\n$$\\begin{aligned}a&=b\\\\c&=d\\end{aligned}$$\n\n$$\\begin{cases}x^2&x>0\\\\0&x\\le0\\end{cases}$$\n\n$$\\begin{pmatrix}1&2\\\\3&4\\end{pmatrix}$$"
        s.editBody(id,markdown:body);s.finishAction()
        let unchanged = try Data(contentsOf:url); check(unchanged==original,"editing never rewrites source")
        let recovery=s.recoverableRecord!
        let recovered=try DocumentSession.open(url:url); try recovered.restoreRecovery(recovery)
        check(recovered.annotations.notes.first?.markdown==body,"body and region draft recovery")
        try save(s)
        let reopened=try DocumentSession.open(url:url)
        check(!reopened.annotationReadOnly,"new format opens editable")
        if reopened.annotations != s.annotations, EcruEnvironment.value("ECRU_TEST_DIAGNOSTICS") == "1" {
            print("EXPECTED MODEL", try AnnotationPDF.encode(s.annotations))
            print("ACTUAL MODEL", try AnnotationPDF.encode(reopened.annotations))
            print("WARNINGS", reopened.annotationWarnings)
            fflush(stdout)
        }
        check(reopened.annotations==s.annotations,"full authoritative data roundtrip")
        let originalPopups = PDFDocument(data:original)!.page(at:0)!.annotations.filter { $0.type == "Popup" }.count
        check(reopened.document.page(at:0)!.annotations.filter { $0.type == "Popup" }.count == originalPopups,
              "reopening removes generated note popups from the editing layer")
        let selection=PDFSelection(document:s.document)
        for i in 0..<min(2,s.document.pageCount) { let p=s.document.page(at:i)!; if let part=p.selection(for:p.bounds(for:.cropBox)){selection.add(part)} }
        let cross=s.addTextSelection(selection,withNote:true)!
        check(s.annotations.notes.filter{$0.id==cross}.count==1,"cross page one logical note")
        check(Set(s.annotations.notes.last!.anchors.map(\.page)).count==2,"cross page preserves fragments")
        check(s.annotations.marks.filter{$0.contents.isEmpty}.allSatisfy{AnnotationPDF.make($0).contents == nil},"empty page marks do not create spurious PDF note icons")
        let count=s.annotations.marks.count
        let first=s.annotations.notes.last!.links[0].markID
        check(s.annotateMarks([first])==cross && s.annotations.marks.count==count,"existing highlight body never duplicates marks")
        s.editBody(cross,markdown:"跨页正文");s.finishAction();s.editBody(cross,markdown:"");s.finishAction()
        check(s.annotations.marks.count==count,"clear body retains all marks")
        s.undo();check(s.annotations.notes.last!.markdown=="跨页正文","body clear undo")
        let stroke=InkStroke(points:[InkPoint(x:60,y:300),InkPoint(x:200,y:300)],width:3,rgba:[0,0,1,1],kind:.pen)
        s.beginInkAction("write");s.replaceInk(on:page,ids:[],with:[stroke]);s.finishAction()
        let inkNote=s.annotateMarks([stroke.id])!
        s.editBody(inkNote,markdown:"笔迹解释");s.finishAction()
        s.referenceMarks([stroke.id],to:id)
        check(s.annotations.notes.first{$0.id==id}!.links.contains{ $0.markID==stroke.id && !$0.owned },"references never acquire deletion ownership")
        s.deleteNote(id);check(s.inkStrokes(on:page).contains{$0.id==stroke.id},"deleting referencing note preserves other owned ink")
        s.undo();check(s.annotations.notes.contains{$0.id==id},"undo restores reference note and owned region")
        let pieces=InkGeometry.erase(stroke,center:CGPoint(x:130,y:300),radius:12)
        s.beginInkAction("erase");s.replaceInk(on:page,ids:[stroke.id],with:pieces);s.finishAction()
        check(pieces.count==2 && Set(s.annotations.notes.last!.links.map(\.markID))==Set(pieces.map(\.id)),"split fragments inherit ownership")
        s.beginInkAction("erase all");s.replaceInk(on:page,ids:Set(pieces.map(\.id)),with:[]);s.finishAction()
        check(!s.annotations.hasMarks(s.annotations.notes.last!) && s.annotations.notes.last!.markdown=="笔迹解释","complete erase keeps body and anchors")
        try save(s);let orphan=try DocumentSession.open(url:url)
        check(orphan.annotations.notes.last!.markdown=="笔迹解释" && !orphan.annotations.hasMarks(orphan.annotations.notes.last!),"orphan note roundtrip")
        s.undo();check(s.annotations.notes.last!.links.count==2,"undo restores split association")
        s.deleteNote(inkNote);check(s.inkStrokes(on:page).isEmpty,"delete note removes owned fragments")
        s.undo();check(s.annotations.notes.last!.id==inkNote && s.inkStrokes(on:page)==pieces,"delete undo restores complete note")
        s.redo();s.undo();try save(s)
        let another=InkStroke(points:[InkPoint(x:230,y:310),InkPoint(x:280,y:310)],width:3,rgba:[0,0,1,1],kind:.pen)
        s.beginInkAction("another stroke");s.replaceInk(on:page,ids:[],with:[another]);s.finishAction()
        let anotherNote=s.annotateMarks([another.id])!
        let moving=pieces+[another]
        s.beginInkAction("move multiple associations");s.replaceInk(on:page,ids:Set(moving.map(\.id)),with:moving.map{$0.translated(dx:4,dy:3)});s.finishAction()
        check(s.annotations.notes.first{$0.id==anotherNote}!.links.map(\.markID)==[another.id],"multi-stroke move retains individual note associations")
        check(Set(s.annotations.notes.first{$0.id==inkNote}!.links.map(\.markID))==Set(pieces.map(\.id)),"multi-stroke move never acquires another note ownership")
        s.undo();s.undo();s.undo();try save(s)
        let bodyBeforeSave=s.annotations.notes.first{$0.id==id}!.markdown
        let gate=DispatchSemaphore(value:0);s.saveWorkHook={gate.wait()}
        var concurrent:Result<SaveOutcome,Error>?
        s.save {concurrent=$0}
        s.editBody(id,markdown:"并发保存之后的新正文");s.finishAction();gate.signal();s.saveWorkHook=nil
        let saveDeadline=Date().addingTimeInterval(15)
        while concurrent == nil && Date()<saveDeadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
        _ = try concurrent!.get()
        check(s.isModified,"typing during save remains unsaved")
        let savedSnapshot=try DocumentSession.open(url:url)
        check(savedSnapshot.annotations.notes.first{$0.id==id}!.markdown==bodyBeforeSave,"save confirms only captured body revision")
        try save(s)
        let saved=try Data(contentsOf:url)
        func mutate(_ name:String,_ change:(PDFDocument)->Void)throws->DocumentSession {
            let pdf=PDFDocument(data:saved)!;change(pdf);let u=dir.appendingPathComponent(name+".pdf");try pdf.dataRepresentation()!.write(to:u);return try DocumentSession.open(url:u)
        }
        let missing=try mutate("missing-fragment") { pdf in
            let p=pdf.page(at:0)!;if let a=p.annotations.first(where:{$0.value(forAnnotationKey:AnnotationPDF.markKey) != nil}){p.removeAnnotation(a)}
        }
        check(!missing.annotationReadOnly && !missing.annotationWarnings.isEmpty,"external fragment deletion detected without readonly")
        let remaining=missing.annotations.allMarkIDs.count;try save(missing)
        let missingReopen = try DocumentSession.open(url:missing.fileURL); check(missingReopen.annotations.allMarkIDs.count==remaining,"external deletion never resurrects")
        let conflict=try mutate("changed-body") { pdf in
            pdf.page(at:0)!.annotations.first(where:{$0.value(forAnnotationKey:AnnotationPDF.noteKey) != nil})?.contents="外部修改"
        }
        check(conflict.annotationReadOnly,"external standard body conflict is protected")
        let noManifest=try mutate("missing-manifest") { pdf in
            let p=pdf.page(at:0)!;for a in p.annotations where a.value(forAnnotationKey:AnnotationPDF.manifest) != nil {p.removeAnnotation(a)}
        }
        check(noManifest.annotationReadOnly && !noManifest.annotations.notes.isEmpty,"missing manifest recovers plain body read-only")
        let duplicate=try mutate("duplicate") { pdf in
            let p=pdf.page(at:0)!;let a=p.annotations.first(where:{$0.value(forAnnotationKey:AnnotationPDF.manifest) != nil})!
            let b=PDFAnnotation(bounds:.zero,forType:.text,withProperties:nil);b.setValue(a.value(forAnnotationKey:AnnotationPDF.manifest)!,forAnnotationKey:AnnotationPDF.manifest);p.addAnnotation(b)
        }
        check(duplicate.annotationReadOnly,"duplicate manifests never choose first or last")
        let repeatedMark=try mutate("duplicate-mark") { pdf in
            let p=pdf.page(at:0)!;let original=p.annotations.first(where:{$0.value(forAnnotationKey:AnnotationPDF.markKey) != nil})!
            let duplicate=PDFAnnotation(bounds:original.bounds,forType:.square,withProperties:nil)
            duplicate.setValue(original.value(forAnnotationKey:AnnotationPDF.markKey)!,forAnnotationKey:AnnotationPDF.markKey);p.addAnnotation(duplicate)
        }
        check(repeatedMark.annotationReadOnly,"conflicting duplicate marker IDs never select one copy")
        let corrupt=try mutate("corrupt") {pdf in pdf.page(at:0)!.annotations.first(where:{$0.value(forAnnotationKey:AnnotationPDF.manifest) != nil})!.setValue("broken",forAnnotationKey:AnnotationPDF.manifest)}
        check(corrupt.annotationReadOnly,"corrupt payload protected")
        let future=try mutate("future") {pdf in
            let a=pdf.page(at:0)!.annotations.first(where:{$0.value(forAnnotationKey:AnnotationPDF.manifest) != nil})!
            var envelope=try! JSONDecoder().decode(AnnotationPDF.Envelope.self,from:Data((a.value(forAnnotationKey:AnnotationPDF.manifest) as! String).utf8));envelope.minimumReader=99
            a.setValue(String(decoding:try! JSONEncoder().encode(envelope),as:UTF8.self),forAnnotationKey:AnnotationPDF.manifest)
        }
        check(future.annotationReadOnly && !future.beginInkAction("forbidden"),"future format disallows mutation")
        var blocked=false;future.save { if case .failure = $0 { blocked=true } };check(blocked,"future format cannot overwrite or save as downgraded")
        let legacy=try DocumentSession.open(url:root.appendingPathComponent("Tests/Fixtures/PDF/legacy-annotations.pdf"))
        check(!legacy.annotationReadOnly && legacy.annotations.ink.flatMap{$0}.count==3,"legacy ink migration remains editable")
        let legacyDuplicateURL=dir.appendingPathComponent("legacy-duplicate.pdf")
        let legacyPDF=PDFDocument(data:original)!
        legacyPDF.page(at:0)!.addAnnotation(InkAnnotationCodec.make(stroke))
        legacyPDF.page(at:0)!.addAnnotation(InkAnnotationCodec.make(stroke))
        try legacyPDF.dataRepresentation()!.write(to:legacyDuplicateURL)
        let legacyDuplicate=try DocumentSession.open(url:legacyDuplicateURL)
        check(legacyDuplicate.annotationReadOnly && legacyDuplicate.document.page(at:0)!.annotations.filter{InkAnnotationCodec.stroke(from:$0)?.id==stroke.id}.count==2,"legacy ID conflict preserves both original appearances read-only")
        // Old model-based recovery remains supported without notes.
        let oldRecord=RecoveryRecord(version:2,sourcePath:url.path,originalFingerprint:"legacy",pdfData:original,revision:UUID(),updatedAt:Date(),ink:s.annotations.ink)
        let oldRestore=try DocumentSession.open(url:url);try oldRestore.restoreRecovery(oldRecord)
        check(oldRestore.annotations.ink==s.annotations.ink,"version 2 recovery migrates ink without notes")
        let changedPage=try mutate("page-content-change") {pdf in pdf.page(at:0)!.rotation=90}
        check(!changedPage.annotationReadOnly && changedPage.annotations.notes.contains(where: \.locationUncertain),"changed page distinguishes uncertain location from removed marks")
        let uncertain=changedPage.annotations.notes.first(where: \.locationUncertain)!.id
        _ = changedPage.addRegion(page:changedPage.document.page(at:0)!,rect:CGRect(x:40,y:40,width:60,height:60),to:uncertain)
        check(changedPage.annotations.notes.first{$0.id==uncertain}!.locationUncertain==false,"explicit region selection re-associates uncertain original")
        try save(changedPage)
        let relinked=try DocumentSession.open(url:changedPage.fileURL)
        check(!relinked.annotationReadOnly && relinked.annotations.notes.first{$0.id==uncertain}!.locationUncertain==false,"explicit re-association survives PDF roundtrip")
        let privateURL=dir.appendingPathComponent("foreign-recovery.pdf")
        let privatePDF=PDFDocument(data:original)!
        let foreign=PDFAnnotation(bounds:CGRect(x:40,y:200,width:120,height:18),forType:.highlight,withProperties:nil)
        let privateKey=PDFAnnotationKey(rawValue:"/ThirdPartyPrivate")
        foreign.setValue("retain-after-recovery",forAnnotationKey:privateKey);privatePDF.page(at:0)!.addAnnotation(foreign)
        try privatePDF.dataRepresentation()!.write(to:privateURL)
        let beforeCrash=try DocumentSession.open(url:privateURL)
        let foreignID=beforeCrash.annotations.marks.first{$0.anchor.bounds==foreign.bounds}!.id
        let foreignNote=beforeCrash.annotateMarks([foreignID])!
        beforeCrash.editBody(foreignNote,markdown:"恢复后保留第三方扩展");beforeCrash.finishAction()
        let afterCrash=try DocumentSession.open(url:privateURL)
        let validRecovery=beforeCrash.recoverableRecord!
        try afterCrash.restoreRecovery(validRecovery);try save(afterCrash)
        // Annotation keys may lazily read strings from the owning CGPDFDocument.
        // Keep that document alive until the value has been copied out.
        let restoredDocument=PDFDocument(url:privateURL)!
        let restoredValue=withExtendedLifetime(restoredDocument) {
            restoredDocument.page(at:0)!.annotations.first{$0.value(forAnnotationKey:privateKey) != nil}?.value(forAnnotationKey:privateKey) as? String
        }
        check(restoredValue == "retain-after-recovery","recovery and save preserve original highlight private fields")
        let beforeInvalid=afterCrash.annotations
        var invalidRecord=validRecovery;invalidRecord.annotations=nil
        do { try afterCrash.restoreRecovery(invalidRecord);check(false,"invalid recovery should fail") } catch {}
        check(afterCrash.annotations==beforeInvalid,"invalid recovery leaves current session intact")
        let scanURL=dir.appendingPathComponent("scan-replacement.pdf")
        try original.write(to:scanURL)
        let scanSession=try DocumentSession.open(url:scanURL)
        let scanNote=scanSession.addRegion(page:scanSession.document.page(at:3)!,rect:CGRect(x:40,y:50,width:90,height:50))!
        scanSession.editBody(scanNote,markdown:"扫描页区域解释");scanSession.finishAction();try save(scanSession)
        // Simulate an external editor replacing page graphics while preserving
        // the complete Ecru records and their standard projections.
        let scanPDF=PDFDocument(data:original)!,oldScan=scanSession.document.page(at:3)!
        let box=oldScan.bounds(for:.cropBox)
        let picture=NSImage(size:box.size);picture.lockFocus();NSColor.white.setFill();CGRect(origin:.zero,size:box.size).fill();NSColor.red.setFill();CGRect(x:80,y:80,width:60,height:80).fill();picture.unlockFocus()
        let replacement=PDFPage(image:picture)!;replacement.setBounds(box,for:.cropBox)
        scanPDF.removePage(at:3);scanPDF.insert(replacement,at:3)
        for i in 0..<scanPDF.pageCount {let p=scanPDF.page(at:i)!;for a in p.annotations where a.type=="Highlight" {p.removeAnnotation(a)}}
        for mark in scanSession.annotations.marks {scanPDF.page(at:mark.anchor.page)!.addAnnotation(AnnotationPDF.make(mark))}
        try AnnotationPDF.install(scanSession.annotations,into:scanPDF)
        try scanPDF.dataRepresentation()!.write(to:scanURL)
        let replacedScan=try DocumentSession.open(url:scanURL)
        check(replacedScan.annotations.notes.first{$0.id==scanNote}?.locationUncertain == true,"scan image replacement flags original location without losing note")
        // Quartz may emit an orphan object with offset zero after replacing an image page.
        // This new parser-risk policy protects such external rewrites rather than silently repairing them.
        check(!replacedScan.annotationReadOnly || replacedScan.capabilities.features & 256 != 0,"external scan with structural warning is protected read-only")
        print("\(checks) annotation checks passed; fixtures: \(dir.path)")
    }
}
