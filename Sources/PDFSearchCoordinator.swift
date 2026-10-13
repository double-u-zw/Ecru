import Foundation
import PDFKit

/// PDFKit ownership: the displayed document stays on main. A separately parsed
/// immutable reading copy, pages and selections stay on this serial worker.
/// Only character ranges and strings cross back to the UI.
final class PDFSearchCoordinator {
    enum TextAvailability:String {case unknown,searchable,unsearchable}
    struct Fragment {var page:Int;var ranges:[NSRange]}
    struct Match {var fragments:[Fragment];var snippet:String}
    struct Update {
        var matches:[Match];var total:Int;var finished:Bool
        var availability:TextAvailability;var limited:Bool
    }
    static let resultLimit=10_000
    private let worker=DispatchQueue(label:"Ecru.pdf-search",qos:.userInitiated)
    private let lock=NSLock()
    private var generation=0
    private var debounce:DispatchWorkItem?
    private var data=Data()
    private var identity=UUID()
    // These fields are touched only by worker.
    private var workerIdentity:UUID?
    private var document:PDFDocument?
    private var textPages:[Bool?]=[]
    // Coalesced delivery has one scheduled callback and bounded pending results.
    private var pending:[Match]=[]
    private var pendingUpdate:Update?
    private var deliveryScheduled=false
    var batchHook:(()->Void)? // Synthetic cancellation/ownership tests.
    func configure(data:Data,identity:UUID) {
        precondition(Thread.isMainThread)
        guard self.identity != identity else{return}
        cancel();self.data=data;self.identity=identity
    }
    func cancel() {
        precondition(Thread.isMainThread)
        debounce?.cancel();debounce=nil
        lock.lock();generation &+= 1;pending=[];pendingUpdate=nil;deliveryScheduled=false;lock.unlock()
    }
    private func current(_ token:Int)->Bool {lock.lock();defer{lock.unlock()};return generation==token}
    func search(_ query:String,composing:Bool=false,delay:Double=0.18,update:@escaping(Update)->Void) {
        precondition(Thread.isMainThread)
        cancel();guard !composing else{return}
        lock.lock();let token=generation;lock.unlock()
        let bytes=data,identity=self.identity
        let work=DispatchWorkItem {[weak self] in
            guard let self,self.current(token) else{return}
            self.worker.async{[weak self] in self?.run(query,bytes:bytes,identity:identity,token:token,update:update)}
        }
        debounce=work;DispatchQueue.main.asyncAfter(deadline:.now()+delay,execute:work)
    }
    private func availability()->TextAvailability {
        textPages.contains(true) ? .searchable:textPages.contains(where:{$0==nil}) ? .unknown:.unsearchable
    }
    private func run(_ query:String,bytes:Data,identity:UUID,token:Int,update:@escaping(Update)->Void) {
        guard current(token) else{return}
        if workerIdentity != identity {
            document=PDFDocument(data:bytes);workerIdentity=identity;textPages=Array(repeating:nil,count:document?.pageCount ?? 0)
        }
        guard let document else {
            publish(Update(matches:[],total:0,finished:true,availability:.unknown,limited:false),token:token,update:update);return
        }
        var total=0,retained=0,batch:[Match]=[],lastPublish=ProcessInfo.processInfo.systemUptime
        for pageIndex in 0..<document.pageCount {
            guard current(token) else{return}
            autoreleasepool {
                guard let page=document.page(at:pageIndex) else{return}
                if textPages[pageIndex]==nil {textPages[pageIndex] = !(page.string ?? "").trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
                if query.isEmpty || textPages[pageIndex] != true {return}
                // Search a worker-owned page using PDFKit's exact match/range semantics.
                // Never insert or copy a page from the active UI document.
                let local=PDFDocument();local.insert(page.copy() as! PDFPage,at:0)
                var previous:PDFSelection?,finishedPage=false
                while !finishedPage && current(token) {
                    // Scalar searches and short autorelease pools bound native
                    // PDFSelection allocation even on a page with millions of hits.
                    autoreleasepool {
                        for _ in 0..<64 {
                            guard let selection=local.findString(query,fromSelection:previous,withOptions:[.caseInsensitive]) else{finishedPage=true;break}
                            previous=selection;total += 1
                            if retained>=Self.resultLimit {continue}
                            guard let found=selection.pages.first else{continue}
                    let ranges=(0..<selection.numberOfTextRanges(on:found)).map{selection.range(at:$0,on:found)}
                    let line=found.selectionForLine(at:selection.bounds(for:found).origin)?.string ?? selection.string ?? ""
                    let clean=line.replacingOccurrences(of:"\n",with:" ").trimmingCharacters(in:.whitespacesAndNewlines)
                    var snippet=String(clean.prefix(90))
                    if let match=clean.range(of:query,options:.caseInsensitive) {
                        let start=clean.index(match.lowerBound,offsetBy:-24,limitedBy:clean.startIndex) ?? clean.startIndex
                        let end=clean.index(match.upperBound,offsetBy:60,limitedBy:clean.endIndex) ?? clean.endIndex
                        snippet=(start>clean.startIndex ? "…":"")+String(clean[start..<end])+(end<clean.endIndex ? "…":"")
                    }
                    batch.append(Match(fragments:[Fragment(page:pageIndex,ranges:ranges)],snippet:String(snippet.prefix(180))))
                    retained += 1
                        }
                    }
                    let now=ProcessInfo.processInfo.systemUptime
                    if batch.count>=128 || now-lastPublish>=0.08 {
                        publish(Update(matches:batch,total:total,finished:false,availability:availability(),limited:total>Self.resultLimit),token:token,update:update)
                        batch=[];lastPublish=now
                    }
                }

            }
            batchHook?()
            let now=ProcessInfo.processInfo.systemUptime
            if batch.count>=128 || now-lastPublish>=0.08 {
                publish(Update(matches:batch,total:total,finished:false,availability:availability(),limited:total>Self.resultLimit),token:token,update:update)
                batch=[];lastPublish=now
            }
        }
        publish(Update(matches:batch,total:total,finished:true,availability:availability(),limited:total>Self.resultLimit),token:token,update:update)
    }
    private func publish(_ value:Update,token:Int,update:@escaping(Update)->Void) {
        lock.lock()
        guard generation==token else{lock.unlock();return}
        pending+=value.matches;pendingUpdate=value
        let schedule = !deliveryScheduled;deliveryScheduled=true;lock.unlock()
        guard schedule else{return}
        DispatchQueue.main.asyncAfter(deadline:.now()+0.04){[weak self] in
            guard let self else{return}
            self.lock.lock()
            guard self.generation==token,var value=self.pendingUpdate else{self.lock.unlock();return}
            value.matches=self.pending;self.pending=[];self.pendingUpdate=nil;self.deliveryScheduled=false;self.lock.unlock()
            update(value)
        }
    }
    static func selection(_ match:Match,in document:PDFDocument)->PDFSelection? {
        precondition(Thread.isMainThread)
        let combined=PDFSelection(document:document)
        for fragment in match.fragments {
            guard let page=document.page(at:fragment.page) else{return nil}
            for range in fragment.ranges {
                guard range.location != NSNotFound,range.location>=0,range.length>0,NSMaxRange(range)<=page.numberOfCharacters,let selection=page.selection(for:range) else{return nil}
                combined.add(selection)
            }
        }
        return combined
    }
}
