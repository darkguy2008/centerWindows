import AppKit
import ApplicationServices

enum WindowCenteringError: LocalizedError {
    case accessibilityPermissionMissing
    case noFrontmostApplication
    case noWindow
    case fullscreenWindow
    case unableToReadWindowFrame
    case unableToWriteWindowPosition

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "缺少辅助功能权限，请在“系统设置 -> 隐私与安全性 -> 辅助功能”中授权。"
        case .noFrontmostApplication:
            return "未检测到前台应用。"
        case .noWindow:
            return "前台应用没有可操作窗口。"
        case .fullscreenWindow:
            return "当前窗口处于全屏状态，已跳过居中。"
        case .unableToReadWindowFrame:
            return "无法读取窗口位置或尺寸。"
        case .unableToWriteWindowPosition:
            return "无法设置窗口位置（窗口可能不可移动）。"
        }
    }
}

enum WindowSelectionPolicy {
    case focusedOnly
    case focusedOrAnyNonFullscreen
}

final class WindowCenteringService {
    private enum CoordinateMode {
        case bottomLeft
        case topLeft(screenTop: CGFloat)
    }

    func centerFrontmostWindow(selectionPolicy: WindowSelectionPolicy = .focusedOrAnyNonFullscreen) throws {
        guard AccessibilityPermission.ensureTrusted(prompt: false) else {
            throw WindowCenteringError.accessibilityPermissionMissing
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            throw WindowCenteringError.noFrontmostApplication
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if isApplicationInFullscreen(appElement) {
            throw WindowCenteringError.fullscreenWindow
        }

        let focusedWindow = focusedWindowElement(for: appElement)
        let allWindows = windowElements(for: appElement)
        guard let windowElement = selectCenterableWindow(
            focused: focusedWindow,
            windows: allWindows,
            selectionPolicy: selectionPolicy
        ) else {
            if let focusedWindow, isFullscreenWindow(focusedWindow) {
                throw WindowCenteringError.fullscreenWindow
            }
            throw WindowCenteringError.noWindow
        }

        try centerWindowElement(windowElement)
    }

    func centerWindowElement(_ windowElement: AXUIElement, appElement: AXUIElement? = nil) throws {
        if let appElement, isApplicationInFullscreen(appElement) {
            throw WindowCenteringError.fullscreenWindow
        }
        if isFullscreenWindow(windowElement) {
            throw WindowCenteringError.fullscreenWindow
        }

        guard
            let currentPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            throw WindowCenteringError.unableToReadWindowFrame
        }

        guard let context = detectWindowContext(rawPosition: currentPosition, windowSize: windowSize) else {
            throw WindowCenteringError.unableToReadWindowFrame
        }

        let visibleFrame = effectiveVisibleFrame(for: context.screen)
        let centeredBottomLeftOrigin = WindowGeometry.centeredOrigin(windowSize: windowSize, visibleFrame: visibleFrame)
        let targetAXOrigin = CGPoint(
            x: centeredBottomLeftOrigin.x,
            y: toAXY(bottomLeftY: centeredBottomLeftOrigin.y, windowHeight: windowSize.height, mode: context.mode)
        )

        guard setPointAttribute(kAXPositionAttribute as CFString, value: targetAXOrigin, on: windowElement) else {
            throw WindowCenteringError.unableToWriteWindowPosition
        }
    }

    private func focusedWindowElement(for appElement: AXUIElement) -> AXUIElement? {
        windowAttribute(kAXFocusedWindowAttribute as CFString, on: appElement)
    }

    private func mainWindowElement(for appElement: AXUIElement) -> AXUIElement? {
        windowAttribute(kAXMainWindowAttribute as CFString, on: appElement)
    }

