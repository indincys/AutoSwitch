import XCTest
@testable import AutoSwitch

final class VisibilityDiffTests: XCTestCase {
    func testResolveDetectsAppearedAndDisappearedBundleIDs() {
        let diff = VisibilityDiff.resolve(
            previous: ["com.apple.Spotlight", "com.raycast.macos"],
            current: ["com.apple.Spotlight", "com.runningwithcrayons.Alfred"]
        )

        XCTAssertEqual(diff.appeared, ["com.runningwithcrayons.Alfred"])
        XCTAssertEqual(diff.disappeared, ["com.raycast.macos"])
        XCTAssertTrue(diff.hasChanges)
    }

    func testResolveHasNoChangesForSameVisibilitySet() {
        let diff = VisibilityDiff.resolve(
            previous: ["com.apple.Spotlight"],
            current: ["com.apple.Spotlight"]
        )

        XCTAssertTrue(diff.appeared.isEmpty)
        XCTAssertTrue(diff.disappeared.isEmpty)
        XCTAssertFalse(diff.hasChanges)
    }
}
