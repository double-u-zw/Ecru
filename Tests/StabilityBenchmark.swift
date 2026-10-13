import AppKit
import PDFKit
import Darwin

/// Same deterministic operations before/after; all inputs and recovery are isolated.
@main enum StabilityBenchmark {
    static func rss() -> UInt64 {
        var info = mach_task_basic_info(); var count = mach_msg_type_number_t(MemoryLayout.size(ofValue:info)/4)
        let result = withUnsafeMutablePointer(to:&info) { p in p.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) } }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
    static func clock() -> Double { ProcessInfo.processInfo.systemUptime }
    static func main() throws {
        let root = URL(fileURLWithPath:CommandLine.arguments[1]); var report:[String:Any] = [:]
        let scenario=CommandLine.arguments.count>3 ? CommandLine.arguments[3]:"all"
        for (name,actions,points) in [("large",24,16),("ordinary",600,128)] {
            if scenario != "all" && scenario != name {continue}
            let dataRoot = root.appendingPathComponent(UUID().uuidString)
            setenv("ECRU_DATA_DIR",dataRoot.path,1)
            let start=clock()
            let session:DocumentSession
            var openSubmissionMs=0.0
            #if STABILITY_INCREMENTAL
            let opener=DocumentOpenCoordinator();var prepared:Result<DocumentSession,Error>?
            opener.open(root.appendingPathComponent(name+".pdf")){prepared=$0}
            openSubmissionMs=(clock()-start)*1000
            while prepared==nil {RunLoop.current.run(until:Date().addingTimeInterval(0.005))}
            session=try prepared!.get()
            #else
            session=try DocumentSession.open(url:root.appendingPathComponent(name+".pdf"))
            openSubmissionMs=(clock()-start)*1000
            #endif
            let opened=clock()
            let page=session.document.page(at:0)!, memoryBefore=rss()
            let inputBytes=try Data(contentsOf:session.fileURL).count
            var pauses:[Double]=[], encoding:[Double]=[], written=0, recordSize=0
            for i in 0..<actions {
                let stroke=InkStroke(points:(0..<points).map{InkPoint(x:Double($0)*0.1+20,y:Double(i%100)+400)},width:1.6,rgba:[0,0.2,0.8,1],kind:.pen)
                #if STABILITY_INCREMENTAL
                let previous=session.recoveryMetrics
                #endif
                let tick=clock(); precondition(session.beginInkAction("sample"));session.replaceInk(on:page,ids:[],with:[stroke]);session.finishAction();pauses.append((clock()-tick)*1000)
                let record=session.recoverableRecord!
                #if STABILITY_INCREMENTAL
                let next=session.recoveryMetrics
                encoding.append((next.encodingSeconds-previous.encodingSeconds)*1000)
                written=next.bytesWritten
                #else
                let tick2=clock();_ = try JSONEncoder().encode(record);encoding.append((clock()-tick2)*1000)
                #endif
                precondition(record.annotations?.ink[0].count==i+1)
                let enumerator=FileManager.default.enumerator(at:dataRoot.appendingPathComponent("Recovery"),includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey])!
                recordSize=0
                for case let file as URL in enumerator {
                    let values=try file.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]);if values.isRegularFile==true {recordSize += values.fileSize ?? 0}
                }
                #if !STABILITY_INCREMENTAL
                written += recordSize
                #endif
                RunLoop.current.run(until:Date().addingTimeInterval(0.001))
            }
            let memoryAfter=rss(), saveStart=clock()
            var done=false;session.save(to:dataRoot.appendingPathComponent("saved.pdf")){result in precondition((try? result.get()) != nil);done=true}
            let capture=(clock()-saveStart)*1000
            while !done {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
            pauses.sort();encoding.sort()
            report[name] = ["actions":actions,"pointsPerAction":points,"inputBytes":inputBytes,"openMs":(opened-start)*1000,"openMainSubmissionMs":openSubmissionMs,"actionP95Ms":pauses[Int(Double(actions-1)*0.95)],"actionMaxMs":pauses.last!,"fullRecordEncodeP95Ms":encoding[Int(Double(actions-1)*0.95)],"recoveryBytes":recordSize,"legacyWrittenBytes":written,"rssGrowthBytes":Int64(memoryAfter)-Int64(memoryBefore),"saveCaptureMs":capture]
            #if STABILITY_INCREMENTAL
            var values=report[name] as! [String:Any];values["historyEstimatedBytes"]=session.historyEstimatedBytes;values["checkpoints"]=session.recoveryMetrics.fullCheckpoints;report[name]=values
            #endif
        }
        if scenario=="undo" {
            setenv("ECRU_DATA_DIR",root.appendingPathComponent(UUID().uuidString).path,1)
            let session=try DocumentSession.open(url:root.appendingPathComponent("ordinary.pdf")),page=session.document.page(at:0)!
            let entered=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0)
            session.recoveryWriteHook={entered.signal();release.wait()}
            let before=rss();var times:[Double]=[]
            for i in 0..<1500 {
                let stroke=InkStroke(points:(0..<64).map{InkPoint(x:Double($0)+20,y:Double(i%100)+400)},width:1.6,rgba:[0,0,1,1],kind:.pen)
                let tick=clock();precondition(session.beginInkAction("sample"));session.replaceInk(on:page,ids:[],with:[stroke]);session.finishAction();times.append((clock()-tick)*1000)
                if i==0 {precondition(entered.wait(timeout:.now()+5) == .success);session.recoveryWriteHook=nil}
            }
            let after=rss();release.signal();_ = session.recoverableRecord
            times.sort();report["undo"]=["actions":1500,"rssGrowthBytes":Int64(after)-Int64(before),"actionP95Ms":times[1425],"actionMaxMs":times.last!]
            #if STABILITY_INCREMENTAL
            var values=report["undo"] as! [String:Any];values["historyEstimatedBytes"]=session.historyEstimatedBytes;values["undoActions"]=session.undoActionCount;report["undo"]=values
            #endif
        }
        if scenario=="all" || scenario=="search" {
        let doc=PDFDocument(url:root.appendingPathComponent("search.pdf"))!
        let start=clock();let hits=doc.findString("needle",withOptions:[.caseInsensitive]);let searchMs=(clock()-start)*1000
        report["search"]=["pages":doc.pageCount,"hits":hits.count,"synchronousMs":searchMs]
        #if STABILITY_INCREMENTAL
        let coordinator=PDFSearchCoordinator();coordinator.configure(data:try Data(contentsOf:root.appendingPathComponent("search.pdf")),identity:UUID())
        var done=false,total=0,first:Double?,gap=0.0,last=clock();let asyncStart=clock()
        let timer=Timer(timeInterval:0.005,repeats:true){_ in let now=clock();gap=max(gap,(now-last)*1000);last=now};RunLoop.main.add(timer,forMode:.common)
        coordinator.search("needle",delay:0){value in total=value.total;if first==nil && !value.matches.isEmpty{first=(clock()-asyncStart)*1000};done=value.finished}
        while !done {RunLoop.current.run(until:Date().addingTimeInterval(0.005))};timer.invalidate()
        precondition(total==hits.count)
        report["search"]=["pages":doc.pageCount,"hits":total,"synchronousMs":searchMs,"firstResultsMs":first ?? 0,"asyncTotalMs":(clock()-asyncStart)*1000,"mainRunLoopMaxGapMs":gap]
        #endif
        }
        let data=try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]);try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]));print(String(decoding:data,as:UTF8.self))
    }
}
