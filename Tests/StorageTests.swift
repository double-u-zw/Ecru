import AppKit
import PDFKit
import Darwin

@main
enum StorageTests {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    static func save(_ session: DocumentSession, to url: URL? = nil) -> Result<SaveOutcome, Error> {
        var result: Result<SaveOutcome, Error>?
        session.save(to: url) { result = $0 }
        let deadline = Date().addingTimeInterval(10)
        while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(result != nil, "save worker completion")
        if case .failure = result!, EcruEnvironment.value("ECRU_TEST_DIAGNOSTICS") == "1" {
            // This runner uses only isolated synthetic fixture copies.
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            try? Data(contentsOf: session.fileURL).write(to: root.appendingPathComponent(".build/pdf-save-original.pdf"))
            try? session.portableDocument()?.dataRepresentation()?.write(to: root.appendingPathComponent(".build/pdf-save-export.pdf"))

        }
        return result!
    }
    static func isSuccess(_ result: Result<SaveOutcome, Error>) -> Bool {
        if case .success = result { return true }
        if case .failure(let error) = result { print("Save error:", error.localizedDescription, error as NSError) }
        return false
    }
    static func add(_ session: DocumentSession, x: Double, y: Double = 400, kind: InkKind = .pen) -> InkStroke {
        let stroke = InkStroke(points: [InkPoint(x: x, y: y), InkPoint(x: x + 60, y: y + 10)], width: kind == .marker ? 15 : 2,
                               rgba: kind == .marker ? [1, 0.8, 0, 0.28] : [0.1, 0.2, 0.8, 1], kind: kind)
        session.beginAction("书写")
        session.replaceInk(on: session.document.page(at: 0)!, ids: [], with: [stroke])
        session.finishAction()
        return stroke
    }
    static func owned(_ session: DocumentSession) -> [InkStroke] {
        (0..<session.document.pageCount).flatMap { session.inkStrokes(on: session.document.page(at: $0)!) }
    }
    static func copy(_ input: URL, to directory: URL, name: String) throws -> URL {
        let target = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: input, to: target)
        return target
    }
    static func main() throws {
        let workspace = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let fixture = workspace.appendingPathComponent("output/pdf/reader-test-original.pdf")
        let inputData = try Data(contentsOf: fixture)
        let directory = workspace.appendingPathComponent(".build/storage-tests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let isolated = directory.appendingPathComponent("isolated-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
        setenv("ECRU_DATA_DIR", isolated.appendingPathComponent("data").path, 1)
        let source = try copy(fixture, to: isolated, name: "editable.pdf")
        let session = try DocumentSession.open(url: source)
        let baselineAnnotations = session.document.page(at: 0)!.annotations.count
        check(!session.isModified && !session.canUndo, "open starts clean")
        let initialContentToken = session.contentChangeToken
        session.beginAction("empty action"); session.finishAction()
        check(!session.isModified && !session.canUndo, "empty action does not add undo")
        check(session.contentChangeToken == initialContentToken && session.contentChangeToken == session.revision,
              "unchanged action clears pending token and returns to original content revision")
        // The portable codec remains compatible with the previous PDF-only format.
        let legacyURL = workspace.appendingPathComponent("Tests/Fixtures/PDF/legacy-annotations.pdf")
        let legacy = try DocumentSession.open(url: legacyURL)
        check(owned(legacy).count == 3, "previous-build PDF restores all editable ink into the model")
        check(legacy.document.page(at: 0)!.annotations.allSatisfy { InkAnnotationCodec.stroke(from: $0) == nil },
              "displayed PDF excludes owned ink so Canvas cannot double-render it")
        let legacyExport = legacy.portableDocument()!
        check(legacyExport.page(at: 0)!.annotations.compactMap(InkAnnotationCodec.stroke) == owned(legacy),
              "detached PDF export preserves previous stroke identities geometry and style")
        check(!legacy.isModified, "importing old PDF ink into the model does not mark the document modified")
        let fractionalSource = try copy(fixture, to: isolated, name: "fractional.pdf")
        let fractional = try DocumentSession.open(url: fractionalSource)
        let fractionalStroke = InkStroke(points: [InkPoint(x: 165.08723451, y: 488.78153213), InkPoint(x: 211.28392482, y: 520.87643197)], width: 2.5, rgba: [0, 0.4, 1, 1], kind: .pen)
        fractional.beginAction("subpixel input")
        fractional.replaceInk(on: fractional.document.page(at: 0)!, ids: [], with: [fractionalStroke])
        fractional.finishAction()
        check(isSuccess(save(fractional)), "subpixel mouse geometry tolerates PDF numeric rounding during save")
        let fractionalReopen = try DocumentSession.open(url: fractionalSource)
        check(owned(fractionalReopen) == [fractionalStroke], "PDF reopen restores full precision authoritative mouse geometry")
        let pressureURL = try copy(fixture, to: isolated, name: "pressure-ink.pdf")
        let pressureSession = try DocumentSession.open(url:pressureURL)
        let pressurePage=pressureSession.document.page(at:0)!
        var pressureStroke=InkStroke(points:[InkPoint(x:120,y:400)],width:4,rgba:[0.1,0.2,0.8,1],kind:.pen,widthFactors:[0.6])
        check(pressureSession.beginInkAction("pressure pen"),"pressure fast transaction")
        pressureSession.replaceInk(on:pressurePage,ids:[],with:[pressureStroke])
        pressureSession.appendInkPoints([InkPoint(x:170,y:430),InkPoint(x:210,y:400)],factors:[1.2,0.5],to:pressureStroke.id,on:pressurePage)
        pressureSession.finishAction()
        pressureStroke=owned(pressureSession)[0]
        check(pressureStroke.widthFactors == [0.6,1.2,0.5],"live pressure append aligned with geometry")
        let pressureRecovery=try DocumentSession.open(url:pressureURL)
        try pressureRecovery.restoreRecovery(pressureSession.recoverableRecord!)
        check(owned(pressureRecovery)==[pressureStroke],"async recovery restores pressure widths")
        let pressureFragments=InkGeometry.erase(pressureStroke,center:CGPoint(x:170,y:430),radius:4)
        check(pressureFragments.count==2,"pressure local erase produces pressureFragments")
        check(pressureSession.beginInkAction("pressure erase"),"pressure erase transaction")
        pressureSession.replaceInk(on:pressurePage,ids:[pressureStroke.id],with:pressureFragments)
        pressureSession.finishAction();pressureSession.undo()
        check(owned(pressureSession)==[pressureStroke],"pressure erase undo exact")
        pressureSession.redo()
        check(owned(pressureSession)==pressureFragments,"pressure erase redo exact")
        let pressureShifted=pressureFragments.map{$0.translated(dx:30,dy:20)}
        check(pressureSession.beginInkAction("pressure move"),"pressure move transaction")
        pressureSession.replaceInk(on:pressurePage,ids:Set(pressureFragments.map(\.id)),with:pressureShifted)
        pressureSession.finishAction()
        check(isSuccess(save(pressureSession)),"pressure appearance passes full safe-save validation")
        check(owned(try DocumentSession.open(url:pressureURL))==pressureShifted,"pressure moved pressureFragments reopen from PDF alone")
        pressureSession.undo();check(owned(pressureSession)==pressureFragments,"pressure move undo remains after save")
        pressureSession.redo();check(owned(pressureSession)==pressureShifted,"pressure move redo remains after save")
        let pen = add(session, x: 100)
        check(session.document.page(at: 0)!.annotations.count == baselineAnnotations,
              "committed ink has one display owner and never enters the PDFKit display document")
        check(session.isModified && session.canUndo && owned(session) == [pen], "stroke action records geometry")
        check(session.contentChangeToken != initialContentToken && session.contentChangeToken == session.revision,
              "completed content action clears pending token and exposes its new revision")
        check(session.recoverableRecord != nil, "unsaved action creates isolated recovery")
        check(isSuccess(save(session)), "save + validated atomic write")
        check(!session.isModified && session.canUndo && session.recoverableRecord == nil, "successful save stays undoable and clears recovery")
        let reopened = try DocumentSession.open(url: source)
        check(owned(reopened) == [pen], "PDF alone restores editable stroke")
        check(reopened.document.pageCount == 4 && reopened.document.page(at: 1)!.rotation == 90, "rotated fixture preserves pages")
        check(reopened.document.page(at: 0)!.annotations.count == baselineAnnotations && reopened.document.outlineRoot != nil, "foreign annotations and outline retained")
        let displayDocument = session.document, displayPage = session.document.page(at: 0)!
        session.undo()
        check(session.document === displayDocument && session.document.page(at: 0) === displayPage, "ink undo keeps the live PDF document and page identity; no blank-page rebind")
        check(owned(session).isEmpty && session.isModified, "undo after save marks unsaved")
        session.redo()
        check(owned(session) == [pen] && !session.isModified, "redo to saved revision is clean")
        let marker = add(session, x: 180, y: 430, kind: .marker)
        let gate = DispatchSemaphore(value: 0)
        session.saveWorkHook = { gate.wait() }
        var concurrentResult: Result<SaveOutcome, Error>?
        session.save { concurrentResult = $0 }
        check(session.isSaving && session.savingTarget == source, "save reserves its target on the main thread until completion")
        let newer = add(session, x: 240, y: 460)
        gate.signal()
        let concurrentDeadline = Date().addingTimeInterval(10)
        while concurrentResult == nil && Date() < concurrentDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(concurrentResult != nil && isSuccess(concurrentResult!), "save with simultaneous later action")
        check(!session.isSaving && session.savingTarget == nil, "save completion releases reserved target")
        check(session.isModified, "save of older captured revision does not clear new edit")
        let oldCapture = try DocumentSession.open(url: source)
        check(owned(oldCapture) == [pen, marker] && owned(session) == [pen, marker, newer], "disk contains captured revision only")
        session.saveWorkHook = nil
        check(isSuccess(save(session)), "followup manual save writes newer action")

        session.beginAction("一次拖选的两行文字高亮")
        for x in [40.0, 180.0] {
            let highlight = PDFAnnotation(bounds: CGRect(x: x, y: 590, width: 120, height: 16), forType: .highlight, withProperties: nil)
            highlight.color = NSColor.systemYellow.withAlphaComponent(0.45)
            highlight.contents = "LeafInk text highlight"
            session.document.page(at: 0)!.addAnnotation(highlight)
        }
        session.finishAction()
        let withHighlightsCount = session.document.page(at: 0)!.annotations.count
        session.undo()
        check(session.document === displayDocument && session.document.page(at: 0) === displayPage, "text-highlight undo also preserves the live PDF page")
        check(session.document.page(at: 0)!.annotations.count == withHighlightsCount - 2 && !session.isModified, "one drag creates two highlights in one undo action")
        session.redo()
        check(session.document.page(at: 0)!.annotations.count == withHighlightsCount && session.isModified, "redo restores complete multiline highlight action")
        check(isSuccess(save(session)), "text highlight standard appearance survives safe save")
        let textReopen = try DocumentSession.open(url: source)
        check(textReopen.document.page(at: 0)!.annotations.filter { $0.contents == "LeafInk text highlight" }.count == 2, "PDF-only reopen retains both text highlights")

        // Reading position/preferences are deliberately absent in this independent data directory.
        setenv("ECRU_DATA_DIR", isolated.appendingPathComponent("fresh-data").path, 1)
        let portable = try DocumentSession.open(url: source)
        check(portable.recoverableRecord == nil && owned(portable) == [pen, marker, newer], "isolated reopen has no local editable-state dependency")
        let page = portable.document.page(at: 0)!
        portable.beginAction("局部擦除")
        let fragments = InkGeometry.erase(pen, center: CGPoint(x: 130, y: 405), radius: 5)
        portable.replaceInk(on: page, ids: [pen.id], with: fragments)
        portable.finishAction()
        check(fragments.count == 2, "reopened stroke splits into independent fragments")
        portable.beginAction("移动片段")
        let moved = fragments[0].translated(dx: 20, dy: -12)
        portable.replaceInk(on: page, ids: [fragments[0].id], with: [moved])
        portable.finishAction()
        let portableOutput = directory.appendingPathComponent("reader-portable-storage.pdf")
        if FileManager.default.fileExists(atPath: portableOutput.path) { try FileManager.default.removeItem(at: portableOutput) }
        check(isSuccess(save(portable, to: portableOutput)), "save-as after isolated erase/move")
        check(portable.fileURL == portableOutput && !portable.isModified, "save-as switches path only after success")
        let portableCheck = try DocumentSession.open(url: portableOutput)
        check(owned(portableCheck).contains(moved) && owned(portableCheck).contains(fragments[1]), "fragment identities and movement survive another PDF-only reopen")

        let conflictURL = try copy(fixture, to: isolated, name: "conflict.pdf")
        let conflict = try DocumentSession.open(url: conflictURL)
        _ = add(conflict, x: 100)
        let externalData = try Data(contentsOf: source)
        try externalData.write(to: conflictURL, options: .atomic)
        check(!isSuccess(save(conflict)) && conflict.conflictDetected && conflict.isModified, "external conflict fails and preserves edits")
        check(try Data(contentsOf: conflictURL) == externalData, "external file remains byte-for-byte unchanged")
        check(!isSuccess(save(conflict)), "retry cannot silently overwrite detected conflict")
        let conflictCopy = isolated.appendingPathComponent("conflict-copy.pdf")
        check(isSuccess(save(conflict, to: conflictCopy)) && !conflict.conflictDetected, "conflict supports save-as without source overwrite")
        check(try Data(contentsOf: conflictURL) == externalData, "save-as preserves conflicted original")

        let imageGuardURL = try copy(fixture, to: isolated, name: "image-guard.pdf")
        let imageGuard = try DocumentSession.open(url: imageGuardURL)
        let imagePage = imageGuard.document.page(at: 3)!
        let blankPage = PDFPage()
        for box in [PDFDisplayBox.mediaBox, .cropBox, .bleedBox, .trimBox, .artBox] { blankPage.setBounds(imagePage.bounds(for: box), for: box) }
        blankPage.rotation = imagePage.rotation
        imageGuard.document.removePage(at: 3)
        imageGuard.document.insert(blankPage, at: 3)
        // Deliberately simulate a serializer/content-loss bug: same page count,
        // boxes, rotation and empty text layer, but the scanned image is absent.
        let guardedResult = save(imageGuard)
        var rejectedImageLoss = false
        if case .failure(let error) = guardedResult, case DocumentSessionError.validation(let detail) = error {
            rejectedImageLoss = detail.contains("原始页面内容或图像资源")
        }
        check(rejectedImageLoss, "content guard rejects missing scanned image despite unchanged text/count/geometry")
        check(try Data(contentsOf: imageGuardURL) == inputData, "image preservation failure leaves original PDF byte-for-byte unchanged")

        let snapshotFailureURL = try copy(fixture, to: isolated, name: "snapshot-failure.pdf")
        let snapshotFailure = try DocumentSession.open(url: snapshotFailureURL)
        let oldDiscardApproval = snapshotFailure.contentChangeToken
        snapshotFailure.snapshotDataProvider = { nil }
        check(!snapshotFailure.beginAction("blocked stroke") && !snapshotFailure.isModified, "failed before-snapshot refuses mutation authorization")
        check(snapshotFailure.contentChangeToken == oldDiscardApproval, "failed begin does not invent a content change token")
        snapshotFailure.snapshotDataProvider = nil
        check(snapshotFailure.beginAction("one complete stroke"), "successful before-snapshot authorizes one action")
        let pendingContentToken = snapshotFailure.contentChangeToken
        check(pendingContentToken != oldDiscardApproval && snapshotFailure.revision == oldDiscardApproval,
              "starting a new action invalidates an old discard approval even before the revision changes")
        let pendingStroke = InkStroke(points: [InkPoint(x: 80, y: 80)], width: 2, rgba: [0, 0, 0, 1], kind: .pen)
        snapshotFailure.replaceInk(on: snapshotFailure.document.page(at: 0)!, ids: [], with: [pendingStroke])
        snapshotFailure.snapshotDataProvider = { nil }
        snapshotFailure.finishAction()
        check(snapshotFailure.isModified && owned(snapshotFailure) == [pendingStroke], "failed after-snapshot retains unsaved action and visible content")
        check(snapshotFailure.contentChangeToken == pendingContentToken && snapshotFailure.contentChangeToken != oldDiscardApproval,
              "new stroke with failed after-snapshot cannot reuse the old quit-discard approval")
        check(!snapshotFailure.beginAction("must not combine next action"), "unrecorded pending action blocks further mutations")
        snapshotFailure.undo()
        check(owned(snapshotFailure) == [pendingStroke] && snapshotFailure.isModified, "failed snapshot cannot silently undo/discard pending content")
        snapshotFailure.snapshotDataProvider = nil
        snapshotFailure.finishAction()
        check(snapshotFailure.contentChangeToken == snapshotFailure.revision && snapshotFailure.contentChangeToken != pendingContentToken,
              "successful after-snapshot clears pending token and uses the completed revision")
        snapshotFailure.undo()
        check(owned(snapshotFailure).isEmpty && !snapshotFailure.isModified, "after serialization recovers, completed stroke is undoable as one action")
        check(snapshotFailure.contentChangeToken == oldDiscardApproval,
              "undo to the original content exposes its original revision token")

        let readOnlyURL = try copy(fixture, to: isolated, name: "readonly.pdf")
        let readOnly = try DocumentSession.open(url: readOnlyURL)
        _ = add(readOnly, x: 140)
        chmod(readOnlyURL.path, 0o444)
        check(!isSuccess(save(readOnly)) && readOnly.isModified, "read-only target rejects atomic replacement")
        check(try Data(contentsOf: readOnlyURL) == inputData, "failed write preserves all original bytes")
        chmod(readOnlyURL.path, 0o644)
        let priorURL = readOnly.fileURL
        let impossible = isolated.appendingPathComponent("missing-parent/no.pdf")
        check(!isSuccess(save(readOnly, to: impossible)) && readOnly.fileURL == priorURL, "failed save-as keeps current path")
        readOnly.isTargetOpenElsewhere = { _ in true }
        check(!isSuccess(save(readOnly, to: isolated.appendingPathComponent("open-elsewhere.pdf"))), "duplicate opened save target rejected")
        readOnly.isTargetOpenElsewhere = nil

        let recoveryURL = try copy(fixture, to: isolated, name: "recovery.pdf")
        let recovery = try DocumentSession.open(url: recoveryURL)
        let unsaved = add(recovery, x: 200)
        let afterCrash = try DocumentSession.open(url: recoveryURL)
        let record = afterCrash.recoverableRecord!
        check(owned(afterCrash).isEmpty, "recovery never silently overwrites source")
        try afterCrash.restoreRecovery(record)
        check(afterCrash.isModified && afterCrash.isRecovered && owned(afterCrash) == [unsaved], "restoring recovery is explicitly unsaved")
        check(try Data(contentsOf: recoveryURL) == inputData, "recovery does not save to original")
        afterCrash.discardRecovery()
        check(try DocumentSession.open(url: recoveryURL).recoverableRecord == nil, "discard removes intentionally abandoned recovery")

        let recoveryConflictURL = try copy(fixture, to: isolated, name: "recovery-conflict.pdf")
        let beforeCrash = try DocumentSession.open(url: recoveryConflictURL)
        _ = add(beforeCrash, x: 190)
        try externalData.write(to: recoveryConflictURL, options: .atomic)
        let afterExternal = try DocumentSession.open(url: recoveryConflictURL)
        try afterExternal.restoreRecovery(afterExternal.recoverableRecord!)
        check(afterExternal.conflictDetected && afterExternal.isModified, "recovery recognizes source changed after checkpoint")
        check(!isSuccess(save(afterExternal)), "restored conflict cannot overwrite current source")
        check(isSuccess(save(afterExternal, to: isolated.appendingPathComponent("recovery-conflict-copy.pdf"))), "recovered old source supports safe save-as")

        let cleanupData = isolated.appendingPathComponent("cleanup-data", isDirectory: true)
        setenv("ECRU_DATA_DIR", cleanupData.path, 1)
        let cleanupSource = try copy(fixture, to: isolated, name: "cleanup-failure.pdf")
        let cleanupFailure = try DocumentSession.open(url: cleanupSource)
        check(cleanupFailure.discardRecovery(), "discard succeeds when no recovery record exists")
        _ = add(cleanupFailure, x: 150)
        let recoveryDirectory = cleanupData.appendingPathComponent("Recovery", isDirectory: true)
        var cleanupNotifications = 0
        cleanupFailure.onChange = { cleanupNotifications += 1 }
        check(chmod(recoveryDirectory.path, 0o555) == 0, "test-only recovery directory made undeletable")
        let blockedDiscard = cleanupFailure.discardRecovery()
        check(!blockedDiscard && cleanupFailure.recoverableRecord != nil, "failed discard returns false and retains recovery bytes")
        check(cleanupFailure.lastError != nil && cleanupFailure.statusText == "恢复记录清理失败" && cleanupNotifications > 0, "failed discard reports persistent state and notifies UI")
        chmod(recoveryDirectory.path, 0o755)
        check(cleanupFailure.discardRecovery() && cleanupFailure.recoverableRecord == nil && cleanupFailure.lastError == nil, "fixed permissions permit discard and clear cleanup failure")
        check(cleanupFailure.discardRecovery(), "repeated discard of nonexistent record remains successful")

        cleanupFailure.recoveryDataProvider = { nil }
        _ = add(cleanupFailure, x: 180)
        check(cleanupFailure.isModified && cleanupFailure.lastError?.localizedDescription.contains("自动恢复数据生成失败") == true,
              "failed recovery serialization is visible and keeps edited content unsaved")
        check(cleanupFailure.recoverableRecord == nil && owned(cleanupFailure).count == 2,
              "failed recovery generation cannot claim a record exists or discard window content")
        cleanupFailure.recoveryDataProvider = nil
        cleanupFailure.checkpointRecovery()
        check(cleanupFailure.recoverableRecord != nil, "later recovery serialization can protect the retained current edits")

        _ = add(cleanupFailure, x: 220)
        check(chmod(recoveryDirectory.path, 0o555) == 0, "test-only old recovery made undeletable before save-as")
        let cleanSaveAsTarget = isolated.appendingPathComponent("cleanup-saved-copy.pdf")
        let cleanupSaveResult = save(cleanupFailure, to: cleanSaveAsTarget)
        var savedButCleanupFailed = false
        if case .success(let outcome) = cleanupSaveResult {
            savedButCleanupFailed = !outcome.recoveryCleanupSucceeded && !outcome.containsNewerUnsavedChanges
        }
        check(savedButCleanupFailed && cleanupFailure.fileURL == cleanSaveAsTarget && !cleanupFailure.isModified,
              "save-as reports PDF success separately from failed old recovery cleanup")
        check(cleanupFailure.statusText == "恢复记录清理失败" && cleanupFailure.lastError != nil,
              "successful PDF write does not claim recovery cleanup succeeded")
        let oldSourceReopen = try DocumentSession.open(url: cleanupSource)
        let oldSourceBytes = try Data(contentsOf: cleanupSource)
        check(oldSourceReopen.recoverableRecord != nil && oldSourceBytes == inputData,
              "failed old recovery cleanup retains record and save-as leaves old PDF unchanged")
        cleanupFailure.checkpointRecovery()
        check(cleanupFailure.statusText == "恢复记录清理失败", "checkpoint cannot clear an unresolved old-path cleanup failure")
        chmod(recoveryDirectory.path, 0o755)
        check(cleanupFailure.discardRecovery() && oldSourceReopen.recoverableRecord == nil && cleanupFailure.lastError == nil,
              "current session retries its retained old recovery path after permissions recover")
        check(isSuccess(save(cleanupFailure)), "normal save still succeeds after successful cleanup retry")

        _ = add(cleanupFailure, x: 280)
        chmod(recoveryDirectory.path, 0o555)
        let cleanupGate = DispatchSemaphore(value: 0)
        cleanupFailure.saveWorkHook = { cleanupGate.wait() }
        var doubleFailureResult: Result<SaveOutcome, Error>?
        cleanupFailure.save(to: isolated.appendingPathComponent("cleanup-newer-copy.pdf")) { doubleFailureResult = $0 }
        _ = add(cleanupFailure, x: 300)
        cleanupGate.signal()
        let cleanupDeadline = Date().addingTimeInterval(10)
        while doubleFailureResult == nil && Date() < cleanupDeadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        chmod(recoveryDirectory.path, 0o755)
        cleanupFailure.saveWorkHook = nil
        var compoundFailureReported = false
        if case .success(let outcome) = doubleFailureResult {
            compoundFailureReported = !outcome.recoveryCleanupSucceeded && outcome.containsNewerUnsavedChanges
        }
        check(compoundFailureReported && cleanupFailure.isModified, "save-as keeps newer edits unsaved when old recovery cleanup fails")
        let combinedReason = cleanupFailure.lastError?.localizedDescription ?? ""
        check(combinedReason.contains("无法清除恢复记录") && combinedReason.contains("自动恢复保护写入失败"),
              "simultaneous cleanup and new recovery-write failures both remain visible")
        cleanupFailure.checkpointRecovery()
        check(cleanupFailure.recoverableRecord != nil && cleanupFailure.discardRecovery(), "fixed permissions protect newer edits and permit all retained recovery cleanup")
        check(try Data(contentsOf: fixture) == inputData, "original fixture never changed")
        // Actual Canvas transaction path: disk work may be blocked while more
        // writing/erasing/undo remains available on the calling thread.
        setenv("ECRU_DATA_DIR", isolated.appendingPathComponent("fast-data").path, 1)
        let fastURL = try copy(fixture, to: isolated, name: "fast-ink.pdf")
        let fast = try DocumentSession.open(url: fastURL)
        let fastPage = fast.document.page(at: 0)!
        let ink = InkStroke(points: [InkPoint(x:100,y:400),InkPoint(x:300,y:400)],width:2,rgba:[0,0,1,1],kind:.pen)
        let writerEntered = DispatchSemaphore(value:0), releaseWriter = DispatchSemaphore(value:0)
        fast.recoveryWriteHook = { writerEntered.signal(); releaseWriter.wait() }
        check(fast.beginInkAction("write"), "ink transaction opens without PDF snapshot")
        fast.replaceInk(on:fastPage,ids:[],with:[ink]); fast.finishAction()
        check(writerEntered.wait(timeout:.now()+2) == .success, "recovery writes on independent worker")
        fast.recoveryWriteHook = nil
        let fastPieces = InkGeometry.erase(ink,center:CGPoint(x:200,y:400),radius:9)
        check(fast.beginInkAction("erase"), "eraser starts while recovery disk writer is blocked")
        fast.replaceInk(on:fastPage,ids:[ink.id],with:fastPieces); fast.finishAction()
        check(owned(fast) == fastPieces && fastPieces.count == 2, "eraser commits complete fragments without disk wait")
        fast.undo(); check(owned(fast) == [ink], "ink-only erase undo uses exact model")
        fast.redo(); check(owned(fast) == fastPieces, "ink-only erase redo uses exact model")
        releaseWriter.signal()
        let fastRecord = fast.recoverableRecord!
        check(fastRecord.version == 3 && fastRecord.ink?[0] == fastPieces, "queued recovery keeps newest revision instead of obsolete stroke")
        let recoveredFast = try DocumentSession.open(url:fastURL)
        try recoveredFast.restoreRecovery(fastRecord)
        check(owned(recoveredFast) == fastPieces && recoveredFast.isModified, "version 3 recovery restores precise model and remains unsaved")
        check(try Data(contentsOf:fastURL) == inputData, "async recovery never overwrites source PDF")
        check(fast.beginAction("text highlight"), "generic PDF action follows fast ink")
        let fastHighlight = PDFAnnotation(bounds:CGRect(x:40,y:650,width:100,height:12),forType:.highlight,withProperties:nil)
        fastPage.addAnnotation(fastHighlight); fast.finishAction()
        let shifted = fastPieces.map { $0.translated(dx:12,dy:-9) }
        check(fast.beginInkAction("move"), "fast ink follows generic PDF action")
        fast.replaceInk(on:fastPage,ids:Set(fastPieces.map(\.id)),with:shifted); fast.finishAction()
        fast.undo(); check(owned(fast) == fastPieces && fastPage.annotations.contains(where: { $0.type == "Highlight" && $0.bounds == fastHighlight.bounds }), "ink undo keeps preceding text annotation")
        fast.undo(); check(!fastPage.annotations.contains(where: { $0.type == "Highlight" && $0.bounds == fastHighlight.bounds }) && owned(fast) == fastPieces, "mixed history undo restores text and ink independently")
        fast.redo(); fast.redo()
        check(owned(fast) == shifted && fastPage.annotations.contains(where: { $0.type == "Highlight" && $0.bounds == fastHighlight.bounds }), "mixed history redo restores both layers")
        let mixedRecord = fast.recoverableRecord!
        let mixedReopen = try DocumentSession.open(url:fastURL)
        try mixedReopen.restoreRecovery(mixedRecord)
        check(owned(mixedReopen) == shifted && mixedReopen.document.page(at:0)!.annotations.count == baselineAnnotations+1,
              "recovery base follows generic changes before fast ink")
        check(isSuccess(save(fast)) && fast.recoverableRecord == nil, "manual save flushes and clears async recovery")
        check(owned(try DocumentSession.open(url:fastURL)) == shifted, "fast ink persists as editable standard PDF")
        check(fast.beginInkAction("move again"), "post-save fast action opens")
        fast.replaceInk(on:fastPage,ids:Set(shifted.map(\.id)),with:fastPieces); fast.finishAction()
        check(fast.discardRecovery() && fast.recoverableRecord == nil, "discard cancels pending writes without recreating recovery")

        // Save As while a newer ink revision is being recovered must neither
        // mark it saved nor allow an old-path queued write to reappear.
        let fastSaveGate = DispatchSemaphore(value:0)
        fast.saveWorkHook = { fastSaveGate.wait() }
        var fastSaveResult: Result<SaveOutcome,Error>?
        let fastSaveAs = isolated.appendingPathComponent("fast-save-as.pdf")
        fast.save(to:fastSaveAs) { fastSaveResult = $0 }
        check(fast.beginInkAction("newer edit during save"), "fast editing remains available during save")
        fast.replaceInk(on:fastPage,ids:Set(fastPieces.map(\.id)),with:shifted); fast.finishAction()
        fastSaveGate.signal()
        let fastDeadline = Date().addingTimeInterval(10)
        while fastSaveResult == nil && Date() < fastDeadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        if case .success(let outcome) = fastSaveResult {
            check(outcome.containsNewerUnsavedChanges && fast.isModified, "save capture cannot mark newer fast ink saved")
        } else { check(false, "fast Save As completed") }
        let afterFastSave = fast.recoverableRecord!
        let reopenFastSave = try DocumentSession.open(url:fastSaveAs)
        try reopenFastSave.restoreRecovery(afterFastSave)
        check(owned(reopenFastSave) == shifted, "new-path recovery includes newer fast edits")
        check(try DocumentSession.open(url:fastURL).recoverableRecord == nil, "old-path recovery cannot reappear after Save As")
        fast.saveWorkHook = nil
        check(fast.discardRecovery(), "new-path fast recovery can be explicitly discarded")

        let badRecoveryRoot = isolated.appendingPathComponent("recovery-is-a-file")
        try Data("block directory creation".utf8).write(to:badRecoveryRoot)
        setenv("ECRU_DATA_DIR",badRecoveryRoot.path,1)
        let failingFast = try DocumentSession.open(url:fastURL)
        check(failingFast.beginInkAction("recovery failure"), "disk failure does not block starting ink")
        failingFast.replaceInk(on:failingFast.document.page(at:0)!,ids:[],with:[ink]); failingFast.finishAction()
        _ = failingFast.recoverableRecord // Wait only in this check, never in input.
        let errorDeadline = Date().addingTimeInterval(2)
        while failingFast.lastError == nil && Date() < errorDeadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
        check(failingFast.lastError?.localizedDescription.contains("自动恢复保护写入失败") == true && failingFast.isModified,
              "background recovery failure is surfaced without discarding editable ink")

        print("PASS: \(checks) storage / safe-save / conflict / recovery checks; portable PDF: \(portableOutput.path)")
        try FileManager.default.removeItem(at: isolated)
    }
}
