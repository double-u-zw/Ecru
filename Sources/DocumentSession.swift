import AppKit
import PDFKit
import CryptoKit
import Darwin

enum DocumentSessionError: LocalizedError {
    case passwordRequired, incorrectPassword, invalidPDF, unsupported(String), serialize, validation(String), readOnly, conflict, duplicateTarget, busy, io(String), recoveryCleanup(String)
    var errorDescription: String? {
        switch self {
        case .passwordRequired: return "此 PDF 需要打开密码。"
        case .incorrectPassword: return "密码不正确，或系统不支持此加密方式。请重新输入。"
        case .invalidPDF: return "无法读取这个 PDF。"
        case .unsupported(let reason): return "此文件受到安全保护：\(reason)"
        case .serialize: return "PDF 数据生成失败，当前修改仍在窗口中。"
        case .validation(let detail): return "保存校验失败（\(detail)），原文件未被替换。"
        case .readOnly: return "文件或所在目录不可写；当前修改已保留，请另存。"
        case .conflict: return "文件已在外部修改，当前笔记尚未保存。请另存到其他文件。"
        case .duplicateTarget: return "保存目标已经在另一个窗口打开，请选择其他文件。"
        case .busy: return "正在保存，请稍候。"
        case .io(let reason): return "保存失败：\(reason)。当前修改已保留。"
        case .recoveryCleanup(let reason): return "无法清除恢复记录：\(reason)。恢复记录已保留；请修复恢复目录权限后重试。"
        }
    }
}

struct SaveOutcome {
    let url: URL
    let containsNewerUnsavedChanges: Bool
    let recoveryCleanupSucceeded: Bool
}

struct MarkSourceOrigin: Codable {
    let id: UUID
    let page: Int
    let slot: Int
}

struct RecoveryRecord: Codable {
    let version: Int
    let sourcePath: String
    let originalFingerprint: String
    let pdfData: Data
    let revision: UUID
    let updatedAt: Date
    var ink: [[InkStroke]]? = nil
    var annotations: AnnotationStore? = nil
    var markOrigins: [MarkSourceOrigin]? = nil
    var independentStore: Bool? = nil
    var independentBaseRevision: UUID? = nil
}

/// Saved PDFs are self-contained. Crash recovery may pair an immutable PDF base
/// with the latest value-type ink model; it is never the primary note store.
/// The displayed PDFKit graph stays on main. Workers parse separate graphs from
/// immutable bytes and values, so edits made during a save remain unsaved.
final class DocumentSession {
    // The displayed PDF contains original content and foreign/text annotations only.
    // Editable ink lives here, including the active stroke, and is rendered once by its PDFKit page overlay.
    private(set) var usesLocalAnnotations = false
    private var allowsLocalPDFExport = true
    private var localBaseRevision:UUID?
    private(set) var capabilities: PDFCapabilities
    private(set) var searchData:Data
    private(set) var searchIdentity=UUID()
    private(set) var document: PDFDocument
    private(set) var annotations = AnnotationStore(pages: [], ink: [])
    private var inkPages: [[InkStroke]] {
        _read { yield annotations.ink }
        _modify { yield &annotations.ink }
    }
    private(set) var annotationWarnings: [String] = []
    private(set) var annotationReadOnly = false
    var onHistoryNote: ((UUID?, String) -> Void)?
    private var managedSourceSlots: [Set<Int>] = []
    private var sourceMarkSlots: [UUID: (Int,Int)] = [:]
    private(set) var fileURL: URL
    private(set) var revision = UUID()
    private var savedRevision: UUID
    private(set) var isSaving = false
    private(set) var savingTarget: URL?
    private(set) var conflictDetected = false
    private(set) var isRecovered = false
    private(set) var lastError: Error?
    var onChange: (() -> Void)?
    // Presentation receives page-space damage, independently from transaction/UI updates.
    var onInkChange: ((PDFPage, CGRect, InkChange) -> Void)?
    var isTargetOpenElsewhere: ((URL) -> Bool)?
    // Test seam: runs on the background worker after capture, before the file check.
    var saveWorkHook: (() -> Void)?
    // Test seam for PDFKit failing to serialize an undo snapshot.
    var snapshotDataProvider: (() -> Data?)?
    // Test seam for native PDF serialization failing after a complete edit.
    var saveDataProvider: (() -> Data?)?
    // Test seam for PDFKit failing to generate crash-recovery bytes.
    var recoveryDataProvider: (() -> Data?)?
    private var originalFingerprint: String
    private var backingPages: [PDFPage] = []
    private var backingData: Data
    private var originalStructure: PDFStructure
    private var originalContent: PDFContentIntegrity
    private var undoEntries: [ActionEntry] = []
    private var redoEntries: [ActionEntry] = []
    private var historyBytes = 0
    private var historyBudget = 128 * 1024 * 1024
    #if ECRU_INPUT_TESTS
    func testSetHistoryBudget(_ bytes:Int){historyBudget=bytes}
    #endif
    var historyEstimatedBytes:Int {historyBytes}
    var undoActionCount:Int {undoEntries.count}
    var recoveryMetrics:RecoveryStore.Metrics {recoveryWriter.metrics}
    var recoveryStageHook:((String)throws->Void)? {get{recoveryWriter.stageHook}set{recoveryWriter.stageHook=newValue}}
    private var pendingAction: (String, Snapshot)?
    private var pendingActionToken: UUID?
    // Immutable PDF base for recovery; ink is captured separately without PDFKit.
    private var recoveryBasePDF: Data
    private let recoveryWriter = InkRecoveryWriter()
    var recoveryWriteHook: (() -> Void)? // Test-only worker gate.
    private var pendingOldRecoveryURLs: Set<URL> = []
    private let dataDirectory: URL
    private let worker = DispatchQueue(label: "Ecru.safe-save")

