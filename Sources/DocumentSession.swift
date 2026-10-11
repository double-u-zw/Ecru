import AppKit
import PDFKit
import CryptoKit
import Darwin

enum DocumentSessionError: LocalizedError {
    case invalidPDF, unsupported(String), serialize, validation(String), readOnly, conflict, duplicateTarget, busy, io(String), recoveryCleanup(String)
    var errorDescription: String? {
        switch self {
        case .invalidPDF: return "无法读取这个 PDF。"
        case .unsupported(let reason): return "此文件目前不能安全编辑：\(reason)。请使用普通 PDF 的测试副本。"
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
}

/// Saved PDFs are self-contained. Crash recovery may pair an immutable PDF base
/// with the latest value-type ink model; it is never the primary note store.
/// All PDFKit access and mutation happens on the main thread. The save worker receives
/// immutable captured bytes, so edits made during a save remain unsaved.
final class DocumentSession {
    // The displayed PDF contains original content and foreign/text annotations only.
    // Editable ink lives here, including the active stroke, and is rendered once by its PDFKit page overlay.
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
    // Test seam for PDFKit failing to generate crash-recovery bytes.
    var recoveryDataProvider: (() -> Data?)?
    private var originalFingerprint: String
    private var backingPages: [PDFPage] = []
    private var backingData: Data
    private var originalStructure: PDFStructure
    private var originalContent: PDFContentIntegrity
    private var undoEntries: [ActionEntry] = []
    private var redoEntries: [ActionEntry] = []
    private var pendingAction: (String, Snapshot)?
    private var pendingActionToken: UUID?
    // Immutable PDF base for recovery; ink is captured separately without PDFKit.
    private var recoveryBasePDF: Data
    private let recoveryWriter = InkRecoveryWriter()
    var recoveryWriteHook: (() -> Void)? // Test-only worker gate.
    private var pendingOldRecoveryURLs: Set<URL> = []
    private let dataDirectory: URL
    private let worker = DispatchQueue(label: "Ecru.safe-save")

    var isModified: Bool { revision != savedRevision || pendingAction != nil }
    var contentChangeToken: UUID { pendingActionToken ?? revision }
    var currentFileIsReadOnly: Bool {
        var info = stat()
        var directoryInfo = stat()
        let parent = fileURL.deletingLastPathComponent().path
        return stat(fileURL.path, &info) != 0 || info.st_mode & 0o222 == 0 ||
            info.st_flags & UInt32(UF_IMMUTABLE | SF_IMMUTABLE | UF_APPEND | SF_APPEND) != 0 ||
            stat(parent, &directoryInfo) != 0 || directoryInfo.st_mode & 0o222 == 0 ||
            !FileManager.default.isWritableFile(atPath: fileURL.path) || !FileManager.default.isWritableFile(atPath: parent)
    }
    var canUndo: Bool { !undoEntries.isEmpty }
    var canRedo: Bool { !redoEntries.isEmpty }
    var statusText: String {
        if conflictDetected { return "文件已在外部修改，当前笔记尚未保存" }
        if let error = lastError, case DocumentSessionError.recoveryCleanup = error { return "恢复记录清理失败" }
        if lastError != nil { return "保存失败" }
        if isSaving { return isModified ? "正在保存 · 未保存" : "正在保存" }
        if isRecovered && isModified { return "已恢复未保存内容 · 未保存" }
        return isModified ? "未保存" : ""
    }

    static func canonicalURL(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
    static func open(url: URL) throws -> DocumentSession {
        let canonical = canonicalURL(url)
        let data = try Data(contentsOf: canonical)
        guard let document = PDFDocument(data: data), document.pageCount > 0 else { throw DocumentSessionError.invalidPDF }
        try checkSupported(document: document, data: data)
        return try DocumentSession(document: document, url: canonical, data: data)
    }

    private init(document: PDFDocument, url: URL, data: Data) throws {
        self.document = document
        fileURL = url
        backingData = data
        recoveryBasePDF = data
        originalFingerprint = Self.fingerprint(data)
        originalStructure = PDFStructure(document)
        originalContent = try PDFContentIntegrity(data)
        savedRevision = revision
        if let override = EcruEnvironment.value("ECRU_DATA_DIR"), !override.isEmpty {
            dataDirectory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dataDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("LeafInk-development", isDirectory: true)
        }
        importEditableInk()
    }

    private func importEditableInk() {
        backingPages = (0..<document.pageCount).map { document.page(at: $0)! }
        annotations = AnnotationStore(pages: backingPages.map(AnnotationPDF.identity), ink: backingPages.map { _ in [] })
        for i in annotations.pages.indices {
            annotations.pages[i].contentHash = AnnotationPDF.hash(Data(originalContent.pages[i].utf8))
        }
        managedSourceSlots = backingPages.map { _ in [] }; sourceMarkSlots = [:]
        annotationWarnings = []; annotationReadOnly = false
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
                    if !AnnotationPDF.close(actual.crop,saved.crop) || actual.rotation != saved.rotation || actual.textHash != saved.textHash || actual.contentHash != saved.contentHash {
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
                let noteIDs = Set(annotations.notes.map(\.id))
                if bodies.keys.contains(where: { !noteIDs.contains($0) }) { annotationReadOnly = true }
                for note in annotations.notes {
                    // Missing/changed standard body is an external edit, not permission to restore it.
                    if bodies[note.id]?.count != 1 || bodies[note.id]?.first?.contents ?? "" != note.markdown { annotationReadOnly = true }
                }
                let missing = ids.subtracting(marked.keys)
                if !missing.isEmpty {
                    annotationWarnings.append("部分页面标记已在外部移除；正文与定位已保留，不会重新生成这些标记。")
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
            annotations.ink = backingPages.map { _ in [] }
            return
        }
        for (pi,page) in backingPages.enumerated() {
            let originals = page.annotations
            for (slot,a) in originals.enumerated() {
                let isCarrier = a.value(forAnnotationKey: AnnotationPDF.manifest) != nil || a.value(forAnnotationKey: AnnotationPDF.noteKey) != nil
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
                    let mark = AnnotationPDF.mark(a,page:pi,pageID:annotations.pages[pi].id)
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
                    let mark = AnnotationPDF.mark(a,page:pi,pageID:annotations.pages[pi].id)
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
        inkPages[index].removeAll { ids.contains($0.id) }
        inkPages[index].insert(contentsOf: replacements, at: min(insertion, inkPages[index].count))
        if !damaged.isNull { onInkChange?(page, damaged, .replaced(ids.union(replacements.map(\.id)))) }
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
        guard !annotationReadOnly, let exported = PDFDocument(data: backingData), exported.pageCount == document.pageCount else { return nil }
        var originals: [UUID:PDFAnnotation] = [:]
        for (id,slot) in sourceMarkSlots { if let p=exported.page(at:slot.0),p.annotations.indices.contains(slot.1) { originals[id]=p.annotations[slot.1] } }
        for index in 0..<document.pageCount {
            guard let page = exported.page(at:index) else { return nil }
            // Remove only known managed source slots. Foreign annotations/resources remain in place.
            for (slot,a) in page.annotations.enumerated() where managedSourceSlots[index].contains(slot) { page.removeAnnotation(a) }
        }
        for mark in annotations.marks {
            let a = originals[mark.id] ?? AnnotationPDF.make(mark)
            a.setValue(mark.id.uuidString,forAnnotationKey:AnnotationPDF.markKey)
            exported.page(at:mark.anchor.page)?.addAnnotation(a)
        }
        for (index,strokes) in inkPages.enumerated() {
            for stroke in strokes {
                let a = InkAnnotationCodec.make(stroke); a.setValue(stroke.id.uuidString,forAnnotationKey:AnnotationPDF.markKey)
                exported.page(at:index)?.addAnnotation(a)
            }
        }
        do { try AnnotationPDF.install(annotations,into:exported) } catch { return nil }
        return exported
    }

    @discardableResult
    func beginAction(_ label: String) -> Bool {
        precondition(Thread.isMainThread)
        guard !annotationReadOnly else { return false }
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
        if snapshotDataProvider != nil { return beginAction(label) }
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
        guard let after = before.inkOnly ? inkSnapshot() : snapshot() else { return }
        pendingAction = nil
        bodyActionID = nil
        pendingActionToken = nil
        guard after.model != before.model || (!before.inkOnly && after.signature != before.signature) else { return }
        revision = UUID()
        let revised = Snapshot(data: after.data, revision: revision, signature: after.signature, inkOnly: after.inkOnly, model: after.model)
        recoveryBasePDF = after.data
        undoEntries.append(ActionEntry(label: label, before: before, after: revised))
        redoEntries.removeAll()
        if after.inkOnly { scheduleInkRecovery() }
        else { checkpointRecovery(captured: after.data) }
        onChange?()
    }

    func undo() {
        finishAction()
        guard pendingAction == nil else { return }
        guard let action = undoEntries.popLast(), restore(action.before) else { return }
        redoEntries.append(action)
        historyNote(action.before.model, other:action.after.model, label:"撤销 · " + action.label)
        if action.before.inkOnly { scheduleInkRecovery() } else { checkpointRecovery() }
        onChange?()
    }

    func redo() {
        finishAction()
        guard pendingAction == nil else { return }
        guard let action = redoEntries.popLast(), restore(action.after) else { return }
        undoEntries.append(action)
        historyNote(action.after.model, other:action.before.model, label:"重做 · " + action.label)
        if action.after.inkOnly { scheduleInkRecovery() } else { checkpointRecovery() }
        onChange?()
    }

    private func snapshot() -> Snapshot? {
        let exported = portableDocument()
        let bytes = snapshotDataProvider.map { $0() } ?? exported?.dataRepresentation()
        guard let data = bytes else {
            lastError = DocumentSessionError.serialize
            onChange?()
            return nil
        }
        return Snapshot(data: data, revision: revision, signature: exported.map { PDFFidelity($0).signature } ?? "", model: annotations)
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
                old.ink[i] != annotations.ink[i] || old.marks.filter({$0.anchor.page == i}) != annotations.marks.filter({$0.anchor.page == i}) {
                onInkChange?(page,page.bounds(for:.cropBox),.reset)
            }
        }
    }

    /// Manual save only. Capture is synchronous, validation and atomic I/O are asynchronous.
    func save(to proposedURL: URL? = nil, completion: @escaping (Result<SaveOutcome, Error>) -> Void) {
        precondition(Thread.isMainThread)
        finishAction()
        guard !annotationReadOnly else { completion(.failure(DocumentSessionError.unsupported("批注冲突或新格式，只读保护"))); return }
        guard !isSaving else { completion(.failure(DocumentSessionError.busy)); return }
        let target = Self.canonicalURL(proposedURL ?? fileURL)
        let sameTarget = target == fileURL
        if sameTarget && conflictDetected { failSave(DocumentSessionError.conflict, completion: completion); return }
        if isTargetOpenElsewhere?(target) == true { failSave(DocumentSessionError.duplicateTarget, completion: completion); return }
        guard backingPages.count == document.pageCount && backingPages.enumerated().allSatisfy({ document.page(at: $0.offset) === $0.element }) else {
            failSave(DocumentSessionError.validation("原始页面内容或图像资源的页面身份改变"), completion: completion); return
        }
        guard let exported = portableDocument(), let bytes = exported.dataRepresentation() else { failSave(DocumentSessionError.serialize, completion: completion); return }
        let expectedManifest = try? AnnotationPDF.encode(annotations)
        let capturedRevision = revision
        let fidelity = PDFFidelity(exported)
        let expectedOpacity = AppearanceOpacityExpectation.capture(exported)
        let structure = originalStructure
        let content = originalContent
        let expectedFingerprint: String?
        do {
            expectedFingerprint = sameTarget ? originalFingerprint : (FileManager.default.fileExists(atPath: target.path) ? Self.fingerprint(try Data(contentsOf: target)) : nil)
        } catch { failSave(error, completion: completion); return }
        isSaving = true
        savingTarget = target
        lastError = nil
        onChange?()
        let hook = saveWorkHook
        worker.async { [weak self] in
            let result: Result<String, Error>
            do {
                hook?()
                guard let reopened = PDFDocument(data: bytes) else { throw DocumentSessionError.validation("重开失败") }
                try Self.checkSupported(document: reopened, data: bytes)
                guard PDFStructure(reopened) == structure else { throw DocumentSessionError.validation("原文、页框、旋转或目录改变") }
                guard try PDFContentIntegrity(bytes) == content else { throw DocumentSessionError.validation("原始页面内容或图像资源改变") }
                guard PDFFidelity(reopened).signature == fidelity.signature else {
                    if EcruEnvironment.value("ECRU_TEST_DIAGNOSTICS") == "1" {
                        print("EXPECTED", fidelity.signature, "ACTUAL", PDFFidelity(reopened).signature)
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
                    if case DocumentSessionError.conflict = error { self.conflictDetected = sameTarget }
                    self.lastError = error
                    self.onChange?()
                    completion(.failure(error))
                }
            }
        }
    }

    private func failSave(_ error: Error, completion: (Result<SaveOutcome, Error>) -> Void) {
        lastError = error
        onChange?()
        completion(.failure(error))
    }

    var recoverableRecord: RecoveryRecord? {
        recoveryWriter.flush()
        guard let data = try? Data(contentsOf: recoveryURL), let record = try? JSONDecoder().decode(RecoveryRecord.self, from: data), (1...5).contains(record.version),
              Self.canonicalURL(URL(fileURLWithPath: record.sourcePath)) == fileURL else { return nil }
        return record
    }

    func restoreRecovery(_ record: RecoveryRecord) throws {
        precondition(Thread.isMainThread)
        guard !annotationReadOnly else { throw DocumentSessionError.unsupported("当前 PDF 的批注格式受保护，保留恢复记录，禁止用旧草稿覆盖") }
        guard (1...5).contains(record.version), Self.canonicalURL(URL(fileURLWithPath: record.sourcePath)) == fileURL,
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
        conflictDetected = record.originalFingerprint != originalFingerprint
        originalFingerprint = record.originalFingerprint
        backingData = record.pdfData
        document = restored
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
        originalStructure = PDFStructure(restored)
        originalContent = recoveredContent
        revision = UUID() // Recovery always remains unsaved, even if its bytes equal disk.
        undoEntries.removeAll()
        redoEntries.removeAll()
        isRecovered = true
        lastError = nil
        checkpointRecovery()
        onChange?()
    }

    @discardableResult
    func discardRecovery() -> Bool {
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
                try FileManager.default.removeItem(at: url)
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

    private var recoveryURL: URL {
        let key = Self.fingerprint(Data(fileURL.path.utf8))
        return dataDirectory.appendingPathComponent("Recovery", isDirectory: true).appendingPathComponent(key + ".json")
    }

    func checkpointRecovery(captured: Data? = nil) {
        recoveryWriter.cancelAndWait()
        if !isModified { discardRecovery(); return }
        let generated = recoveryDataProvider.map { $0() } ?? captured ?? portableDocument()?.dataRepresentation()
        guard let bytes = generated else {
            let pending = pendingOldRecoveryURLs.isEmpty ? "" : "；旧路径的恢复记录也尚未清理"
            lastError = DocumentSessionError.io("自动恢复数据生成失败，当前内容仍在窗口\(pending)")
            onChange?()
            return
        }
        let record = RecoveryRecord(version: 1, sourcePath: fileURL.path, originalFingerprint: originalFingerprint, pdfData: bytes, revision: revision, updatedAt: Date())
        do {
            try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: recoveryURL, options: .atomic)
        } catch {
            // Recovery failure is visible and does not masquerade as a successful save.
            lastError = DocumentSessionError.io("自动恢复保护写入失败：\(error.localizedDescription)")
        }
    }

    private func scheduleInkRecovery() {
        if !isModified { discardRecovery(); return }
        let record = RecoveryRecord(version: annotations.minimumReader>=3 ? 5 : (annotations.minimumReader>=2 ? 4 : 3), sourcePath: fileURL.path,
            originalFingerprint: originalFingerprint, pdfData: backingData,
            revision: revision, updatedAt: Date(), ink: inkPages, annotations: annotations,
            markOrigins: sourceMarkSlots.map { MarkSourceOrigin(id: $0.key, page: $0.value.0, slot: $0.value.1) })
        let target = recoveryURL
        recoveryWriter.submit(record, to: target, hook: recoveryWriteHook) { [weak self] error in
            guard let self, self.isModified, self.revision == record.revision,
                  self.recoveryURL == target else { return }
            if let error {
                self.lastError = DocumentSessionError.io("自动恢复保护写入失败：\(error.localizedDescription)")
                self.onChange?()
            }
        }
    }

    private static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private static func checkSupported(document: PDFDocument, data: Data) throws {
        if document.isEncrypted || document.isLocked { throw DocumentSessionError.unsupported("加密 PDF") }
        if data.range(of: Data("/ByteRange".utf8)) != nil { throw DocumentSessionError.unsupported("带数字签名的 PDF") }
        guard let provider = CGDataProvider(data: data as CFData), let cg = CGPDFDocument(provider), let catalog = cg.catalog else { throw DocumentSessionError.invalidPDF }
        var object: CGPDFObjectRef?
        for key in ["AcroForm", "Collection", "Perms", "AF"] {
            if CGPDFDictionaryGetObject(catalog, key, &object) { throw DocumentSessionError.unsupported("表单、签名或附件结构（\(key)）") }
        }
        var names: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names = names, CGPDFDictionaryGetObject(names, "EmbeddedFiles", &object) {
            throw DocumentSessionError.unsupported("嵌入附件")
        }
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                if ["Widget", "RichMedia", "Movie", "Sound", "FileAttachment", "Screen", "3D"].contains(annotation.type ?? "") {
                    throw DocumentSessionError.unsupported("\(annotation.type ?? "交互")批注")
                }
            }
        }
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
    @discardableResult func addTextSelection(_ selection: PDFSelection, color: NSColor = .systemYellow, withNote: Bool) -> UUID? {
        guard beginInkAction(withNote ? "添加选文批注" : "文字高亮") else { return nil }
        var links: [NoteLink] = []; var anchors: [PageAnchor] = []
        let c = color.usingColorSpace(.sRGB) ?? .systemYellow
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let rect = line.bounds(for:page); guard rect.width > 0, rect.height > 0 else { continue }
                let anchor = pageAnchor(page:page,bounds:rect,quote:line.string ?? "")
                let mark = PageMark(kind:.highlight,anchor:anchor,rgba:[c.redComponent,c.greenComponent,c.blueComponent,0.45],quads:[InkPoint(x:0,y:rect.height),InkPoint(x:rect.width,y:rect.height),InkPoint(x:0,y:0),InkPoint(x:rect.width,y:0)])
                annotations.marks.append(mark); anchors.append(anchor); links.append(NoteLink(markID:mark.id,owned:true))
            }
        }
        var id: UUID?
        if withNote && !anchors.isEmpty { let note = AnnotationNote(anchors:anchors,links:links); annotations.notes.append(note); id = note.id }
        syncMarkAdapters(on:Set(anchors.map(\.page))); finishAction(); invalidateAnchors(anchors); return id
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
           creation.after.model==annotations,!creation.before.model.notes.contains(where:{$0.id==id}) {
            _ = restore(creation.before);undoEntries.removeLast();scheduleInkRecovery();onChange?();return
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
    private struct ActionEntry { let label: String; let before: Snapshot; let after: Snapshot }
}

private func number(_ value: CGFloat) -> String { String(format: "%.4f", Double(value)) }
private func rectangle(_ value: CGRect) -> String { [value.origin.x, value.origin.y, value.width, value.height].map(number).joined(separator: ",") }
private func point(_ value: CGPoint) -> String { number(value.x) + "," + number(value.y) }

private struct PDFStructure: Equatable {
    let pages: [String]
    let outline: [String]
    init(_ document: PDFDocument) {
        pages = (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else { return "missing" }
            let boxes = [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox].map { rectangle(page.bounds(for: $0)) }.joined(separator: "|")
            return "\(page.rotation)|\(boxes)|\(page.string ?? "")"
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
    let signature: String
    let recordsByPage: [[String]]
    init(_ document: PDFDocument) {
        var records: [String] = []
        var pages: [[String]] = []
        for index in 0..<document.pageCount {
            let start = records.count
            let pageAnnotations = document.page(at:index)?.annotations ?? []
            let ownedPopups = pageAnnotations.filter { $0.value(forAnnotationKey:AnnotationPDF.noteKey) != nil }.compactMap(\.popup)
            for annotation in pageAnnotations {
                if ownedPopups.contains(where: { $0 === annotation }) { continue }
                let rgb = annotation.color.usingColorSpace(.sRGB) ?? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
                // PDF /C stores RGB only. Translucency lives in the appearance
                // stream, which is checked separately before committing bytes.
                let color = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map(number).joined(separator: ",")
                let quad = (annotation.quadrilateralPoints ?? []).map { point($0.pointValue) }.joined(separator: ";")
                let metadata = [PDFAnnotationKey(rawValue:"/LeafInkStroke"),AnnotationPDF.markKey,AnnotationPDF.noteKey].map { annotation.value(forAnnotationKey:$0) as? String ?? "" }.joined(separator:"|")
                let owned = InkAnnotationCodec.stroke(from: annotation)
                let rawPathPoints = (annotation.paths ?? []).map { path -> String in
                    var pieces: [String] = []
                    var values = [NSPoint](repeating: .zero, count: 3)
                    for element in 0..<path.elementCount {
                        let kind = path.element(at: element, associatedPoints: &values)
                        let count: Int
                        if #available(macOS 14.0, *) { count = kind == .cubicCurveTo ? 3 : (kind == .closePath ? 0 : 1) }
                        else { count = kind == .curveTo ? 3 : (kind == .closePath ? 0 : 1) }
                        pieces.append("\(kind.rawValue):" + values.prefix(count).map(point).joined(separator: ";"))
                    }
                    return pieces.joined(separator: "/")
                }.joined(separator: "~")
                // Owned geometry is checked against exact embedded points by the codec.
                // PDFKit rounds InkList/Rect during serialization; decimal-string
                // equality falsely rejects ordinary subpixel mouse coordinates.
                let pathPoints = owned.map { $0.points.map { point($0.cgPoint) }.joined(separator: ";") } ?? rawPathPoints
                let bounds = annotation.value(forAnnotationKey:AnnotationPDF.noteKey) != nil ? CGRect.zero : owned?.bounds ?? annotation.bounds
                let destination = annotation.destination
                let navigation = destination != nil ? actionDescription(nil, destination: destination, document: document) : actionDescription(annotation.action, destination: nil, document: document)
                records.append("\(index)|\(annotation.type ?? "")|\(rectangle(bounds))|\(color)|\(annotation.contents ?? "")|\(annotation.userName ?? "")|\(number(annotation.border?.lineWidth ?? 0))|\(quad)|\(pathPoints)|\(metadata)|\(annotation.shouldDisplay)|\(annotation.shouldPrint)|" + navigation)
            }
            pages.append(Array(records[start...]))
        }
        recordsByPage = pages
        signature = records.joined(separator: "\n")
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


/// One pending recovery value, independent of the input/main queue. Newer
/// revisions replace pending work; no PDFKit object crosses this boundary.
private final class InkRecoveryWriter {
    private let queue = DispatchQueue(label: "Ecru.ink-recovery", qos: .utility)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var pending: Job?
    private var draining = false
    private struct Job {
        let generation: UInt64
        let record: RecoveryRecord
        let url: URL
        let hook: (() -> Void)?
        let completion: (Error?) -> Void
    }
    func submit(_ record: RecoveryRecord, to url: URL, hook: (() -> Void)?, completion: @escaping (Error?) -> Void) {
        lock.lock()
        generation &+= 1
        pending = Job(generation: generation, record: record, url: url, hook: hook, completion: completion)
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }
    private func isCurrent(_ token: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return generation == token
    }
    private func drain() {
        while true {
            lock.lock()
            guard let job = pending else { draining = false; lock.unlock(); return }
            pending = nil
            lock.unlock()
            job.hook?()
            guard isCurrent(job.generation) else { continue }
            var failure: Error?
            do {
                let bytes = try JSONEncoder().encode(job.record)
                guard isCurrent(job.generation) else { continue }
                try FileManager.default.createDirectory(at: job.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: job.url, options: .atomic)
            } catch { failure = error }
            let result = failure
            DispatchQueue.main.async {
                if self.isCurrent(job.generation) { job.completion(result) }
            }
        }
    }
    func flush() { queue.sync {} }
    func cancelAndWait() {
        lock.lock(); generation &+= 1; pending = nil; lock.unlock()
        queue.sync {}
    }
}
