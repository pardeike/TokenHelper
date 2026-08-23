import AppKit
import TokenCoffeeCore
import XCTest
@testable import Token_Coffee

@MainActor
final class ScreenBlankingControllerTests: XCTestCase {
    func testBlackoutStartsAtConfiguredDelayAndEndsAfterInput() {
        var idleTime: TimeInterval = 59.99
        let presenter = FakeScreenBlackoutPresenter()
        let controller = ScreenBlankingController(
            checkInterval: 3_600,
            idleTimeProvider: { idleTime },
            presenter: presenter
        )
        defer { controller.shutdown() }

        controller.setConfiguration(powerMode: .keepAwakeDisplay, blackoutDelay: .oneMinute)
        XCTAssertFalse(presenter.isVisible)

        idleTime = 60
        controller.checkNow()
        XCTAssertTrue(presenter.isVisible)

        idleTime = 0
        controller.checkNow()
        XCTAssertFalse(presenter.isVisible)
    }

    func testOnlyKeepScreenOnEnablesBlackoutAndModeChangeEndsIt() {
        let presenter = FakeScreenBlackoutPresenter()
        let controller = ScreenBlankingController(
            checkInterval: 3_600,
            idleTimeProvider: { 60 },
            presenter: presenter
        )
        defer { controller.shutdown() }

        controller.setConfiguration(powerMode: .off, blackoutDelay: .oneMinute)
        XCTAssertFalse(presenter.isVisible)

        controller.setConfiguration(powerMode: .keepAwake, blackoutDelay: .oneMinute)
        XCTAssertFalse(presenter.isVisible)

        controller.setConfiguration(powerMode: .keepAwakeDisplay, blackoutDelay: .off)
        XCTAssertFalse(presenter.isVisible)

        controller.setConfiguration(powerMode: .keepAwakeDisplay, blackoutDelay: .oneMinute)
        XCTAssertTrue(presenter.isVisible)

        controller.setConfiguration(powerMode: .keepAwake, blackoutDelay: .oneMinute)
        XCTAssertFalse(presenter.isVisible)
    }

    func testChangingDelayReevaluatesAndOffImmediatelyEndsBlackout() {
        var idleTime: TimeInterval = 90
        let presenter = FakeScreenBlackoutPresenter()
        let controller = ScreenBlankingController(
            checkInterval: 3_600,
            idleTimeProvider: { idleTime },
            presenter: presenter
        )
        defer { controller.shutdown() }

        controller.setConfiguration(powerMode: .keepAwakeDisplay, blackoutDelay: .oneMinute)
        XCTAssertTrue(presenter.isVisible)

        controller.setConfiguration(powerMode: .keepAwakeDisplay, blackoutDelay: .twoMinutes)
        XCTAssertFalse(presenter.isVisible)

        idleTime = 120
        controller.checkNow()
        XCTAssertTrue(presenter.isVisible)

        controller.setConfiguration(powerMode: .keepAwakeDisplay, blackoutDelay: .off)
        XCTAssertFalse(presenter.isVisible)
    }

    func testDisplayChangesOnlyRefreshAnActiveBlackout() {
        let presenter = FakeScreenBlackoutPresenter()
        let controller = ScreenBlankingController(
            checkInterval: 3_600,
            idleTimeProvider: { 60 },
            presenter: presenter
        )
        defer { controller.shutdown() }

        controller.setConfiguration(powerMode: .keepAwakeDisplay, blackoutDelay: .oneMinute)
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        XCTAssertEqual(presenter.refreshCount, 1)

        controller.setConfiguration(powerMode: .off, blackoutDelay: .oneMinute)
        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        XCTAssertEqual(presenter.refreshCount, 1)
    }

    func testPresenterMovesCursorBeforeBlackoutToBottomRightOfRightmostDisplay() {
        var actions: [String] = []
        var cursorPoints: [CGPoint] = []
        let presenter = ScreenBlackoutPresenter(
            screensProvider: {
                actions.append("blackout")
                return []
            },
            displayBoundsProvider: {
                [
                    CGRect(x: -1_280, y: 0, width: 1_280, height: 1_024),
                    CGRect(x: 0, y: 0, width: 1_440, height: 900),
                    CGRect(x: 1_440, y: 100, width: 1_920, height: 1_080)
                ]
            },
            moveCursor: { point in
                actions.append("cursor")
                cursorPoints.append(point)
                return .success
            }
        )

        presenter.show()
        presenter.show()
        XCTAssertEqual(actions, ["cursor", "blackout"])
        XCTAssertEqual(cursorPoints, [CGPoint(x: 3_359, y: 1_179)])
    }

    func testBlackoutMenuListsEveryDelayAndChecksCurrentSelection() throws {
        var selectedDelay: ScreenBlackoutDelay?
        let menuItem = PanelControlMenu.screenBlackoutMenuItem(selectedDelay: .fiveMinutes) {
            selectedDelay = $0
        }
        let submenu = try XCTUnwrap(menuItem.submenu)

        XCTAssertEqual(
            submenu.items.map(\.title),
            ["Off", "1min idle", "2min idle", "5min idle", "10min idle", "1h idle"]
        )
        XCTAssertEqual(
            submenu.items.map(\.state),
            [.off, .off, .off, .on, .off, .off]
        )

        let tenMinuteItem = submenu.items[4]
        XCTAssertTrue(NSApp.sendAction(
            try XCTUnwrap(tenMinuteItem.action),
            to: tenMinuteItem.target,
            from: tenMinuteItem
        ))
        XCTAssertEqual(selectedDelay, .tenMinutes)
    }
}

@MainActor
private final class FakeScreenBlackoutPresenter: ScreenBlackoutPresenting {
    private(set) var isVisible = false
    private(set) var refreshCount = 0

    func show() {
        isVisible = true
    }

    func hide() {
        isVisible = false
    }

    func refreshDisplays() {
        guard isVisible else {
            return
        }
        refreshCount += 1
    }
}