    var isModified: Bool { revision != savedRevision || pendingAction != nil || (usesLocalAnnotations && lastError != nil) }
    var contentChangeToken: UUID { pendingActionToken ?? revision }
    var currentFileIsReadOnly: Bool {
        var info = stat()
        var directoryInfo = stat()
        let parent = fileURL.deletingLastPathComponent().path
        // A recovered document whose original is missing remains editable;
        // save-to-original is conflict protected, and Save As is available.
        if stat(fileURL.path,&info) != 0 && errno==ENOENT {return false}
        return stat(fileURL.path, &info) != 0 || info.st_mode & 0o222 == 0 ||
            info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) != 0 ||
            stat(parent, &directoryInfo) != 0 || directoryInfo.st_mode & 0o222 == 0 ||
            !FileManager.default.isWritableFile(atPath: fileURL.path) || !FileManager.default.isWritableFile(atPath: parent)
    }
    var canUndo: Bool { !undoEntries.isEmpty }
    var canRedo: Bool { !redoEntries.isEmpty }
    var statusText: String {
        if usesLocalAnnotations { return lastError != nil ? "独立批注 · 保存失败" : isModified ? "独立批注 · 正在保存" : "独立批注 · 已保存在 Ecru" }
        if !capabilities.canEdit { return "只读 · " + (capabilities.features & 2 != 0 ? "签名未验证" : "兼容性保护") }
        if conflictDetected { return "文件已在外部修改，当前笔记尚未保存" }
        if let error = lastError, case DocumentSessionError.recoveryCleanup = error { return "恢复记录清理失败" }
        if lastError != nil { return "保存失败" }
        if isSaving { return isModified ? "正在保存 · 未保存" : "正在保存" }
        if isRecovered && isModified { return "已恢复未保存内容 · 未保存" }
        return isModified ? "未保存" : capabilities.mode == .annotationCopy ? "静态批注副本" : ""
    }

    static func canonicalURL(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    static func open(url: URL, password: String? = nil) throws -> DocumentSession {
        let canonical = canonicalURL(url)
        let data:Data
        var missingSource=false
        do {data=try Data(contentsOf:canonical)}catch {
            let failure=error as NSError
            guard failure.domain==NSCocoaErrorDomain && (failure.code==NSFileReadNoSuchFileError || failure.code==NSFileNoSuchFileError) else{throw error}
            let key=Self.fingerprint(Data(canonical.path.utf8))
            let url=EcruEnvironment.applicationSupportDirectory.appendingPathComponent("Recovery/"+key+".json")
            let record=try RecoveryStore.read(url)
            guard canonicalURL(URL(fileURLWithPath:record.sourcePath))==canonical else{throw error}
            data=record.pdfData;missingSource=true
        }
        // Reject malformed graphs before entering the platform PDF parser.
        let inspection = try PDFPagePreservation.inspect(data, password: password)
        guard let original = PDFDocument(data: data) else { throw DocumentSessionError.invalidPDF }
        if original.isLocked {
            guard let password else { throw DocumentSessionError.passwordRequired }
            guard original.unlock(withPassword: password), !original.isLocked else { throw DocumentSessionError.incorrectPassword }
        }
        var capabilities = PDFCapabilities.assess(inspection.features, allowsCommenting: original.allowsCommenting, allowsPrinting: original.allowsPrinting)
        if capabilities.canEdit, let keywords=original.documentAttributes?[PDFDocumentAttribute.keywordsAttribute] as? [String], keywords.contains("EcruStaticAnnotationCopy") {
            capabilities=PDFCapabilities(mode:.annotationCopy,features:inspection.features,reasons:["仅含转换时的静态页面；原动态结构与可编辑批注已移除。"],canCreateStaticCopy:false)
        }
        let readingData = inspection.readingData ?? data
        guard let document = inspection.readingData == nil ? original : PDFDocument(data: readingData), document.pageCount > 0,
              (0..<document.pageCount).allSatisfy({ i in
                  guard let p = document.page(at:i) else { return false }
                  let r=p.bounds(for:.cropBox)
                  return r.width.isFinite && r.height.isFinite && r.width>0 && r.height>0
              }) else { throw DocumentSessionError.invalidPDF }
        let session=try DocumentSession(document: document, url: canonical, data: data, readingData: readingData, capabilities: capabilities, allowsPrinting: original.allowsPrinting)
        if missingSource {session.conflictDetected=true}
        return session
    }

    private init(document: PDFDocument, url: URL, data: Data, readingData: Data, capabilities: PDFCapabilities, allowsPrinting: Bool) throws {
        self.document = document
        self.allowsLocalPDFExport = allowsPrinting
        self.searchData = readingData
        self.capabilities = capabilities
        fileURL = url
        backingData = data
        recoveryBasePDF = data
        originalFingerprint = Self.fingerprint(data)
        originalStructure = PDFStructure(document)
        do { originalContent = try PDFContentIntegrity(readingData) }
        catch {
            originalContent=PDFContentIntegrity(pageCount:document.pageCount)
            if capabilities.canEdit {
                self.capabilities=PDFCapabilities(mode:.readOnly,features:capabilities.features,reasons:["页面资源完整性未通过检查；允许阅读，禁止修改和保存。"],canCreateStaticCopy:false)
            }
        }
        savedRevision = revision
        dataDirectory = EcruEnvironment.applicationSupportDirectory
        importEditableInk()
        // Prove the specific form/attachment can survive this export before enabling editing.
        if capabilities.features & (4|16) != 0 && !annotationReadOnly && portableData(portableDocument()) == nil {
            self.capabilities=PDFCapabilities(mode:.readOnly,features:capabilities.features,reasons:["此文件的表单或附件未通过对象保留预检，禁止修改和保存。"],canCreateStaticCopy:false)
            guard let original=PDFDocument(data:readingData) else { throw DocumentSessionError.invalidPDF }
            self.document=original;importEditableInk()
        }
        if annotationReadOnly {
            // Keep all source projections intact, including unknown/newer manifests.
            guard let inert = PDFDocument(data:readingData) else { throw DocumentSessionError.invalidPDF }
            self.document=inert
            backingPages=(0..<inert.pageCount).map{inert.page(at:$0)!}
            annotations=AnnotationStore(pages:backingPages.map(AnnotationPDF.identity),ink:backingPages.map{_ in []})
            managedSourceSlots=backingPages.map{_ in []};sourceMarkSlots=[:]
            usesLocalAnnotations=true;annotationReadOnly=false
        }
        if currentFileIsReadOnly { usesLocalAnnotations=true }
        if FileManager.default.fileExists(atPath:localAnnotationsURL.path) {
            let record=try RecoveryStore.read(localAnnotationsURL)
            guard record.originalFingerprint==originalFingerprint,record.pdfData==backingData,
                  Self.canonicalURL(URL(fileURLWithPath:record.sourcePath))==fileURL, let model=record.annotations,
                  model.valid(),model.pages.count==document.pageCount else {throw DocumentSessionError.validation("独立批注与原文件不匹配，已保留批注文件")}
            annotations=model;revision=record.revision;savedRevision=record.revision;localBaseRevision=record.revision
            usesLocalAnnotations=true;annotationReadOnly=false;syncMarkAdapters()
        }
        // Ecru supports annotations around forms, not field-value editing. Never let native
        // widgets acquire mutable values in the presentation while saving the original field tree.
        for page in backingPages { for a in page.annotations where a.type == "Widget" { a.isReadOnly=true } }
    }

    private func importEditableInk() {
        backingPages = (0..<document.pageCount).map { document.page(at: $0)! }
        annotations = AnnotationStore(pages: backingPages.map(AnnotationPDF.identity), ink: backingPages.map { _ in [] })
        for i in annotations.pages.indices {
            annotations.pages[i].contentHash = AnnotationPDF.hash(Data(originalContent.pages[i].utf8))
        }
        managedSourceSlots = backingPages.map { _ in [] }; sourceMarkSlots = [:]
        annotationWarnings = []; annotationReadOnly = !capabilities.canEdit
        if annotationReadOnly {
            // Keep original annotations and widget appearances in the reading view.
            // Never remove adapters or start recovery for protected documents.
            for page in backingPages {
                for a in page.annotations {
                    if let raw=a.value(forAnnotationKey:AnnotationPDF.noteKey) as? String, let id=UUID(uuidString:raw) {
                        annotations.notes.append(AnnotationNote(id:id,markdown:a.contents ?? "",anchors:[],links:[],locationUncertain:true))
                    }
                }
            }
            return
        }
        var manifests: [String] = []
        var marked: [UUID: [(Int, PDFAnnotation)]] = [:]
        var bodies: [UUID: [PDFAnnotation]] = [:]
        for (pi,page) in backingPages.enumerated() {
            for a in page.annotations {
                if let raw = a.value(forAnnotationKey: AnnotationPDF.manifest) {
                    if let raw = raw as? String { manifests.append(raw) } else { annotationReadOnly = true }
                }
                if let raw = a.value(forAnnotationKey: AnnotationPDF.markKey) {
                    if let str = raw as? String, let id = UUID(uuidString: str) { marked[id,default:[]].append((pi,a)) } else { annotationReadOnly = true }
                }
                if let raw = a.value(forAnnotationKey: AnnotationPDF.noteKey) {
                    if let str = raw as? String, let id = UUID(uuidString: str) { bodies[id,default:[]].append(a) } else { annotationReadOnly = true }
                }
            }
        }
        if manifests.count == 1 {
            do {
                annotations = try AnnotationPDF.decode(manifests[0])
                if annotations.pages.count != document.pageCount { annotationReadOnly = true }
                for (i,page) in backingPages.enumerated() where annotations.pages.indices.contains(i) {
                    var actual = AnnotationPDF.identity(page)
                    actual.contentHash = AnnotationPDF.hash(Data(originalContent.pages[i].utf8))
                    let saved = annotations.pages[i]
                    // PDFKit extraction order can differ after saving even when
                    // the original page drawing and character inventory are intact.
                    // Older manifests without the optional inventory retain the
                    // conservative exact-text check.
                    let textChanged = actual.textHash != saved.textHash &&
                        (saved.textInventoryHash == nil || actual.textInventoryHash != saved.textInventoryHash)
                    if !AnnotationPDF.close(actual.crop,saved.crop) || actual.rotation != saved.rotation || textChanged || actual.contentHash != saved.contentHash {
                        var updated = actual; updated.id = saved.id; annotations.pages[i] = updated
                        for n in annotations.notes.indices where annotations.notes[n].anchors.contains(where: {$0.page == i}) { annotations.notes[n].locationUncertain = true }
                        annotationWarnings.append("第 \(i+1) 页内容或页框已变化；相关批注保留原定位，需手动重新关联。")
                    }
                }
                let ids = annotations.allMarkIDs
                if marked.keys.contains(where: { !ids.contains($0) }) || marked.values.contains(where: { $0.count != 1 }) { annotationReadOnly = true }
                for mark in annotations.marks {
                    if let values = marked[mark.id], values.count == 1 {
                        if values[0].0 != mark.anchor.page || !AnnotationPDF.compatible(mark, values[0].1) { annotationReadOnly = true }
                    }
                }
                for (pi,strokes) in annotations.ink.enumerated() {
                    for stroke in strokes {
                        if let values = marked[stroke.id], values.count == 1 {
                            if values[0].0 != pi || InkAnnotationCodec.stroke(from: values[0].1) != stroke { annotationReadOnly = true }
                        }
                    }
                }
                for image in annotations.images {
                    if let values=marked[image.id],values.count==1, (values[0].0 != image.page || !ImagePDFAnnotation.compatible(image,values[0].1)) {annotationReadOnly=true}
                }
                let noteIDs = Set(annotations.notes.map(\.id))
                if bodies.keys.contains(where: { !noteIDs.contains($0) }) { annotationReadOnly = true }
                for note in annotations.notes {
                    // Missing/changed standard body is an external edit, not permission to restore it.
                    if bodies[note.id]?.count != 1 || bodies[note.id]?.first?.contents ?? "" != note.markdown { annotationReadOnly = true }
                }
                let missing = ids.subtracting(marked.keys)
                if !missing.isEmpty {
                    annotationWarnings.append("部分页面标记已在外部移除；正文与定位已保留，不会重新生成这些标记。")
                    annotations.images.removeAll {missing.contains($0.id)}
                    annotations.groups=annotations.groups.compactMap{var g=$0;g.members.removeAll{missing.contains($0)};return g.members.count>=2 ? g:nil}
                    annotations.objectOrder=annotations.objectOrder?.filter{!missing.contains($0)}
                    annotations.marks.removeAll { missing.contains($0.id) }
                    for i in annotations.ink.indices { annotations.ink[i].removeAll { missing.contains($0.id) } }
                }
            } catch { annotationReadOnly = true; annotationWarnings.append(error.localizedDescription) }
        } else if !manifests.isEmpty || !marked.isEmpty || !bodies.isEmpty {
            annotationReadOnly = true
            // Recover plain text for inspection, never manufacture an editable replacement manifest.
            for (id,values) in bodies where values.count == 1 {
                annotations.notes.append(AnnotationNote(id:id, markdown:values[0].contents ?? "", anchors:[], links:[], locationUncertain:true))
            }
        }
        // Detect legacy identifier collisions before removing any PDF adapters.
        var importedIDs = annotations.allMarkIDs
        for page in backingPages {
            for a in page.annotations where a.value(forAnnotationKey: AnnotationPDF.markKey) == nil && a.shouldDisplay && a.shouldPrint {
                if let stroke = InkAnnotationCodec.stroke(from: a), !importedIDs.insert(stroke.id).inserted {
                    annotationReadOnly = true
                    annotationWarnings.append("重复笔迹编号，保留原始显示并禁止保存覆盖。")
                }
            }
        }
        if annotationReadOnly {
            if annotations.notes.isEmpty {
                for (id,values) in bodies where values.count == 1 {
                    annotations.notes.append(AnnotationNote(id:id,markdown:values[0].contents ?? "",anchors:[],links:[],locationUncertain:true))
                }
            }
            for note in annotations.notes {
                if let values=bodies[note.id], values.count == 1, let external=values[0].contents, external != note.markdown {
                    annotationWarnings.append("外部正文（\(note.id.uuidString.prefix(8))）：\(external)")
                }
            }
            annotationWarnings.append("批注格式或标准内容存在冲突：受限只读，禁止保存覆盖。原始数据保留在 PDF 中；可在批注框复制正文。")
            annotations.ink = backingPages.map { _ in [] }; annotations.images=[]
            return
        }
        for (pi,page) in backingPages.enumerated() {
            let originals = page.annotations
            let ownedPopups = AnnotationPDF.ownedPopupIndices(on: page)
            for (slot,a) in originals.enumerated() {
                let isCarrier = ownedPopups.contains(slot) || a.value(forAnnotationKey: AnnotationPDF.manifest) != nil || a.value(forAnnotationKey: AnnotationPDF.noteKey) != nil
                let isManaged = a.value(forAnnotationKey: AnnotationPDF.markKey) != nil
                if isCarrier || isManaged {
                    if isManaged, let str=a.value(forAnnotationKey:AnnotationPDF.markKey) as? String, let id=UUID(uuidString:str), annotations.marks.contains(where:{$0.id == id}) { sourceMarkSlots[id]=(pi,slot) }
                    managedSourceSlots[pi].insert(slot); page.removeAnnotation(a); continue
                }
                if let stroke = InkAnnotationCodec.stroke(from:a), a.shouldDisplay, a.shouldPrint {
                    if annotations.allMarkIDs.contains(stroke.id) { annotationReadOnly = true; annotationWarnings.append("重复笔迹编号，禁止保存覆盖。") }
                    else { annotations.ink[pi].append(stroke);annotations.minimumReader=max(stroke.requiredReader,annotations.minimumReader) }
                    managedSourceSlots[pi].insert(slot); page.removeAnnotation(a)
                } else if a.type == "Highlight" {
                    // Preserve foreign highlights verbatim until explicitly adopted or deleted.
                    var mark = AnnotationPDF.mark(a,page:pi,pageID:annotations.pages[pi].id)
                    mark.textEditable = a.contents == "LeafInk text highlight"
                    annotations.marks.append(mark); sourceMarkSlots[mark.id]=(pi,slot); managedSourceSlots[pi].insert(slot); page.removeAnnotation(a)
                }
            }
        }
        syncMarkAdapters()
    }

    private func syncMarkAdapters(on indices: Set<Int>? = nil) {
        guard !annotationReadOnly else { return }
        for (index,page) in backingPages.enumerated() where indices == nil || indices!.contains(index) {
            for a in page.annotations where a.value(forAnnotationKey: AnnotationPDF.adapterKey) != nil { page.removeAnnotation(a) }
        }
        for mark in annotations.marks where backingPages.indices.contains(mark.anchor.page) && (indices == nil || indices!.contains(mark.anchor.page)) {
            let a = AnnotationPDF.make(mark); a.setValue(mark.id.uuidString, forAnnotationKey:AnnotationPDF.adapterKey)
            backingPages[mark.anchor.page].addAnnotation(a)
        }
    }

    // Compatibility entry for old callers/tests; production tools mutate values directly.
    private func captureNativeHighlights() {
        guard !annotationReadOnly else { return }
        var present = Set<UUID>()
        for (pi,page) in backingPages.enumerated() {
            for a in page.annotations where a.type == "Highlight" || a.type == "Square" {
                if let str = a.value(forAnnotationKey: AnnotationPDF.adapterKey) as? String, let id = UUID(uuidString:str) { present.insert(id) }
                else if a.type == "Highlight" {
                    var mark = AnnotationPDF.mark(a,page:pi,pageID:annotations.pages[pi].id)
                    mark.textEditable = a.contents == "LeafInk text highlight"
                    annotations.marks.append(mark); present.insert(mark.id)
                    a.setValue(mark.id.uuidString,forAnnotationKey:AnnotationPDF.adapterKey)
                }
            }
        }
        annotations.marks.removeAll { !present.contains($0.id) }
    }

    func inkStrokes(on page: PDFPage) -> [InkStroke] {
        let index = document.index(for: page)
        return inkPages.indices.contains(index) ? inkPages[index] : []
    }

    func replaceInk(on page: PDFPage, ids: Set<UUID>, with replacements: [InkStroke]) {
        precondition(Thread.isMainThread)
        precondition(pendingAction != nil, "Ink changes require an undo transaction")
        precondition(replacements.allSatisfy(\.isValid))
        let index = document.index(for: page)
        precondition(inkPages.indices.contains(index))
        let damaged = (inkPages[index].filter { ids.contains($0.id) } + replacements)
            .reduce(CGRect.null) { $0.union($1.bounds) }
        // Keep the replaced stroke's stacking position, especially for transparent ink.
        let insertion = inkPages[index].firstIndex { ids.contains($0.id) } ?? inkPages[index].count
        for n in annotations.notes.indices {
            let links = annotations.notes[n].links.filter { ids.contains($0.markID) }
            if !links.isEmpty {
                annotations.notes[n].links.removeAll { ids.contains($0.markID) }
                for replacement in replacements where !annotations.notes[n].links.contains(where: { $0.markID == replacement.id }) {
                    // Movement preserves each ID. Only a single-stroke split can
                    // transfer one source's ownership to newly minted fragment IDs.
                    if let original = links.first(where: { $0.markID == replacement.id }) ?? (ids.count == 1 ? links.first : nil) {
                        annotations.notes[n].links.append(NoteLink(markID:replacement.id,owned:original.owned))
                    }
                }
            }
        }
        annotations.minimumReader=max(replacements.map(\.requiredReader).max() ?? 1,annotations.minimumReader)
        let removed=Set(inkPages[index].filter{ids.contains($0.id)}.map(\.id)).subtracting(replacements.map(\.id))
        if !removed.isEmpty {
            if let order=annotations.objectOrder,let position=order.firstIndex(where:{removed.contains($0)}) {
                var next=order.filter{!removed.contains($0)};next.insert(contentsOf:replacements.map(\.id).filter{!next.contains($0)},at:min(position,next.count));annotations.objectOrder=next
            }
            annotations.groups=annotations.groups.compactMap{var g=$0;let included = !Set(g.members).isDisjoint(with:removed);g.members.removeAll{removed.contains($0)};if ids.count==1,included {g.members += replacements.map(\.id).filter{!g.members.contains($0)}};return g.members.count>=2 ? g:nil}
        }
        inkPages[index].removeAll { ids.contains($0.id) }
        inkPages[index].insert(contentsOf: replacements, at: min(insertion, inkPages[index].count))
        if !damaged.isNull { onInkChange?(page, damaged, .replaced(ids.union(replacements.map(\.id)))) }
    }

    func images(on page:PDFPage)->[PageImage] {annotations.images.filter{$0.page==document.index(for:page)}}
    @discardableResult func insertImage(_ data:Data,on page:PDFPage,rect:CGRect)throws->UUID {
        guard !annotationReadOnly,(usesLocalAnnotations || !currentFileIsReadOnly) else {throw DocumentSessionError.readOnly}
        let index=document.index(for:page),key=AnnotationPDF.hash(data)
        guard annotations.pages.indices.contains(index),rect.width>=0.1,rect.height>=0.1 else{throw DocumentSessionError.invalidPDF}
        var next=annotations;next.minimumReader=5
        next.imageAssets=next.imageAssets ?? [:];next.imageAssets?[key]=data
        let object=PageImage(page:index,asset:key,rect:rect);next.images.append(object)
        // New images sit behind every existing Ecru stroke/image; later writing sits above.
        next.objectOrder=[object.id]+(next.objectOrder ?? annotations.ink.flatMap{$0.map(\.id)}+annotations.images.map(\.id))
        _=try AnnotationPDF.encode(next) // Enforce total manifest budget before changing user data.
        guard beginInkAction("插入图片") else{throw DocumentSessionError.readOnly}
        annotations=next;onInkChange?(page,object.bounds,.reset);finishAction();return object.id
    }
    func replaceObjects(on page:PDFPage,ids proposedIDs:Set<UUID>,ink:[InkStroke],images:[PageImage]) {
        precondition(pendingAction != nil)
        let ids=proposedIDs.intersection(annotations.movableObjectIDs)
        replaceInk(on:page,ids:Set(inkPages[document.index(for:page)].filter{ids.contains($0.id)}.map(\.id)),with:ink)
        annotations.images.removeAll{ids.contains($0.id)};annotations.images += images
        let retained=Set(ink.map(\.id)+images.map(\.id)),removed=ids.subtracting(retained)
        annotations.groups=annotations.groups.compactMap{var g=$0;g.members.removeAll{removed.contains($0)};return g.members.count>=2 ? g:nil}
        annotations.objectOrder=annotations.objectOrder?.filter{!removed.contains($0)}
        for n in annotations.notes.indices {annotations.notes[n].links.removeAll{removed.contains($0.markID)}}
        onInkChange?(page,page.bounds(for:.cropBox),.reset)
    }
    func pasteObjects(_ incoming:ObjectClipboard,on page:PDFPage,center:CGPoint)throws->Set<UUID> {
        var packet=incoming;packet.marks=[]
        let movable=Set(packet.ink.map(\.id)+packet.images.map(\.id))
        packet.groups=packet.groups.compactMap{var group=$0;group.members=group.members.filter{movable.contains($0)};return group.members.count>=2 ? group:nil}
        packet.order=packet.order.filter{movable.contains($0)}
        guard !annotationReadOnly,(usesLocalAnnotations || !currentFileIsReadOnly) else{throw DocumentSessionError.readOnly}
        let ids=packet.ink.map(\.id)+packet.images.map(\.id)+packet.marks.map(\.id)
        guard !ids.isEmpty,Set(ids).count==ids.count else{throw DocumentSessionError.invalidPDF}
        let bounds=(packet.ink.map(\.bounds)+packet.images.map(\.bounds)+packet.marks.map{$0.anchor.bounds}).reduce(CGRect.null){$0.union($1)}
        let transform=CGAffineTransform(translationX:center.x-bounds.midX,y:center.y-bounds.midY)
        let mapping=Dictionary(uniqueKeysWithValues:ids.map{($0,UUID())}),index=document.index(for:page)
        var next=annotations;next.minimumReader=5;next.imageAssets=next.imageAssets ?? [:]
        for (key,data) in packet.assets {next.imageAssets?[key]=data}
        next.ink[index] += packet.ink.map{var stroke=$0.applying(transform);stroke.id=mapping[$0.id]!;return stroke}
        next.images += packet.images.map{var image=$0;image.id=mapping[$0.id]!;image.page=index;image.rect=image.rect.applying(transform);return image}
        next.marks += packet.marks.map{var mark=$0;mark.id=mapping[$0.id]!;mark.anchor.page=index;mark.anchor.pageID=next.pages[index].id;mark.anchor.bounds=mark.anchor.bounds.applying(transform);mark.quads=mark.quads.map{InkPoint($0.cgPoint.applying(transform))};mark.textSpan=nil;mark.textEditable=false;return mark}
        next.groups += packet.groups.map{AnnotationGroup(members:$0.members.compactMap{mapping[$0]})}
        next.objectOrder=annotations.ink.indices.flatMap{annotations.orderedIDs(on:$0)}+packet.order.compactMap{mapping[$0]}
        _=try AnnotationPDF.encode(next)
        guard beginInkAction("粘贴对象") else{throw DocumentSessionError.readOnly}
        annotations=next;syncMarkAdapters();onInkChange?(page,page.bounds(for:.cropBox),.reset);finishAction();return Set(mapping.values)
    }
    func groupObjects(_ proposed:Set<UUID>,ungroup:Bool=false) {
        let ids=proposed.intersection(annotations.movableObjectIDs)
        guard ids.count>=2 || ungroup,beginInkAction(ungroup ? "取消组合":"组合对象") else{return}
        let expanded=annotations.expanded(ids)
        annotations.groups.removeAll{!expanded.isDisjoint(with:$0.members)}
        if !ungroup,expanded.count>=2,Set(expanded.compactMap{annotations.pageIndex(for:$0)}).count==1 {annotations.groups.append(AnnotationGroup(members:Array(expanded)));annotations.minimumReader=5}
        finishAction()
    }
    func arrangeObjects(_ ids:Set<UUID>,front:Bool) {
        guard beginInkAction(front ? "移到最前":"移到最后") else{return}
        let all=annotations.ink.indices.flatMap{annotations.orderedIDs(on:$0)},moving=all.filter{ids.contains($0)},rest=all.filter{!ids.contains($0)}
        annotations.objectOrder=front ? rest+moving:moving+rest;annotations.minimumReader=5
        onInkChange?(document.page(at:annotations.pageIndex(for:ids.first!) ?? 0)!,document.page(at:0)!.bounds(for:.cropBox),.reset);finishAction()
    }

    func appendInkPoint(_ point: CGPoint, to id: UUID, on page: PDFPage) {
        appendInkPoints([InkPoint(point)], to: id, on: page)
    }

    func updatePerfectInk(_ update:InkOutlineUpdate,to id:UUID,on page:PDFPage) {
        precondition(Thread.isMainThread && pendingAction != nil)
        guard !update.points.isEmpty else{return}
        let pi=document.index(for:page)
        guard inkPages.indices.contains(pi),let index=(inkPages[pi].last?.id==id ? inkPages[pi].count-1 : inkPages[pi].firstIndex(where:{$0.id==id})),let shapeCount=inkPages[pi][index].outlines?.count else{return}
        precondition(update.removing>=0 && update.removing<=inkPages[pi][index].points.count && inkPages[pi][index].points.count-update.removing+update.points.count>0 && update.points.count==update.factors.count && update.removingOutlines>=0 && update.removingOutlines<=shapeCount)
        let from=shapeCount-update.removingOutlines
        let oldTail=Array(inkPages[pi][index].outlines!.suffix(update.removingOutlines))
        let damaged=InkOutline.bounds(oldTail+update.outlines).insetBy(dx:-1,dy:-1)
        if update.removing>0 {inkPages[pi][index].points.removeLast(update.removing);inkPages[pi][index].widthFactors?.removeLast(update.removing)}
        inkPages[pi][index].points.append(contentsOf:update.points);inkPages[pi][index].widthFactors?.append(contentsOf:update.factors)
        inkPages[pi][index].outlines?.removeLast(update.removingOutlines);inkPages[pi][index].outlines?.append(contentsOf:update.outlines)
        // Native Ink can finalize or accept a pressure sample without changing
        // any contour. A null damage rectangle must not enter view conversion.
        if !damaged.isNull && !damaged.isEmpty { onInkChange?(page,damaged,.tail(id,from)) }
    }

    func appendInkPoints(_ points: [InkPoint], factors: [Double]? = nil, to id: UUID, on page: PDFPage) {
        updateInkTail(removing:0,points:points,factors:factors,to:id,on:page)
    }

    func updateInkTail(removing: Int, points: [InkPoint], factors: [Double]? = nil, to id: UUID, on page: PDFPage) {
        precondition(Thread.isMainThread && pendingAction != nil)
        let pageIndex = document.index(for: page)
        guard !points.isEmpty, inkPages.indices.contains(pageIndex),
              let index = (inkPages[pageIndex].last?.id==id ? inkPages[pageIndex].count-1 : inkPages[pageIndex].firstIndex(where: { $0.id == id })) else { return }
        precondition(inkPages[pageIndex][index].widthFactors == nil ? factors == nil : factors?.count == points.count)
        let count=inkPages[pageIndex][index].points.count
        precondition(removing>=0 && removing<count && count-removing+points.count<=100_000)
        let from=count-removing
        // Only copy the bounded old tail for damage; never retain the entire stroke.
        let oldTail=Array(inkPages[pageIndex][index].points.suffix(removing+1))
        let width = inkPages[pageIndex][index].width
        let priorFactor = inkPages[pageIndex][index].widthFactors?.suffix(removing+1).max() ?? 1
        let tail = oldTail+points
        let radius = width * max(priorFactor, factors?.max() ?? 1) / 2
        let damage = tail.reduce(CGRect.null) { $0.union(CGRect(origin: $1.cgPoint, size: .zero)) }
            .insetBy(dx: -radius-1, dy: -radius-1)
        if removing>0 {inkPages[pageIndex][index].points.removeLast(removing);inkPages[pageIndex][index].widthFactors?.removeLast(removing)}
        inkPages[pageIndex][index].points.append(contentsOf: points)
        if let factors { inkPages[pageIndex][index].widthFactors?.append(contentsOf: factors) }
        onInkChange?(page,damage,.tail(id,from))
    }

    // Export into a detached document. The displayed PDF never temporarily gains a
    // second copy of Canvas ink, even during undo snapshots, recovery, or a slow save.
    func portableDocument() -> PDFDocument? {
        guard !annotationReadOnly else{return nil}
        return Self.exportDocument(base:backingData,model:annotations,slots:managedSourceSlots,origins:sourceMarkSlots)
    }

    // Each export owns its PDFKit graph entirely on its calling queue.
    private static func exportDocument(base:Data,model annotations:AnnotationStore,slots managedSourceSlots:[Set<Int>],origins sourceMarkSlots:[UUID:(Int,Int)]) -> PDFDocument? {
        let inkPages=annotations.ink
        guard let exported = PDFDocument(data: base), exported.pageCount == inkPages.count else { return nil }
        var originals: [UUID:PDFAnnotation] = [:]
        for (id,slot) in sourceMarkSlots { if let p=exported.page(at:slot.0),p.annotations.indices.contains(slot.1) { originals[id]=p.annotations[slot.1] } }
        for index in 0..<exported.pageCount {
            guard let page = exported.page(at:index) else { return nil }
            // Remove only known managed source slots. Foreign annotations/resources remain in place.
            for (slot,a) in page.annotations.enumerated() where managedSourceSlots[index].contains(slot) { page.removeAnnotation(a) }
        }
        for mark in annotations.marks {
            let original=originals[mark.id]
            let a = original.flatMap { AnnotationPDF.compatible(mark,$0) ? $0:nil } ?? AnnotationPDF.make(mark)
            a.setValue(mark.id.uuidString,forAnnotationKey:AnnotationPDF.markKey)
            exported.page(at:mark.anchor.page)?.addAnnotation(a)
        }
        let imagesByID=Dictionary(uniqueKeysWithValues:annotations.images.map{($0.id,$0)})
        for index in inkPages.indices {
            let inkByID=Dictionary(uniqueKeysWithValues:inkPages[index].map{($0.id,$0)})
            for id in annotations.orderedIDs(on:index) {
                if let image=imagesByID[id],let data=annotations.imageAssets?[image.asset] {
                    exported.page(at:index)?.addAnnotation(ImagePDFAnnotation(image,data:data))
                } else if let stroke=inkByID[id] {
                    let a=InkAnnotationCodec.make(stroke);a.setValue(id.uuidString,forAnnotationKey:AnnotationPDF.markKey)
                    exported.page(at:index)?.addAnnotation(a)
                }
            }
        }
        do { try AnnotationPDF.install(annotations,into:exported) } catch { return nil }
        return exported
    }

    private func portableData(_ exported: PDFDocument?) -> Data? {
        guard let bytes = exported?.dataRepresentation() else { return nil }
        return PDFPagePreservation.preserve(backingData, in: bytes, removing: managedSourceSlots)
    }

    @discardableResult
    func beginAction(_ label: String) -> Bool {
        precondition(Thread.isMainThread)
        guard !annotationReadOnly else { return false }
        if usesLocalAnnotations { return beginInkAction(label) }
        if pendingAction != nil { finishAction() }
        guard pendingAction == nil, let snapshot = snapshot() else { return false }
        pendingAction = (label, snapshot)
        pendingActionToken = UUID()
        return true
    }

    @discardableResult
    func beginAction(label: String) -> Bool { beginAction(label) }

    /// Ink, erasing and moving only mutate value-type geometry. Their undo
    /// snapshots share immutable array storage and never serialize a PDF.
    @discardableResult
    func beginInkAction(_ label: String) -> Bool {
        precondition(Thread.isMainThread)
        guard !annotationReadOnly else { return false }
        if snapshotDataProvider != nil && !usesLocalAnnotations { return beginAction(label) }
        if pendingAction != nil { finishAction() }
        guard pendingAction == nil else { return false }
        pendingAction = (label, inkSnapshot())
        pendingActionToken = UUID()
        return true
    }

    private var bodyActionID: UUID?

    func finishBodyEditing() {
        if bodyActionID != nil { finishAction() }
    }

    private func inkSnapshot() -> Snapshot {
        Snapshot(data: recoveryBasePDF, revision: revision, signature: "", inkOnly: true, model: annotations)
    }

    func finishAction() {
        precondition(Thread.isMainThread)
        guard let (label, before) = pendingAction else { return }
        // A failed after-snapshot keeps the action dirty and in memory. Navigation,
        // close/save and later edits cannot silently treat it as a clean document.
        if !before.inkOnly { captureNativeHighlights() }
        let existing=annotations.allMarkIDs
        if annotations.objectGroups != nil {annotations.groups=annotations.groups.compactMap{var g=$0;g.members.removeAll{!existing.contains($0)};return g.members.count>=2 ? g:nil}}
        annotations.objectOrder=annotations.objectOrder?.filter{existing.contains($0)}
        let usedAssets=Set(annotations.images.map(\.asset));annotations.imageAssets=annotations.imageAssets?.filter{usedAssets.contains($0.key)}
        guard let after = before.inkOnly ? inkSnapshot() : snapshot() else { return }
        pendingAction = nil
        bodyActionID = nil
        pendingActionToken = nil
        guard after.model != before.model || (!before.inkOnly && after.signature != before.signature) else { return }
        revision = UUID()
        let revised = Snapshot(data: after.data, revision: revision, signature: after.signature, inkOnly: after.inkOnly, model: after.model)
        recoveryBasePDF = after.data
        let change=AnnotationChange(from:before.model,to:after.model)
        let entry=ActionEntry(label:label,beforeRevision:before.revision,afterRevision:revised.revision,change:change)
        historyBytes -= redoEntries.reduce(0){$0+$1.change.estimatedBytes}
        undoEntries.append(entry);historyBytes += change.estimatedBytes
        // Retire only oldest complete actions, preserving useful recent undo/redo.
        while historyBytes>historyBudget && undoEntries.count>32 {historyBytes -= undoEntries.removeFirst().change.estimatedBytes}
        redoEntries.removeAll()
        if after.inkOnly { scheduleInkRecovery() }
        else { checkpointRecovery(captured: after.data) }
        onChange?()
    }

    func undo() {
        finishAction()
        guard pendingAction == nil else { return }
        guard let action = undoEntries.popLast() else { return }
        let old=annotations;applyHistory(action,forward:false)
        redoEntries.append(action)
        historyNote(annotations, other:old, label:"撤销 · " + action.label)
        scheduleInkRecovery()
        onChange?()
    }

    func redo() {
        finishAction()
        guard pendingAction == nil else { return }
        guard let action = redoEntries.popLast() else { return }
        let old=annotations;applyHistory(action,forward:true)
        undoEntries.append(action)
        historyNote(annotations, other:old, label:"重做 · " + action.label)
        scheduleInkRecovery()
        onChange?()
    }

    private func snapshot() -> Snapshot? {
        let exported = portableDocument()
        let bytes = snapshotDataProvider.map { $0() } ?? portableData(exported)
        guard let data = bytes else {
            lastError = DocumentSessionError.serialize
            onChange?()
            return nil
        }
        return Snapshot(data: data, revision: revision, signature: exported.map { PDFFidelity($0).signature } ?? "", model: annotations)
    }

    private func applyHistory(_ action:ActionEntry,forward:Bool) {
        let old=annotations
        annotations=action.change.applying(to:annotations,forward:forward)
        revision=forward ? action.afterRevision:action.beforeRevision
        if old.marks != annotations.marks {syncMarkAdapters()}
        invalidateModelDifference(old)
    }

    private func restore(_ snapshot: Snapshot) -> Bool {
        let old = annotations
        annotations = snapshot.model; revision = snapshot.revision; recoveryBasePDF = snapshot.data
        if old.marks != annotations.marks { syncMarkAdapters() }
        invalidateModelDifference(old)
        return true
    }

    private func invalidateModelDifference(_ old: AnnotationStore) {
        for (i,page) in backingPages.enumerated() {
            if old.ink.indices.contains(i), annotations.ink.indices.contains(i),
                old.images != annotations.images || old.objectOrder != annotations.objectOrder || old.ink[i] != annotations.ink[i] || old.marks.filter({$0.anchor.page == i}) != annotations.marks.filter({$0.anchor.page == i}) {
                onInkChange?(page,page.bounds(for:.cropBox),.reset)
            }
        }
    }

    /// Manual save only. Main captures immutable values; detached export, validation
    /// and atomic I/O execute serially on the save worker.
    func save(to proposedURL: URL? = nil, completion: @escaping (Result<SaveOutcome, Error>) -> Void) {
        precondition(Thread.isMainThread)
        finishAction()
        guard !annotationReadOnly else { completion(.failure(DocumentSessionError.unsupported(capabilities.canEdit ? "批注冲突或新格式，只读保护" : capabilities.summary))); return }
        guard !isSaving else { completion(.failure(DocumentSessionError.busy)); return }
        if usesLocalAnnotations {
            do {
                if let proposedURL { try exportLocalAnnotations(to:proposedURL) }
                else { try saveLocalAnnotations() }
                completion(.success(SaveOutcome(url:proposedURL ?? fileURL,containsNewerUnsavedChanges:isModified,recoveryCleanupSucceeded:true)))
            } catch { failSave(error,completion:completion) }
            return
        }
        let target = Self.canonicalURL(proposedURL ?? fileURL)
        let sameTarget = target == fileURL
        if sameTarget && conflictDetected { failSave(DocumentSessionError.conflict, completion: completion); return }
        if isTargetOpenElsewhere?(target) == true { failSave(DocumentSessionError.duplicateTarget, completion: completion); return }
        guard backingPages.count == document.pageCount && backingPages.enumerated().allSatisfy({ document.page(at: $0.offset) === $0.element }) else {
            failSave(DocumentSessionError.validation("原始页面内容或图像资源的页面身份改变"), completion: completion); return
        }
        let capturedRevision = revision
        let capturedModel=annotations
        let originalBytes = backingData
        let removedSlots = managedSourceSlots
        let origins=sourceMarkSlots
        let structure = originalStructure
        let content = originalContent
        let sourceFingerprint=originalFingerprint
        // Save As target identity is read on the worker, before capture/export.
        // The final atomic write still checks it again immediately before rename.
        isSaving = true
        savingTarget = target
        lastError = nil
        onChange?()
        let hook = saveWorkHook
        let exportProvider = saveDataProvider
        worker.async { [weak self] in
            let result: Result<String, Error>
            // PDFKit can create AppKit annotation adaptors even for detached
            // graphs. Transfer their final teardown to main after worker use.
            var detachedDocuments:[PDFDocument]=[]
            defer {
                let completed=detachedDocuments
                DispatchQueue.main.async {withExtendedLifetime(completed){}}
            }
            do {
                let expectedFingerprint:String? = sameTarget ? sourceFingerprint:(FileManager.default.fileExists(atPath:target.path) ? Self.fingerprint(try Data(contentsOf:target)):nil)
                hook?()
                guard let exported=Self.exportDocument(base:originalBytes,model:capturedModel,slots:removedSlots,origins:origins) else{throw DocumentSessionError.serialize}
                detachedDocuments.append(exported)
                let generated=exportProvider.map{$0()} ?? exported.dataRepresentation()
                guard let raw=generated,let bytes=PDFPagePreservation.preserve(originalBytes,in:raw,removing:removedSlots) else {throw DocumentSessionError.serialize}
                let expectedManifest=(0..<exported.pageCount).flatMap{exported.page(at:$0)!.annotations}.compactMap{$0.value(forAnnotationKey:AnnotationPDF.manifest) as? String}.first
                let fidelity=PDFFidelity(exported)
                let expectedOpacity=AppearanceOpacityExpectation.capture(exported)
                guard let reopened = PDFDocument(data: bytes) else { throw DocumentSessionError.validation("重开失败") }
                detachedDocuments.append(reopened)
                try Self.checkSupported(document: reopened, data: bytes)
                guard PDFPagePreservation.validate(originalBytes, saved:bytes, removing:removedSlots) else {
                    throw DocumentSessionError.validation("表单、附件或未修改对象关系改变")
                }
                let reopenedStructure = PDFStructure(reopened)
                guard reopenedStructure == structure else {
                    if EcruEnvironment.value("ECRU_TEST_DIAGNOSTICS") == "1" {
                        print("EXPECTED STRUCTURE", structure, "ACTUAL STRUCTURE", reopenedStructure)
                    }
                    throw DocumentSessionError.validation("原文、页框、旋转或目录改变")
                }
                guard try PDFContentIntegrity(bytes) == content else { throw DocumentSessionError.validation("原始页面内容或图像资源改变") }
                guard PDFFidelity(reopened).matches(fidelity) else {
                    if EcruEnvironment.value("ECRU_TEST_DIAGNOSTICS") == "1" {
                        print("EXPECTED", fidelity.signature, "ACTUAL", PDFFidelity(reopened).signature)
                        fflush(stdout)
                    }
                    throw DocumentSessionError.validation("批注、链接或可编辑笔迹信息改变")
                }
                let manifests = (0..<reopened.pageCount).flatMap { reopened.page(at:$0)!.annotations }.compactMap { $0.value(forAnnotationKey:AnnotationPDF.manifest) as? String }
                guard manifests.count == 1, manifests[0] == expectedManifest else { throw DocumentSessionError.validation("内嵌批注数据改变") }
                try AppearanceOpacityExpectation.validate(expectedOpacity, in: bytes)
                try Self.atomicWrite(bytes, target: target, expectedFingerprint: expectedFingerprint)
                result = .success(Self.fingerprint(bytes))
            } catch { result = .failure(error) }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isSaving = false
                self.savingTarget = nil
                switch result {
                case .success(let fingerprint):
                    let oldRecoveryURL = self.recoveryURL
                    self.fileURL = target
                    self.originalFingerprint = fingerprint
                    self.savedRevision = capturedRevision
                    self.conflictDetected = false
                    self.isRecovered = false
                    self.lastError = nil
                    if oldRecoveryURL != self.recoveryURL { self.pendingOldRecoveryURLs.insert(oldRecoveryURL) }
                    let cleanupSucceeded: Bool
                    if self.isModified {
                        cleanupSucceeded = self.clearRecoveryRecords(at: self.pendingOldRecoveryURLs)
                        let cleanupError = cleanupSucceeded ? nil : self.lastError
                        self.checkpointRecovery()
                        if let cleanupError {
                            if let recoveryError = self.lastError, recoveryError.localizedDescription != cleanupError.localizedDescription {
                                self.lastError = DocumentSessionError.recoveryCleanup(cleanupError.localizedDescription + "；" + recoveryError.localizedDescription)
                            } else { self.lastError = cleanupError }
                        }
                    } else {
                        cleanupSucceeded = self.discardRecovery()
                    }
                    self.onChange?()
                    completion(.success(SaveOutcome(url: target, containsNewerUnsavedChanges: self.isModified, recoveryCleanupSucceeded: cleanupSucceeded)))
                case .failure(let error):
                    if let failure=error as? DocumentSessionError {
                        switch failure {
                        case .serialize, .validation:
                            self.usesLocalAnnotations=true
                            do {
                                try self.saveLocalAnnotations()
                                if target != self.fileURL {try self.exportLocalAnnotations(to:target)}
                                self.onChange?()
                                completion(.success(SaveOutcome(url:target,containsNewerUnsavedChanges:self.isModified,recoveryCleanupSucceeded:true)))
                            } catch {self.failSave(error,completion:completion)}
                            return
                        default:break
                        }
                    }
                    if case DocumentSessionError.conflict = error { self.conflictDetected = sameTarget }
                    self.lastError = error
                    self.onChange?()
                    completion(.failure(error))
                }
            }
        }
    }

    /// Explicitly lossy conversion after UI consent. No permissions/encryption/signature bypass.
    /// Generate from the inert reading view into a brand new file; never replace any file.
    func createStaticAnnotationCopy(to url: URL) throws {
        precondition(Thread.isMainThread)
        guard capabilities.canCreateStaticCopy, !isModified else { throw DocumentSessionError.unsupported(capabilities.summary) }
        let target=Self.canonicalURL(url)
        guard target != fileURL, !FileManager.default.fileExists(atPath:target.path) else { throw DocumentSessionError.io("副本必须使用尚不存在的新文件名") }
        guard isTargetOpenElsewhere?(target) != true else { throw DocumentSessionError.duplicateTarget }
        let data=try staticAnnotationCopyData()
        try Self.atomicWrite(data,target:target,expectedFingerprint:nil)
    }

    private func staticAnnotationCopyData() throws -> Data {
        // PDFPage.copy() can retain the source document/page backing. Changing its
        // rotation then notifies the live PDFThumbnailView, including while hidden.
        // Render from independently parsed, inert bytes so conversion never mutates
        // or sends page-geometry notifications for the document bound to the reader.
        guard let drawingDocument = PDFDocument(data: searchData),
              drawingDocument.pageCount == document.pageCount else { throw DocumentSessionError.serialize }
        for i in 0..<drawingDocument.pageCount {
            let page=drawingDocument.page(at:i)!
            for (slot,annotation) in page.annotations.enumerated() where managedSourceSlots[i].contains(slot) {page.removeAnnotation(annotation)}
        }
        let beforeDocument=PDFDocument(data:drawingDocument.dataRepresentation() ?? searchData)!
        let bytes=NSMutableData()
        guard let consumer=CGDataConsumer(data:bytes), let context=CGContext(consumer:consumer,mediaBox:nil,nil) else { throw DocumentSessionError.serialize }
        for i in 0..<document.pageCount {
            guard let page=document.page(at:i) else { throw DocumentSessionError.invalidPDF }
            var box=page.bounds(for:.mediaBox), crop=page.bounds(for:.cropBox)
            let boxData=Data(bytes:&box,count:MemoryLayout<CGRect>.size)
            let cropData=Data(bytes:&crop,count:MemoryLayout<CGRect>.size)
            context.beginPDFPage([kCGPDFContextMediaBox as String:boxData,kCGPDFContextCropBox as String:cropData] as CFDictionary)
            guard let drawing=drawingDocument.page(at:i) else { throw DocumentSessionError.serialize }
            // PDFPage.draw applies /Rotate. Paint once at zero rotation, then restore
            // the source /Rotate on the output page so rotated/cropped pages are not double-rotated.
            drawing.rotation=0;drawing.draw(with:.mediaBox,to:context)
            context.endPDFPage()
        }
        context.closePDF()
        guard let copy=PDFDocument(data:bytes as Data),copy.pageCount==document.pageCount else { throw DocumentSessionError.serialize }
        for i in 0..<copy.pageCount { copy.page(at:i)?.rotation=document.page(at:i)!.rotation }
        copy.documentAttributes=[PDFDocumentAttribute.subjectAttribute:"Ecru 静态批注副本：动态结构与原有可编辑批注已移除", PDFDocumentAttribute.keywordsAttribute:["EcruStaticAnnotationCopy"]]
        guard let data=copy.dataRepresentation() else { throw DocumentSessionError.serialize }
        try Self.checkSupported(document:copy,data:data)
        let inspection=try PDFPagePreservation.inspect(data,password:nil)
        guard inspection.features == 0, (0..<copy.pageCount).allSatisfy({ copy.page(at:$0)?.annotations.isEmpty == true }) else { throw DocumentSessionError.validation("静态副本仍包含原有交互结构") }
        guard let verified=PDFDocument(data:data),verified.pageCount==document.pageCount else { throw DocumentSessionError.validation("静态副本重开失败") }
        for i in 0..<document.pageCount {
            let before=beforeDocument.page(at:i)!,after=verified.page(at:i)!
            guard before.rotation==after.rotation, AnnotationPDF.close(AnnotationPDF.identity(before).crop,AnnotationPDF.identity(after).crop),
                  Self.staticTextPreserved(before.string ?? "",in:after.string ?? ""),
                  Self.sameStaticAppearance(before,after) else { throw DocumentSessionError.validation("第 \(i+1) 页静态内容或显示改变，未创建副本") }
        }
        return data
    }

    func exportAnnotatedPDF(to url:URL) throws {
        if usesLocalAnnotations {try exportLocalAnnotations(to:url);return}
        finishAction()
        let target=Self.canonicalURL(url)
        guard target != fileURL,!FileManager.default.fileExists(atPath:target.path) else {throw DocumentSessionError.io("导出必须使用新文件名，原件不会改变")}
        guard isTargetOpenElsewhere?(target) != true else {throw DocumentSessionError.duplicateTarget}
        guard let projected=portableDocument(),let bytes=portableData(projected),let reopened=PDFDocument(data:bytes),
              PDFStructure(reopened)==originalStructure,try PDFContentIntegrity(bytes)==originalContent,
              PDFFidelity(reopened).matches(PDFFidelity(projected)) else {throw DocumentSessionError.validation("导出未通过页面和批注保留校验")}
        try AppearanceOpacityExpectation.validate(AppearanceOpacityExpectation.capture(projected),in:bytes)
        try Self.atomicWrite(bytes,target:target,expectedFingerprint:nil)
    }

    /// Share a self-contained PDF; local notes are never a prerequisite for the recipient.
    func exportLocalAnnotations(to url:URL) throws {
        guard usesLocalAnnotations,allowsLocalPDFExport else {throw DocumentSessionError.unsupported("文档不允许打印或导出；独立批注仍保存在 Ecru")}
        finishAction()
        do {try saveLocalAnnotations()} catch {lastError=error} // Export can rescue edits even when the local store is unavailable.
        let target=Self.canonicalURL(url)
        guard target != fileURL,!FileManager.default.fileExists(atPath:target.path) else {throw DocumentSessionError.io("导出必须使用新的文件名，不能覆盖原件或已有文件")}
        guard isTargetOpenElsewhere?(target) != true else {throw DocumentSessionError.duplicateTarget}
        let base=try staticAnnotationCopyData()
        guard let baseDocument=PDFDocument(data:base) else {throw DocumentSessionError.serialize}
        let content=try PDFContentIntegrity(base)
        var exportModel=annotations
        for i in exportModel.pages.indices {
            var page=AnnotationPDF.identity(baseDocument.page(at:i)!);page.id=exportModel.pages[i].id
            page.contentHash=AnnotationPDF.hash(Data(content.pages[i].utf8));exportModel.pages[i]=page
        }
        guard let projected=Self.exportDocument(base:base,model:exportModel,slots:backingPages.map{_ in []},origins:[:]),
              let raw=projected.dataRepresentation(),let bytes=PDFPagePreservation.preserve(base,in:raw,removing:backingPages.map{_ in []}),
              let reopened=PDFDocument(data:bytes),PDFFidelity(reopened).matches(PDFFidelity(projected)) else {throw DocumentSessionError.validation("导出批注内容未通过检查")}
        try Self.checkSupported(document:reopened,data:bytes)
        let models=(0..<reopened.pageCount).flatMap{reopened.page(at:$0)!.annotations}.compactMap{$0.value(forAnnotationKey:AnnotationPDF.manifest) as? String}
        guard models.count==1,try AnnotationPDF.decode(models[0])==exportModel else {throw DocumentSessionError.validation("导出的笔记或笔迹不完整")}
        try Self.atomicWrite(bytes,target:target,expectedFingerprint:nil)
    }

    private static func staticTextPreserved(_ original:String,in copy:String) -> Bool {
        func inventory(_ value:String)->[Character:Int] {
            value.filter { !$0.isWhitespace }.reduce(into:[:]) { $0[$1,default:0]+=1 }
        }
        let output=inventory(copy)
        // Flattened widget appearances become additional searchable page text.
        return inventory(original).allSatisfy { output[$0.key,default:0] >= $0.value }
    }

    private static func sameStaticAppearance(_ before:PDFPage,_ after:PDFPage) -> Bool {
        func pixels(_ page:PDFPage)->[UInt8]? {
            let image=page.thumbnail(of:CGSize(width:512,height:512),for:.cropBox)
            var rect=CGRect(origin:.zero,size:image.size)
            guard let cg=image.cgImage(forProposedRect:&rect,context:nil,hints:nil) else{return nil}
            var bytes=[UInt8](repeating:255,count:512*512*4)
            let ok=bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context=CGContext(data:buffer.baseAddress,width:512,height:512,bitsPerComponent:8,bytesPerRow:512*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
                context.setFillColor(CGColor(gray:1,alpha:1));context.fill(CGRect(x:0,y:0,width:512,height:512))
                context.draw(cg,in:CGRect(x:0,y:0,width:512,height:512));return true
            }
            return ok ? bytes : nil
        }
        guard let a=pixels(before),let b=pixels(after) else{return false}
        var total=0,changed=0
        for i in a.indices { let difference=abs(Int(a[i])-Int(b[i]));total+=difference;if difference>24 {changed+=1} }
        // Allow raster antialiasing drift, reject lost fields, drawings or page transforms.
        return Double(total)/Double(a.count)<1 && Double(changed)/Double(a.count)<0.005
    }

    private func failSave(_ error: Error, completion: (Result<SaveOutcome, Error>) -> Void) {
        lastError = error
        onChange?()
        completion(.failure(error))
    }

    var recoverableRecord: RecoveryRecord? {
        guard !usesLocalAnnotations else {return nil}
        recoveryWriter.flush()
        guard let record = try? RecoveryStore.read(recoveryURL), (1...7).contains(record.version),
              Self.canonicalURL(URL(fileURLWithPath: record.sourcePath)) == fileURL else { return nil }
        return record
    }

    func restoreRecovery(_ record: RecoveryRecord) throws {
        precondition(Thread.isMainThread)
        guard !annotationReadOnly && !usesLocalAnnotations else { throw DocumentSessionError.unsupported("当前 PDF 只读，保留恢复记录，禁止用旧草稿覆盖") }
        guard (1...7).contains(record.version), Self.canonicalURL(URL(fileURLWithPath: record.sourcePath)) == fileURL,
        let restored = PDFDocument(data: record.pdfData) else { throw DocumentSessionError.invalidPDF }
        try Self.checkSupported(document: restored, data: record.pdfData)
        if record.version == 2 {
            guard let ink = record.ink, ink.count == restored.pageCount,
                  ink.allSatisfy({ $0.allSatisfy(\.isValid) }) else { throw DocumentSessionError.invalidPDF }
        }
        if record.version >= 3 {
            guard let model = record.annotations, model.valid(), model.pages.count == restored.pageCount else { throw DocumentSessionError.invalidPDF }
            let origins = record.markOrigins ?? []
            guard Set(origins.map(\.id)).count == origins.count,
                  Set(origins.map { "\($0.page):\($0.slot)" }).count == origins.count,
                  origins.allSatisfy({ origin in
                      guard origin.page >= 0, origin.page < restored.pageCount,
                            let page = restored.page(at: origin.page) else { return false }
                      guard page.annotations.indices.contains(origin.slot) else { return false }
                      if let mark = model.marks.first(where: { $0.id == origin.id }) {
                          return mark.anchor.page == origin.page && AnnotationPDF.compatible(mark, page.annotations[origin.slot])
                      }
                      return true // An origin for a deleted mark is retained for undo.
                  }) else { throw DocumentSessionError.invalidPDF }
        }
        let recoveredContent = try PDFContentIntegrity(record.pdfData)
        // A source changed since a crash is retained as a conflict, never overwritten.
        conflictDetected = record.originalFingerprint != originalFingerprint || !FileManager.default.fileExists(atPath:fileURL.path)
        originalFingerprint = record.originalFingerprint
        backingData = record.pdfData
        document = restored
        searchData=record.pdfData;searchIdentity=UUID()
        recoveryBasePDF = record.pdfData
        originalContent = recoveredContent
        importEditableInk()
        if record.version == 2 { inkPages = record.ink!;annotations.minimumReader=max(inkPages.flatMap{$0}.map(\.requiredReader).max() ?? 1,annotations.minimumReader) }
        if record.version >= 3 {
            annotations = record.annotations!
            if let origins = record.markOrigins {
                sourceMarkSlots = Dictionary(uniqueKeysWithValues: origins.map { ($0.id, ($0.page, $0.slot)) })
            }
            syncMarkAdapters()
        }
        capabilities = PDFCapabilities.assess(try PDFPagePreservation.inspect(record.pdfData,password:nil).features, allowsCommenting:restored.allowsCommenting, allowsPrinting:restored.allowsPrinting)
        originalStructure = PDFStructure(restored)
        originalContent = recoveredContent
        revision = UUID() // Recovery always remains unsaved, even if its bytes equal disk.
        undoEntries.removeAll()
        redoEntries.removeAll();historyBytes=0
        isRecovered = true
        lastError = nil
        checkpointRecovery()
        onChange?()
    }

    /// Used only after the user explicitly chooses not to save.
    @discardableResult
    func discardUnsavedChanges() -> Bool {
        guard usesLocalAnnotations else {return discardRecovery()}
        recoveryWriter.cancelAndWait()
        do {
            if FileManager.default.fileExists(atPath:localAnnotationsURL.path) {
                let record=try RecoveryStore.read(localAnnotationsURL)
                guard let model=record.annotations,model.valid(),record.originalFingerprint==originalFingerprint,record.pdfData==backingData else {throw DocumentSessionError.invalidPDF}
                annotations=model;revision=record.revision;localBaseRevision=record.revision
            }
            savedRevision=revision;lastError=nil;return true
        } catch {lastError=error;return false}
    }

    @discardableResult
    func discardRecovery() -> Bool {
        if usesLocalAnnotations {
            recoveryWriter.flush()
            if let error=recoveryWriter.failure {lastError=error;return false}
            return true
        }
        guard capabilities.canEdit else { return true } // Protected opens never delete existing drafts.
        let result = clearRecoveryRecords(at: pendingOldRecoveryURLs.union([recoveryURL]))
        onChange?()
        return result
    }

    private func clearRecoveryRecords(at urls: Set<URL>) -> Bool {
        // Explicit save/discard may wait for disk I/O. No queued older write can
        // recreate a recovery file after this deletion or a Save As path change.
        recoveryWriter.cancelAndWait()
        var failures: [String] = []
        for url in urls {
            do {
                try RecoveryStore.remove(url)
                pendingOldRecoveryURLs.remove(url)
            } catch {
                let failure = error as NSError
                if failure.domain == NSCocoaErrorDomain && failure.code == NSFileNoSuchFileError {
                    pendingOldRecoveryURLs.remove(url)
                } else {
                    failures.append(error.localizedDescription)
                }
            }
        }
        if failures.isEmpty {
            if let error = lastError, case DocumentSessionError.recoveryCleanup = error { lastError = nil }
            return true
        }
        lastError = DocumentSessionError.recoveryCleanup(failures.joined(separator: "；"))
        return false
    }

    private var localAnnotationsURL:URL {
        dataDirectory.appendingPathComponent("Annotations/"+Self.fingerprint(Data(fileURL.path.utf8)),isDirectory:true).appendingPathComponent(originalFingerprint+".json")
    }
    private func saveLocalAnnotations() throws {
        scheduleInkRecovery();recoveryWriter.flush()
        if let error=recoveryWriter.failure {throw error}
        savedRevision=revision;localBaseRevision=revision;lastError=nil;onChange?()
    }

    private var recoveryURL: URL {
        let key = Self.fingerprint(Data(fileURL.path.utf8))
        return dataDirectory.appendingPathComponent("Recovery", isDirectory: true).appendingPathComponent(key + ".json")
    }

    func checkpointRecovery(captured: Data? = nil) {
        guard !annotationReadOnly else{return}
        if let provider=recoveryDataProvider,provider()==nil {
            lastError=DocumentSessionError.io("自动恢复数据生成失败，当前内容仍在窗口")
            onChange?();return
        }
        scheduleInkRecovery()
        recoveryWriter.flush()
        // Explicit lifecycle checkpoint waits for durability, not PDF export.
        // Deliver a worker failure synchronously as existing save/quit callers require.
        if let error=recoveryWriter.failure,isModified {lastError=DocumentSessionError.io("自动恢复保护写入失败：\(error.localizedDescription)")}
    }

    private func scheduleInkRecovery() {
        if !isModified && !usesLocalAnnotations { discardRecovery(); return }
        var record = RecoveryRecord(version: annotations.minimumReader>=5 ? 7 : annotations.minimumReader>=4 ? 6 : annotations.minimumReader>=3 ? 5 : (annotations.minimumReader>=2 ? 4 : 3), sourcePath: fileURL.path,
            originalFingerprint: originalFingerprint, pdfData: backingData,
            revision: revision, updatedAt: Date(), ink: inkPages, annotations: annotations,
            markOrigins: sourceMarkSlots.map { MarkSourceOrigin(id: $0.key, page: $0.value.0, slot: $0.value.1) })
        if usesLocalAnnotations {record.independentStore=true;record.independentBaseRevision=localBaseRevision}
        let target = usesLocalAnnotations ? localAnnotationsURL : recoveryURL
        recoveryWriter.submit(record, to: target, hook: recoveryWriteHook) { [weak self] error in
            guard let self, (self.usesLocalAnnotations || self.isModified), self.revision == record.revision,
                  (self.usesLocalAnnotations ? self.localAnnotationsURL : self.recoveryURL) == target else { return }
            if self.usesLocalAnnotations && error == nil {
                self.savedRevision=record.revision;self.localBaseRevision=record.revision;self.lastError=nil;self.onChange?()
            }
            if let error {
                let reason="自动恢复保护写入失败：\(error.localizedDescription)"
                if let existing=self.lastError,case DocumentSessionError.recoveryCleanup=existing {
                    if !existing.localizedDescription.contains(reason) {self.lastError=DocumentSessionError.recoveryCleanup(existing.localizedDescription+"；"+reason)}
                } else {self.lastError = DocumentSessionError.io(reason)}
                self.onChange?()
            }
        }
    }

    private static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func checkSupported(document: PDFDocument, data: Data) throws {
        guard !document.isLocked, document.pageCount>0 else { throw DocumentSessionError.invalidPDF }
        let result = try PDFPagePreservation.inspect(data,password:nil)
        let ability = PDFCapabilities.assess(result.features,allowsCommenting:document.allowsCommenting,allowsPrinting:document.allowsPrinting)
        guard ability.canEdit else { throw DocumentSessionError.unsupported(ability.summary) }
    }

    private static func atomicWrite(_ bytes: Data, target: URL, expectedFingerprint: String?) throws {
        let manager = FileManager.default
        let parent = target.deletingLastPathComponent()
        var parentInfo = stat()
        guard stat(parent.path, &parentInfo) == 0, parentInfo.st_mode & 0o222 != 0, manager.isWritableFile(atPath: parent.path) else { throw DocumentSessionError.readOnly }
        let exists = manager.fileExists(atPath: target.path)
        var mode: mode_t = 0o600
        if exists {
            var info = stat()
            guard stat(target.path, &info) == 0, info.st_mode & 0o222 != 0,
                  info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) == 0,
                  manager.isWritableFile(atPath: target.path) else { throw DocumentSessionError.readOnly }
            mode = info.st_mode & 0o777
        }
        let temporary = parent.appendingPathComponent(".Ecru-\(UUID().uuidString).pdf.tmp")
        defer { try? manager.removeItem(at: temporary) }
        try bytes.write(to: temporary, options: .withoutOverwriting)
        guard chmod(temporary.path, mode) == 0 else { throw DocumentSessionError.io(String(cString: strerror(errno))) }
        let descriptor = Darwin.open(temporary.path, O_RDONLY)
        if descriptor >= 0 { defer { Darwin.close(descriptor) }; guard fsync(descriptor) == 0 else { throw DocumentSessionError.io(String(cString: strerror(errno))) } }
        // Recheck immediately before the atomic rename. This detects observed
        // external edits; an uncooperative writer racing inside this final small
        // interval is not a supported concurrent-editing workflow.
        let currentlyExists = manager.fileExists(atPath: target.path)
        let currentFingerprint = currentlyExists ? Self.fingerprint(try Data(contentsOf: target)) : nil
        guard currentFingerprint == expectedFingerprint else { throw DocumentSessionError.conflict }
        guard Darwin.rename(temporary.path, target.path) == 0 else { throw DocumentSessionError.io(String(cString: strerror(errno))) }
        // Directory durability needs a search descriptor, not directory contents.
        // Reading a protected parent may wait on a separate access check even
        // after an explicitly opened document has been safely renamed. On APFS
        // fsync accepts this search-only descriptor; preserve best-effort
        // directory sync without widening the document's access scope.
        let directoryDescriptor = Darwin.open(parent.path, O_SEARCH | O_CLOEXEC)
        if directoryDescriptor >= 0 { _ = fsync(directoryDescriptor); Darwin.close(directoryDescriptor) }
    }

    private func historyNote(_ model: AnnotationStore, other: AnnotationStore, label: String) {
        let changed = model.notes.first { n in other.notes.first(where: {$0.id == n.id}) != n }
        onHistoryNote?(changed?.id, label)
    }
    func markID(for annotation: PDFAnnotation) -> UUID? {
        ((annotation.value(forAnnotationKey: AnnotationPDF.adapterKey) ?? annotation.value(forAnnotationKey:AnnotationPDF.markKey)) as? String).flatMap(UUID.init(uuidString:))
    }
    func pageAnchor(page: PDFPage, bounds: CGRect, quote: String = "") -> PageAnchor {
        let i = document.index(for:page)
        var anchor = PageAnchor(page:i,pageID:annotations.pages[i].id,bounds:bounds,quote:quote)
        if !quote.isEmpty, let text = page.string, let range = text.range(of:quote) {
            anchor.prefix = String(text[..<range.lowerBound].suffix(48)); anchor.suffix = String(text[range.upperBound...].prefix(48))
        }
        return anchor
    }
    private func visibleTextIndices(_ indices:IndexSet, on page:PDFPage) -> IndexSet {
        let text=(page.string ?? "") as NSString
        return IndexSet(indices.filter { i in
            guard i>=0,i<text.length else{return false}
            let c=text.character(at:i)
            return c != 10 && c != 13 && c != 0x2028 && c != 0x2029
        })
    }
    private func textIndices(_ mark: PageMark, on page: PDFPage) -> IndexSet {
        // Text extraction order may change after PDFKit serialization. Check the
        // stored range against the original geometry before using its indices.
        if let span=mark.textSpan,span.location+span.length<=page.numberOfCharacters,
           let selected=page.selection(for:span.range),AnnotationPDF.close(selected.bounds(for:page),mark.anchor.bounds) {
            return visibleTextIndices(IndexSet(integersIn:span.location..<span.location+span.length),on:page)
        }
        var indices=IndexSet()
        let rect=mark.anchor.bounds
        for i in 0..<page.numberOfCharacters {
            // characterBounds uses a different glyph inventory on some PDFs.
            let b=page.selection(for:NSRange(location:i,length:1))?.bounds(for:page) ?? .zero
            guard !b.isEmpty,rect.insetBy(dx:-0.1,dy:-0.1).contains(CGPoint(x:b.midX,y:b.midY)) else{continue}
            if mark.quads.isEmpty {indices.insert(i)}
            else {
                for offset in stride(from:0,to:mark.quads.count-3,by:4) {
                    let q=[0,1,3,2].map {j in CGPoint(x:rect.minX+mark.quads[offset+j].x,y:rect.minY+mark.quads[offset+j].y)}
                    if InkGeometry.contains(CGPoint(x:b.midX,y:b.midY),polygon:q) {indices.insert(i);break}
                }
            }
        };return visibleTextIndices(indices,on:page)
    }
    private func textFragments(_ indices: IndexSet, page: PDFPage, template: PageMark? = nil, rgba: [Double]) -> [PageMark] {
        var result:[PageMark]=[]
        for range in indices.rangeView {
            guard let selection=page.selection(for:NSRange(location:range.lowerBound,length:range.count)) else{continue}
            for line in selection.selectionsByLine() {
                for n in 0..<line.numberOfTextRanges(on:page) {
                    let expanded=line.range(at:n,on:page)
                    guard expanded.location != NSNotFound,expanded.length>0 else{continue}
                    // PDFKit includes a synthetic newline in the final glyph's range.
                    // Never let that expansion recreate punctuation outside the requested range.
                    let clipped=visibleTextIndices(IndexSet(integersIn:expanded.location..<expanded.location+expanded.length).intersection(indices),on:page)
                    for span in clipped.rangeView {
                        let r=NSRange(location:span.lowerBound,length:span.count)
                        guard let exact=page.selection(for:r) else{continue}
                        let rect=exact.bounds(for:page)
                        guard rect.width>0,rect.height>0 else{continue}
                        var mark=PageMark(kind:.highlight,anchor:pageAnchor(page:page,bounds:rect,quote:exact.string ?? ""),rgba:rgba,
                            quads:[InkPoint(x:0,y:rect.height),InkPoint(x:rect.width,y:rect.height),InkPoint(x:0,y:0),InkPoint(x:rect.width,y:0)])
                        mark.textSpan=TextSpan(location:r.location,length:r.length);mark.textEditable=true
                        if let template {mark.contents=template.contents;mark.userName=template.userName;mark.display=template.display;mark.print=template.print}
                        result.append(mark)
                    }
                }
            }
        };return result
    }
    /// One selection-wide toggle, with subtraction confined to editable Ecru ranges.
    @discardableResult func addTextSelection(_ selection: PDFSelection, color: NSColor = NSColor.systemYellow.withAlphaComponent(0.45), withNote: Bool) -> UUID? {
        let c=color.usingColorSpace(.sRGB) ?? .systemYellow
        let rgba:[Double]=[Double(c.redComponent),Double(c.greenComponent),Double(c.blueComponent),Double(c.alphaComponent)]
        var selected:[Int:IndexSet]=[:]
        for page in selection.pages {
            var indices=IndexSet()
            let text=(page.string ?? "") as NSString
            for n in 0..<selection.numberOfTextRanges(on:page) {
                let r=selection.range(at:n,on:page)
                guard r.location != NSNotFound,r.location>=0,r.length>0,r.location+r.length<=page.numberOfCharacters else{continue}
                for i in r.location..<r.location+r.length {
                    let code=i<text.length ? text.character(at:i):0
                    if code != 10 && code != 13 && code != 0x2028 && code != 0x2029 {indices.insert(i)}
                }
            }
            if !indices.isEmpty {selected[document.index(for:page)]=indices}
        }
        guard !selected.isEmpty,beginInkAction(withNote ? "添加选文批注":"切换文字高亮") else{return nil}
        var fullySame=true
        for (pi,indices) in selected {
            let page=document.page(at:pi)!
            var covered=IndexSet()
            for mark in annotations.marks where mark.kind == .highlight && mark.anchor.page == pi && mark.textEditable != false && zip(mark.rgba,rgba).allSatisfy({abs($0-$1)<0.005}) {covered.formUnion(textIndices(mark,on:page))}
            if !indices.subtracting(covered).isEmpty {fullySame=false}
        }
        var affected:[PageAnchor]=[],added:[PageMark]=[]
        var transferred:[(Int,IndexSet,Int,Bool)]=[]
        for (pi,indices) in selected {
            let page=document.page(at:pi)!
            for old in annotations.marks.filter({$0.kind == .highlight && $0.anchor.page == pi && $0.textEditable != false}) {
                let oldIndices=textIndices(old,on:page)
                guard !oldIndices.intersection(indices).isEmpty else{continue}
                let fragments=textFragments(oldIndices.subtracting(indices),page:page,template:old,rgba:old.rgba)
                annotations.marks.removeAll{$0.id==old.id};annotations.marks+=fragments;affected.append(old.anchor)
                for n in annotations.notes.indices {
                    if let link=annotations.notes[n].links.first(where:{$0.markID==old.id}) {
                        transferred.append((pi,oldIndices.intersection(indices),n,link.owned))
                        annotations.notes[n].links.removeAll{$0.markID==old.id}
                        annotations.notes[n].links+=fragments.map{NoteLink(markID:$0.id,owned:link.owned)}
                        // Body and anchors survive even when the highlight is gone.
                    }
                }
            }
            if !fullySame || withNote {added+=textFragments(indices,page:page,rgba:rgba)}
        }
        if !withNote {
            var owned=Set<UUID>()
            for mark in added {
                let indices=textIndices(mark,on:document.page(at:mark.anchor.page)!)
                for (pi,overlap,n,isOwner) in transferred where pi==mark.anchor.page && !overlap.intersection(indices).isEmpty {
                    if !annotations.notes[n].links.contains(where:{$0.markID==mark.id}) {
                        let owns=isOwner && !owned.contains(mark.id);if owns{owned.insert(mark.id)}
                        annotations.notes[n].links.append(NoteLink(markID:mark.id,owned:owns))
                    }
                }
            }
        }
        annotations.marks+=added;affected+=added.map(\.anchor)
        annotations.minimumReader=max(4,annotations.minimumReader)
        var id:UUID?
        if withNote && !added.isEmpty {
            let note=AnnotationNote(anchors:added.map(\.anchor),links:added.map{NoteLink(markID:$0.id,owned:true)})
            annotations.notes.append(note);id=note.id
        }
        syncMarkAdapters(on:Set(selected.keys));finishAction();invalidateAnchors(affected);return id
    }
    @discardableResult func addRegion(page: PDFPage, rect: CGRect, to noteID: UUID? = nil) -> UUID? {
        guard rect.width > 1, rect.height > 1, beginInkAction(noteID == nil ? "添加区域批注" : "重新关联原文") else { return nil }
        let anchor = pageAnchor(page:page,bounds:rect)
        let mark = PageMark(kind:.region,anchor:anchor,rgba:[0.48,0.40,0.28,0.75])
        annotations.marks.append(mark)
        let id: UUID
        if let noteID, let n = annotations.notes.firstIndex(where: {$0.id == noteID}) {
            annotations.notes[n].links.append(NoteLink(markID:mark.id,owned:true))
            annotations.notes[n].anchors = [anchor]; annotations.notes[n].locationUncertain = false; id = noteID
        } else {
            let note = AnnotationNote(anchors:[anchor],links:[NoteLink(markID:mark.id,owned:true)])
            annotations.notes.append(note); id = note.id
        }
        syncMarkAdapters(on:[anchor.page]); finishAction(); invalidateAnchors([anchor]); return id
    }
    @discardableResult func annotateMarks(_ ids: Set<UUID>) -> UUID? {
        if let existing = annotations.notes.first(where: { n in n.links.contains { ids.contains($0.markID) } }) { return existing.id }
        guard !ids.isEmpty, beginInkAction("为页面标记添加正文") else { return nil }
        var anchors = annotations.marks.filter { ids.contains($0.id) }.map(\.anchor)
        for (i,strokes) in inkPages.enumerated() {
            anchors += strokes.filter { ids.contains($0.id) }.map { pageAnchor(page:backingPages[i],bounds:$0.bounds) }
        }
        // Explicit adoption of selected, previously unowned marks.
        let ownedIDs = Set(annotations.notes.flatMap { $0.links.filter(\.owned).map(\.markID) })
        let note = AnnotationNote(anchors:anchors,links:ids.sorted { $0.uuidString < $1.uuidString }.map { NoteLink(markID:$0,owned:!ownedIDs.contains($0)) })
        annotations.notes.append(note); finishAction(); return note.id
    }
    func referenceMarks(_ ids:Set<UUID>, to noteID:UUID) {
        let valid = ids.intersection(annotations.allMarkIDs)
        guard !valid.isEmpty, let n=annotations.notes.firstIndex(where:{$0.id == noteID}), beginInkAction("关联页面标记") else{return}
        for id in valid where !annotations.notes[n].links.contains(where:{$0.markID == id}) {
            annotations.notes[n].links.append(NoteLink(markID:id,owned:false))
        }
        finishAction()
    }
    func discardEmptyNote(_ id: UUID, preserveMarks: Bool) {
        guard let note=annotations.notes.first(where:{$0.id==id}),note.markdown.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{return}
        // A pristine provisional creation can be cancelled as though it never
        // existed. Restore its exact baseline revision, without a phantom dirty
        // document or a redo entry that resurrects an empty note.
        if pendingAction == nil,let creation=undoEntries.last,
           creation.afterRevision==revision,!creation.change.applying(to:annotations,forward:false).notes.contains(where:{$0.id==id}) {
            applyHistory(creation,forward:false);undoEntries.removeLast();historyBytes -= creation.change.estimatedBytes;scheduleInkRecovery();onChange?();return
        }
        if !preserveMarks {deleteNote(id);return}
        guard beginInkAction("取消空正文，保留原标记") else{return}
        annotations.notes.removeAll{$0.id==id};finishAction()
    }
    func editBody(_ id: UUID, markdown: String) {
        guard !annotationReadOnly, let i = annotations.notes.firstIndex(where: {$0.id == id}), annotations.notes[i].markdown != markdown else { return }
        if bodyActionID != id || pendingAction == nil {
            guard beginInkAction("编辑批注正文") else { return }
            bodyActionID = id
        }
        annotations.notes[i].markdown = markdown; annotations.notes[i].revision = UUID()
        // Value snapshot recovery only; no PDF serialization per keystroke.
        pendingActionToken = UUID(); scheduleInkRecovery()
        onChange?()
    }
    func removeMark(_ id: UUID) {
        guard beginInkAction("删除页面标记") else { return }
        let affected = annotations.marks.filter { $0.id == id }.map(\.anchor)
        annotations.marks.removeAll { $0.id == id }
        for n in annotations.notes.indices { annotations.notes[n].links.removeAll { $0.markID == id } }
        syncMarkAdapters(on:Set(affected.map(\.page))); finishAction(); invalidateAnchors(affected)
    }
    func deleteNote(_ id: UUID) {
        guard let note = annotations.notes.first(where: {$0.id == id}), beginInkAction("删除整条批注") else { return }
        let owned = Set(note.links.filter(\.owned).map(\.markID)); let before = annotations
        annotations.notes.removeAll { $0.id == id }
        annotations.marks.removeAll { owned.contains($0.id) }
        for i in inkPages.indices { inkPages[i].removeAll { owned.contains($0.id) } }
        for n in annotations.notes.indices { annotations.notes[n].links.removeAll { owned.contains($0.markID) } }
        syncMarkAdapters(); finishAction(); invalidateModelDifference(before)
    }
    private func invalidateAnchors(_ anchors: [PageAnchor]) {
        for a in anchors where backingPages.indices.contains(a.page) { onInkChange?(backingPages[a.page],a.bounds.insetBy(dx:-4,dy:-4),.replaced([])) }
    }

    private struct Snapshot { let data: Data; let revision: UUID; let signature: String; var inkOnly = false; let model: AnnotationStore }
    private struct ActionEntry {let label:String;let beforeRevision:UUID;let afterRevision:UUID;let change:AnnotationChange}
}

