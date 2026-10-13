import Foundation

/// Builds a fresh session/PDFKit graph on one loader queue, then transfers sole
/// ownership to main. No reader, view or active session is used by the loader.
final class DocumentOpenCoordinator {
    private let worker=DispatchQueue(label:"Ecru.document-open",qos:.userInitiated)
    private var generation=0 // main only
    func cancelAll(){precondition(Thread.isMainThread);generation &+= 1}
    func open(_ url:URL,password:String?=nil,completion:@escaping(Result<DocumentSession,Error>)->Void) {
        precondition(Thread.isMainThread)
        let token=generation
        worker.async{[weak self] in
            let result=Result{try DocumentSession.open(url:url,password:password)}
            DispatchQueue.main.async{[weak self] in
                guard let self,self.generation==token else{return}
                completion(result)
            }
        }
    }
}
