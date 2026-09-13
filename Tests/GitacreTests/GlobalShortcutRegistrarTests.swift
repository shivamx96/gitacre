import Carbon.HIToolbox
import XCTest
@testable import Gitacre

final class GlobalShortcutRegistrarTests: XCTestCase {
    func testDefaultShortcutUsesTheDisplayedKeyAndModifiers() {
        let shortcut = GlobalShortcutDefinition.showGitacre

        XCTAssertEqual(shortcut.keyCode, UInt32(kVK_ANSI_G))
        XCTAssertEqual(shortcut.modifiers, UInt32(cmdKey | optionKey))
        XCTAssertEqual(shortcut.label, "⌥⌘G")
    }
}