private func number(_ value: CGFloat) -> String { String(format: "%.4f", Double(value)) }
private func rectangle(_ value: CGRect) -> String { [value.origin.x, value.origin.y, value.width, value.height].map(number).joined(separator: ",") }
private func point(_ value: CGPoint) -> String { number(value.x) + "," + number(value.y) }

private struct PDFStructure: Equatable {
    let pages: [String]
    let outline: [String]
    // PDFKit on older macOS may reorder extracted text runs and whitespace
    // after serialization. Compare characters here; PDFContentIntegrity still
    // requires unchanged drawing streams, preserving text sequence/placement.
    init(_ document: PDFDocument) {
        pages = (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else { return "missing" }
            let boxes = [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox].map { rectangle(page.bounds(for: $0)) }.joined(separator: "|")
            return "\(page.rotation)|\(boxes)|\(AnnotationPDF.textCharacters(page.string ?? ""))"
        }
        var entries: [String] = []
        func walk(_ node: PDFOutline, prefix: String) {
            entries.append(prefix + "|" + (node.label ?? "") + "|" + actionDescription(node.action, destination: node.destination, document: document))
            for index in 0..<node.numberOfChildren { if let child = node.child(at: index) { walk(child, prefix: prefix + "/\(index)") } }
        }
        if let root = document.outlineRoot { walk(root, prefix: "root") }
        outline = entries
    }
}

