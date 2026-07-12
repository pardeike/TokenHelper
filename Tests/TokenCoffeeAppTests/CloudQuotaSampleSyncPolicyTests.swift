import CloudKit
import XCTest
@testable import Token_Coffee
@testable import TokenCoffeeCore

final class CloudQuotaSampleSyncPolicyTests: XCTestCase {
    func testInitialUploadWatermarkStartsAtNewestLocalSample() {
        let older = sample(capturedAt: 100)
        let newer = sample(capturedAt: 300)

        let watermark = CloudQuotaSampleSyncPolicy.initialUploadWatermark(
            existing: nil,
            localSamples: [newer, older]
        )

        XCTAssertEqual(watermark, newer.capturedAt)
    }

    func testSamplesToUploadOnlyUsesNewerSamplesMissingRemotely() {
        let watermark = Date(timeIntervalSince1970: 200)
        let old = sample(capturedAt: 100)
        let remote = sample(capturedAt: 250)
        let upload = sample(capturedAt: 300)

        let samples = CloudQuotaSampleSyncPolicy.samplesToUpload(
            localSamples: [old, remote, upload],
            remoteRecordNames: [remote.syncRecordName],
            uploadWatermark: watermark,
            windowStartDate: Date(timeIntervalSince1970: 200)
        )

        XCTAssertEqual(samples, [upload])
    }

    func testSamplesToUploadRecoversMissingCurrentWindowRecordsBelowWatermark() {
        let watermark = Date(timeIntervalSince1970: 400)
        let outsideWindow = sample(capturedAt: 100)
        let olderMissing = sample(capturedAt: 250)
        let newestMissing = sample(capturedAt: 350)

        let samples = CloudQuotaSampleSyncPolicy.samplesToUpload(
            localSamples: [outsideWindow, olderMissing, newestMissing],
            remoteRecordNames: [],
            uploadWatermark: watermark,
            windowStartDate: Date(timeIntervalSince1970: 200),
            limit: 1
        )

        XCTAssertEqual(samples, [newestMissing])
    }

    func testContinuityCleanupDeletesRejectedRemoteSampleOnly() {
        let trusted = sample(capturedAt: 1_000, resetAt: 20_000, usedPercent: 13)
        let dropout = sample(capturedAt: 1_360, resetAt: 20_190, usedPercent: 1)
        let recovered = sample(capturedAt: 1_540, resetAt: 20_000, usedPercent: 13)
        let candidates = [trusted, dropout, recovered]
        let repaired = QuotaSnapshotContinuityPolicy.repairedSamples(candidates)

        let recordNames = CloudQuotaSampleSyncPolicy.continuityRejectedRecordNames(
            candidateSamples: candidates,
            repairedSamples: repaired,
            remoteRecordNames: Set(candidates.map(\.syncRecordName)),
            limit: 100
        )

        XCTAssertEqual(recordNames, [dropout.syncRecordName])
    }

    func testCleanupUsesCurrentTimeAxisLeftEdgeOnly() {
        let windowStart = Date(timeIntervalSince1970: 1_000)
        let tooOld = sample(capturedAt: 999, limitId: "other", resetAt: 100)
        let exactlyAtStart = sample(capturedAt: 1_000, limitId: "other", resetAt: 100)
        let inWindowWithDifferentReset = sample(capturedAt: 1_001, limitId: "other", resetAt: 100)
        let remoteSamples = remoteMetadata([tooOld, exactlyAtStart, inWindowWithDifferentReset])

        let recordNames = CloudQuotaSampleSyncPolicy.cleanupCandidateRecordNames(
            remoteSamplesByRecordName: remoteSamples,
            context: CloudQuotaSampleCleanupContext(windowStartDate: windowStart),
            limit: 10
        )

        XCTAssertEqual(recordNames, [tooOld.syncRecordName])
    }

    func testCleanupHonorsBatchLimitAndOldestFirst() {
        let windowStart = Date(timeIntervalSince1970: 1_000)
        let newestOld = sample(capturedAt: 900)
        let oldest = sample(capturedAt: 700)
        let middle = sample(capturedAt: 800)
        let remoteSamples = remoteMetadata([newestOld, oldest, middle])

        let recordNames = CloudQuotaSampleSyncPolicy.cleanupCandidateRecordNames(
            remoteSamplesByRecordName: remoteSamples,
            context: CloudQuotaSampleCleanupContext(windowStartDate: windowStart),
            limit: 2
        )

        XCTAssertEqual(recordNames, [oldest.syncRecordName, middle.syncRecordName])
    }

