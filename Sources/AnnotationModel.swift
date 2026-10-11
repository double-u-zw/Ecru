import AppKit
import PDFKit
import CryptoKit

// Canonical editing values. PDFKit objects are disposable adapters.
struct PageAnchor: Codable, Equatable {
    var page: Int
    var pageID: UUID
    var bounds: CGRect
    var quote: String = ""
    var prefix: String = ""
    var suffix: String = ""
}
struct PageIdentity: Codable, Equatable {
    var id = UUID()
    var crop: CGRect
    var rotation: Int
    var textHash: String
    var contentHash: String? = nil
}
struct PageMark: Codable, Equatable {
    enum Kind: String, Codable { case highlight, region }
    var id = UUID()
    var kind: Kind
    var anchor: PageAnchor
    var rgba: [Double]
    var quads: [InkPoint] = []
    var contents: String = ""
    var userName: String = ""
    var display = true
    var print = true
}
struct NoteLink: Codable, Equatable {
    var markID: UUID
    // Ownership is explicit; references never imply cascading deletion.
    var owned: Bool
}
struct AnnotationNote: Codable, Equatable {
    var id = UUID()
    var markdown = ""
    var revision = UUID()
    var anchors: [PageAnchor]
    var links: [NoteLink]
    var locationUncertain = false
    var macros: [String: String] = [:]
}
struct AnnotationStore: Codable, Equatable {
    var version = 1
    var minimumReader = 1
    var documentID = UUID()
    var pages: [PageIdentity]
    var ink: [[InkStroke]]
    var marks: [PageMark] = []
    var notes: [AnnotationNote] = []
    var allMarkIDs: Set<UUID> { Set(marks.map(\.id) + ink.flatMap { $0.map(\.id) }) }
    func note(for mark: UUID) -> AnnotationNote? { notes.first { $0.links.contains { $0.markID == mark } } }
    func hasMarks(_ note: AnnotationNote) -> Bool { note.links.contains { allMarkIDs.contains($0.markID) } }
    func valid() -> Bool {
        let ids = marks.map(\.id) + ink.flatMap { $0.map(\.id) }
        let noteIDs = notes.map(\.id)
        let pageIDs = pages.map(\.id)
        func anchorValid(_ a: PageAnchor) -> Bool {
            pages.indices.contains(a.page) && pages[a.page].id == a.pageID &&
            [a.bounds.minX,a.bounds.minY,a.bounds.width,a.bounds.height].allSatisfy(\.isFinite) && a.bounds.width >= 0 && a.bounds.height >= 0
        }
        return version == 1 && (1...3).contains(minimumReader) && minimumReader >= (ink.flatMap{$0}.map(\.requiredReader).max() ?? 1) && ink.count == pages.count &&
        Set(ids).count == ids.count && Set(noteIDs).count == noteIDs.count && Set(pageIDs).count == pageIDs.count &&
        ink.allSatisfy { $0.allSatisfy(\.isValid) } && marks.allSatisfy { anchorValid($0.anchor) && $0.rgba.count == 4 && $0.rgba.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } } &&
        notes.allSatisfy { $0.anchors.allSatisfy(anchorValid) && Set($0.links.map(\.markID)).count == $0.links.count } &&
        Dictionary(grouping: notes.flatMap { $0.links.filter(\.owned).map(\.markID) }, by: { $0 }).values.allSatisfy { $0.count == 1 }
    }
}