/// This guards supported semantic fields, not byte-for-byte PDF preservation.
private struct PDFFidelity {
    private struct Record {
        let identity: String
        let coordinates: [CGFloat]
    }
    private let comparable: [Record]
    let signature: String
    let recordsByPage: [[String]]
    init(_ document: PDFDocument) {
        var records: [String] = []
        var comparable: [Record] = []
        var pages: [[String]] = []
        for index in 0..<document.pageCount {
            let start = records.count
            let page = document.page(at:index)
            let pageAnnotations = page?.annotations ?? []
            let ownedPopupIndices = page.map { AnnotationPDF.ownedPopupIndices(on: $0) } ?? []
            let ownedPopups = pageAnnotations.filter { $0.value(forAnnotationKey:AnnotationPDF.noteKey) != nil }.compactMap(\.popup)
            for (position, annotation) in pageAnnotations.enumerated() {
                if ownedPopupIndices.contains(position) || ownedPopups.contains(where: { $0 === annotation }) { continue }
                let rgb = annotation.color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
                // PDF /C stores RGB only. Translucency lives in the appearance
                // stream, which is checked separately before committing bytes.
                let color = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(number).joined(separator: ",")
                let quad = (annotation.quadrilateralPoints ?? []).map { point($0.pointValue) }.joined(separator: ";")
                let metadata = [PDFAnnotationKey(rawValue:"/LeafInkStroke"),AnnotationPDF.markKey,AnnotationPDF.noteKey].map { annotation.value(forAnnotationKey:$0) as? String ?? "" }.joined(separator:"|")
                let owned = InkAnnotationCodec.stroke(from: annotation)
                var pathCoordinates: [CGFloat] = []
                var pathTopology: [String] = []
                let rawPathPoints = (annotation.paths ?? []).map { path -> String in
                    var pieces: [String] = []
                    var values = [NSPoint](repeating: .zero, count: 3)
                    for element in 0..<path.elementCount {
                        let kind = path.element(at: element, associatedPoints: &values)
                        let count: Int
                        if #available(macOS 14.0, *) { count = kind == .cubicCurveTo ? 3 : (kind == .closePath ? 0 : 1) }
                        else { count = kind == .curveTo ? 3 : (kind == .closePath ? 0 : 1) }
                        pathCoordinates += values.prefix(count).flatMap { [$0.x,$0.y] }
                        pieces.append("\(kind.rawValue):" + values.prefix(count).map(point).joined(separator: ";"))
                    }
                    pathTopology.append((0..<path.elementCount).map { String(path.element(at:$0).rawValue) }.joined(separator:","))
                    return pieces.joined(separator: "/")
                }.joined(separator: "~")
                // Owned geometry is checked against exact embedded points by the codec.
                // PDFKit rounds InkList/Rect during serialization; decimal-string
                // equality falsely rejects ordinary subpixel mouse coordinates.
                let pathPoints = owned.map { $0.points.map { point($0.cgPoint) }.joined(separator: ";") } ?? rawPathPoints
                let bounds = annotation.value(forAnnotationKey:AnnotationPDF.noteKey) != nil ? CGRect.zero : owned?.bounds ?? annotation.bounds
                let destination = annotation.destination
                let navigation = destination != nil ? actionDescription(nil, destination: destination, document: document) : actionDescription(annotation.action, destination: nil, document: document)
                let identity = "\(index)|\(annotation.type ?? "")|\(color)|\(annotation.contents ?? "")|\(annotation.userName ?? "")|\(number(annotation.border?.lineWidth ?? 0))|\((annotation.quadrilateralPoints ?? []).count)|\(owned == nil ? pathTopology.joined(separator:"~") : pathPoints)|\(metadata)|\(annotation.shouldDisplay)|\(annotation.shouldPrint)|" + navigation
                let coordinates = [bounds.minX,bounds.minY,bounds.width,bounds.height] +
                    (annotation.quadrilateralPoints ?? []).flatMap { [$0.pointValue.x,$0.pointValue.y] } +
                    (owned == nil ? pathCoordinates : [])
                comparable.append(Record(identity:identity,coordinates:coordinates))
                records.append("\(index)|\(annotation.type ?? "")|\(rectangle(bounds))|\(color)|\(annotation.contents ?? "")|\(annotation.userName ?? "")|\(number(annotation.border?.lineWidth ?? 0))|\(quad)|\(pathPoints)|\(metadata)|\(annotation.shouldDisplay)|\(annotation.shouldPrint)|" + navigation)
            }
            pages.append(Array(records[start...]))
        }
        recordsByPage = pages
        self.comparable = comparable
        signature = records.joined(separator: "\n")
    }
    func matches(_ other: PDFFidelity) -> Bool {
        // Older PDFKit rounds Rect, QuadPoints and unowned InkList coordinates.
        // Keep identities, text, links, colors, topology and editable payload exact;
        // permit only sub-millipoint serialization drift in standard geometry.
        comparable.count == other.comparable.count && zip(comparable,other.comparable).allSatisfy { a,b in
            a.identity == b.identity && a.coordinates.count == b.coordinates.count &&
                zip(a.coordinates,b.coordinates).allSatisfy { $0.isFinite && $1.isFinite && abs($0-$1)<=0.001 }
        }
    }
}

