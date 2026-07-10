import XCTest
@testable import TokenCoffeeCore

final class QuotaSampleStoreTests: XCTestCase {
    func testAppendsLoadsAndIgnoresCorruptLines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("samples.jsonl")
        let store = QuotaSampleStore(fileURL: fileURL)
        let sample = makeSample(capturedAt: 123, usedPercent: 12)

        try store.append(sample)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()

        let loaded = try store.load(policy: .countOnly(2_000))

        XCTAssertEqual(loaded, [sample])
        try? FileManager.default.removeItem(at: directory)
    }

    func testSyncIdentityAndRecordNameAreStableAcrossSubsecondDates() {
        let first = makeSample(capturedAt: 123.1, limitId: "codex/pro", resetAt: 456.2)
        let second = makeSample(capturedAt: 123.4, limitId: "codex/pro", resetAt: 456.4)

        XCTAssertEqual(first.syncIdentity, second.syncIdentity)
        XCTAssertEqual(first.syncRecordName, "quota_codex_pro_123_456")
    }

    func testMergeDedupeSortsAndRewritesStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("samples.jsonl")
        let store = QuotaSampleStore(fileURL: fileURL)
        let newest = makeSample(capturedAt: 300, usedPercent: 30)
        let duplicate = makeSample(capturedAt: 200.1, usedPercent: 20)
        let duplicateReplacement = makeSample(capturedAt: 200.4, usedPercent: 21)
        let oldest = makeSample(capturedAt: 100, usedPercent: 10)

        try store.append(duplicate)
        let merged = try store.merge([newest, duplicateReplacement, oldest], policy: .countOnly(2_000))
        let reloaded = try store.load(policy: .countOnly(2_000))

        XCTAssertEqual(merged, [oldest, duplicateReplacement, newest])
        XCTAssertEqual(reloaded, merged)
        XCTAssertFalse(String(decoding: try Data(contentsOf: fileURL), as: UTF8.self).contains("\"weeklyUsedPercent\":20"))
        try? FileManager.default.removeItem(at: directory)
    }

    func testMergeAppliesAgeRetentionAndHardCap() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let fileURL = directory.appendingPathComponent("samples.jsonl")
        let store = QuotaSampleStore(fileURL: fileURL)
        let policy = QuotaSampleRetentionPolicy(maximumSampleAge: 120, maximumSampleCount: 2)
        let now = Date(timeIntervalSince1970: 1_000)

        let tooOld = makeSample(capturedAt: 800, usedPercent: 1)
        let olderRetained = makeSample(capturedAt: 900, usedPercent: 2)
        let firstRetained = makeSample(capturedAt: 940, usedPercent: 3)
        let secondRetained = makeSample(capturedAt: 980, usedPercent: 4)

        let merged = try store.merge(
            [tooOld, olderRetained, firstRetained, secondRetained],
            policy: policy,
            now: now
        )

        XCTAssertEqual(merged, [firstRetained, secondRetained])
        XCTAssertEqual(try store.load(policy: .countOnly(10)), [firstRetained, secondRetained])
        try? FileManager.default.removeItem(at: directory)
    }

    func testContinuityPolicyDefersSingleEarlyResetDropout() {
        let trusted = makeSnapshot(usedPercent: 54, resetAt: 10_000)
        let dropout = makeSnapshot(usedPercent: 0, resetAt: 20_000)
        var policy = QuotaSnapshotContinuityPolicy(trustedSnapshot: trusted)

        XCTAssertEqual(
            policy.evaluate(dropout, capturedAt: Date(timeIntervalSince1970: 1_000)),
            .pending
        )
        XCTAssertEqual(
            policy.evaluate(trusted, capturedAt: Date(timeIntervalSince1970: 1_060)),
            .accepted([QuotaSnapshotObservation(
                snapshot: trusted,
                capturedAt: Date(timeIntervalSince1970: 1_060)
            )])
        )
    }

    func testContinuityPolicyAcceptsConfirmedEarlyOpenAIReset() {
        let trusted = makeSnapshot(usedPercent: 54, resetAt: 10_000)
        let reset = makeSnapshot(usedPercent: 0, resetAt: 20_000)
        var policy = QuotaSnapshotContinuityPolicy(trustedSnapshot: trusted)

        XCTAssertEqual(policy.evaluate(reset, capturedAt: Date(timeIntervalSince1970: 1_000)), .pending)
        XCTAssertEqual(policy.evaluate(reset, capturedAt: Date(timeIntervalSince1970: 1_060)), .pending)
        XCTAssertEqual(
            policy.evaluate(reset, capturedAt: Date(timeIntervalSince1970: 1_120)),
            .accepted([
                QuotaSnapshotObservation(snapshot: reset, capturedAt: Date(timeIntervalSince1970: 1_000)),
                QuotaSnapshotObservation(snapshot: reset, capturedAt: Date(timeIntervalSince1970: 1_060)),
                QuotaSnapshotObservation(snapshot: reset, capturedAt: Date(timeIntervalSince1970: 1_120)),
            ])
        )
        XCTAssertEqual(policy.trustedSnapshot, reset)
    }

    func testContinuityPolicyDoesNotConfirmMovingFallbackWindow() {
        let trusted = makeSnapshot(usedPercent: 54, resetAt: 10_000)
        var policy = QuotaSnapshotContinuityPolicy(trustedSnapshot: trusted)

        for index in 0..<5 {
            let fallback = makeSnapshot(
                usedPercent: 0,
                resetAt: 20_000 + TimeInterval(index * 60)
            )
            XCTAssertEqual(
                policy.evaluate(
                    fallback,
                    capturedAt: Date(timeIntervalSince1970: 1_000 + TimeInterval(index * 60))
                ),
                .pending
            )
        }
        XCTAssertEqual(policy.trustedSnapshot, trusted)
    }

    func testContinuityPolicyAcceptsScheduledResetImmediately() {
        let trusted = makeSnapshot(usedPercent: 54, resetAt: 10_000)
        let reset = makeSnapshot(usedPercent: 0, resetAt: 20_000)
        let capturedAt = Date(timeIntervalSince1970: 10_001)
        var policy = QuotaSnapshotContinuityPolicy(trustedSnapshot: trusted)

        XCTAssertEqual(
            policy.evaluate(reset, capturedAt: capturedAt),
            .accepted([QuotaSnapshotObservation(snapshot: reset, capturedAt: capturedAt)])
        )
    }

    func testContinuityBootstrapUsesDominantRecentResetWindow() {
        let oldReset = Date(timeIntervalSince1970: 20_000)
        let dropoutReset = Date(timeIntervalSince1970: 30_000)
        let samples = [
            makeSample(capturedAt: 1_000, resetAt: oldReset.timeIntervalSince1970, usedPercent: 53),
            makeSample(capturedAt: 1_060, resetAt: oldReset.timeIntervalSince1970, usedPercent: 53),
            makeSample(capturedAt: 1_120, resetAt: oldReset.timeIntervalSince1970, usedPercent: 54),
            makeSample(capturedAt: 1_180, resetAt: dropoutReset.timeIntervalSince1970, usedPercent: 0),
        ]

        let snapshot = QuotaSnapshotContinuityPolicy.bootstrapSnapshot(from: samples)

        XCTAssertEqual(snapshot?.secondary?.usedPercent, 54)
        XCTAssertEqual(snapshot?.secondary?.resetDate, oldReset)
    }

    func testContinuityRepairRemovesDropoutAndKeepsConfirmedEarlyReset() {
        let oldReset: TimeInterval = 20_000
        let newReset: TimeInterval = 30_000
        let samples = [
            makeSample(capturedAt: 1_000, resetAt: oldReset, usedPercent: 53),
            makeSample(capturedAt: 1_060, resetAt: oldReset, usedPercent: 54),
            makeSample(capturedAt: 1_120, resetAt: newReset, usedPercent: 0),
            makeSample(capturedAt: 1_180, resetAt: oldReset, usedPercent: 54),
            makeSample(capturedAt: 1_240, resetAt: newReset, usedPercent: 0),
            makeSample(capturedAt: 1_300, resetAt: newReset, usedPercent: 0),
            makeSample(capturedAt: 1_360, resetAt: newReset, usedPercent: 1),
        ]

        let repaired = QuotaSnapshotContinuityPolicy.repairedSamples(samples)

        XCTAssertEqual(
            repaired.map(\.capturedAt),
            [1_000, 1_060, 1_180, 1_240, 1_300, 1_360].map(Date.init(timeIntervalSince1970:))
        )
    }

    private func makeSample(
        capturedAt: TimeInterval,
        limitId: String = "codex",
        resetAt: TimeInterval = 456,
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

    private func makeSnapshot(usedPercent: Double, resetAt: TimeInterval) -> RateLimitSnapshot {
        RateLimitSnapshot(
            limitId: "codex",
            limitName: nil,
            primary: RateLimitWindow(
                usedPercent: min(usedPercent, 20),
                windowDurationMins: 300,
                resetsAt: Int(resetAt - 1_000)
            ),
            secondary: RateLimitWindow(
                usedPercent: usedPercent,
                windowDurationMins: 10_080,
                resetsAt: Int(resetAt)
            ),
            credits: nil,
            planType: "pro",
            rateLimitReachedType: nil
        )
    }
}
