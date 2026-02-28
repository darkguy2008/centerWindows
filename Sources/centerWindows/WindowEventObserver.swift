import AppKit
import ApplicationServices

@MainActor
final class WindowEventObserver {
    private let service: WindowCenteringService
    private var observer: AXObserver?
    private var observedPID: pid_t?
    private var centeredWindowKeys: [String] = []
    private var centeredWindowKeySet: Set<String> = []
    private var initialCenterTimer: DispatchSourceTimer?

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
        initialCenterTimer?.cancel()
        initialCenterTimer = nil
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

        initialCenterTimer?.cancel()
        initialCenterTimer = nil
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
        _ = handle(notification: "initial", element: appElement, forcedPID: pid)

        // Some apps only create their focused window after a short delay (splash screens, permission prompts, etc.).
        // Retry briefly without showing alerts; stop once we successfully center a window or after a timeout.
        startInitialCenteringRetries(pid: pid, appElement: appElement)
    }

    @discardableResult
    private func handle(notification: String, element: AXUIElement, forcedPID: pid_t? = nil) -> Bool {
        let appName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"

        let isNewWindow = notification == kAXWindowCreatedNotification as String

        // For AXWindowCreated, check the notification element itself. Some apps
        // (e.g. Chrome) fire spurious AXWindowCreated for internal helper windows
        // that are not standard windows. Filter them out at the source.
        if isNewWindow && !isAutoCenterEligibleWindow(element) {
            NSLog("[cw] SKIPPED (ineligible created element) app=%@", appName)
            return false
        }

        let isEnabled = isNewWindow ? Preferences.centerNewWindows : Preferences.centerOnSwitch
        NSLog("[cw] notification=%@ app=%@ isNewWindow=%d isEnabled=%d",
              notification, appName, isNewWindow ? 1 : 0, isEnabled ? 1 : 0)
        guard isEnabled else { return false }

        let pid: pid_t
        if let forcedPID {
            pid = forcedPID
        } else {
            guard let app = NSWorkspace.shared.frontmostApplication else { return false }
            pid = app.processIdentifier
        }

        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return false }

        let appElement = AXUIElementCreateApplication(pid)
        guard let windowElement = centerCandidateWindow(for: appElement) else {
            NSLog("[cw] SKIPPED (no candidate window)")
            return false
        }

        let wKey = key(pid: pid, window: windowElement)
        if let wKey, centeredWindowKeySet.contains(wKey) {
            NSLog("[cw] SKIPPED (already centered) key=%@", wKey)
            return false
        }

        do {
            try service.centerWindowElement(windowElement, pid: pid, appElement: appElement)
            if let wKey { recordCenteredKey(wKey) }
            NSLog("[cw] CENTERED key=%@ app=%@", wKey ?? "?", appName)
            return true
        } catch {
            NSLog("[cw] FAILED: %@", error.localizedDescription)
            return false
        }
    }

    private func centerCandidateWindow(for appElement: AXUIElement) -> AXUIElement? {
        // Prefer the focused window if it is a standard main window.
        if
            let focused = windowElementAttribute(kAXFocusedWindowAttribute as CFString, on: appElement),
            isAutoCenterEligibleWindow(focused)
        {
            return focused
        }

        // Some apps do not set AXFocusedWindow immediately after activation; fall back to selecting the
        // largest standard window from AXWindows.
        let windows = windowElementsAttribute(kAXWindowsAttribute as CFString, on: appElement)
        var best: (window: AXUIElement, area: CGFloat)?
        for w in windows where isAutoCenterEligibleWindow(w) {
            guard let size = sizeAttribute(kAXSizeAttribute as CFString, on: w) else { continue }
            let area = max(0, size.width) * max(0, size.height)
            if let best, best.area >= area { continue }
            best = (w, area)
        }
        return best?.window
    }

    private func isAutoCenterEligibleWindow(_ window: AXUIElement) -> Bool {
        // Only auto-center standard main windows. This skips dialogs/sheets/panels that users perceive as
        // "secondary pages" within the same app.
        if stringAttribute(kAXRoleAttribute as CFString, on: window) == kAXUnknownRole as String {
            return false
        }

        if let minimized = boolAttribute(kAXMinimizedAttribute as CFString, on: window), minimized {
            return false
        }
        if let modal = boolAttribute(kAXModalAttribute as CFString, on: window), modal {
            return false
        }

        if let subrole = stringAttribute(kAXSubroleAttribute as CFString, on: window) {
            // Only standard windows are eligible; dialogs, floating panels, and
            // any other subrole are skipped to avoid surprise movements.
            return subrole == kAXStandardWindowSubrole as String
        }

        // No subrole exposed: treat as eligible (many apps omit it for normal windows).
        return true
    }

    private func startInitialCenteringRetries(pid: pid_t, appElement: AXUIElement) {
        initialCenterTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var attempts = 0
        timer.schedule(deadline: .now() + 0.25, repeating: 0.35)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            attempts += 1

            // If user has switched away, stop retrying.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                self.initialCenterTimer?.cancel()
                self.initialCenterTimer = nil
                return
            }

            let didCenter = self.handle(notification: "initial-retry", element: appElement, forcedPID: pid)
            if didCenter {
                self.initialCenterTimer?.cancel()
                self.initialCenterTimer = nil
                return
            }

            if attempts >= 12 {
                self.initialCenterTimer?.cancel()
                self.initialCenterTimer = nil
            }
        }
        initialCenterTimer = timer
        timer.resume()
    }

    private func windowElementAttribute(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func windowElementsAttribute(_ attribute: CFString, on element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private func stringAttribute(_ attribute: CFString, on element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        guard let value, CFGetTypeID(value) == CFStringGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: CFString.self) as String
    }

    private func boolAttribute(_ attribute: CFString, on element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID() else {
            return nil
        }
        return CFBooleanGetValue(unsafeDowncast(value, to: CFBoolean.self))
    }

    private func sizeAttribute(_ attribute: CFString, on element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        guard let value else {
            return nil
        }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        let axValue = unsafeDowncast(value, to: AXValue.self)

        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }
        return size
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

    private func recordCenteredKey(_ key: String) {
        guard centeredWindowKeySet.insert(key).inserted else { return }
        centeredWindowKeys.append(key)

        // Prevent unbounded growth.
        if centeredWindowKeys.count > 200, let oldest = centeredWindowKeys.first {
            centeredWindowKeys.removeFirst()
            centeredWindowKeySet.remove(oldest)
        }
    }
}