private func actionDescription(_ action: PDFAction?, destination: PDFDestination?, document: PDFDocument) -> String {
    if let url = action as? PDFActionURL { return "url:" + (url.url?.absoluteString ?? "") }
    if let named = action as? PDFActionNamed { return "named:\(named.name.rawValue)" }
    if let remote = action as? PDFActionRemoteGoTo { return "remote:\(remote.url.absoluteString)|\(remote.pageIndex)|\(point(remote.point))" }
    let goTo = (action as? PDFActionGoTo)?.destination ?? destination
    if let goTo = goTo, let page = goTo.page { return "goto:\(document.index(for: page))|\(point(goTo.point))|\(number(goTo.zoom))" }
    return action?.type ?? ""
}

/// The original page drawing streams are never edited by this app. Hash their
/// decoded content and image/Form resources before replacing any PDF, in addition
/// to checking selectable text. This catches a lost scanned page or background
/// image even when the page count and text layer happen to remain unchanged.
private struct PDFContentIntegrity: Equatable {
    let pages: [String]
    init(pageCount: Int) { pages = Array(repeating:"unverified",count:pageCount) }

    init(_ data: Data) throws {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { throw DocumentSessionError.invalidPDF }
        var values: [String] = []
        for index in 1...document.numberOfPages {
            guard let page = document.page(at: index), let dictionary = page.dictionary else { throw DocumentSessionError.invalidPDF }
            var drawing: CGPDFObjectRef?
            var records: [String] = []
            if CGPDFDictionaryGetObject(dictionary, "Contents", &drawing), let drawing = drawing {
                records.append("contents:" + (try Self.value(drawing, depth: 0)))
            }
            if let resources = Self.inheritedResources(dictionary) { try Self.xObjects(resources, path: "xobjects", depth: 0, into: &records) }
            values.append(records.joined(separator: "\n"))
        }
        pages = values
    }

