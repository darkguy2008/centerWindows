import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let centeringService = WindowCenteringService()
    private lazy var eventObserver = WindowEventObserver(service: centeringService)
    private var statusItem: NSStatusItem?
    private var launchCenterTimer: DispatchSourceTimer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Preferences.registerDefaults()
        setupStatusItem()
        _ = ScreenCapturePermission.ensureAuthorized(prompt: true)
        _ = AccessibilityPermission.ensureTrusted(prompt: true)
        eventObserver.start()
        centerOnceOnLaunch()
    }

    // MARK: - Actions

    @objc private func centerNow() {
        centerNowInternal(showAlertOnFailure: true, selectionPolicy: .focusedOnly)
    }

    @objc private func toggleCenterNewWindows(_ sender: NSMenuItem) {
        Preferences.centerNewWindows.toggle()
        sender.state = Preferences.centerNewWindows ? .on : .off
    }

    @objc private func toggleCenterOnSwitch(_ sender: NSMenuItem) {
        Preferences.centerOnSwitch.toggle()
        sender.state = Preferences.centerOnSwitch ? .on : .off
    }

    @objc private func selectChinese() {
        Preferences.language = "zh"
        rebuildMenu()
    }

    @objc private func selectEnglish() {
        Preferences.language = "en"
        rebuildMenu()
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

    // MARK: - Menu

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

        statusItem = item
        rebuildMenu()
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        addMenuItem(to: menu, Preferences.L("立即将前台窗口居中", "Center frontmost window"), #selector(centerNow))

        menu.addItem(.separator())

        addMenuItem(to: menu, Preferences.L("新窗口自动居中", "Center new windows"),
                    #selector(toggleCenterNewWindows(_:)), checked: Preferences.centerNewWindows)
        addMenuItem(to: menu, Preferences.L("切换应用时自动居中", "Center on app switch"),
                    #selector(toggleCenterOnSwitch(_:)), checked: Preferences.centerOnSwitch)

        menu.addItem(.separator())

        addMenuItem(to: menu, "中文", #selector(selectChinese), checked: Preferences.language == "zh")
        addMenuItem(to: menu, "English", #selector(selectEnglish), checked: Preferences.language == "en")

        menu.addItem(.separator())

        addMenuItem(to: menu, Preferences.L("打开辅助功能权限设置", "Open Accessibility settings"),
                    #selector(openAccessibilitySettings))
        addMenuItem(to: menu, Preferences.L("打开屏幕录制权限设置", "Open Screen Recording settings"),
                    #selector(openScreenCaptureSettings))

        menu.addItem(.separator())

        addMenuItem(to: menu, Preferences.L("退出", "Quit"), #selector(quitApp))

        statusItem?.menu = menu
    }

    private func addMenuItem(to menu: NSMenu, _ title: String, _ action: Selector, checked: Bool? = nil) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        if let checked {
            item.state = checked ? .on : .off
        }
    }

    // MARK: - Centering helpers

    private func centerNowInternal(showAlertOnFailure: Bool, selectionPolicy: WindowSelectionPolicy) {
        do {
            try centeringService.centerFrontmostWindow(selectionPolicy: selectionPolicy)
        } catch {
            if let centeringError = error as? WindowCenteringError, centeringError == .fullscreenWindow {
                return
            }
            if showAlertOnFailure {
                showAlert(
                    title: Preferences.L("窗口居中失败", "Window centering failed"),
                    message: error.localizedDescription
                )
            }
        }
    }

    private func centerOnceOnLaunch() {
        guard Preferences.centerOnSwitch else { return }
        launchCenterTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        var attempts = 0
        timer.schedule(deadline: .now() + 0.35, repeating: 0.45)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            attempts += 1
            self.centerNowInternal(showAlertOnFailure: false, selectionPolicy: .focusedOrAnyNonFullscreen)

            if attempts >= 10 {
                self.launchCenterTimer?.cancel()
                self.launchCenterTimer = nil
            }
        }
        launchCenterTimer = timer
        timer.resume()
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
