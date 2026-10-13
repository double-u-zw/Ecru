import Foundation

struct PDFCapabilities {
    enum Mode: String { case fullEditing, readOnly, annotationCopy }
    let mode: Mode
    let features: UInt32
    let reasons: [String]
    let canCreateStaticCopy: Bool
    var canEdit: Bool { mode != .readOnly }
    var summary: String { reasons.joined(separator: "\n") }
    static func assess(_ flags: UInt32, allowsCommenting: Bool, allowsPrinting: Bool) -> PDFCapabilities {
        var reasons: [String] = []
        if flags & 1 != 0 { reasons.append("加密文档已解锁供阅读；尚未验证加密写回和恢复保护，禁止批注及导出解密副本。") }
        if !allowsCommenting { reasons.append("文档权限不允许批注；输入打开密码并不授予修改权限。") }
        if flags & 2 != 0 { reasons.append("检测到数字签名字段或签名结构，未验证密码学有效性。修改可能使签名失效；当前仅供阅读，禁止覆盖和批注副本。") }
        if flags & 8 != 0 { reasons.append("包含 XFA 动态表单；仅显示 PDF 中的静态页面，动态内容可能不完整。") }
        if flags & 32 != 0 { reasons.append("包含活动或媒体结构；脚本、启动动作和媒体交互已禁用，仅显示静态页面。") }
        if flags & 64 != 0 { reasons.append("包含 PDF Portfolio；仅显示主体页面，未提供包内文档浏览。") }
        if flags & 128 != 0 { reasons.append("包含文档认证或使用权限限制，禁止修改原文件。") }
        if flags & 256 != 0 { reasons.append("解析器报告结构异常；无法验证无损保存，仅供阅读。") }
        let readOnly = !reasons.isEmpty
        let copy = readOnly && flags & (1|2|128|256) == 0 && allowsCommenting && allowsPrinting
        return PDFCapabilities(mode: readOnly ? .readOnly : .fullEditing, features: flags, reasons: reasons, canCreateStaticCopy: copy)
    }
}

/// QPDF owns the original object graph. PDFKit supplies only new managed annotations.
enum PDFPagePreservation {
    struct Inspection { let features: UInt32; let readingData: Data? }
    static func inspect(_ input: Data, password: String?) throws -> Inspection {
        var output: UnsafeMutablePointer<UInt8>?
        var count = 0
        var features: UInt32 = 0
        let success = input.withUnsafeBytes { bytes in
            let run: (UnsafePointer<CChar>?) -> Int32 = { secret in
                ecru_pdf_inspect(bytes.bindMemory(to: UInt8.self).baseAddress, input.count, secret, &features, &output, &count)
            }
            return password.map { $0.withCString(run) } ?? run(nil)
        }
        defer { if let output { ecru_pdf_free(output) } }
        if success == -1 { throw password == nil ? DocumentSessionError.passwordRequired : DocumentSessionError.incorrectPassword }
        guard success == 1 else { throw DocumentSessionError.unsupported("PDF 结构不完整、无法解密或不能可靠解析") }
        return Inspection(features: features, readingData: output.map { Data(bytes: $0, count: count) })
    }
    static func slotDescription(_ slots: [Set<Int>]) -> String {
        slots.enumerated().flatMap { page, values in values.sorted().map { "\(page):\($0)" } }.joined(separator: " ")
    }
    static func preserve(_ original: Data, in annotated: Data, removing slots: [Set<Int>]) -> Data? {
        var output: UnsafeMutablePointer<UInt8>?
        var count = 0
        let success = original.withUnsafeBytes { source in
            annotated.withUnsafeBytes { export in
                slotDescription(slots).withCString { removed in
                    ecru_pdf_preserve_pages(source.bindMemory(to: UInt8.self).baseAddress, original.count,
                        export.bindMemory(to: UInt8.self).baseAddress, annotated.count, removed, &output, &count)
                }
            }
        }
        guard success == 1, let output else { return nil }
        defer { ecru_pdf_free(output) }
        return Data(bytes: output, count: count)
    }
    static func validate(_ original: Data, saved: Data, removing slots: [Set<Int>]) -> Bool {
        original.withUnsafeBytes { source in saved.withUnsafeBytes { target in
            slotDescription(slots).withCString { removed in
                ecru_pdf_validate(source.bindMemory(to: UInt8.self).baseAddress, original.count,
                    target.bindMemory(to: UInt8.self).baseAddress, saved.count, removed) == 1
            }
        } }
    }
}
