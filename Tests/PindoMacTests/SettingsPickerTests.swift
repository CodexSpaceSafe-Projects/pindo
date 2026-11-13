import AppKit
import SwiftUI
import XCTest
@testable import Pindo

final class SettingsPickerTests: XCTestCase {
    @MainActor private func host(_ buttons: [NSPopUpButton]) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 500, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(x: 20, y: 40 + index * 50, width: 220, height: 30)
            window.contentView?.addSubview(button)
        }
        window.orderFrontRegardless()
        return window
    }

    @MainActor func testOnlyTheOwnedExplicitCustomColorItemCanOpenTheColorPanel() throws {
        var color = GroupColorMenu.defaultColor
        let picker = GroupColorMenu(colorHex: Binding(get: { color }, set: { color = $0 }), accessibilityName: "Color")
        let coordinator = picker.makeCoordinator(), button = GroupColorPopUpButton(frame: .zero, pullsDown: false)
        let window = host([button])
        defer { GroupColorEditor.shared.close(); window.orderOut(nil) }
        GroupColorEditor.shared.close(); NSColorPanel.shared.orderOut(nil)
        coordinator.update(picker, button: button)
        XCTAssertTrue(button.canSendSettingsAction)
        let menu = try XCTUnwrap(button.menu)
        let foreign = NSPopUpButton(frame: .zero, pullsDown: false)
        foreign.addItem(withTitle: "Task group")
        coordinator.chooseGroupColor(foreign)
        XCTAssertFalse(NSColorPanel.shared.isVisible)

        button.select(nil)
        coordinator.chooseGroupColor(button)
        let unknown = NSMenuItem(title: "Unrecognized item", action: nil, keyEquivalent: "")
        unknown.representedObject = UUID()
        menu.addItem(unknown); button.select(unknown)
        coordinator.chooseGroupColor(button)
        XCTAssertFalse(NSColorPanel.shared.isVisible)
        XCTAssertEqual(color, GroupColorMenu.defaultColor)

        let preset = try XCTUnwrap(menu.items.first { ($0.representedObject as? String) == "#66CCEE" })
        button.select(preset); coordinator.chooseGroupColor(button)
        XCTAssertEqual(color, "#66CCEE")
        XCTAssertFalse(NSColorPanel.shared.isVisible)
        coordinator.update(picker, button: button)
        button.select(try XCTUnwrap(button.menu?.items.last))
        coordinator.chooseGroupColor(button)
        XCTAssertTrue(NSColorPanel.shared.isVisible)
        GroupColorMenu.dismantleNSView(button, coordinator: coordinator)
        XCTAssertFalse(NSColorPanel.shared.isVisible)
        XCTAssertNil(button.target); XCTAssertNil(button.action)
        coordinator.chooseGroupColor(button)
        XCTAssertFalse(NSColorPanel.shared.isVisible)
    }

    @MainActor func testFontMenuIgnoresForeignSendersNotificationsAndUnknownItems() throws {
        var family: String? = "Menlo"
        let picker = FontFamilyPicker(label: "Font", defaultLabel: "System", options: [FontFamilyOption("Menlo"), FontFamilyOption("Helvetica")],
                                      excludedFamily: nil, selection: Binding(get: { family }, set: { family = $0 }))
        let coordinator = picker.makeCoordinator(), button = FontFamilyPopUpButton(frame: .zero, pullsDown: false)
        let window = host([button])
        defer { window.orderOut(nil) }
        coordinator.update(picker, button: button)
        XCTAssertTrue(button.canSendSettingsAction)
        coordinator.prepareFontFamilyMenu(Notification(name: NSPopUpButton.willPopUpNotification, object: button))
        let menu = try XCTUnwrap(button.menu)
        let foreign = NSPopUpButton(frame: .zero, pullsDown: false)
        foreign.addItem(withTitle: "Task group")
        foreign.selectedItem?.representedObject = "Helvetica"
        coordinator.prepareFontFamilyMenu(Notification(name: NSPopUpButton.willPopUpNotification, object: foreign))
        coordinator.chooseFontFamily(foreign)
        XCTAssertEqual(foreign.numberOfItems, 1)
        XCTAssertEqual(family, "Menlo")

        let unknown = NSMenuItem(title: "Unrecognized item", action: nil, keyEquivalent: "")
        unknown.representedObject = UUID()
        menu.addItem(unknown); button.select(unknown)
        coordinator.chooseFontFamily(button)
        XCTAssertEqual(family, "Menlo")
        let helvetica = try XCTUnwrap(menu.items.first { ($0.representedObject as? String) == "Helvetica" })
        button.select(helvetica); coordinator.chooseFontFamily(button)
        XCTAssertEqual(family, "Helvetica")
        FontFamilyPicker.dismantleNSView(button, coordinator: coordinator)
        XCTAssertNil(button.target); XCTAssertNil(button.action)
        button.select(try XCTUnwrap(menu.items.first { ($0.representedObject as? String) == "Menlo" }))
        coordinator.chooseFontFamily(button)
        XCTAssertEqual(family, "Helvetica")
    }

    @MainActor func testHiddenSettingsAndAnAttachedTaskSheetCannotTriggerSettingsPickers() async throws {
        var color = GroupColorMenu.defaultColor, family: String? = "Menlo"
        let colors = GroupColorMenu(colorHex: Binding(get: { color }, set: { color = $0 }), accessibilityName: "Color")
        let fonts = FontFamilyPicker(label: "Font", defaultLabel: "System", options: [FontFamilyOption("Menlo"), FontFamilyOption("Helvetica")],
                                     excludedFamily: nil, selection: Binding(get: { family }, set: { family = $0 }))
        let colorCoordinator = colors.makeCoordinator(), fontCoordinator = fonts.makeCoordinator()
        let colorButton = GroupColorPopUpButton(frame: .zero, pullsDown: false)
        let fontButton = FontFamilyPopUpButton(frame: .zero, pullsDown: false)
        let window = host([colorButton, fontButton])
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        defer { window.endSheet(sheet); sheet.orderOut(nil); GroupColorEditor.shared.close(); window.orderOut(nil) }
        GroupColorEditor.shared.close(); NSColorPanel.shared.orderOut(nil)
        colorCoordinator.update(colors, button: colorButton); fontCoordinator.update(fonts, button: fontButton)
        fontCoordinator.prepareFontFamilyMenu(Notification(name: NSPopUpButton.willPopUpNotification, object: fontButton))
        colorButton.select(try XCTUnwrap(colorButton.menu?.items.last))
        fontButton.select(try XCTUnwrap(fontButton.menu?.items.first { ($0.representedObject as? String) == "Helvetica" }))
        colorButton.isHidden = true; fontButton.isHidden = true
        colorCoordinator.chooseGroupColor(colorButton); fontCoordinator.chooseFontFamily(fontButton)
        XCTAssertFalse(NSColorPanel.shared.isVisible); XCTAssertEqual(family, "Menlo")
        colorButton.isHidden = false; fontButton.isHidden = false
        window.beginSheet(sheet, completionHandler: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(window.attachedSheet)
        XCTAssertFalse(colorButton.canSendSettingsAction); XCTAssertFalse(fontButton.canSendSettingsAction)
        colorCoordinator.chooseGroupColor(colorButton); fontCoordinator.chooseFontFamily(fontButton)
        XCTAssertFalse(NSColorPanel.shared.isVisible); XCTAssertEqual(family, "Menlo")
        XCTAssertEqual(color, GroupColorMenu.defaultColor)
    }

    @MainActor func testAnUnchangedRenderRestoresTheCorrectActionTarget() throws {
        var color = GroupColorMenu.defaultColor, family: String? = nil
        let colors = GroupColorMenu(colorHex: Binding(get: { color }, set: { color = $0 }), accessibilityName: "Color")
        let fonts = FontFamilyPicker(label: "Font", defaultLabel: "System", options: [], excludedFamily: nil,
                                     selection: Binding(get: { family }, set: { family = $0 }))
        let colorCoordinator = colors.makeCoordinator(), fontCoordinator = fonts.makeCoordinator()
        let colorButton = GroupColorPopUpButton(frame: .zero, pullsDown: false)
        let fontButton = FontFamilyPopUpButton(frame: .zero, pullsDown: false)
        colorCoordinator.update(colors, button: colorButton); fontCoordinator.update(fonts, button: fontButton)
        let colorAction = colorButton.action, fontAction = fontButton.action
        colorButton.target = fontCoordinator; colorButton.action = fontAction
        fontButton.target = colorCoordinator; fontButton.action = colorAction
        colorCoordinator.update(colors, button: colorButton); fontCoordinator.update(fonts, button: fontButton)
        XCTAssertTrue(colorButton.target === colorCoordinator); XCTAssertTrue(fontButton.target === fontCoordinator)
        XCTAssertEqual(colorButton.action, colorAction); XCTAssertEqual(fontButton.action, fontAction)
        XCTAssertNotEqual(colorAction, fontAction)
    }
}