    private static func inheritedResources(_ dictionary: CGPDFDictionaryRef) -> CGPDFDictionaryRef? {
        var cursor = dictionary
        for _ in 0..<32 {
            var resources: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(cursor, "Resources", &resources), let resources = resources { return resources }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(cursor, "Parent", &parent), let parent = parent else { return nil }
            cursor = parent
        }
        return nil
    }

    private static func xObjects(_ resources: CGPDFDictionaryRef, path: String, depth: Int, into records: inout [String]) throws {
        guard depth < 32 else { throw DocumentSessionError.unsupported("递归或过深的页面图像资源") }
        var dictionary: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &dictionary), let dictionary = dictionary else { return }
        let entries = dictionaryEntries(dictionary)
        for key in entries.keys.sorted() {
            guard let object = entries[key] else { continue }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream = stream, let streamDictionary = CGPDFStreamGetDictionary(stream) else { continue }
            var subtype: UnsafePointer<CChar>?
            _ = CGPDFDictionaryGetName(streamDictionary, "Subtype", &subtype)
            let type = subtype.map { String(cString: $0) } ?? ""
            let location = path + "/" + key
            records.append(location + "|" + type + "|" + (try streamDigest(stream)))
            for attribute in ["Width", "Height", "BitsPerComponent", "ColorSpace", "ImageMask", "Decode", "Mask", "SMask", "BBox", "Matrix"] {
                var attributeObject: CGPDFObjectRef?
                if CGPDFDictionaryGetObject(streamDictionary, attribute, &attributeObject), let attributeObject = attributeObject {
                    records.append(location + "/" + attribute + ":" + (try value(attributeObject, depth: depth + 1)))
                }
            }
            var nested: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(streamDictionary, "Resources", &nested), let nested = nested {
                try xObjects(nested, path: location, depth: depth + 1, into: &records)
            }
        }
    }

    private static func value(_ object: CGPDFObjectRef, depth: Int) throws -> String {
        guard depth < 32 else { throw DocumentSessionError.unsupported("递归或过深的页面资源") }
        switch CGPDFObjectGetType(object) {
        case .null: return "null"
        case .boolean:
            var result: CGPDFBoolean = 0; CGPDFObjectGetValue(object, .boolean, &result); return "bool:\(result)"
        case .integer:
            var result: CGPDFInteger = 0; CGPDFObjectGetValue(object, .integer, &result); return "int:\(result)"
        case .real:
            var result: CGPDFReal = 0; CGPDFObjectGetValue(object, .real, &result); return "number:" + number(result)
        case .name:
            var result: UnsafePointer<CChar>?
            CGPDFObjectGetValue(object, .name, &result); return "name:" + (result.map { String(cString: $0) } ?? "")
        case .string:
            var result: CGPDFStringRef?
            guard CGPDFObjectGetValue(object, .string, &result), let result = result, let bytes = CGPDFStringGetBytePtr(result) else { throw DocumentSessionError.invalidPDF }
            return "string:" + digest(Data(bytes: bytes, count: CGPDFStringGetLength(result)))
        case .array:
            var result: CGPDFArrayRef?
            guard CGPDFObjectGetValue(object, .array, &result), let result = result else { throw DocumentSessionError.invalidPDF }
            return "array:[" + (try (0..<CGPDFArrayGetCount(result)).map { index in
                var item: CGPDFObjectRef?
                guard CGPDFArrayGetObject(result, index, &item), let item = item else { throw DocumentSessionError.invalidPDF }
                return try value(item, depth: depth + 1)
            }).joined(separator: ",") + "]"
        case .dictionary:
            var result: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &result), let result = result else { throw DocumentSessionError.invalidPDF }
            let entries = dictionaryEntries(result)
            return "dictionary:{" + (try entries.keys.sorted().map { key in key + "=" + (try value(entries[key]!, depth: depth + 1)) }).joined(separator: ",") + "}"
        case .stream:
            var result: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &result), let result = result else { throw DocumentSessionError.invalidPDF }
            return "stream:" + (try streamDigest(result))
        @unknown default: throw DocumentSessionError.unsupported("未知页面资源类型")
        }
    }

    private static func streamDigest(_ stream: CGPDFStreamRef) throws -> String {
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { throw DocumentSessionError.unsupported("无法校验的页面内容编码") }
        return "\(format.rawValue):" + digest(data as Data)
    }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

