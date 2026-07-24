import Carbon
import Testing
@testable import KotobaneCore

@Test func controlOptionSpaceConvertsToCarbonWithoutLosingTheKeyCode() {
    let shortcut = Shortcut(keyCode: 49, modifiers: [.control, .option])

    #expect(CarbonHotKeyModifiers.mask(for: shortcut.modifiers) == UInt32(controlKey | optionKey))
}

@MainActor
@Test func configuredShortcutAndCallbackAreForwardedToTheSystem() throws {
    let system = SpyGlobalShortcutSystem()
    let registrar = CarbonGlobalShortcut(system: system)
    var callbackCount = 0

    try registrar.register(.init(keyCode: 49, modifiers: [.control, .option])) {
        callbackCount += 1
    }
    system.fire()

    #expect(system.registrations.map(\.keyCode) == [49])
    #expect(system.registrations.map(\.modifiers) == [UInt32(controlKey | optionKey)])
    #expect(callbackCount == 1)
}

@MainActor
@Test func carbonConflictIsReportedAsActionableShortcutConflict() {
    let system = SpyGlobalShortcutSystem(error: .conflict)
    let registrar = CarbonGlobalShortcut(system: system)

    #expect(throws: GlobalShortcutError.conflict) {
        try registrar.register(.init(keyCode: 49, modifiers: [.control, .option])) {}
    }
}

@MainActor
@Test func carbonAdapterRequestsExclusiveRegistrationSoConflictsAreReported() {
    var observedOptions: OptionBits?
    let system = CarbonGlobalShortcutSystem(
        registerEventHotKey: { _, _, _, _, options, _ in
            observedOptions = options
            return OSStatus(eventHotKeyExistsErr)
        }
    )

    #expect(throws: GlobalShortcutError.conflict) {
        _ = try system.register(
            keyCode: 49,
            modifiers: CarbonHotKeyModifiers.mask(for: [.control, .option]),
            callback: {}
        )
    }
    #expect(observedOptions == OptionBits(kEventHotKeyExclusive))
}

@MainActor
@Test func reconfigurationReleasesPreviousHotKeyAndHandlerBeforeRegisteringNewOne() throws {
    let system = SpyGlobalShortcutSystem()
    let registrar = CarbonGlobalShortcut(system: system)
    try registrar.register(.init(keyCode: 49, modifiers: [.control, .option])) {}
    let first = try #require(system.activeToken)

    try registrar.register(.init(keyCode: 11, modifiers: [.command])) {}

    #expect(system.events == [
        "register:49", "unregister:\(first.id)", "register:11",
    ])
    #expect(system.unregisterCounts[first.id] == 1)
}

@MainActor
@Test func explicitUnregisterAndDeinitEachReleaseOwnedResourcesExactlyOnce() throws {
    let system = SpyGlobalShortcutSystem()
    var registrar: CarbonGlobalShortcut? = CarbonGlobalShortcut(system: system)
    try registrar?.register(.init(keyCode: 49, modifiers: [.control, .option])) {}
    let first = try #require(system.activeToken)
    registrar?.unregister()
    registrar = nil
    #expect(system.unregisterCounts[first.id] == 1)

    var secondRegistrar: CarbonGlobalShortcut? = CarbonGlobalShortcut(system: system)
    try secondRegistrar?.register(.init(keyCode: 11, modifiers: [.command])) {}
    let second = try #require(system.activeToken)
    secondRegistrar = nil
    #expect(system.unregisterCounts[second.id] == 1)
}

@MainActor
private final class SpyGlobalShortcutSystem: GlobalShortcutSystem {
    struct Registration {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    final class Token: GlobalShortcutRegistration {
        let id: Int
        init(id: Int) { self.id = id }
    }

    var error: GlobalShortcutError?
    private(set) var registrations: [Registration] = []
    private(set) var events: [String] = []
    private(set) var unregisterCounts: [Int: Int] = [:]
    private(set) var activeToken: Token?
    private var callback: (@MainActor @Sendable () -> Void)?

    init(error: GlobalShortcutError? = nil) {
        self.error = error
    }

    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        callback: @escaping @MainActor @Sendable () -> Void
    ) throws -> any GlobalShortcutRegistration {
        if let error { throw error }
        let token = Token(id: registrations.count + 1)
        registrations.append(.init(keyCode: keyCode, modifiers: modifiers))
        events.append("register:\(keyCode)")
        activeToken = token
        self.callback = callback
        return token
    }

    func unregister(_ registration: any GlobalShortcutRegistration) {
        guard let token = registration as? Token else { return }
        events.append("unregister:\(token.id)")
        unregisterCounts[token.id, default: 0] += 1
        if activeToken === token {
            activeToken = nil
            callback = nil
        }
    }

    func fire() {
        callback?()
    }
}
