import AppKit
import ApplicationServices

@MainActor
final class WindowEventObserver {
    private let service: WindowCenteringService
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var centeredWindowKeys: [String] = []
    private var centeredWindowKeySet: Set<String> = []

    init(service: WindowCenteringService) {
        self.service = service
    }

    func start() {
        stop()
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeAppChanged),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        attachToFrontmostApp()
    }

    func stop() {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = nil
        centeredWindowKeys.removeAll()
        centeredWindowKeySet.removeAll()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func activeAppChanged() {
        attachToFrontmostApp()
    }

    private func attachToFrontmostApp() {
        guard AccessibilityPermission.ensureTrusted(prompt: false) else { return }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }

        if observedPID == app.processIdentifier {
            return
        }

        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observer = nil
        observedPID = nil

        let pid = app.processIdentifier
        var newObserver: AXObserver?
        let result = AXObserverCreate(pid, { _, element, notification, refcon in
            guard let refcon else { return }
            let unmanaged = Unmanaged<WindowEventObserver>.fromOpaque(refcon)
            let obj = unmanaged.takeUnretainedValue()
            Task { @MainActor in
                obj.handle(notification: notification as String, element: element)
            }
        }, &newObserver)

        guard result == .success, let newObserver else {
            return
        }

        observer = newObserver
        observedPID = pid

        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(newObserver), .defaultMode)

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(newObserver, appElement, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(newObserver, appElement, kAXWindowCreatedNotification as CFString, refcon)

        // Ensure newly activated apps get centered once even if no AX notifications fire after attaching.
        handle(notification: "initial", element: appElement)
    }

    private func handle(notification: String, element: AXUIElement) {
        // For focused-window-changed, element is usually the app; for window-created it can be the window.
        // We always center the current focused window once per window.
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success else {
            return
        }
        guard let focusedWindow = focusedValue else { return }
        guard CFGetTypeID(focusedWindow) == AXUIElementGetTypeID() else { return }
        let windowElement = unsafeDowncast(focusedWindow, to: AXUIElement.self)

        if hasCentered(windowElement: windowElement, pid: app.processIdentifier) {
            return
        }

        do {
            try service.centerWindowElement(windowElement, appElement: appElement)
            markCentered(windowElement: windowElement, pid: app.processIdentifier)
        } catch {
            // Skip fullscreen or any other temporary failures silently.
        }
    }

    private func windowNumber(of window: AXUIElement) -> Int? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXWindowNumber" as CFString, &value) != .success {
            return nil
        }
        guard let value, CFGetTypeID(value) == CFNumberGetTypeID() else {
            return nil
        }
        var n: Int = 0
        if CFNumberGetValue(unsafeDowncast(value, to: CFNumber.self), .intType, &n) {
            return n
        }
        return nil
    }

    private func key(pid: pid_t, window: AXUIElement) -> String? {
        guard let num = windowNumber(of: window) else { return nil }
        return "\(pid):\(num)"
    }

    private func hasCentered(windowElement: AXUIElement, pid: pid_t) -> Bool {
        guard let k = key(pid: pid, window: windowElement) else { return false }
        return centeredWindowKeySet.contains(k)
    }

    private func markCentered(windowElement: AXUIElement, pid: pid_t) {
        guard let k = key(pid: pid, window: windowElement) else { return }
        if centeredWindowKeySet.contains(k) { return }

        centeredWindowKeySet.insert(k)
        centeredWindowKeys.append(k)

        // Prevent unbounded growth.
        if centeredWindowKeys.count > 200, let oldest = centeredWindowKeys.first {
            centeredWindowKeys.removeFirst()
            centeredWindowKeySet.remove(oldest)
        }
    }
}