private final class PDFDictionaryEntryCollector { var entries: [String: CGPDFObjectRef] = [:] }
private func dictionaryEntries(_ dictionary: CGPDFDictionaryRef) -> [String: CGPDFObjectRef] {
    let collector = PDFDictionaryEntryCollector()
    CGPDFDictionaryApplyFunction(dictionary, { key, object, context in
        guard let context = context else { return }
        let collector = Unmanaged<PDFDictionaryEntryCollector>.fromOpaque(context).takeUnretainedValue()
        collector.entries[String(cString: key)] = object
    }, Unmanaged.passUnretained(collector).toOpaque())
    return collector.entries
}

private struct AppearanceOpacityExpectation {
    let page: Int
    let annotation: Int
    let alpha: Double

    static func capture(_ document: PDFDocument) -> [AppearanceOpacityExpectation] {
        var values: [AppearanceOpacityExpectation] = []
        for pageIndex in 0..<document.pageCount {
            for (index, annotation) in (document.page(at: pageIndex)?.annotations ?? []).enumerated() {
                let alpha: Double
                if let stroke = InkAnnotationCodec.stroke(from: annotation) { alpha = stroke.rgba[3] }
                else if annotation.type == "Highlight", annotation.contents == "LeafInk text highlight" { alpha = Double(annotation.color.alphaComponent) }
                else { continue }
                if alpha < 0.999 { values.append(AppearanceOpacityExpectation(page: pageIndex, annotation: index, alpha: alpha)) }
            }
        }
        return values
    }

