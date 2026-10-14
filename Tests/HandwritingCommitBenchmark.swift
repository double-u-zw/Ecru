import AppKit
import PDFKit
/// Measures model commit work, not device input or frame presentation.
/// Recovery is held while sampling to isolate main-thread action costs.
@main enum HandwritingCommitBenchmark {
 static func now()->Double {ProcessInfo.processInfo.systemUptime}
 static func stats(_ values:[Double])->[String:Double] {let s=values.sorted();return ["p50":s[s.count/2],"p95":s[Int(Double(s.count-1)*0.95)],"max":s.last!]}
 static func main() throws {
  let root=URL(fileURLWithPath:CommandLine.arguments[1]);let n=Int(CommandLine.arguments[2])!
  let folder=root.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  setenv("ECRU_DATA_DIR",folder.path,1)
  let input=folder.appendingPathComponent("sample.pdf");try FileManager.default.copyItem(at:root.appendingPathComponent("fixture.pdf"),to:input)
  let session=try DocumentSession.open(url:input),page=session.document.page(at:0)!
  let release=DispatchSemaphore(value:0),entered=DispatchSemaphore(value:0)
  session.recoveryWriteHook={entered.signal();release.wait()}
  let builder=GoogleInkPenBuilder(point:InkPoint(x:20,y:20),width:1.6,pressure:0.3,timestamp:0)
  var exemplar=InkStroke(points:[InkPoint(x:20,y:20)],width:1.6,rgba:[0,0,1,1],kind:.pen,widthFactors:builder.initialFactors,appearance:.perfectFreehandV1,outlines:builder.initialOutlines)
  for i in 1...120 {
   let t=Double(i)/120;let u=builder.append(InkPoint(x:20+50*t,y:20+10*sin(t*8)),pressure:0.3,isRelease:i==120,timestamp:t)
   exemplar.points.removeLast(u.removing);exemplar.points += u.points;exemplar.widthFactors!.removeLast(u.removing);exemplar.widthFactors! += u.factors;exemplar.outlines!.removeLast(u.removingOutlines);exemplar.outlines! += u.outlines
  }
  precondition(session.beginInkAction("fixture"))
  session.replaceInk(on:page,ids:[],with:(0..<max(1,n)).map{_ in var s=exemplar;s.id=UUID();return s});session.finishAction()
  precondition(entered.wait(timeout:.now()+5) == .success);session.recoveryWriteHook=nil
  var begin:[Double]=[],update:[Double]=[],finish:[Double]=[]
  for _ in 0..<80 {
   let b=GoogleInkPenBuilder(point:InkPoint(x:20,y:20),width:1.6,pressure:0.3,timestamp:0)
   let s=InkStroke(points:[InkPoint(x:20,y:20)],width:1.6,rgba:[0,0,1,1],kind:.pen,widthFactors:b.initialFactors,appearance:.perfectFreehandV1,outlines:b.initialOutlines)
   var tick=now();precondition(session.beginInkAction("pen"));session.replaceInk(on:page,ids:[],with:[s]);begin.append((now()-tick)*1000)
   for i in 1...24 {
    let t=Double(i)/120;let u=b.append(InkPoint(x:20+50*t,y:20+10*sin(t*8)),pressure:0.3,isRelease:i==24,timestamp:t)
    tick=now();session.updatePerfectInk(u,to:s.id,on:page);update.append((now()-tick)*1000)
   }
   tick=now();session.finishAction();finish.append((now()-tick)*1000)
  }
  release.signal();_ = session.recoverableRecord
  let report:[String:Any] = ["existingStrokes":n,"beginMs":stats(begin),"updateMs":stats(update),"finishMs":stats(finish)]
  let data=try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys]);print(String(decoding:data,as:UTF8.self))
 }
}
