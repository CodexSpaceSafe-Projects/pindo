import AppKit
import SwiftUI
import ServiceManagement
import PindoCore

@main struct PindoApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    static func taskPanel() -> QuickPanel {
        // Let WindowServer own the rounded frame and resize handles. Clipping a
        // second rounded hosting layer produces a light fringe at the corners.
        let panel = nativePanel(size: NSSize(width: 420, height: 640), resizable: true)
        panel.contentMinSize = NSSize(width: 360, height: 420)
        panel.setFrameAutosaveName("PindoTaskPanel")
        panel.setFrameUsingName("PindoTaskPanel")
        return panel
    }

    static func quickAddPanel() -> QuickPanel {
        nativePanel(size: NSSize(width: QuickAddView.panelWidth, height: 194), resizable: false)
    }

    private static func nativePanel(size: NSSize, resizable: Bool) -> QuickPanel {
        var style: NSWindow.StyleMask = [.titled, .fullSizeContentView, .nonactivatingPanel]
        if resizable { style.insert(.resizable) }
        let panel = QuickPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(kind)?.isHidden = true }
        panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false; panel.isOpaque = false
        panel.backgroundColor = .clear; panel.hasShadow = true
        panel.configurePin(false)
        return panel
    }

    func configurePin(_ pinned: Bool) {
        // Transient panels must also sit above the active application's normal windows.
        level = .floating
        collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
    }

    func showInFront() {
        level = .floating
        makeKeyAndOrderFront(nil)
        // The app remains inactive, so explicitly order the panel across applications.
        orderFrontRegardless()
    }
}

