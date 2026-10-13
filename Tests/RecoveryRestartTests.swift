import AppKit
import PDFKit
import CryptoKit
import Darwin

@main enum RecoveryRestartTests {
    static var checks=0
    static func check(_ value:Bool,_ message:String) {
        checks+=1;guard value else{fputs("FAIL: \(message)\n",stderr);exit(1)};print("PASS: "+message)
    }
    static func add(_ session:DocumentSession,_ value:Int) {
        check(session.beginInkAction("action \(value)"),"begin complete action")
        let stroke=InkStroke(points:[InkPoint(x:20,y:Double(value)+400),InkPoint(x:50,y:Double(value)+410)],width:1.6,rgba:[0,0,1,1],kind:.pen)
        session.replaceInk(on:session.document.page(at:0)!,ids:[],with:[stroke]);session.finishAction()
    }
    static func recovery(_ source:URL,_ data:URL)->URL {
        let hash=SHA256.hash(data:Data(source.path.utf8)).map{String(format:"%02x",$0)}.joined()
        return data.appendingPathComponent("Recovery/"+hash+".json")
    }
    static func child(_ mode:String,_ root:URL,_ expected:Int)throws {
        let source=root.appendingPathComponent("source.pdf"),data=root.appendingPathComponent("data")
        setenv("ECRU_DATA_DIR",data.path,1)
        let url=recovery(source,data)
        if mode=="read" || mode=="read-missing" {
            let record=try RecoveryStore.read(url)
            check(record.annotations?.ink[0].count==expected,"fresh process reconstructs last committed model")
            if mode=="read" {
                let session=try DocumentSession.open(url:source);try session.restoreRecovery(record)
                check(session.isModified && session.isRecovered,"restart remains explicitly unsaved")
                check(session.inkStrokes(on:session.document.page(at:0)!).count==expected,"restart imports exact action count")
            } else {
                check(!record.pdfData.isEmpty,"recovery retains its matching base when original is missing")
                let session=try DocumentSession.open(url:source);try session.restoreRecovery(record)
                check(!session.currentFileIsReadOnly && session.isModified,"missing-original recovery remains editable")
                add(session,2);session.checkpointRecovery()
                check(session.recoverableRecord?.annotations?.ink[0].count==2,"missing original is not needed for subsequent recovery commits")
            }
            return
        }
        let session=try DocumentSession.open(url:source)
        if mode=="write" {add(session,1);session.checkpointRecovery();check(session.recoverableRecord != nil,"first durable commit");return}
        if mode=="crash" {
            let old=try RecoveryStore.read(url);try session.restoreRecovery(old)
            session.recoveryStageHook={stage in if stage=="before-head"{_exit(73)}}
            add(session,2);session.checkpointRecovery();fatalError("crash seam not reached")
        }
        if mode=="failure" {
            try session.restoreRecovery(RecoveryStore.read(url));let original=try Data(contentsOf:url)
            session.recoveryStageHook={stage in if stage=="before-head"{throw POSIXError(.ENOSPC)}}
            add(session,2);session.checkpointRecovery()
            check(session.isModified && session.lastError != nil,"write failure preserves editable dirty state")
            check(try Data(contentsOf:url)==original,"failed commit leaves previous complete head intact")
            check(try RecoveryStore.read(url).annotations?.ink[0].count==1,"staged objects never become mixed recovery")
            session.recoveryStageHook=nil;add(session,3);session.checkpointRecovery()
            check(session.recoverableRecord?.annotations?.ink[0].count==3,"retry protects all retained edits")
            session.undo();check(session.inkStrokes(on:session.document.page(at:0)!).count==2,"failed save/recovery does not clear action undo")
            session.redo();session.checkpointRecovery();return
        }
        if mode.hasPrefix("legacy-") {
            let version=Int(mode.dropFirst(7))!;add(session,1)
            var record=session.recoverableRecord!
            if version==1 {record=RecoveryRecord(version:1,sourcePath:source.path,originalFingerprint:record.originalFingerprint,pdfData:session.portableDocument()!.dataRepresentation()!,revision:record.revision,updatedAt:Date())}
            else {record=RecoveryRecord(version:version,sourcePath:source.path,originalFingerprint:record.originalFingerprint,pdfData:record.pdfData,revision:record.revision,updatedAt:Date(),ink:record.ink,annotations:version>=3 ? record.annotations:nil,markOrigins:record.markOrigins)}
            try JSONEncoder().encode(record).write(to:url,options:.atomic);return
        }
        if mode=="migrate" {
            let old=try Data(contentsOf:url),record=try RecoveryStore.read(url)
            session.recoveryStageHook={stage in if stage=="before-head"{throw POSIXError(.ENOSPC)}}
            try session.restoreRecovery(record)
            check(try Data(contentsOf:url)==old,"legacy bytes survive unsuccessful migration")
            session.recoveryStageHook=nil;session.checkpointRecovery()
            let head=try JSONDecoder().decode(RecoveryStore.Head.self,from:Data(contentsOf:url))
            check(head.format==8,"successful migration publishes new head only after durable objects")
            return
        }
        if mode=="external" {
            let original=try Data(contentsOf:source);try (original+Data("\n% external modification\n".utf8)).write(to:source,options:.atomic)
            let external=try DocumentSession.open(url:source);try external.restoreRecovery(RecoveryStore.read(url))
            check(external.conflictDetected && external.isModified,"external changes are detected after independent restart")
            var result:Result<SaveOutcome,Error>?
            external.save{result=$0};while result==nil{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
            if case .failure(DocumentSessionError.conflict)=result! {check(true,"conflicting original cannot be overwritten")}else{check(false,"conflict save must fail")}
            result=nil;external.save(to:root.appendingPathComponent("copy.pdf")){result=$0}
            while result==nil{RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
            check((try? result!.get()) != nil,"failed original save can safely retry Save As");return
        }
    }
    static func run(_ mode:String,_ root:URL,_ count:Int=1,_ exitCode:Int32=0)throws {
        let process=Process();process.executableURL=URL(fileURLWithPath:CommandLine.arguments[0]);process.arguments=["--child",mode,root.path,String(count)]
        try process.run();process.waitUntilExit();check(process.terminationStatus==exitCode,"independent process \(mode) exits as expected")
    }
    static func main()throws {
        if CommandLine.arguments.count>1,CommandLine.arguments[1]=="--child" {try child(CommandLine.arguments[2],URL(fileURLWithPath:CommandLine.arguments[3]),Int(CommandLine.arguments[4])!);return}
        let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/recovery-restart-"+UUID().uuidString)
        func sample(_ name:String)throws->URL {
            let path=root.appendingPathComponent(name);try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true)
            try FileManager.default.copyItem(at:URL(fileURLWithPath:"output/pdf/reader-test-original.pdf"),to:path.appendingPathComponent("source.pdf"));return path
        }
        let crash=try sample("crash");try run("write",crash);try run("crash",crash,1,73);try run("read",crash)
        let failure=try sample("failure");try run("write",failure);try run("failure",failure);try run("read",failure,3)
        let missing=try sample("missing");try run("write",missing);try FileManager.default.removeItem(at:missing.appendingPathComponent("source.pdf"));try run("read-missing",missing)
        let external=try sample("external");try run("write",external);try run("external",external)
        for version in 1...7 {let legacy=try sample("legacy-\(version)");try run("legacy-\(version)",legacy);try run("migrate",legacy);try run("read",legacy)}
        let history=try sample("history");setenv("ECRU_DATA_DIR",history.appendingPathComponent("data").path,1)
        let session=try DocumentSession.open(url:history.appendingPathComponent("source.pdf"))
        session.testSetHistoryBudget(96*1024)
        for i in 0..<80 {
            check(session.beginInkAction("budgeted action"),"budget action begins")
            session.replaceInk(on:session.document.page(at:0)!,ids:[],with:[InkStroke(points:(0..<128).map{InkPoint(x:Double($0)+20,y:Double(i)+400)},width:1.6,rgba:[0,0,1,1],kind:.pen)]);session.finishAction()
        }
        let retained=session.undoActionCount
        check(retained>=32 && retained<80 && session.historyEstimatedBytes<=96*1024,"budget retires oldest actions while preserving useful recent history")
        for _ in 0..<retained{session.undo()}
        check(session.isModified && !session.canUndo && session.canRedo,"undo retention cannot mark truncated document clean")
        for _ in 0..<retained{session.redo()}
        check(session.inkStrokes(on:session.document.page(at:0)!).count==80 && session.isModified,"redo restores each retained action and dirty revision semantics")
        let record=session.recoverableRecord!,shared=history.appendingPathComponent("data/Recovery/late-writer.json")
        let older=RecoveryRecord(version:record.version,sourcePath:record.sourcePath,originalFingerprint:record.originalFingerprint,pdfData:record.pdfData,revision:UUID(),updatedAt:record.updatedAt.addingTimeInterval(-10),ink:record.ink,annotations:record.annotations,markOrigins:record.markOrigins)
        let current=RecoveryStore(),late=RecoveryStore()
        try current.commit(record,to:shared,isCurrent:{true});let committed=try Data(contentsOf:shared)
        try late.commit(older,to:shared,isCurrent:{true})
        check(try Data(contentsOf:shared)==committed,"independent delayed writer cannot overwrite a newer durable state")
        let head=try JSONDecoder().decode(RecoveryStore.Head.self,from:committed)
        let base=RecoveryStore.objects(shared).appendingPathComponent(head.base)
        try Data("corrupt".utf8).write(to:base)
        do {_ = try RecoveryStore.read(shared);check(false,"corrupt referenced base must be rejected")}catch{check(true,"base/model association is verified by immutable content hash")}
        let imageRoot=try sample("images");setenv("ECRU_DATA_DIR",imageRoot.appendingPathComponent("data").path,1)
        let images=try DocumentSession.open(url:imageRoot.appendingPathComponent("source.pdf"))
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:256,pixelsHigh:256,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:1024,bitsPerPixel:32)!
        var random:UInt32=87421
        for i in 0..<(256*256*4) {random=random &* 1664525 &+ 1013904223;bitmap.bitmapData![i]=i%4==3 ? 255:UInt8(truncatingIfNeeded:random>>24)}
        let png=try ImageImport.normalize(bitmap.representation(using:.png,properties:[:])!)
        let imageID=try images.insertImage(png,on:images.document.page(at:0)!,rect:CGRect(x:50,y:300,width:128,height:128))
        let noteID=images.annotateMarks([imageID])!
        images.checkpointRecovery();let written=images.recoveryMetrics.bytesWritten
        for i in 0..<10 {images.editBody(noteID,markdown:"body \(i)");images.finishBodyEditing();images.checkpointRecovery()}
        let recordWithImage=images.recoverableRecord!
        check(recordWithImage.annotations==images.annotations,"externalized image sources reconstruct exact complete annotations")
        check(images.recoveryMetrics.bytesWritten-written<png.count,"typing with an image writes metadata deltas instead of re-encoding its source")
        let restored=try DocumentSession.open(url:images.fileURL);try restored.restoreRecovery(recordWithImage)
        check(restored.annotations.imageAssets==images.annotations.imageAssets,"image recovery survives another session and head checkpoint")
        images.undo();images.redo()
        check(images.annotations.imageAssets==recordWithImage.annotations?.imageAssets,"metadata undo/redo retains shared immutable image source")
        print("\(checks) independent restart orchestration checks passed; child assertions also enforced. Artifacts: \(root.path)")
    }
}