    func testCleanupContextKeepsAtLeastSevenRollingDays() throws {
        let reset = Date(timeIntervalSince1970: 10_000)
        let graphWindowStart = QuotaHistoryWindow.startDate(resetDate: reset)
        let now = graphWindowStart.addingTimeInterval(3 * 24 * 60 * 60)
        let expectedWindowStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        let snapshot = snapshot(reset: reset, windowMinutes: 14 * 24 * 60)

        let context = try XCTUnwrap(
            CloudQuotaSampleCleanupContext(
                snapshot: snapshot,
                now: now
            )
        )

        XCTAssertEqual(context.windowStartDate, expectedWindowStart)
    }

    func testGraphHistoryWindowAlwaysUsesSevenDaysBeforeReset() {
        let reset = Date(timeIntervalSince1970: 10_000)

        let start = QuotaHistoryWindow.startDate(resetDate: reset)

        XCTAssertEqual(start, reset.addingTimeInterval(-7 * 24 * 60 * 60))
    }

    func testGraphDayBoundariesUseFixed24HourCycles() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = date(year: 2026, month: 5, day: 1, hour: 15, minute: 30, calendar: calendar)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)

        let boundaries = QuotaGraphTimeAxis.dayBoundaries(
            startDate: start,
            resetDate: reset,
            calendar: calendar
        )

        XCTAssertEqual(boundaries.first?.date, date(year: 2026, month: 5, day: 2, hour: 0, minute: 0, calendar: calendar))
        XCTAssertEqual(boundaries.count, 7)
        XCTAssertTrue(
            zip(boundaries, boundaries.dropFirst()).allSatisfy {
                $1.date.timeIntervalSince($0.date) == 24 * 60 * 60
            }
        )
    }

    func testGraphDayBandsCoverWindowWithIntersecting24HourCycles() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = date(year: 2026, month: 5, day: 1, hour: 15, minute: 30, calendar: calendar)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)

        let bands = QuotaGraphTimeAxis.dayBands(startDate: start, resetDate: reset, calendar: calendar)

        XCTAssertEqual(bands.count, 8)
        XCTAssertEqual(bands.first?.startDate, date(year: 2026, month: 5, day: 1, hour: 0, minute: 0, calendar: calendar))
        XCTAssertEqual(bands.last?.endDate, date(year: 2026, month: 5, day: 9, hour: 0, minute: 0, calendar: calendar))
        XCTAssertTrue(bands.allSatisfy { $0.endDate.timeIntervalSince($0.startDate) == 24 * 60 * 60 })
        XCTAssertTrue(try XCTUnwrap(bands.first?.startDate) < start)
        XCTAssertTrue(try XCTUnwrap(bands.last?.endDate) > reset)
        XCTAssertEqual(bands.first?.isLight, true)
        XCTAssertTrue(
            zip(bands, bands.dropFirst()).allSatisfy {
                $0.endDate == $1.startDate && $0.isLight != $1.isLight
            }
        )
    }

    func testGraphDayBandsMatchFridayToFridayWindowAtLocalMidnights() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Stockholm"))
        let start = date(year: 2026, month: 7, day: 10, hour: 21, minute: 38, calendar: calendar)
        let reset = date(year: 2026, month: 7, day: 17, hour: 21, minute: 38, calendar: calendar)

        let bands = QuotaGraphTimeAxis.dayBands(startDate: start, resetDate: reset, calendar: calendar)

        XCTAssertEqual(bands.count, 8)
        XCTAssertEqual(bands.first?.startDate, date(year: 2026, month: 7, day: 10, hour: 0, minute: 0, calendar: calendar))
        XCTAssertEqual(bands.last?.endDate, date(year: 2026, month: 7, day: 18, hour: 0, minute: 0, calendar: calendar))
        XCTAssertEqual(bands.first?.isLight, true)
        XCTAssertTrue(
            zip(bands, bands.dropFirst()).allSatisfy {
                $0.endDate == $1.startDate && $0.isLight != $1.isLight
            }
        )
    }

    func testGraphDayBandsAlwaysBeginWithLightBand() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        for day in [1, 2] {
            let start = date(year: 2026, month: 5, day: day, hour: 15, minute: 30, calendar: calendar)
            let reset = start.addingTimeInterval(7 * 24 * 60 * 60)

            let bands = QuotaGraphTimeAxis.dayBands(startDate: start, resetDate: reset, calendar: calendar)

            XCTAssertEqual(bands.first?.isLight, true)
        }
    }

    func testGraphIntensityBandsAdaptWhenRunCrossesDayBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = date(year: 2026, month: 5, day: 1, hour: 15, minute: 30, calendar: calendar)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let dayBands = QuotaGraphTimeAxis.dayBands(startDate: start, resetDate: reset, calendar: calendar)
        let run = QuotaForecastRun(
            startDate: date(year: 2026, month: 5, day: 1, hour: 23, minute: 0, calendar: calendar),
            endDate: date(year: 2026, month: 5, day: 2, hour: 1, minute: 0, calendar: calendar),
            startUsedPercent: 10,
            endUsedPercent: 12
        )

        let intensityBands = QuotaGraphTimeAxis.intensityBands(
            runs: [run],
            dayBands: dayBands,
            startDate: start,
            resetDate: reset
        )

        XCTAssertEqual(
            intensityBands,
            [
                QuotaGraphIntensityBand(
                    index: 0,
                    startDate: run.startDate,
                    endDate: date(year: 2026, month: 5, day: 2, hour: 0, minute: 0, calendar: calendar),
                    isLight: true
                ),
                QuotaGraphIntensityBand(
                    index: 1,
                    startDate: date(year: 2026, month: 5, day: 2, hour: 0, minute: 0, calendar: calendar),
                    endDate: run.endDate,
                    isLight: false
                )
            ]
        )
    }

    func testGraphIntensityBandsStayWithinRealWindow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = date(year: 2026, month: 5, day: 1, hour: 15, minute: 30, calendar: calendar)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)
        let dayBands = QuotaGraphTimeAxis.dayBands(startDate: start, resetDate: reset, calendar: calendar)
        let run = QuotaForecastRun(
            startDate: start.addingTimeInterval(-60 * 60),
            endDate: reset.addingTimeInterval(60 * 60),
            startUsedPercent: 10,
            endUsedPercent: 20
        )

        let intensityBands = QuotaGraphTimeAxis.intensityBands(
            runs: [run],
            dayBands: dayBands,
            startDate: start,
            resetDate: reset
        )

        XCTAssertEqual(intensityBands.first?.startDate, start)
        XCTAssertEqual(intensityBands.last?.endDate, reset)
        XCTAssertTrue(intensityBands.allSatisfy { $0.startDate >= start && $0.endDate <= reset })
    }

    func testGraphDayBandsRemain24HoursAcrossDaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Stockholm"))
        let start = date(year: 2026, month: 3, day: 28, hour: 12, minute: 0, calendar: calendar)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)

        let bands = QuotaGraphTimeAxis.dayBands(startDate: start, resetDate: reset, calendar: calendar)

        XCTAssertFalse(bands.isEmpty)
        XCTAssertTrue(bands.allSatisfy { $0.endDate.timeIntervalSince($0.startDate) == 24 * 60 * 60 })
        XCTAssertEqual(calendar.component(.hour, from: try XCTUnwrap(bands.first?.startDate)), 0)
        let bandCrossingDST = try XCTUnwrap(
            bands.first {
                calendar.component(.day, from: $0.startDate) == 29
            }
        )
        XCTAssertEqual(calendar.component(.hour, from: bandCrossingDST.startDate), 0)
        XCTAssertEqual(calendar.component(.hour, from: bandCrossingDST.endDate), 1)
        XCTAssertTrue(
            zip(bands, bands.dropFirst()).allSatisfy {
                $0.isLight != $1.isLight
            }
        )
    }

    func testGraphDayBandsAlternateAcrossAutumnDaylightSavingChange() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Stockholm"))
        let start = date(year: 2026, month: 10, day: 24, hour: 12, minute: 0, calendar: calendar)
        let reset = start.addingTimeInterval(7 * 24 * 60 * 60)

        let bands = QuotaGraphTimeAxis.dayBands(startDate: start, resetDate: reset, calendar: calendar)

        XCTAssertTrue(bands.allSatisfy { $0.endDate.timeIntervalSince($0.startDate) == 24 * 60 * 60 })
        XCTAssertTrue(
            zip(bands, bands.dropFirst()).allSatisfy {
                $0.endDate == $1.startDate && $0.isLight != $1.isLight
            }
        )
    }

    func testRateLimitRetryDateUsesCloudKitRetryAfter() {
        let now = Date(timeIntervalSince1970: 1_000)
        let error = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.requestRateLimited.rawValue,
            userInfo: [CKErrorRetryAfterKey: 42]
        )

        let retryAt = CloudQuotaSampleSyncPolicy.retryDate(for: error, now: now)

        XCTAssertEqual(retryAt, now.addingTimeInterval(42))
    }

    func testStatusShowsRateLimitedWhenRetryIsFuture() {
        let now = Date(timeIntervalSince1970: 1_000)
        let retryAt = now.addingTimeInterval(60)
        var state = CloudQuotaSampleSyncState.empty
        state.nextAllowedSyncAt = retryAt
        state.nextAllowedSyncReason = .rateLimited

        XCTAssertEqual(CloudQuotaSampleSyncPolicy.status(for: state, now: now), .rateLimited(retryAt))
    }

    func testTransientBackoffStatusDoesNotLookRateLimited() {
        let now = Date(timeIntervalSince1970: 1_000)
        let error = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.networkUnavailable.rawValue
        )
        var state = CloudQuotaSampleSyncState.empty

        CloudQuotaSampleSyncPolicy.apply(error: error, now: now, to: &state)

        XCTAssertEqual(state.nextAllowedSyncAt, now.addingTimeInterval(5 * 60))
        XCTAssertEqual(state.nextAllowedSyncReason, .transientFailure)
        XCTAssertEqual(
            CloudQuotaSampleSyncPolicy.status(for: state, now: now),
            .failed("CloudKit temporarily unavailable; retrying")
        )
    }

    func testChangeTokenResetBackoffStatusDoesNotLookRateLimited() {
        let now = Date(timeIntervalSince1970: 1_000)
        let error = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.changeTokenExpired.rawValue
        )
        var state = CloudQuotaSampleSyncState.empty
        state.zoneChangeTokenData = Data([1, 2, 3])
        state.remoteSamplesByRecordName = remoteMetadata([sample(capturedAt: 900)])

        CloudQuotaSampleSyncPolicy.apply(error: error, now: now, to: &state)

        XCTAssertNil(state.zoneChangeTokenData)
        XCTAssertTrue(state.remoteSamplesByRecordName.isEmpty)
        XCTAssertEqual(state.nextAllowedSyncAt, now.addingTimeInterval(5 * 60))
        XCTAssertEqual(state.nextAllowedSyncReason, .changeTokenReset)
        XCTAssertEqual(
            CloudQuotaSampleSyncPolicy.status(for: state, now: now),
            .failed("CloudKit sync state reset; retrying")
        )
    }

    func testRateLimitBackoffStatusRequiresRateLimitReason() {
        let now = Date(timeIntervalSince1970: 1_000)
        let retryAt = now.addingTimeInterval(42)
        let error = NSError(
            domain: CKError.errorDomain,
            code: CKError.Code.requestRateLimited.rawValue,
            userInfo: [CKErrorRetryAfterKey: 42]
        )
        var state = CloudQuotaSampleSyncState.empty

        CloudQuotaSampleSyncPolicy.apply(error: error, now: now, to: &state)

        XCTAssertEqual(state.nextAllowedSyncAt, retryAt)
        XCTAssertEqual(state.nextAllowedSyncReason, .rateLimited)
        XCTAssertEqual(CloudQuotaSampleSyncPolicy.status(for: state, now: now), .rateLimited(retryAt))
    }

    func testCleanupCatchUpSyncUsesTwoMinuteIntervalWhileLegacyWindowIsIncomplete() {
        let now = Date(timeIntervalSince1970: 1_000)
        let context = CloudQuotaSampleCleanupContext(windowStartDate: Date(timeIntervalSince1970: 500))
        var state = CloudQuotaSampleSyncState.empty
        state.isCaughtUp = true
        state.lastSuccessfulSyncAt = now
        state.lastLegacyDefaultZoneScanAt = now

        XCTAssertFalse(
            CloudQuotaSampleSyncPolicy.shouldRunSync(
                state: state,
                cleanupContext: context,
                now: now.addingTimeInterval(119)
            )
        )
        XCTAssertTrue(
            CloudQuotaSampleSyncPolicy.shouldRunSync(
                state: state,
                cleanupContext: context,
                now: now.addingTimeInterval(120)
            )
        )

        state.legacyDefaultZoneCompletedWindowStartDate = context.windowStartDate
        XCTAssertFalse(
            CloudQuotaSampleSyncPolicy.shouldRunSync(
                state: state,
                cleanupContext: context,
                now: now.addingTimeInterval(120)
            )
        )
    }

    func testCustomZoneCleanupUsesTwoMinuteIntervalWhileCandidatesRemain() {
        let now = Date(timeIntervalSince1970: 1_000)
        let context = CloudQuotaSampleCleanupContext(windowStartDate: Date(timeIntervalSince1970: 500))
        var state = CloudQuotaSampleSyncState.empty
        state.isCaughtUp = true
        state.lastCleanupAt = now
        state.remoteSamplesByRecordName = remoteMetadata([sample(capturedAt: 100)])

        XCTAssertFalse(
            CloudQuotaSampleSyncPolicy.shouldRunCleanup(
                state: state,
                context: context,
                now: now.addingTimeInterval(119)
            )
        )
        XCTAssertTrue(
            CloudQuotaSampleSyncPolicy.shouldRunCleanup(
                state: state,
                context: context,
                now: now.addingTimeInterval(120)
            )
        )
    }

    func testLegacyDefaultZoneScanBridgesPreviousVersionUsersOncePerWindow() {
        let now = Date(timeIntervalSince1970: 1_000)
        let windowStart = Date(timeIntervalSince1970: 500)
        let context = CloudQuotaSampleCleanupContext(windowStartDate: windowStart)
        var state = CloudQuotaSampleSyncState.empty
        state.isCaughtUp = true

        XCTAssertTrue(
            CloudQuotaSampleSyncPolicy.shouldRunLegacyDefaultZoneScan(
                state: state,
                context: context,
                now: now
            )
        )

        state.lastLegacyDefaultZoneScanAt = now
        state.legacyDefaultZoneCompletedWindowStartDate = nil
        XCTAssertFalse(
            CloudQuotaSampleSyncPolicy.shouldRunLegacyDefaultZoneScan(
                state: state,
                context: context,
                now: now.addingTimeInterval(119)
            )
        )
        XCTAssertTrue(
            CloudQuotaSampleSyncPolicy.shouldRunLegacyDefaultZoneScan(
                state: state,
                context: context,
                now: now.addingTimeInterval(120)
            )
        )

        state.legacyDefaultZoneCompletedWindowStartDate = windowStart
        XCTAssertFalse(
            CloudQuotaSampleSyncPolicy.shouldRunLegacyDefaultZoneScan(
                state: state,
                context: context,
                now: now
            )
        )

        let nextWindowContext = CloudQuotaSampleCleanupContext(windowStartDate: windowStart.addingTimeInterval(7 * 24 * 60 * 60))
        XCTAssertTrue(
            CloudQuotaSampleSyncPolicy.shouldRunLegacyDefaultZoneScan(
                state: state,
                context: nextWindowContext,
                now: now.addingTimeInterval(7 * 24 * 60 * 60)
            )
        )
    }

    private func remoteMetadata(_ samples: [QuotaSample]) -> [String: CloudQuotaSampleRemoteMetadata] {
        Dictionary(
            uniqueKeysWithValues: samples.map {
                (
                    $0.syncRecordName,
                    CloudQuotaSampleRemoteMetadata(recordName: $0.syncRecordName, sample: $0)
                )
            }
        )
    }

    private func snapshot(reset: Date, windowMinutes: Int = 10_080) -> RateLimitSnapshot {
        RateLimitSnapshot(
            limitId: "codex",
            limitName: "Codex",
            primary: RateLimitWindow(
                usedPercent: 5,
                windowDurationMins: 300,
                resetsAt: Int(reset.timeIntervalSince1970) - 3_600
            ),
            secondary: RateLimitWindow(
                usedPercent: 12,
                windowDurationMins: windowMinutes,
                resetsAt: Int(reset.timeIntervalSince1970)
            ),
            credits: nil,
            planType: "pro",
            rateLimitReachedType: nil
        )
    }

    private func date(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(
                calendar: calendar,
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: minute
            )
        )!
    }

    private func sample(
        capturedAt: TimeInterval,
        limitId: String = "codex",
        resetAt: TimeInterval = 1_600,
        usedPercent: Double = 12
    ) -> QuotaSample {
        QuotaSample(
            capturedAt: Date(timeIntervalSince1970: capturedAt),
            limitId: limitId,
            limitName: nil,
            weeklyUsedPercent: usedPercent,
            weeklyWindowMinutes: 10_080,
            weeklyResetsAt: Date(timeIntervalSince1970: resetAt),
            fiveHourUsedPercent: 4,
            fiveHourWindowMinutes: 300,
            fiveHourResetsAt: Date(timeIntervalSince1970: 200),
            planType: "pro",
            rateLimitReachedType: nil
        )
    }
}
