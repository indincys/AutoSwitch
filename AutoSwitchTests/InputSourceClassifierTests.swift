import XCTest
@testable import AutoSwitch

final class InputSourceClassifierTests: XCTestCase {
    func testBuiltInPinyinIsChineseNotAscii() {
        // Regression: id contains "abc" (…SCIM.ITABC). An ascii-first substring
        // check used to tag built-in Pinyin as ascii; Chinese must win.
        let kind = InputSourceClassifier.classify(
            sourceID: "com.apple.inputmethod.SCIM.ITABC",
            category: "Keyboard Input Method",
            languages: ["zh-Hans"]
        )
        XCTAssertEqual(kind, .chinese)
    }

    func testZhuyinIsChinese() {
        let kind = InputSourceClassifier.classify(
            sourceID: "com.apple.inputmethod.TCIM.Zhuyin",
            category: "Keyboard Input Method",
            languages: ["zh-Hant"]
        )
        XCTAssertEqual(kind, .chinese)
    }

    func testThirdPartyChineseByIDFragment() {
        let kind = InputSourceClassifier.classify(
            sourceID: "com.sogou.inputmethod.sogou.pinyin",
            category: "Keyboard Input Method",
            languages: []
        )
        XCTAssertEqual(kind, .chinese)
    }

    func testABCLayoutIsAscii() {
        let kind = InputSourceClassifier.classify(
            sourceID: "com.apple.keylayout.ABC",
            category: "Keyboard Layout",
            languages: ["en"]
        )
        XCTAssertEqual(kind, .ascii)
    }

    func testUSLayoutIsAscii() {
        let kind = InputSourceClassifier.classify(
            sourceID: "com.apple.keylayout.US",
            category: "Keyboard Layout",
            languages: ["en"]
        )
        XCTAssertEqual(kind, .ascii)
    }

    func testNonLatinAppleLayoutIsNeitherAsciiNorChinese() {
        // Regression: substring "us" used to make "Russian"/"Australian" ascii.
        let russian = InputSourceClassifier.classify(
            sourceID: "com.apple.keylayout.Russian",
            category: "Keyboard Layout",
            languages: ["ru"]
        )
        XCTAssertNotEqual(russian, .ascii)
        XCTAssertNotEqual(russian, .chinese)
    }

    func testThirdPartyNonChineseIsOther() {
        let kind = InputSourceClassifier.classify(
            sourceID: "com.example.inputmethod.Korean",
            category: "Keyboard Input Method",
            languages: ["ko"]
        )
        XCTAssertEqual(kind, .other)
    }
}
