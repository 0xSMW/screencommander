import CoreGraphics
import XCTest
@testable import ScreenCommander

final class MenuShortcutsTests: XCTestCase {
    private func chord(_ raw: String) throws -> ParsedKeyChord {
        try KeyCodes.parseChord(raw)
    }

    func testCommandModifierBitsDecode() {
        // Command is implied unless bit 8 (no-command) is set.
        XCTAssertEqual(MenuShortcut.flags(fromMenuModifiers: 0), [.maskCommand])
        XCTAssertEqual(MenuShortcut.flags(fromMenuModifiers: 1), [.maskCommand, .maskShift])
        XCTAssertEqual(MenuShortcut.flags(fromMenuModifiers: 2), [.maskCommand, .maskAlternate])
        XCTAssertEqual(MenuShortcut.flags(fromMenuModifiers: 4), [.maskCommand, .maskControl])
        XCTAssertEqual(MenuShortcut.flags(fromMenuModifiers: 8), [])
        XCTAssertEqual(MenuShortcut.flags(fromMenuModifiers: 8 | 1), [.maskShift])
    }

    func testCharacterShortcutMatchesChord() throws {
        let selectAll = MenuShortcut(character: "A", virtualKey: nil, flags: [.maskCommand])
        XCTAssertTrue(selectAll.matches(try chord("cmd+a")))
        XCTAssertFalse(selectAll.matches(try chord("cmd+shift+a")))
        XCTAssertFalse(selectAll.matches(try chord("cmd+b")))

        let save = MenuShortcut(character: "S", virtualKey: nil, flags: [.maskCommand, .maskShift])
        XCTAssertTrue(save.matches(try chord("cmd+shift+s")))
        XCTAssertFalse(save.matches(try chord("cmd+s")))
    }

    func testVirtualKeyShortcutMatchesWhenNoCharacter() throws {
        // Right arrow (kVK_RightArrow = 124) with Command.
        let shortcut = MenuShortcut(character: nil, virtualKey: 124, flags: [.maskCommand])
        XCTAssertTrue(shortcut.matches(try chord("cmd+right")))
        XCTAssertFalse(shortcut.matches(try chord("cmd+left")))
    }

    func testFunctionAndSpecialKeyCharacters() {
        XCTAssertEqual(MenuShortcut.menuCharacter(forToken: "f5").map { String($0.unicodeScalars.first!.value, radix: 16) }, "f708")
        XCTAssertEqual(MenuShortcut.menuCharacter(forToken: "left").map { String($0.unicodeScalars.first!.value, radix: 16) }, "f702")
        XCTAssertEqual(MenuShortcut.menuCharacter(forToken: "a"), "A")
    }

    func testFirstMatchPrefersAnEnabledAlternate() throws {
        let disabled = MenuShortcutItem(path: ["Edit", "Paste"], shortcut: MenuShortcut(character: "V", virtualKey: nil, flags: [.maskCommand]))
        let enabled = MenuShortcutItem(path: ["Edit", "Paste and Match Style"], shortcut: MenuShortcut(character: "V", virtualKey: nil, flags: [.maskCommand]))
        let items = [disabled, enabled]
        let picked = AXMenuShortcuts.firstMatch(chord: try chord("cmd+v"), in: items) { item in
            item.pathDescription == enabled.pathDescription
        }
        XCTAssertEqual(picked?.pathDescription, enabled.pathDescription)
        // With no enabledness known, menu order wins.
        XCTAssertEqual(AXMenuShortcuts.firstMatch(chord: try chord("cmd+v"), in: items)?.pathDescription, disabled.pathDescription)
    }
}
