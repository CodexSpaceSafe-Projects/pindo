import AppKit
import Carbon
import PindoCore

enum HotkeyRegistrationError: Error {
    case handlerUnavailable, unavailable(String)
}

@MainActor final class GlobalHotkeys {
    enum Action { case quickAdd, showList }
    private struct Registration {
        let id: UInt32
        let binding: HotkeyBinding
        let reference: EventHotKeyRef
    }
    private var handler: EventHandlerRef?
    private var registrations: [Registration] = []
    private var actions: [UInt32: Action] = [:]
    private var nextID: UInt32 = 1
    private var pressTracker = HotkeyPressTracker()
    var perform: (Action) -> Void = { _ in }

    init() {
        var types = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var key = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &key)
            guard status == noErr else { return status }
            guard key.signature == 0x50494E44 else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<GlobalHotkeys>.fromOpaque(context).takeUnretainedValue()
            let identifier = key.id
            let isDown = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            Task { @MainActor in
                if manager.pressTracker.update(id: identifier, isDown: isDown), let action = manager.actions[identifier] { manager.perform(action) }
            }
            return noErr
        }, 2, &types, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func configure(_ preferences: Preferences) throws {
        guard preferences.quickAddHotkey.isValid, preferences.listHotkey.isValid,
              !preferences.quickAddHotkey.matches(preferences.listHotkey) else { throw PindoError.invalidHotkey }
        guard handler != nil else { throw HotkeyRegistrationError.handlerUnavailable }
        let desired: [(Action, HotkeyBinding)] = [(.quickAdd, preferences.quickAddHotkey), (.showList, preferences.listHotkey)]
        var next: [Registration] = [], created: [Registration] = [], nextActions: [UInt32: Action] = [:]
        do {
            for (action, binding) in desired where binding.enabled {
                if let existing = registrations.first(where: { $0.binding.keyCode == binding.keyCode && $0.binding.modifiers == binding.modifiers }) {
                    next.append(existing); nextActions[existing.id] = action; continue
                }
                var carbon: UInt32 = 0
                if binding.modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
                if binding.modifiers.contains(.option) { carbon |= UInt32(optionKey) }
                if binding.modifiers.contains(.control) { carbon |= UInt32(controlKey) }
                if binding.modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
                let identifier = nextID; nextID += 1
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(binding.keyCode, carbon, EventHotKeyID(signature: 0x50494E44, id: identifier), GetApplicationEventTarget(), 0, &ref)
                guard status == noErr, let ref else { throw HotkeyRegistrationError.unavailable(binding.display) }
                let item = Registration(id: identifier, binding: binding, reference: ref)
                created.append(item); next.append(item); nextActions[identifier] = action
            }
        } catch {
            for item in created { UnregisterEventHotKey(item.reference) }
            throw error
        }
        let retained = Set(next.map(\.id))
        for item in registrations where !retained.contains(item.id) { UnregisterEventHotKey(item.reference) }
        registrations = next; actions = nextActions
        pressTracker.reset()
    }

    func stop() {
        for item in registrations { UnregisterEventHotKey(item.reference) }
        registrations.removeAll(); actions.removeAll()
        pressTracker.reset()
        if let handler { RemoveEventHandler(handler); self.handler = nil }
    }
}
