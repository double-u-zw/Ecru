import Foundation
import CryptoKit
import Darwin

/// Content-addressed immutable base/checkpoint/transactions plus one atomic head.
/// Only the head commits a revision. Orphaned staged objects are never replayed.
final class RecoveryStore {
    struct Head:Codable {
        var format=8
        var sourcePath:String
        var originalFingerprint:String
        var base:String
        var checkpoint:String
        var transactions:[String]
        var revision:UUID
        var updatedAt:Date
        var assets:[String]?=nil
    }
    struct State:Codable {var model:AnnotationStore;var origins:[MarkSourceOrigin];var assetsPresent:Bool?=nil}
    struct Transaction:Codable {var change:AnnotationForwardChange;var origins:[MarkSourceOrigin];var assetsPresent:Bool?=nil}
    struct Metrics {var bytesWritten=0;var encodingSeconds=0.0;var commits=0;var fullCheckpoints=0}
    private(set) var metrics=Metrics()
    private var head:Head?
    private var previous:State?
    private var previousBase:Data?
    private var currentURL:URL?
    private var committedHeadData:Data?
    // Durable/accepted revisions survive cache resets after a superseded write.
    private var independentKnownRevisions:[URL:UUID]=[:]
    var stageHook:((String)throws->Void)?
    private let encoder=JSONEncoder()
    func reset(){head=nil;previous=nil;previousBase=nil;currentURL=nil;committedHeadData=nil}
    private static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    static func objects(_ url:URL)->URL {url.deletingPathExtension().appendingPathExtension("store")}
    private func encode<T:Encodable>(_ value:T)throws->Data {
        let start=ProcessInfo.processInfo.systemUptime;defer{metrics.encodingSeconds+=ProcessInfo.processInfo.systemUptime-start}
        return try encoder.encode(value)
    }
    private func put(_ bytes:Data,at folder:URL)throws->String {
        let key=Self.digest(bytes),url=folder.appendingPathComponent(key)
        if !FileManager.default.fileExists(atPath:url.path) {
            try Self.durableWrite(bytes,to:url);metrics.bytesWritten+=bytes.count
        }
        return key
    }
    /// Serialized by InkRecoveryWriter. No PDFKit objects enter this module.
    func commit(_ record:RecoveryRecord,to url:URL,isCurrent:()->Bool)throws {
        guard let model=record.annotations else{throw DocumentSessionError.invalidPDF}
        let state=State(model:model,origins:record.markOrigins ?? [],assetsPresent:model.imageAssets != nil)
        let folder=Self.objects(url)
        try FileManager.default.createDirectory(at:url.deletingLastPathComponent(),withIntermediateDirectories:true)
        let descriptor=try Self.acquireLock(url,exclusive:true,create:true)
        defer{flock(descriptor,LOCK_UN);Darwin.close(descriptor)}
        let diskHeadData=try? Data(contentsOf:url)
        if record.independentStore == true {
            if currentURL==url {
                let diskRevision=try diskHeadData.map{try JSONDecoder().decode(Head.self,from:$0).revision}
                guard diskHeadData==committedHeadData || diskRevision==head?.revision else {throw DocumentSessionError.io("独立批注已在其他窗口更新；未覆盖已有笔记，当前修改仍在窗口中")}
            } else {
                let diskRevision=try diskHeadData.map{try JSONDecoder().decode(Head.self,from:$0).revision}
                guard diskRevision==record.independentBaseRevision || diskRevision==independentKnownRevisions[url] else {throw DocumentSessionError.io("独立批注已在其他窗口更新；未覆盖已有笔记，当前修改仍在窗口中")}
            }
            if let diskHeadData {independentKnownRevisions[url]=try JSONDecoder().decode(Head.self,from:diskHeadData).revision}
        }
        if record.independentStore != true,let bytes=diskHeadData,let newer=try? JSONDecoder().decode(Head.self,from:bytes),newer.updatedAt>record.updatedAt {
            return // A delayed writer cannot replace a newer durable submission.
        }
        // Another session/process may have migrated or checkpointed this head.
        // Never extend cached references that its successful GC has retired.
        if currentURL==url,diskHeadData != committedHeadData {reset()}
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let currentAssets=Set(model.imageAssets?.keys.map{$0} ?? [])
        for (key,data) in model.imageAssets ?? [:] {
            if currentURL==url,head?.assets?.contains(key)==true,FileManager.default.fileExists(atPath:folder.appendingPathComponent(key).path) {continue}
            guard try put(data,at:folder)==key else{throw DocumentSessionError.validation("恢复图片源校验失败")}
        }
        var base:String
        if currentURL==url,previousBase==record.pdfData,let head {base=head.base}
        else {base=try put(record.pdfData,at:folder)}
        try stageHook?("base")
        let checkpoint:String,transactions:[String]
        let retainedAssets:Set<String>
        if currentURL==url,let head,head.base==base,head.transactions.count<127,let previous {
            let patch=AnnotationChange(from:previous.model,to:state.model).forwardOnly
            let key=try put(encode(Transaction(change:patch,origins:state.origins,assetsPresent:state.assetsPresent)),at:folder)
            checkpoint=head.checkpoint;transactions=head.transactions+[key]
            retainedAssets=Set(head.assets ?? []).union(currentAssets)
        } else {
            var compact=state;compact.model.imageAssets=nil
            checkpoint=try put(encode(compact),at:folder);transactions=[];metrics.fullCheckpoints+=1
            retainedAssets=currentAssets
        }
        try stageHook?("state")
        let next=Head(sourcePath:record.sourcePath,originalFingerprint:record.originalFingerprint,base:base,checkpoint:checkpoint,transactions:transactions,revision:record.revision,updatedAt:record.updatedAt,assets:retainedAssets.sorted())
        let bytes=try encode(next)
        guard isCurrent() else{return}
        try stageHook?("before-head")
        try Self.durableWrite(bytes,to:url);metrics.bytesWritten+=bytes.count;metrics.commits+=1
        if record.independentStore == true {independentKnownRevisions[url]=record.revision}
        head=next;previous=state;previousBase=record.pdfData;currentURL=url;committedHeadData=bytes
        // Old JSON is replaced only after all referenced objects are durable.
        // Cleanup considers the current head, never paths from a failed commit.
        let retained=Set([base,checkpoint]+transactions).union(retainedAssets)
        for entry in try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil) where !retained.contains(entry.lastPathComponent) {
            try? FileManager.default.removeItem(at:entry)
        }
    }
    static func read(_ url:URL)throws->RecoveryRecord {
        let descriptor=try acquireLock(url,exclusive:false,create:false)
        defer{if descriptor>=0{flock(descriptor,LOCK_UN);Darwin.close(descriptor)}}
        let bytes=try Data(contentsOf:url)
        // Existing versions 1...7 remain readable without rewriting them first.
        if let old=try? JSONDecoder().decode(RecoveryRecord.self,from:bytes) {return old}
        let head=try JSONDecoder().decode(Head.self,from:bytes)
        guard head.format==8,head.transactions.count<=127 else{throw DocumentSessionError.invalidPDF}
        let folder=objects(url)
        func object(_ key:String)throws->Data {
            guard key.count==64,key.allSatisfy({$0.isHexDigit}) else{throw DocumentSessionError.invalidPDF}
            let value=try Data(contentsOf:folder.appendingPathComponent(key))
            guard digest(value)==key else{throw DocumentSessionError.validation("恢复数据校验失败")}
            return value
        }
        let base=try object(head.base)
        var assets:[String:Data]=[:]
        for key in head.assets ?? [] {assets[key]=try object(key)}
        func attachAssets(_ model:inout AnnotationStore,present:Bool?)throws {
            guard head.assets != nil else{return} // pre-extraction development records
            if present==true {
                var sources:[String:Data]=[:]
                for key in Set(model.images.map(\.asset)) {
                    guard let data=assets[key] else{throw DocumentSessionError.validation("恢复图片源缺失")}
                    sources[key]=data
                }
                model.imageAssets=sources
            } else {model.imageAssets=nil}
        }
        var state=try JSONDecoder().decode(State.self,from:object(head.checkpoint))
        try attachAssets(&state.model,present:state.assetsPresent)
        guard state.model.valid() else{throw DocumentSessionError.invalidPDF}
        for key in head.transactions {
            let transaction=try JSONDecoder().decode(Transaction.self,from:object(key))
            for edit in transaction.change.pages {
                guard state.model.ink.indices.contains(edit.page),edit.after.allSatisfy({$0.index>=0 && $0.index<=state.model.ink[edit.page].count+edit.after.count && $0.stroke.isValid}),
                      Set(edit.after.map{$0.stroke.id}).count==edit.after.count else{throw DocumentSessionError.invalidPDF}
            }
            if let metadata=transaction.change.metadata {
                guard metadata.ink.isEmpty,metadata.pages.count==state.model.pages.count else{throw DocumentSessionError.invalidPDF}
            }
            state.model=transaction.change.applying(to:state.model);state.origins=transaction.origins
            try attachAssets(&state.model,present:transaction.assetsPresent)
        }
        guard state.model.valid() else{throw DocumentSessionError.invalidPDF}
        let version=state.model.minimumReader>=5 ? 7:state.model.minimumReader>=4 ? 6:state.model.minimumReader>=3 ? 5:state.model.minimumReader>=2 ? 4:3
        // Compatibility API reconstructs ink in memory; it is persisted only once.
        return RecoveryRecord(version:version,sourcePath:head.sourcePath,originalFingerprint:head.originalFingerprint,pdfData:base,revision:head.revision,updatedAt:head.updatedAt,ink:state.model.ink,annotations:state.model,markOrigins:state.origins)
    }
    static func remove(_ url:URL)throws {
        let descriptor=try acquireLock(url,exclusive:true,create:false)
        defer{if descriptor>=0{flock(descriptor,LOCK_UN);Darwin.close(descriptor)}}
        // Delete the commit first. A cleanup failure cannot delete its live base.
        do{try FileManager.default.removeItem(at:url)}catch {
            if (error as NSError).code != NSFileNoSuchFileError {throw error}
        }
        if FileManager.default.fileExists(atPath:objects(url).path){try FileManager.default.removeItem(at:objects(url))}
    }
    private static func acquireLock(_ url:URL,exclusive:Bool,create:Bool)throws->Int32 {
        let path=url.deletingPathExtension().appendingPathExtension("lock")
        let fd=Darwin.open(path.path,O_RDWR|(create ? O_CREAT:0),0o600)
        if fd<0 {
            if !create && errno==ENOENT{return -1}
            throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .EIO)
        }
        guard flock(fd,exclusive ? LOCK_EX:LOCK_SH)==0 else{Darwin.close(fd);throw POSIXError(.EIO)}
        return fd
    }
    private static func durableWrite(_ bytes:Data,to url:URL)throws {
        let temporary=url.deletingLastPathComponent().appendingPathComponent(".pending-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:temporary)}
        try bytes.write(to:temporary,options:.withoutOverwriting)
        guard chmod(temporary.path,0o600)==0 else{throw POSIXError(.EACCES)}
        let fd=Darwin.open(temporary.path,O_RDONLY)
        guard fd>=0 else{throw POSIXError(.EIO)}
        defer{Darwin.close(fd)}
        guard fsync(fd)==0,rename(temporary.path,url.path)==0 else{throw POSIXError(.EIO)}
        let directory=Darwin.open(url.deletingLastPathComponent().path,O_SEARCH|O_CLOEXEC)
        if directory>=0 {_ = fsync(directory);Darwin.close(directory)}
    }
}

