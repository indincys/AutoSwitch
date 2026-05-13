import AppKit
import XCTest
@testable import AutoSwitch

final class AppStateWindowSizingTests: XCTestCase {
    @MainActor
    func testSettingsWindowAppliesExpectedFrameSize() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: .zero),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        AppState.applySettingsWindowContentSizing(to: window)

        XCTAssertEqual(window.frame.width, AppState.settingsWindowDefaultFrameSize.width)
        XCTAssertEqual(window.frame.height, AppState.settingsWindowDefaultFrameSize.height)
        XCTAssertEqual(window.contentView?.bounds.width, AppState.settingsWindowDefaultContentSize.width)
        XCTAssertEqual(window.contentView?.bounds.height, AppState.settingsWindowDefaultContentSize.height)
    }

    @MainActor
    func testSettingsWindowFrameCentersAppliedDefaultSizeInVisibleFrame() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: .zero),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let visibleFrame = NSRect(x: 0, y: 66, width: 1512, height: 883)

        AppState.applySettingsWindowContentSizing(to: window, constrainedTo: visibleFrame)

        let frame = window.frame

        XCTAssertEqual(frame.midX, visibleFrame.midX, accuracy: 1)
        XCTAssertEqual(frame.midY, visibleFrame.midY, accuracy: 1)
        XCTAssertEqual(frame.width, AppState.settingsWindowDefaultFrameSize.width)
        XCTAssertEqual(frame.height, AppState.settingsWindowDefaultFrameSize.height)
        XCTAssertEqual(window.contentView?.bounds.width, AppState.settingsWindowDefaultContentSize.width)
        XCTAssertEqual(window.contentView?.bounds.height, AppState.settingsWindowDefaultContentSize.height)
        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX)
        XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY)
    }

    @MainActor
    func testSettingsWindowMinimumSizeAllowsExpectedContentSize() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: .zero),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        AppState.applySettingsWindowContentSizing(to: window)

        XCTAssertEqual(window.contentMinSize, AppState.settingsWindowMinimumContentSize)
        XCTAssertEqual(window.minSize, AppState.settingsWindowMinimumFrameSize)
    }

    @MainActor
    func testSettingsWindowFrameSizeIsConstrainedToVisibleFrame() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 800, height: 600)

        let frameSize = AppState.settingsWindowFrameSize(constrainedTo: visibleFrame)

        XCTAssertEqual(frameSize.width, AppState.settingsWindowMinimumFrameSize.width)
        XCTAssertEqual(frameSize.height, AppState.settingsWindowMinimumFrameSize.height)
    }

    @MainActor
    func testSettingsWindowFrameStaysInsideSmallVisibleFrame() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: .zero),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        let visibleFrame = NSRect(x: 40, y: 80, width: 800, height: 600)

        AppState.applySettingsWindowContentSizing(to: window, constrainedTo: visibleFrame)

        let frame = window.frame

        XCTAssertEqual(frame.width, AppState.settingsWindowMinimumFrameSize.width)
        XCTAssertEqual(frame.height, AppState.settingsWindowMinimumFrameSize.height)
        XCTAssertGreaterThanOrEqual(frame.minX, visibleFrame.minX)
        XCTAssertLessThanOrEqual(frame.maxX, visibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(frame.minY, visibleFrame.minY)
        XCTAssertLessThanOrEqual(frame.maxY, visibleFrame.maxY)
    }

    @MainActor
    func testSettingsWindowContentSizeAccountsForTitlebar() {
        XCTAssertEqual(AppState.settingsWindowDefaultContentSize.width, AppState.settingsWindowDefaultFrameSize.width)
        XCTAssertLessThan(AppState.settingsWindowDefaultContentSize.height, AppState.settingsWindowDefaultFrameSize.height)
    }
}
