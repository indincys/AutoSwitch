import XCTest
@testable import AutoSwitch

final class SystemTextCursorCommandsTests: XCTestCase {
    func testSystemTextCursorCommandsAreExpectedValues() {
        XCTAssertEqual(
            SystemTextCursorCommands.disable,
            "sudo defaults write /Library/Preferences/FeatureFlags/Domain/UIKit.plist redesigned_text_cursor -dict-add Enabled -bool NO"
        )
        XCTAssertEqual(
            SystemTextCursorCommands.restore,
            "sudo defaults write /Library/Preferences/FeatureFlags/Domain/UIKit.plist redesigned_text_cursor -dict-add Enabled -bool YES"
        )
    }
}
