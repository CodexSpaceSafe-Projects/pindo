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

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    private var model: AppModel?
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var quickPanel: QuickPanel?
    private var settingsWindow: NSWindow?
    private var previousApplication: NSRunningApplication?
    private var outsideMonitor: Any?
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
            model.hideList = { [weak self] in self?.closeList() }
            model.dismissList = { [weak self] in self?.closeList(restoreFocus: true) }
            model.hideQuickAdd = { [weak self] in self?.closeQuick() }
            model.preferencesChanged = { [weak self] in self?.apply($0) }
            model.configureHotkeys = { [weak self] in try self?.hotkeys.configure($0) }
            model.configureLogin = { enabled in if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
            hotkeys.perform = { [weak self] action in switch action { case .quickAdd: self?.toggleQuick(); case .showList: self?.toggleList() } }
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem = item
            if let button = item.button {
                button.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: "Pindo")
                button.image?.isTemplate = true; button.imagePosition = .imageLeading
                button.target = self; button.action = #selector(statusClicked)
                button.toolTip = "Pindo · 待办清单"
            }
            popover.behavior = .transient; popover.delegate = self
            let controller = NSViewController()
            controller.view = glassHost(TaskPanelView(model: model))
            controller.view.frame = NSRect(x: 0, y: 0, width: 370, height: 610)
            popover.contentViewController = controller
            popover.contentSize = NSSize(width: 370, height: 610)
            installMenu(); apply(model.document.preferences)
            NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
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

    @objc private func statusClicked() { toggleList() }
    @objc private func didWake() { model?.captureSnapshot(); if let model { apply(model.document.preferences) } }
    private func toggleList() {
        if popover.isShown { closeList(restoreFocus: true); return }
        closeQuick()
        guard let model, let button = statusItem?.button else { return }
        rememberPreviousApplication(); model.leaveNote()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
    private func closeList(restoreFocus: Bool = false) {
        model?.flush(); popover.performClose(nil)
        if restoreFocus { previousApplication?.activate(options: [.activateIgnoringOtherApps]) }
    }
    func popoverDidClose(_ notification: Notification) { model?.flush() }

    private func toggleQuick() {
        if quickPanel?.isVisible == true { closeQuick(); return }
        closeList(); rememberPreviousApplication()
        guard let model else { return }
        model.quickInvocationID = UUID()
        if quickPanel == nil {
            let panel = QuickPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 260), styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.closeButton)?.isHidden = true; panel.standardWindowButton(.miniaturizeButton)?.isHidden = true; panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.delegate = self
            quickPanel = panel
        }
        guard let panel = quickPanel else { return }
        panel.contentView = glassHost(QuickAddView(model: model, sizeChanged: { [weak panel] height in
            guard let panel, let content = panel.contentView, abs(content.frame.height - height) > 1 else { return }
            panel.setContentSize(NSSize(width: 470, height: min(max(height, 180), 520)))
        }).id(model.quickInvocationID))
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 800)
        panel.setFrameOrigin(NSPoint(x: area.midX - 235, y: area.midY - 130))
        panel.makeKeyAndOrderFront(nil)
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in Task { @MainActor in self?.closeQuick() } }
    }
    private func closeQuick() {
        model?.persistDrafts(); quickPanel?.orderOut(nil)
        if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor); self.outsideMonitor = nil }
    }
    private func rememberPreviousApplication() {
        let app = NSWorkspace.shared.frontmostApplication
        previousApplication = app?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : app
    }

    @objc private func showSettings() {
        closeList(); closeQuick(); guard let model else { return }
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 740, height: 570), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Pindo 设置"; window.minSize = NSSize(width: 690, height: 530)
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
        guard model?.flush() == false else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "还有内容未能保存"; alert.informativeText = "请保留当前文字，修复保存问题后再退出。"; alert.addButton(withTitle: "重试保存"); alert.addButton(withTitle: "取消退出")
        if alert.runModal() == .alertFirstButtonReturn, model?.flush() == true { return .terminateNow }
        return .terminateCancel
    }
    func applicationWillTerminate(_ notification: Notification) { hotkeys.stop(); closeQuick(); NSWorkspace.shared.notificationCenter.removeObserver(self) }

    private func glassHost<V: View>(_ root: V) -> NSView {
        let effect = NSVisualEffectView()
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
