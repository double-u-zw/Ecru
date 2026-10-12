import AppKit

/// Local routing only. This scope never fabricates, reposts or holds a system key.
/// A swallowed command's repeats/up stay local; ordinary typing is passed intact.
final class WindowInputScope {
    typealias Handler = (NSEvent) -> NSEvent?
    typealias Install = (NSEvent.EventTypeMask, @escaping Handler) -> Any?
    static let nativeInstall: Install = { NSEvent.addLocalMonitorForEvents(matching: $0, handler: $1) }
    static let nativeRemove: (Any) -> Void = { NSEvent.removeMonitor($0) }
    private var token: Any?
    private let remove: (Any) -> Void
    private let belongs: (NSEvent) -> Bool
    private let handle: (NSEvent) -> Bool
    private var consumed = Set<UInt16>()
    private(set) var stopped = false

    init(install: Install = WindowInputScope.nativeInstall,
         remove: @escaping (Any) -> Void = WindowInputScope.nativeRemove,
         belongs: @escaping (NSEvent) -> Bool,
         handle: @escaping (NSEvent) -> Bool) {
        self.remove = remove; self.belongs = belongs; self.handle = handle
        token = install([.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .scrollWheel,.tabletProximity]) { [weak self] event in
            guard let self else { return event }
            return self.route(event)
        }
    }
    private func route(_ event: NSEvent) -> NSEvent? {
        guard !stopped, belongs(event) else { return event }
        if event.type == .keyUp {
            return consumed.remove(event.keyCode) != nil ? nil : event
        }
        if event.type == .keyDown, consumed.contains(event.keyCode) {
            // A repeat cannot execute a second command after the first dismisses UI.
            if event.isARepeat { return nil }
            // A fresh down is also valid if focus changes made the old up unavailable.
            consumed.remove(event.keyCode)
        }
        guard handle(event) else { return event }
        if event.type == .keyDown { consumed.insert(event.keyCode) }
        return nil
    }
    func lostFocus() { consumed.removeAll() }
    func stop() {
        guard !stopped else { return }
        stopped = true; lostFocus()
        if let token { remove(token) }
        token = nil
    }
    deinit { stop() }
}
