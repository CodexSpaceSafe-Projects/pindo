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

final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private var listPanel: QuickPanel?
    private var quickPanel: QuickPanel?
    private var settingsWindow: NSWindow?
    private var previousApplication: NSRunningApplication?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var listShownAt: TimeInterval = 0
    private var quickShownAt: TimeInterval = 0
    private let hotkeys = GlobalHotkeys()
    private var lastPreferences: Preferences?

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
                button.target = self; button.action = #selector(statusClicked)
                button.toolTip = "Pindo · 待办清单"
            }
            installMenu(); apply(model.document.preferences); installDismissalObservers()
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didActivateApplication(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        } catch {
            let alert = NSAlert(); alert.messageText = "Pindo 未能读取资料"; alert.informativeText = error.localizedDescription + "\n原文件不会被覆盖。"
            alert.addButton(withTitle: "显示资料目录"); alert.addButton(withTitle: "退出")
            if alert.runModal() == .alertFirstButtonReturn, let directory = try? PindoRepository.defaultDirectory() { NSWorkspace.shared.open(directory) }
            NSApp.terminate(nil)
        }
    }

    private func apply(_ preferences: Preferences) {
        switch preferences.appearance { case .system: NSApp.appearance = nil; case .light: NSApp.appearance = NSAppearance(named: .aqua); case .dark: NSApp.appearance = NSAppearance(named: .darkAqua) }
        statusItem?.button?.title = preferences.showTodayCount && (model?.todayCount ?? 0) > 0 ? " \(model!.todayCount)" : ""
        if lastPreferences?.quickAddHotkey != preferences.quickAddHotkey || lastPreferences?.listHotkey != preferences.listHotkey {
            do { try hotkeys.configure(preferences) } catch { model?.errorMessage = error.localizedDescription }
        }
        lastPreferences = preferences
    }

    private func makePanel(width: CGFloat, height: CGFloat) -> QuickPanel {
        let panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(kind)?.isHidden = true }
        panel.isMovableByWindowBackground = true; panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false; panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true; panel.delegate = self
        return panel
    }

    @objc private func statusClicked() { toggleList(fromStatus: true) }
    @objc private func didWake() { model?.captureSnapshot() }
    private func toggleList(fromStatus: Bool = false) {
        if listPanel?.isVisible == true { closeList(restoreFocus: true); return }
        closeQuick()
        guard let model else { return }
        rememberPreviousApplication(); model.leaveNote()
        if listPanel == nil {
            let panel = makePanel(width: 390, height: 610)
            panel.contentView = glassHost(TaskPanelView(model: model))
            listPanel = panel
        }
        guard let panel = listPanel else { return }
        applyPin(model.isPinned); position(panel, fromStatus: fromStatus)
        // A nonactivating panel accepts typing without holding the auto-hidden menu bar open.
        panel.makeKeyAndOrderFront(nil)
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
        listPanel?.level = pinned ? .floating : .normal
        listPanel?.collectionBehavior = pinned ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
    }
    private func position(_ panel: NSPanel, fromStatus: Bool = false) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        var x = area.midX - panel.frame.width / 2
        if fromStatus, let button = statusItem?.button, let window = button.window {
            x = window.convertToScreen(button.convert(button.bounds, to: nil)).midX - panel.frame.width / 2
        }
        panel.setFrameOrigin(NSPoint(x: max(area.minX, min(x, area.maxX - panel.frame.width)),
                                     y: max(area.minY, area.maxY - panel.frame.height - 10)))
    }

    private func toggleQuick() {
        if quickPanel?.isVisible == true { closeQuick(restoreFocus: true); return }
        if model?.isPinned != true { closeList() }
        rememberPreviousApplication()
        guard let model else { return }
        model.quickInvocationID = UUID()
        if quickPanel == nil { quickPanel = makePanel(width: 470, height: 260); quickPanel?.level = .floating }
        guard let panel = quickPanel else { return }
        panel.contentView = glassHost(QuickAddView(model: model, sizeChanged: { [weak panel] height in
            guard let panel, abs((panel.contentView?.frame.height ?? 0) - height) > 1 else { return }
            let top = panel.frame.maxY
            panel.setContentSize(NSSize(width: 470, height: min(max(height, 180), 520)))
            panel.setFrameOrigin(NSPoint(x: panel.frame.minX, y: top - panel.frame.height))
        }).id(model.quickInvocationID))
        position(panel); panel.makeKeyAndOrderFront(nil)
        quickShownAt = ProcessInfo.processInfo.systemUptime
    }
    private func closeQuick(restoreFocus: Bool = false) {
        guard quickPanel?.isVisible == true else { return }
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
            Task { @MainActor in self?.dismissTransientPanels(eventTime: timestamp) }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, event.window != nil else { return event }
            // Leave auxiliary windows (date picker, context menus, IME candidates) alone.
            if event.window === self.settingsWindow || self.belongs(event.window, to: self.listPanel) || event.window === self.statusItem?.button?.window { self.closeQuick() }
            if self.model?.isPinned != true && (event.window === self.settingsWindow || self.belongs(event.window, to: self.quickPanel)) { self.closeList() }
            return event
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
            window.title = "Pindo 设置"; window.minSize = NSSize(width: 740, height: 550)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.isOpaque = false; window.backgroundColor = .clear
            window.contentView = glassHost(SettingsView(model: model))
            settingsWindow = window; window.center()
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    func windowWillClose(_ notification: Notification) { model?.flush() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        listPanel?.makeFirstResponder(nil); quickPanel?.makeFirstResponder(nil)
        guard model?.flush() == false else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "还有内容未能保存"; alert.informativeText = "请保留当前文字，修复保存问题后再退出。"; alert.addButton(withTitle: "重试保存"); alert.addButton(withTitle: "取消退出")
        if alert.runModal() == .alertFirstButtonReturn, model?.flush() == true { return .terminateNow }
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.stop()
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    private func glassHost<V: View>(_ root: V) -> NSView {
        let effect = NSVisualEffectView()
        effect.wantsLayer = true; effect.layer?.cornerRadius = 12; effect.layer?.masksToBounds = true
        effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active
        let host = NSHostingView(rootView: root)
        host.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(host)
        NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: effect.leadingAnchor), host.trailingAnchor.constraint(equalTo: effect.trailingAnchor), host.topAnchor.constraint(equalTo: effect.topAnchor), host.bottomAnchor.constraint(equalTo: effect.bottomAnchor)])
        return effect
    }
    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        let settings = NSMenuItem(title: "设置…", action: #selector(showSettings), keyEquivalent: ","); settings.target = self; appMenu.addItem(settings)
        appMenu.addItem(.separator()); appMenu.addItem(withTitle: "退出 Pindo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem(); editItem.title = "编辑"; let edit = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let redo = NSMenuItem(title: "重做", action: Selector("redo:"), keyEquivalent: "z"); redo.keyEquivalentModifierMask = [.command, .shift]; edit.insertItem(redo, at: 1)
        editItem.submenu = edit; main.addItem(editItem); NSApp.mainMenu = main
    }
}
