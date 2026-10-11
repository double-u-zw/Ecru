import Foundation

/// Preserve original page streams across PDFKit versions that re-encode drawing.
/// Annotations still come from PDFKit; the existing safe-save checks remain final.
enum PDFPagePreservation {
    static func preserve(_ original: Data, in annotated: Data) -> Data? {
        var output: UnsafeMutablePointer<UInt8>?
        var count = 0
        let success = original.withUnsafeBytes { source in
            annotated.withUnsafeBytes { export in
                ecru_pdf_preserve_pages(source.bindMemory(to: UInt8.self).baseAddress, original.count,
                                        export.bindMemory(to: UInt8.self).baseAddress, annotated.count,
                                        &output, &count)
            }
        }
        guard success == 1, let output else { return nil }
        defer { ecru_pdf_free(output) }
        return Data(bytes: output, count: count)
    }
}