    private func windowElements(for appElement: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &value)
        guard result == .success else {
            return []
        }
        return (value as? [AXUIElement]) ?? []
    }

    private func isApplicationInFullscreen(_ appElement: AXUIElement) -> Bool {
        // Prefer checking main/focused window to avoid scanning too many windows.
        if let main = mainWindowElement(for: appElement), isFullscreenWindow(main) {
            return true
        }
        if let focused = focusedWindowElement(for: appElement), isFullscreenWindow(focused) {
            return true
        }
        return false
    }

    private func selectCenterableWindow(
        focused: AXUIElement?,
        windows: [AXUIElement],
        selectionPolicy: WindowSelectionPolicy
    ) -> AXUIElement? {
        if let focused, !isFullscreenWindow(focused) {
            return focused
        }
        if selectionPolicy == .focusedOnly {
            return nil
        }
        return windows.first(where: { !isFullscreenWindow($0) })
    }

    private func windowAttribute(_ attribute: CFString, on element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else {
            return nil
        }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private func pointAttribute(_ attribute: CFString, on element: AXUIElement) -> CGPoint? {
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

        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }
        return point
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

    private func setPointAttribute(_ attribute: CFString, value: CGPoint, on element: AXUIElement) -> Bool {
        var mutablePoint = value
        guard let axValue = AXValueCreate(.cgPoint, &mutablePoint) else {
            return false
        }
        return AXUIElementSetAttributeValue(element, attribute, axValue) == .success
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

    private func isFullscreenWindow(_ windowElement: AXUIElement) -> Bool {
        // Primary signal if available.
        if boolAttribute("AXFullScreen" as CFString, on: windowElement) == true {
            return true
        }

        // Fallback for apps/spaces that don't expose AXFullScreen reliably.
        // Try both coordinate interpretations against every screen and accept the best match.
        guard
            let rawPosition = pointAttribute(kAXPositionAttribute as CFString, on: windowElement),
            let windowSize = sizeAttribute(kAXSizeAttribute as CFString, on: windowElement)
        else {
            return false
        }

        for screen in NSScreen.screens {
            let screenFrame = screen.frame

            // Assume bottom-left coordinates.
            let bottomLeftRect = CGRect(origin: rawPosition, size: windowSize)
            if isFullscreenLike(windowFrame: bottomLeftRect, screenFrame: screenFrame) {
                return true
            }

            // Assume top-left coordinates (y from top of the current screen).
            let convertedBottomY = screenFrame.maxY - rawPosition.y - windowSize.height
            let topLeftRect = CGRect(
                x: rawPosition.x,
                y: convertedBottomY,
                width: windowSize.width,
                height: windowSize.height
            )
            if isFullscreenLike(windowFrame: topLeftRect, screenFrame: screenFrame) {
                return true
            }
        }

        return false
    }

    private func isFullscreenLike(windowFrame: CGRect, screenFrame: CGRect) -> Bool {
        // Be tolerant of minor off-by-few-pixels differences (rounded corners, scaling, etc.).
        let tol: CGFloat = 6.0
        let posMatch = abs(windowFrame.minX - screenFrame.minX) <= tol &&
            abs(windowFrame.minY - screenFrame.minY) <= tol
        let sizeMatch = abs(windowFrame.width - screenFrame.width) <= tol &&
            abs(windowFrame.height - screenFrame.height) <= tol

        if posMatch && sizeMatch {
            return true
        }

        // Secondary heuristic: near-full coverage with aligned origin.
        let screenArea = max(1.0, screenFrame.width * screenFrame.height)
        let ratio = (windowFrame.width * windowFrame.height) / screenArea
        return posMatch && ratio >= 0.98
    }

    private func detectWindowContext(rawPosition: CGPoint, windowSize: CGSize) -> (screen: NSScreen, mode: CoordinateMode)? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }

        var best: (screen: NSScreen, mode: CoordinateMode, overlap: CGFloat)?

        for screen in screens {
            let convertedBottomY = screen.frame.maxY - rawPosition.y - windowSize.height
            let convertedRect = CGRect(
                x: rawPosition.x,
                y: convertedBottomY,
                width: windowSize.width,
                height: windowSize.height
            )
            let topOverlap = convertedRect.intersection(screen.frame).area
            updateBest(
                best: &best,
                candidate: (screen, .topLeft(screenTop: screen.frame.maxY), topOverlap)
            )

            let bottomRect = CGRect(origin: rawPosition, size: windowSize)
            let bottomOverlap = bottomRect.intersection(screen.frame).area
            updateBest(
                best: &best,
                candidate: (screen, .bottomLeft, bottomOverlap)
            )
        }

        if let best {
            return (best.screen, best.mode)
        }
        if let main = NSScreen.main {
            return (main, .bottomLeft)
        }
        return nil
    }

    private func updateBest(
        best: inout (screen: NSScreen, mode: CoordinateMode, overlap: CGFloat)?,
        candidate: (screen: NSScreen, mode: CoordinateMode, overlap: CGFloat)
    ) {
        if let currentBest = best {
            if candidate.overlap > currentBest.overlap {
                best = candidate
                return
            }

            let isTie = abs(candidate.overlap - currentBest.overlap) < 0.5
            if isTie {
                switch (currentBest.mode, candidate.mode) {
                case (.bottomLeft, .topLeft):
                    best = candidate
                    return
                default:
                    return
                }
            }
            return
        }
        best = candidate
    }

    private func toAXY(bottomLeftY: CGFloat, windowHeight: CGFloat, mode: CoordinateMode) -> CGFloat {
        switch mode {
        case .bottomLeft:
            return bottomLeftY
        case .topLeft(let screenTop):
            return (screenTop - bottomLeftY - windowHeight).rounded()
        }
    }

    private func effectiveVisibleFrame(for screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let visible = screen.visibleFrame

        let leftInset = visible.minX - frame.minX
        let rightInset = frame.maxX - visible.maxX
        let bottomInset = visible.minY - frame.minY
        let topInset = frame.maxY - visible.maxY

        return CGRect(
            x: frame.minX + leftInset,
            y: frame.minY + bottomInset,
            width: frame.width - leftInset - rightInset,
            height: frame.height - topInset - bottomInset
        )
    }
}

private extension CGRect {
    var area: CGFloat {
        if isNull || isEmpty {
            return 0
        }
        return width * height
    }
}