@MainActor enum NativeStatusMenu {
    static func show(_ menu: NSMenu, on item: NSStatusItem,
                     track: (NSStatusBarButton) -> Void = { $0.performClick(nil) }) {
        guard let button = item.button else { return }
        let previousMenu = item.menu
        let previousTarget = button.target
        let previousAction = button.action
        item.menu = menu
        defer {
            item.menu = previousMenu
            button.target = previousTarget; button.action = previousAction
        }
        // Let the status item use the system menu-bar presentation and tracking behavior.
        track(button)
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private(set) var listPanel: QuickPanel?
    private(set) var quickPanel: QuickPanel?
    private var settingsWindow: NSWindow?
    private var previousApplication: NSRunningApplication?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var listShownAt: TimeInterval = 0
    private var quickShownAt: TimeInterval = 0
    private var lastStatusClickAt: TimeInterval = -.infinity
    private let hotkeys = GlobalHotkeys()
    private var lastPreferences: Preferences?
    private let quickPosition: QuickPanelPosition
    var presentStatusMenu: ((NSMenu, NSStatusBarButton) -> Void)?

    init(model: AppModel? = nil, quickPosition: QuickPanelPosition = QuickPanelPosition()) {
        self.model = model; self.quickPosition = quickPosition
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let existing = NSRunningApplication.runningApplications(withBundleIdentifier: "com.pindo.Pindo").first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            existing.activate(options: [.activateIgnoringOtherApps]); NSApp.terminate(nil); return
        }
        do {
            let model = try AppModel(directory: PindoRepository.defaultDirectory())
            self.model = model
            model.openSettings = { [weak self] in self?.showSettings() }
            model.dismissList = { [weak self] in self?.closeList(restoreFocus: true) }
            model.hideQuickAdd = { [weak self] in self?.closeQuick() }
            model.preferencesChanged = { [weak self] in self?.apply($0) }
            model.interfaceLanguageChanged = { [weak self] in self?.updateLanguage() }
            model.pinChanged = { [weak self] pinned in self?.applyPin(pinned) }
            model.configureHotkeys = { [weak self] in try self?.hotkeys.configure($0) }
            model.configureLogin = { enabled in if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            hotkeys.perform = { [weak self] action in
                switch action { case .quickAdd: self?.toggleQuick(); case .showList: self?.toggleList() }
            }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
            if let button = item.button {
                button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Pindo")
                button.image?.isTemplate = true; button.imagePosition = .imageLeading
                button.target = self; button.action = #selector(statusClicked(_:))
                button.sendAction(on: [.leftMouseDown, .rightMouseUp])
            }
            updateLanguage(); apply(model.document.preferences); installDismissalObservers()
            model.cloudSync.start()
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didActivateApplication(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        } catch {
            let l10n = localization
            let alert = NSAlert()
            alert.messageText = l10n("Pindo 未能读取资料")
            alert.informativeText = l10n.error(error) + "\n" + l10n("原文件不会被覆盖。")
            alert.addButton(withTitle: l10n("显示资料目录")); alert.addButton(withTitle: l10n("退出"))
            if alert.runModal() == .alertFirstButtonReturn, let directory = try? PindoRepository.defaultDirectory() { NSWorkspace.shared.open(directory) }
            NSApp.terminate(nil)
        }
    }

    private var localization: PindoLocalization {
        model?.localization ?? PindoLocalization(InterfaceLanguage(defaults: .standard))
    }

    private func updateLanguage() {
        let l10n = localization
        statusItem?.button?.toolTip = l10n("Pindo · 待办清单（右键打开菜单）")
        settingsWindow?.title = l10n("Pindo 设置")
        installMenu()
    }

    private func apply(_ preferences: Preferences) {
        if lastPreferences?.appearance != preferences.appearance {
            switch preferences.appearance {
            case .system: NSApp.appearance = nil
            case .light: NSApp.appearance = NSAppearance(named: .aqua)
            case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
            }
        }
        if let button = statusItem?.button {
            let count = preferences.showTodayCount ? model?.todayCount ?? 0 : 0
            let title = count > 0 ? " \(count)" : ""
            if button.title != title { button.title = title }
        }
        if lastPreferences?.quickAddHotkey != preferences.quickAddHotkey || lastPreferences?.listHotkey != preferences.listHotkey {
            do { try hotkeys.configure(preferences) } catch { model?.notice = .failure(error) }
        }
        lastPreferences = preferences
    }

    @objc private func statusClicked(_ button: NSStatusBarButton) {
        handleStatusClick(button, event: NSApp.currentEvent)
    }

    func handleStatusClick(_ button: NSStatusBarButton, event: NSEvent?) {
        if let event {
            lastStatusClickAt = event.timestamp
            if event.type == .rightMouseDown || event.type == .rightMouseUp || event.modifierFlags.contains(.control) {
                showStatusMenu(from: button)
                return
            }
        }
        toggleList(fromStatus: true)
    }

    private func showStatusMenu(from button: NSStatusBarButton) {
        let l10n = localization
        let menu = NSMenu()
        let add = NSMenuItem(title: l10n("添加事项"), action: #selector(showQuickFromMenu), keyEquivalent: "")
        add.target = self
        menu.addItem(add)
        let settings = settingsMenuItem(l10n, key: ",")
        settings.title = l10n("设置"); menu.addItem(settings)
        menu.addItem(.separator())
        let quit = quitMenuItem(l10n, key: "q")
        quit.title = l10n("退出"); menu.addItem(quit)
        if let presentStatusMenu { presentStatusMenu(menu, button) }
        else if let statusItem { NativeStatusMenu.show(menu, on: statusItem) }
    }

    @objc private func showQuickFromMenu() {
        if let panel = quickPanel, panel.isVisible { panel.showInFront() }
        else { toggleQuick() }
    }
    @objc func didWake() { model?.captureSnapshot() }
    func toggleList(fromStatus: Bool = false) {
        if listPanel?.isVisible == true {
            closeList(restoreFocus: true); return
        }
        closeQuick()
        guard let model else { return }
        rememberPreviousApplication()
        if listPanel?.isVisible != true { model.leaveNote() }
        if listPanel == nil {
            let panel = QuickPanel.taskPanel()
            panel.delegate = self
            panel.contentView = glassHost(TaskPanelView(model: model).ignoresSafeArea(), model: model)
            listPanel = panel
        }
        guard let panel = listPanel else { return }
        applyPin(model.isPinned); position(panel, fromStatus: fromStatus)
        // A nonactivating panel accepts typing without holding the auto-hidden menu bar open.
        panel.showInFront()
        listShownAt = ProcessInfo.processInfo.systemUptime
        statusItem?.button?.highlight(false)
    }
    private func closeList(restoreFocus: Bool = false) {
        guard listPanel?.isVisible == true else { return }
        listPanel?.makeFirstResponder(nil)
        model?.flush(); listPanel?.orderOut(nil); statusItem?.button?.highlight(false)
        if restoreFocus { previousApplication?.activate(options: [.activateIgnoringOtherApps]) }
    }
    private func applyPin(_ pinned: Bool) {
        listPanel?.configurePin(pinned)
    }
    private func position(_ panel: NSPanel, fromStatus: Bool = false) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        if panel.styleMask.contains(.resizable) {
            var frame = panel.frame
            frame.size.width = min(frame.width, area.width)
            frame.size.height = min(frame.height, area.height - 10)
            panel.setFrame(frame, display: false)
        }
        var x = area.midX - panel.frame.width / 2
        if fromStatus, let button = statusItem?.button, let window = button.window {
            x = window.convertToScreen(button.convert(button.bounds, to: nil)).midX - panel.frame.width / 2
        }
        panel.setFrameOrigin(NSPoint(x: max(area.minX, min(x, area.maxX - panel.frame.width)),
                                     y: max(area.minY, area.maxY - panel.frame.height - 10)))
    }

    func toggleQuick() {
        if quickPanel?.isVisible == true { closeQuick(restoreFocus: true); return }
        if model?.isPinned != true { closeList() }
        rememberPreviousApplication()
        guard let model else { return }
        model.quickInvocationID = UUID()
        if quickPanel == nil { quickPanel = QuickPanel.quickAddPanel(); quickPanel?.delegate = self }
        guard let panel = quickPanel else { return }
        panel.contentView = glassHost(QuickAddView(model: model, finishEditing: { [weak panel] in
            panel?.makeFirstResponder(nil)
        }, sizeChanged: { [weak self, weak panel] height in
            let targetHeight = min(max(height, 180), 520)
            guard let panel, abs(panel.frame.height - targetHeight) > 1 else { return }
            let frame = panel.frame
            // 全尺寸内容视图覆盖标题栏，窗口高度直接跟随内容并固定顶边。
            panel.setFrame(NSRect(x: frame.minX, y: frame.maxY - targetHeight,
                                  width: QuickAddView.panelWidth, height: targetHeight), display: panel.isVisible)
            self?.keepQuickOnScreen(panel)
        }).id(model.quickInvocationID), model: model, ignoresWindowSafeArea: true)
        if let origin = quickPosition.restoredOrigin(size: panel.frame.size, visibleFrames: NSScreen.screens.map(\.visibleFrame)) {
            panel.setFrameOrigin(origin)
        } else { position(panel) }
        panel.showInFront()
        quickShownAt = ProcessInfo.processInfo.systemUptime
    }
    private func closeQuick(restoreFocus: Bool = false) {
        guard quickPanel?.isVisible == true else { return }
        if let panel = quickPanel { quickPosition.save(frame: panel.frame) }
        quickPanel?.makeFirstResponder(nil)
        model?.persistDrafts(); quickPanel?.orderOut(nil)
        if restoreFocus { previousApplication?.activate(options: [.activateIgnoringOtherApps]) }
    }
    private func rememberPreviousApplication() {
        let app = NSWorkspace.shared.frontmostApplication
        previousApplication = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
    }
    private func installDismissalObservers() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            let timestamp = event.timestamp
            // Status-item clicks can arrive through the system's menu-bar process.
            // They belong to the toggle action, not the outside-dismiss monitor.
            let point = NSEvent.mouseLocation
            Task { @MainActor in
                guard let self, timestamp != self.lastStatusClickAt, !self.isOverStatusItem(point) else { return }
                self.dismissTransientPanels(eventTime: timestamp)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, let window = event.window, window !== self.statusItem?.button?.window else { return event }
            // Leave auxiliary windows (date picker, context menus, IME candidates) alone.
            if window === self.settingsWindow || self.belongs(window, to: self.listPanel) { self.closeQuick() }
            if self.model?.isPinned != true && (event.window === self.settingsWindow || self.belongs(event.window, to: self.quickPanel)) { self.closeList() }
            return event
        }
    }
    private func isOverStatusItem(_ point: NSPoint) -> Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point)
    }
    private func keepQuickOnScreen(_ panel: QuickPanel) {
        if let origin = quickPosition.clampedOrigin(frame: panel.frame, visibleFrames: NSScreen.screens.map(\.visibleFrame)), origin != panel.frame.origin {
            panel.setFrameOrigin(origin)
        }
    }
    private func belongs(_ window: NSWindow?, to panel: NSPanel?) -> Bool {
        guard let panel, var current = window else { return false }
        while true {
            if current === panel { return true }
            guard let parent = current.parent ?? current.sheetParent else { return false }
            current = parent
        }
    }
    private func dismissTransientPanels(eventTime: TimeInterval = .greatestFiniteMagnitude, respectComposition: Bool = true) {
        // Clicking an input-method candidate is not an outside-dismiss gesture.
        if respectComposition && ((listPanel?.firstResponder as? NSTextView)?.hasMarkedText() == true ||
            (quickPanel?.firstResponder as? NSTextView)?.hasMarkedText() == true) { return }
        // Delayed outside-click callbacks must not close a newly opened panel.
        if eventTime >= quickShownAt { closeQuick() }
        if model?.isPinned != true && eventTime >= listShownAt { closeList() }
    }
    @objc private func didActivateApplication(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier, app.activationPolicy != .prohibited else { return }
        dismissTransientPanels(respectComposition: false)
    }
    @objc private func showSettings() {
        if model?.isPinned != true { closeList() }
        closeQuick(); guard let model else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = localization("Pindo 设置"); window.minSize = NSSize(width: 740, height: 550)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.isOpaque = false; window.backgroundColor = .clear
            // The rectangular content meets the native title bar without cutouts.
            window.contentView = glassHost(SettingsView(model: model), model: model)
            settingsWindow = window; window.center()
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow, window === settingsWindow { GroupColorEditor.shared.close() }
        model?.flush()
    }
    func windowDidMove(_ notification: Notification) {
        if let panel = notification.object as? QuickPanel, panel === quickPanel, panel.isVisible { quickPosition.save(frame: panel.frame) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        listPanel?.makeFirstResponder(nil); quickPanel?.makeFirstResponder(nil)
        guard model?.flush() == false else { return .terminateNow }
        let l10n = localization
        let alert = NSAlert()
        alert.messageText = l10n("还有内容未能保存"); alert.informativeText = l10n("请保留当前文字，修复保存问题后再退出。")
        alert.addButton(withTitle: l10n("重试保存")); alert.addButton(withTitle: l10n("取消退出"))
        if alert.runModal() == .alertFirstButtonReturn, model?.flush() == true { return .terminateNow }
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func glassHost<V: View>(_ root: V, model: AppModel, ignoresWindowSafeArea: Bool = false) -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        let host = TransparentHostingView(rootView: LocalizedAppContent(model: model, content: root))
        if ignoresWindowSafeArea { host.safeAreaRegions = [] }
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: effect.leadingAnchor), host.trailingAnchor.constraint(equalTo: effect.trailingAnchor), host.topAnchor.constraint(equalTo: effect.topAnchor), host.bottomAnchor.constraint(equalTo: effect.bottomAnchor)])
        return effect
    }

    private func settingsMenuItem(_ l10n: PindoLocalization, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: l10n("设置…"), action: #selector(showSettings), keyEquivalent: key)
        item.target = self
        return item
    }

    private func quitMenuItem(_ l10n: PindoLocalization, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: l10n("退出 Pindo"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: key)
        item.target = NSApp
        return item
    }

    private func installMenu() {
        let l10n = localization
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(settingsMenuItem(l10n, key: ","))
        appMenu.addItem(.separator()); appMenu.addItem(quitMenuItem(l10n, key: "q"))
        appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem(); editItem.title = l10n("编辑"); let edit = NSMenu(title: editItem.title)
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: l10n(title), action: Selector(action), keyEquivalent: key)
        }
        let redo = NSMenuItem(title: l10n("重做"), action: Selector("redo:"), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]; edit.insertItem(redo, at: 1)
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
    }
}

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}
