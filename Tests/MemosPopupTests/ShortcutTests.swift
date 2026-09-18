import AppKit
import Carbon
import XCTest
@testable import MemosPopup

@MainActor
private final class FakeRegistrar: HotKeyRegistering {
    var active: GlobalShortcut?
    var rejected: GlobalShortcut?
    var clears = 0
    func replace(with shortcut: GlobalShortcut) throws {
        if rejected?.sameKeys(as: shortcut) == true { throw ShortcutRegistrationError() }
        active = shortcut
    }
    func clear() { active = nil; clears += 1 }
}

final class ShortcutTests: XCTestCase {
    @MainActor private func key(_ code: UInt16, flags: NSEvent.ModifierFlags, characters: String = "k", repeatKey: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code)!
    }

    @MainActor func testMigrationFromFixedShortcutAndPersistence() async throws {
        let suite = "MemosShortcutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "shortcutEnabled")
        let registrar = FakeRegistrar()
        let controller = ShortcutController(defaults: defaults, registrar: registrar)
        XCTAssertEqual(controller.shortcut, .standard)
        XCTAssertTrue(controller.enabled)
        controller.start()
        XCTAssertEqual(registrar.active, .standard)
        controller.beginRecording()
        XCTAssertNil(registrar.active)
        controller.record(key(UInt16(kVK_ANSI_K), flags: [.command, .shift]))
        XCTAssertEqual(controller.shortcut.keyCode, UInt32(kVK_ANSI_K))
        XCTAssertEqual(controller.shortcut.modifiers, UInt32(cmdKey | shiftKey))
        XCTAssertEqual(registrar.active, controller.shortcut)
        XCTAssertFalse(controller.isRecording)
        let reopened = ShortcutController(defaults: defaults, registrar: FakeRegistrar())
        XCTAssertEqual(reopened.shortcut, controller.shortcut)
        XCTAssertTrue(reopened.enabled)
    }

    @MainActor func testCancelRestoresOldKeyWithoutChangingSettings() async {
        let registrar = FakeRegistrar()
        let controller = ShortcutController(defaults: nil, registrar: registrar)
        controller.start(); controller.setEnabled(true); controller.beginRecording()
        XCTAssertNil(registrar.active)
        controller.record(key(UInt16(kVK_Escape), flags: [], characters: "\u{1b}"))
        XCTAssertFalse(controller.isRecording)
        XCTAssertEqual(registrar.active, .standard)
        XCTAssertEqual(controller.shortcut, .standard)
        controller.beginRecording()
        controller.cancelRecording() // Same cleanup invoked on focus loss/window close.
        XCTAssertEqual(registrar.active, .standard)
    }

    @MainActor func testConflictingReplacementRestoresOldRegistration() async {
        let registrar = FakeRegistrar()
        let controller = ShortcutController(defaults: nil, registrar: registrar)
        controller.start(); controller.setEnabled(true)
        let candidate = GlobalShortcut(keyCode: UInt32(kVK_ANSI_K), modifiers: UInt32(cmdKey | shiftKey), keyLabel: "K")
        registrar.rejected = candidate
        controller.beginRecording()
        controller.setShortcut(candidate)
        XCTAssertNotNil(controller.error)
        XCTAssertFalse(controller.isRecording)
        XCTAssertTrue(controller.enabled)
        XCTAssertEqual(controller.shortcut, .standard)
        XCTAssertEqual(registrar.active, .standard)
    }

    @MainActor func testDisabledShortcutCanBeEditedAndEnabledLater() async {
        let registrar = FakeRegistrar()
        let controller = ShortcutController(defaults: nil, registrar: registrar)
        controller.start(); controller.beginRecording()
        controller.record(key(UInt16(kVK_Space), flags: [.control, .option], characters: " "))
        XCTAssertEqual(controller.shortcut.display, "⌃⌥ Space")
        XCTAssertNil(registrar.active)
        controller.setEnabled(true)
        XCTAssertEqual(registrar.active, controller.shortcut)
        controller.setEnabled(false)
        XCTAssertNil(registrar.active)
        XCTAssertEqual(controller.shortcut.keyCode, UInt32(kVK_Space))
        controller.setShortcut(.standard)
        XCTAssertEqual(controller.shortcut, .standard)
    }

    @MainActor func testTypingAndRepeatingKeysCannotBecomeGlobalShortcut() async {
        let controller = ShortcutController(defaults: nil, registrar: FakeRegistrar())
        controller.beginRecording()
        controller.record(key(UInt16(kVK_ANSI_K), flags: []))
        XCTAssertNotNil(controller.error)
        XCTAssertTrue(controller.isRecording)
        controller.record(key(UInt16(kVK_ANSI_K), flags: [.shift]))
        XCTAssertEqual(controller.shortcut, .standard)
        controller.record(key(UInt16(kVK_ANSI_K), flags: [.command], repeatKey: true))
        XCTAssertEqual(controller.shortcut, .standard)
        controller.record(key(UInt16(kVK_ANSI_K), flags: [.command, .capsLock, .function]))
        XCTAssertEqual(controller.shortcut.modifiers, UInt32(cmdKey))
        XCTAssertFalse(controller.isRecording)
    }

    @MainActor func testUnavailablePreviousKeyOnCancelDisablesButKeepsDefinition() async {
        let registrar = FakeRegistrar()
        let controller = ShortcutController(defaults: nil, registrar: registrar)
        controller.start(); controller.setEnabled(true); controller.beginRecording()
        registrar.rejected = .standard
        controller.cancelRecording()
        XCTAssertFalse(controller.enabled)
        XCTAssertEqual(controller.shortcut, .standard)
        XCTAssertNotNil(controller.error)
    }

    @MainActor func testCarbonRegistrationConflictAndReplacement() async throws {
        let key = GlobalShortcut(keyCode: UInt32(kVK_F19), modifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "F19")
        let replacement = GlobalShortcut(keyCode: UInt32(kVK_F18), modifiers: UInt32(controlKey | optionKey | cmdKey), keyLabel: "F18")
        let first = CarbonHotKeyRegistrar(), second = CarbonHotKeyRegistrar()
        defer { first.clear(); second.clear() }
        try first.replace(with: key)
        XCTAssertThrowsError(try second.replace(with: key))
        try first.replace(with: replacement)
        try second.replace(with: key) // Replacing a shortcut must release the previous combination.
    }
}