    static func validate(_ values: [AppearanceOpacityExpectation], in data: Data) throws {
        guard !values.isEmpty else { return }
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider) else { throw DocumentSessionError.validation("透明度数据无法读取") }
        for value in values {
            guard let page = document.page(at: value.page + 1), let pageDictionary = page.dictionary else { throw DocumentSessionError.validation("透明度页面丢失") }
            var annotations: CGPDFArrayRef?
            var annotation: CGPDFDictionaryRef?
            var appearances: CGPDFDictionaryRef?
            var normal: CGPDFStreamRef?
            var resources: CGPDFDictionaryRef?
            var graphicsStates: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetArray(pageDictionary, "Annots", &annotations), let annotations = annotations,
                  CGPDFArrayGetDictionary(annotations, value.annotation, &annotation), let annotation = annotation,
                  CGPDFDictionaryGetDictionary(annotation, "AP", &appearances), let appearances = appearances,
                  CGPDFDictionaryGetStream(appearances, "N", &normal), let normal = normal,
                  let appearanceDictionary = CGPDFStreamGetDictionary(normal),
                  CGPDFDictionaryGetDictionary(appearanceDictionary, "Resources", &resources), let resources = resources,
                  CGPDFDictionaryGetDictionary(resources, "ExtGState", &graphicsStates), let graphicsStates = graphicsStates else {
                throw DocumentSessionError.validation("透明笔迹缺少标准外观状态")
            }
            let collector = AlphaGraphicsStateCollector(expected: value.alpha)
            CGPDFDictionaryApplyFunction(graphicsStates, { key, object, context in
                guard let context = context else { return }
                let collector = Unmanaged<AlphaGraphicsStateCollector>.fromOpaque(context).takeUnretainedValue()
                var dictionary: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary = dictionary else { return }
                var strokeAlpha: CGPDFReal = 1
                var fillAlpha: CGPDFReal = 1
                let hasStroke = CGPDFDictionaryGetNumber(dictionary, "CA", &strokeAlpha)
                let hasFill = CGPDFDictionaryGetNumber(dictionary, "ca", &fillAlpha)
                if (hasStroke && abs(Double(strokeAlpha) - collector.expected) < 0.001) || (hasFill && abs(Double(fillAlpha) - collector.expected) < 0.001) {
                    collector.names.append(String(cString: key))
                }
            }, Unmanaged.passUnretained(collector).toOpaque())
            var format = CGPDFDataFormat.raw
            guard let streamData = CGPDFStreamCopyData(normal, &format), let stream = String(data: streamData as Data, encoding: .isoLatin1),
                  collector.names.contains(where: { stream.contains("/" + $0 + " gs") }) else {
                throw DocumentSessionError.validation("透明笔迹的标准外观透明度改变")
            }
        }
    }
}

private final class AlphaGraphicsStateCollector {
    let expected: Double
    var names: [String] = []
    init(expected: Double) { self.expected = expected }
}
