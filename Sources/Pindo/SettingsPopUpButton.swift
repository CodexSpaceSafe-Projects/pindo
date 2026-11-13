import AppKit

/// Separate native types keep the two settings controls out of each other's reuse path.
@MainActor class SettingsPopUpButton: NSPopUpButton {
    var canSendSettingsAction: Bool {
        guard isEnabled, !isHiddenOrHasHiddenAncestor, let window, window.isVisible else { return false }
        // An edit sheet owns interaction until it is dismissed.
        return window.attachedSheet == nil
    }
}

final class GroupColorPopUpButton: SettingsPopUpButton {}
final class FontFamilyPopUpButton: SettingsPopUpButton {}
