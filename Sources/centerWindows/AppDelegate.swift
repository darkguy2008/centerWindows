import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let centeringService = WindowCenteringService()
    private lazy var eventObserver = WindowEventObserver(service: centeringService)
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        _ = ScreenCapturePermission.ensureAuthorized(prompt: true)
        _ = AccessibilityPermission.ensureTrusted(prompt: true)
        centerOnceOnLaunch()
        eventObserver.start()
    }

    @objc private func centerNow() {
        do {
            try centeringService.centerFrontmostWindow(selectionPolicy: .focusedOnly)
        } catch {
            if let centeringError = error as? WindowCenteringError, centeringError == .fullscreenWindow {
                return
            }
            showAlert(title: "窗口居中失败", message: error.localizedDescription)
        }
    }

    @objc private func openAccessibilitySettings() {
        AccessibilityPermission.openSettings()
    }

    @objc private func openScreenCaptureSettings() {
        ScreenCapturePermission.openSettings()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if
            let iconURL = Bundle.main.url(forResource: "StatusIconTemplate", withExtension: "png"),
            let statusImage = NSImage(contentsOf: iconURL)
        {
            statusImage.isTemplate = true
            statusImage.size = NSSize(width: 18, height: 18)
            item.button?.image = statusImage
            item.button?.imagePosition = .imageOnly
            item.button?.title = ""
        } else {
            item.button?.title = "centerWindows"
        }

        let menu = NSMenu()
        menu.autoenablesItems = false

        let centerItem = menu.addItem(
            withTitle: "立即将前台窗口居中",
            action: #selector(centerNow),
            keyEquivalent: ""
        )
        centerItem.target = self

        menu.addItem(.separator())
        let permissionItem = menu.addItem(
            withTitle: "打开辅助功能权限设置",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        permissionItem.target = self
        let screenPermissionItem = menu.addItem(
            withTitle: "打开屏幕录制权限设置",
            action: #selector(openScreenCaptureSettings),
            keyEquivalent: ""
        )
        screenPermissionItem.target = self
        menu.addItem(.separator())
        let quitItem = menu.addItem(
            withTitle: "退出",
            action: #selector(quitApp),
            keyEquivalent: ""
        )
        quitItem.target = self

        item.menu = menu
        statusItem = item
    }

    private func centerOnceOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.centerNow()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