enum AnnotationPDF {
    static let manifest = PDFAnnotationKey(rawValue: "/LeafInkDocument")
    static let markKey = PDFAnnotationKey(rawValue: "/LeafInkMarkID")
    static let noteKey = PDFAnnotationKey(rawValue: "/LeafInkNoteID")
    static let adapterKey = PDFAnnotationKey(rawValue: "/LeafInkAdapterID") // memory-only
    struct Envelope: Codable { var version = 1; var minimumReader = 1; var sha256: String; var payload: String }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func encode(_ store: AnnotationStore) throws -> String {
        guard store.valid() else { throw DocumentSessionError.validation("批注模型不完整，保留当前编辑") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(store)
        let encoded = try encoder.encode(Envelope(minimumReader:store.minimumReader,sha256: hash(data), payload: data.base64EncodedString()))
        guard encoded.count < 64 * 1024 * 1024 else { throw DocumentSessionError.unsupported("批注数据超出本版本 64 MiB 读取上限，保留当前编辑") }
        return String(decoding: encoded, as: UTF8.self)
    }
    static func decode(_ string: String) throws -> AnnotationStore {
        guard string.utf8.count < 64 * 1024 * 1024 else { throw DocumentSessionError.unsupported("批注数据过大") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: Data(string.utf8))
        guard envelope.version == 1, envelope.minimumReader <= 3 else { throw DocumentSessionError.unsupported("较新的 Ecru 批注格式") }
        guard let data = Data(base64Encoded: envelope.payload), hash(data) == envelope.sha256 else { throw DocumentSessionError.validation("批注数据校验和错误") }
        let store = try JSONDecoder().decode(AnnotationStore.self, from: data)
        guard store.valid(),store.version == envelope.version,store.minimumReader == envelope.minimumReader else { throw DocumentSessionError.validation("批注身份、几何或版本不一致") }
        return store
    }
    static func identity(_ page: PDFPage) -> PageIdentity {
        PageIdentity(crop: page.bounds(for: .cropBox), rotation: page.rotation, textHash: hash(Data((page.string ?? "").utf8)))
    }
    static func make(_ mark: PageMark) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: mark.anchor.bounds, forType: mark.kind == .highlight ? .highlight : .square, withProperties: nil)
        a.color = NSColor(srgbRed: mark.rgba[0], green: mark.rgba[1], blue: mark.rgba[2], alpha: mark.rgba[3])
        if !mark.quads.isEmpty { a.quadrilateralPoints = mark.quads.map { NSValue(point: $0.cgPoint) } }
        if mark.kind == .region { let b = PDFBorder(); b.lineWidth = 0.75; a.border = b }
        a.contents = mark.contents.isEmpty ? nil : mark.contents
        a.userName = mark.userName.isEmpty ? nil : mark.userName
        a.shouldDisplay = mark.display; a.shouldPrint = mark.print
        a.setValue(mark.id.uuidString, forAnnotationKey: markKey)
        return a
    }
    static func mark(_ a: PDFAnnotation, page: Int, pageID: UUID, id: UUID = UUID()) -> PageMark {
        let c = a.color.usingColorSpace(.sRGB) ?? .systemYellow
        return PageMark(id: id, kind: a.type == "Square" ? .region : .highlight,
            anchor: PageAnchor(page: page, pageID: pageID, bounds: a.bounds),
            rgba: [c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent],
            quads: (a.quadrilateralPoints ?? []).map { InkPoint($0.pointValue) }, contents: a.contents ?? "",
            userName: a.userName ?? "", display: a.shouldDisplay, print: a.shouldPrint)
    }
    static func close(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        zip([lhs.minX,lhs.minY,lhs.width,lhs.height], [rhs.minX,rhs.minY,rhs.width,rhs.height]).allSatisfy { abs($0-$1) < 0.02 }
    }
    static func compatible(_ mark: PageMark, _ a: PDFAnnotation) -> Bool {
        let c = a.color.usingColorSpace(.sRGB) ?? .black
        let sameColor = zip([c.redComponent,c.greenComponent,c.blueComponent],mark.rgba.prefix(3)).allSatisfy { abs($0-$1) < 0.005 }
        return sameColor && close(mark.anchor.bounds,a.bounds) && a.type == (mark.kind == .highlight ? "Highlight" : "Square") &&
        (a.contents ?? "") == mark.contents && a.shouldDisplay == mark.display && a.shouldPrint == mark.print &&
        (mark.quads.isEmpty || ((a.quadrilateralPoints ?? []).count == mark.quads.count && zip(a.quadrilateralPoints ?? [],mark.quads).allSatisfy { hypot($0.pointValue.x-$1.x,$0.pointValue.y-$1.y) < 0.02 }))
    }
    static func install(_ store: AnnotationStore, into pdf: PDFDocument) throws {
        guard let first = pdf.page(at: 0) else { return }
        let carrier = PDFAnnotation(bounds: CGRect(x:0,y:0,width:1,height:1), forType: .square, withProperties: nil)
        carrier.shouldDisplay = false; carrier.shouldPrint = false
        carrier.setValue(try encode(store), forAnnotationKey: manifest)
        carrier.contents = "Ecru editable annotation data v1 · reader \(store.minimumReader)"; first.addAnnotation(carrier)
        for note in store.notes {
            let anchor = note.anchors.first
            let index = anchor.map { min(max(0,$0.page),pdf.pageCount-1) } ?? 0
            let origin = anchor?.bounds.origin ?? .zero
            let a = PDFAnnotation(bounds: CGRect(origin: origin, size: CGSize(width: 24,height: 24)), forType: .text, withProperties: nil)
            a.contents = note.markdown; a.userName = "Ecru"
            a.setValue(note.id.uuidString, forAnnotationKey: noteKey)
            pdf.page(at: index)?.addAnnotation(a)
        }
    }
}
