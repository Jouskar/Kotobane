import Carbon
import Foundation

public enum GlobalShortcutError: Error, Equatable, Sendable {
    case conflict
    case registrationFailed(OSStatus)
}

@MainActor
public protocol GlobalShortcutRegistering: AnyObject {
    func register(
        _ shortcut: Shortcut,
        onPressed: @escaping @MainActor @Sendable () -> Void
    ) throws
    func unregister()
}

public enum CarbonHotKeyModifiers {
    public static func mask(for modifiers: Shortcut.Modifier) -> UInt32 {
        var result: UInt32 = 0
        if modifiers.contains(.control) { result |= UInt32(controlKey) }
        if modifiers.contains(.option) { result |= UInt32(optionKey) }
        if modifiers.contains(.shift) { result |= UInt32(shiftKey) }
        if modifiers.contains(.command) { result |= UInt32(cmdKey) }
        return result
    }
}

public protocol GlobalShortcutRegistration: AnyObject {}

@MainActor
public protocol GlobalShortcutSystem: AnyObject {
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        callback: @escaping @MainActor @Sendable () -> Void
    ) throws -> any GlobalShortcutRegistration
    func unregister(_ registration: any GlobalShortcutRegistration)
}

@MainActor
public final class CarbonGlobalShortcut: GlobalShortcutRegistering {
    private let system: any GlobalShortcutSystem
    private var registration: (any GlobalShortcutRegistration)?

    public convenience init() {
        self.init(system: CarbonGlobalShortcutSystem())
    }

    public init(system: any GlobalShortcutSystem) {
        self.system = system
    }

    public func register(
        _ shortcut: Shortcut,
        onPressed: @escaping @MainActor @Sendable () -> Void
    ) throws {
        unregister()
        registration = try system.register(
            keyCode: shortcut.keyCode,
            modifiers: CarbonHotKeyModifiers.mask(for: shortcut.modifiers),
            callback: onPressed
        )
    }

    public func unregister() {
        guard let registration else { return }
        self.registration = nil
        system.unregister(registration)
    }

    isolated deinit {
        if let registration {
            system.unregister(registration)
        }
    }
}

@MainActor
public final class CarbonGlobalShortcutSystem: GlobalShortcutSystem {
    private var nextID: UInt32 = 1

    public init() {}

    public func register(
        keyCode: UInt32,
        modifiers: UInt32,
        callback: @escaping @MainActor @Sendable () -> Void
    ) throws -> any GlobalShortcutRegistration {
        let box = CarbonCallbackBox(callback)
        let opaqueBox = Unmanaged.passRetained(box).toOpaque()
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var handler: EventHandlerRef?
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData,
                      GetEventClass(event) == OSType(kEventClassKeyboard),
                      GetEventKind(event) == UInt32(kEventHotKeyPressed)
                else {
                    return OSStatus(eventNotHandledErr)
                }
                let box = Unmanaged<CarbonCallbackBox>
                    .fromOpaque(userData)
                    .takeUnretainedValue()
                Task { @MainActor in box.callback() }
                return noErr
            },
            1,
            &eventType,
            opaqueBox,
            &handler
        )
        guard handlerStatus == noErr, let handler else {
            Unmanaged<CarbonCallbackBox>.fromOpaque(opaqueBox).release()
            throw GlobalShortcutError.registrationFailed(handlerStatus)
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: nextID
        )
        nextID &+= 1
        var hotKey: EventHotKeyRef?
        let hotKeyStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard hotKeyStatus == noErr, let hotKey else {
            RemoveEventHandler(handler)
            Unmanaged<CarbonCallbackBox>.fromOpaque(opaqueBox).release()
            if hotKeyStatus == eventHotKeyExistsErr {
                throw GlobalShortcutError.conflict
            }
            throw GlobalShortcutError.registrationFailed(hotKeyStatus)
        }

        return CarbonRegistration(
            hotKey: hotKey,
            handler: handler,
            callbackBox: opaqueBox
        )
    }

    public func unregister(_ registration: any GlobalShortcutRegistration) {
        guard let registration = registration as? CarbonRegistration else { return }
        registration.dispose()
    }

    private static let signature: OSType = 0x4B_54_42_4E // KTBN
}

private final class CarbonCallbackBox {
    let callback: @MainActor @Sendable () -> Void
    init(_ callback: @escaping @MainActor @Sendable () -> Void) {
        self.callback = callback
    }
}

private final class CarbonRegistration: GlobalShortcutRegistration {
    private let lock = NSLock()
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var callbackBox: UnsafeMutableRawPointer?

    init(
        hotKey: EventHotKeyRef,
        handler: EventHandlerRef,
        callbackBox: UnsafeMutableRawPointer
    ) {
        self.hotKey = hotKey
        self.handler = handler
        self.callbackBox = callbackBox
    }

    func dispose() {
        let resources = lock.withLock { () -> (
            EventHotKeyRef?,
            EventHandlerRef?,
            UnsafeMutableRawPointer?
        ) in
            let resources = (hotKey, handler, callbackBox)
            hotKey = nil
            handler = nil
            callbackBox = nil
            return resources
        }
        if let hotKey = resources.0 {
            UnregisterEventHotKey(hotKey)
        }
        if let handler = resources.1 {
            RemoveEventHandler(handler)
        }
        if let callbackBox = resources.2 {
            Unmanaged<CarbonCallbackBox>.fromOpaque(callbackBox).release()
        }
    }

    deinit {
        dispose()
    }
}
