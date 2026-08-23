import XCTest
@testable import TokenCoffeeCore

final class PowerSessionControllerTests: XCTestCase {
    func testKeepAwakeDisplayCreatesAssertionsAndDisablesClamshellSleep() throws {
        let client = FakePowerAssertionClient()
        let controller = PowerSessionController(client: client)

        try controller.apply(mode: .keepAwakeDisplay)

        XCTAssertEqual(client.createdKinds, [.preventIdleSystemSleep, .preventIdleDisplaySleep])
        XCTAssertEqual(client.clamshellDisabledValues, [true])
    }

    func testOffReleasesAssertionsAndRestoresClamshellSleep() throws {
        let client = FakePowerAssertionClient()
        let controller = PowerSessionController(client: client)

        try controller.apply(mode: .keepAwakeDisplay)
        try controller.apply(mode: .off)

        XCTAssertEqual(client.releasedIDs, [2, 1])
        XCTAssertEqual(client.clamshellDisabledValues, [true, false])
    }

    func testPreferredPowerModeDefaultsToOff() {
        let (defaults, suiteName) = temporaryUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(TokenCoffeeDefaults.preferredPowerMode(userDefaults: defaults), .off)
    }

    func testPreferredPowerModeRoundTrips() {
        let (defaults, suiteName) = temporaryUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TokenCoffeeDefaults.setPreferredPowerMode(.keepAwakeDisplay, userDefaults: defaults)

        XCTAssertEqual(TokenCoffeeDefaults.preferredPowerMode(userDefaults: defaults), .keepAwakeDisplay)
    }

    func testInvalidPreferredPowerModeDefaultsToOff() {
        let (defaults, suiteName) = temporaryUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("not-a-mode", forKey: TokenCoffeeDefaults.preferredPowerModeKey)

        XCTAssertEqual(TokenCoffeeDefaults.preferredPowerMode(userDefaults: defaults), .off)
    }

    func testPreferredScreenBlackoutDelayDefaultsToOneMinute() {
        let (defaults, suiteName) = temporaryUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(TokenCoffeeDefaults.preferredScreenBlackoutDelay(userDefaults: defaults), .oneMinute)
    }

    func testPreferredScreenBlackoutDelayRoundTrips() {
        let (defaults, suiteName) = temporaryUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        TokenCoffeeDefaults.setPreferredScreenBlackoutDelay(.oneHour, userDefaults: defaults)

        XCTAssertEqual(TokenCoffeeDefaults.preferredScreenBlackoutDelay(userDefaults: defaults), .oneHour)
    }

    func testInvalidPreferredScreenBlackoutDelayDefaultsToOneMinute() {
        let (defaults, suiteName) = temporaryUserDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("not-a-delay", forKey: TokenCoffeeDefaults.screenBlackoutDelayKey)

        XCTAssertEqual(TokenCoffeeDefaults.preferredScreenBlackoutDelay(userDefaults: defaults), .oneMinute)
    }

    func testScreenBlackoutDelayThresholds() {
        XCTAssertNil(ScreenBlackoutDelay.off.inactivityThreshold)
        XCTAssertEqual(ScreenBlackoutDelay.oneMinute.inactivityThreshold, 60)
        XCTAssertEqual(ScreenBlackoutDelay.twoMinutes.inactivityThreshold, 120)
        XCTAssertEqual(ScreenBlackoutDelay.fiveMinutes.inactivityThreshold, 300)
        XCTAssertEqual(ScreenBlackoutDelay.tenMinutes.inactivityThreshold, 600)
        XCTAssertEqual(ScreenBlackoutDelay.oneHour.inactivityThreshold, 3_600)
    }

    private func temporaryUserDefaults() -> (UserDefaults, String) {
        let suiteName = "com.pardeike.TokenCoffee.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

private final class FakePowerAssertionClient: PowerAssertionClient {
    private var nextID: UInt32 = 1
    private(set) var createdKinds: [PowerAssertionKind] = []
    private(set) var releasedIDs: [UInt32] = []
    private(set) var clamshellDisabledValues: [Bool] = []

    func createAssertion(kind: PowerAssertionKind, name: String) throws -> UInt32 {
        createdKinds.append(kind)
        defer { nextID += 1 }
        return nextID
    }

    func releaseAssertion(_ id: UInt32) {
        releasedIDs.append(id)
    }

    func setClamshellSleepDisabled(_ disabled: Bool) throws {
        clamshellDisabledValues.append(disabled)
    }
}