/// At most one running and one pending immutable value; newer requests coalesce.
final class InkRecoveryWriter {
    private let queue=DispatchQueue(label:"Ecru.ink-recovery",qos:.utility)
    private let lock=NSLock()
    private var generation:UInt64=0
    private var pending:Job?
    private var draining=false
    private let store=RecoveryStore()
    private var lastFailure:Error?
    var stageHook:((String)throws->Void)?
    private struct Job {
        var generation:UInt64;var record:RecoveryRecord;var url:URL
        var hook:(()->Void)?;var completion:(Error?)->Void
    }
    func submit(_ record:RecoveryRecord,to url:URL,hook:(()->Void)?,completion:@escaping(Error?)->Void) {
        lock.lock();generation &+= 1;pending=Job(generation:generation,record:record,url:url,hook:hook,completion:completion)
        let start = !draining;draining=true;lock.unlock()
        if start{queue.async{self.drain()}}
    }
    private func current(_ token:UInt64)->Bool {lock.lock();defer{lock.unlock()};return generation==token}
    private func drain() {
        while true {
            lock.lock();guard let job=pending else{draining=false;lock.unlock();return};pending=nil;lock.unlock()
            job.hook?();guard current(job.generation) else{continue}
            var failure:Error?
            do{store.stageHook=stageHook;try store.commit(job.record,to:job.url,isCurrent:{self.current(job.generation)})}catch{failure=error}
            lastFailure=failure
            let result=failure
            DispatchQueue.main.async{if self.current(job.generation){job.completion(result)}}
        }
    }
    func flush(){queue.sync{}}
    func cancelAndWait(){lock.lock();generation &+= 1;pending=nil;lock.unlock();queue.sync{store.reset();lastFailure=nil}}
    var metrics:RecoveryStore.Metrics {queue.sync{store.metrics}}
    var failure:Error? {queue.sync{lastFailure}}
}
