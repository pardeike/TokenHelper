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

    func testContinuityPolicyNeverConfirmsRepeatedUsageRegressionInSameWindow() {
        let trusted = makeSnapshot(usedPercent: 40, resetAt: 20_000)
        var policy = QuotaSnapshotContinuityPolicy(trustedSnapshot: trusted)

        for (capturedAt, usedPercent) in [(1_000.0, 24.0), (1_060.0, 24.0), (1_120.0, 25.0)] {
            XCTAssertEqual(
                policy.evaluate(
                    makeSnapshot(usedPercent: usedPercent, resetAt: 20_000),
                    capturedAt: Date(timeIntervalSince1970: capturedAt)
                ),
                .pending
            )
        }

        XCTAssertEqual(policy.trustedSnapshot, trusted)
    }

    func testContinuityPolicyRejectsHighSpikeAndRecoversWithCorroboratedIncrease() {
        let trusted = makeSnapshot(usedPercent: 40, resetAt: 20_000)
        let highSpike = makeSnapshot(usedPercent: 80, resetAt: 20_000)
        let recovered = makeSnapshot(usedPercent: 41, resetAt: 20_000)
        var policy = QuotaSnapshotContinuityPolicy(trustedSnapshot: trusted)

        XCTAssertEqual(
            policy.evaluate(highSpike, capturedAt: Date(timeIntervalSince1970: 1_000)),
            .pending
        )
        XCTAssertEqual(
            policy.evaluate(recovered, capturedAt: Date(timeIntervalSince1970: 1_060)),
            .pending
        )
        XCTAssertEqual(
            policy.evaluate(recovered, capturedAt: Date(timeIntervalSince1970: 1_120)),
            .accepted([
                QuotaSnapshotObservation(
                    snapshot: recovered,
                    capturedAt: Date(timeIntervalSince1970: 1_060)
                ),
                QuotaSnapshotObservation(
                    snapshot: recovered,
                    capturedAt: Date(timeIntervalSince1970: 1_120)
                ),
            ])
        )
        XCTAssertEqual(policy.trustedSnapshot, recovered)

        let increased = makeSnapshot(usedPercent: 42, resetAt: 20_000)
        let higher = makeSnapshot(usedPercent: 50, resetAt: 20_000)
        XCTAssertEqual(
            policy.evaluate(increased, capturedAt: Date(timeIntervalSince1970: 1_180)),
            .pending
        )
        XCTAssertEqual(
            policy.evaluate(higher, capturedAt: Date(timeIntervalSince1970: 1_240)),
            .accepted([
                QuotaSnapshotObservation(
                    snapshot: increased,
                    capturedAt: Date(timeIntervalSince1970: 1_180)
                ),
                QuotaSnapshotObservation(
                    snapshot: increased,
                    capturedAt: Date(timeIntervalSince1970: 1_240)
                ),
            ])
        )
        XCTAssertEqual(policy.trustedSnapshot, increased)
    }

    func testContinuityPolicyPersistsCorroboratedIncreaseAcrossRepair() {
        let resetAt: TimeInterval = 20_000
        let baseline = makeSample(capturedAt: 1_000, resetAt: resetAt, usedPercent: 40)
        let increased = makeSnapshot(usedPercent: 41, resetAt: resetAt)
        let corroborator = makeSnapshot(usedPercent: 42, resetAt: resetAt)
        var policy = QuotaSnapshotContinuityPolicy(
            trustedSnapshot: makeSnapshot(usedPercent: 40, resetAt: resetAt)
        )

        XCTAssertEqual(
            policy.evaluate(increased, capturedAt: Date(timeIntervalSince1970: 1_060)),
            .pending
        )
        let decision = policy.evaluate(
            corroborator,
            capturedAt: Date(timeIntervalSince1970: 1_120)
        )
        guard case let .accepted(observations) = decision else {
            return XCTFail("Expected the corroborated increase to be accepted")
        }

        let acceptedSamples = observations.compactMap {
            QuotaSample(snapshot: $0.snapshot, capturedAt: $0.capturedAt)
        }
        let persisted = QuotaSnapshotContinuityPolicy.repairedSamples(
            [baseline] + acceptedSamples
        )

        XCTAssertEqual(persisted.map(\.weeklyUsedPercent), [40, 41, 41])
        XCTAssertEqual(
            persisted.map(\.capturedAt),
            [1_000, 1_060, 1_120].map(Date.init(timeIntervalSince1970:))
        )
        XCTAssertEqual(QuotaSnapshotContinuityPolicy.repairedSamples(persisted), persisted)
        XCTAssertEqual(
            QuotaSnapshotContinuityPolicy.bootstrapSnapshot(from: persisted)?.secondary?.usedPercent,
            41
        )
    }

    func testContinuityPolicyRecoversFromUncorroboratedInitialSpike() {
        let resetAt: TimeInterval = 20_000
        let spike = makeSnapshot(usedPercent: 80, resetAt: resetAt)
        let recovered = makeSnapshot(usedPercent: 40, resetAt: resetAt)
        var policy = QuotaSnapshotContinuityPolicy()

        let initialDecision = policy.evaluate(
            spike,
            capturedAt: Date(timeIntervalSince1970: 900)
        )
        XCTAssertEqual(
            initialDecision,
            .accepted([
                QuotaSnapshotObservation(
                    snapshot: spike,
                    capturedAt: Date(timeIntervalSince1970: 900)
                ),
            ])
        )
        XCTAssertEqual(
            policy.evaluate(recovered, capturedAt: Date(timeIntervalSince1970: 1_000)),
            .pending
        )
        XCTAssertEqual(
            policy.evaluate(recovered, capturedAt: Date(timeIntervalSince1970: 1_060)),
            .pending
        )

        let recoveryDecision = policy.evaluate(
            recovered,
            capturedAt: Date(timeIntervalSince1970: 1_090)
        )
        guard case let .accepted(recoveryObservations) = recoveryDecision else {
            return XCTFail("Expected the lower run to replace the uncorroborated baseline")
        }
        XCTAssertEqual(recoveryObservations.count, QuotaSnapshotContinuityPolicy.requiredConfirmationCount)
        XCTAssertEqual(policy.trustedSnapshot, recovered)

        let observations = [initialDecision, recoveryDecision].flatMap { decision in
            guard case let .accepted(accepted) = decision else {
                return [QuotaSnapshotObservation]()
            }
            return accepted
        }
        let persisted = QuotaSnapshotContinuityPolicy.repairedSamples(
            observations.compactMap {
                QuotaSample(snapshot: $0.snapshot, capturedAt: $0.capturedAt)
            }
        )

        XCTAssertEqual(persisted.map(\.weeklyUsedPercent), [40, 40, 40])
        XCTAssertEqual(QuotaSnapshotContinuityPolicy.repairedSamples(persisted), persisted)
    }

    func testContinuityPolicyRecoversFromInitialSpikeAfterBootstrap() {
        let resetAt: TimeInterval = 20_000
        let spike = makeSample(capturedAt: 900, resetAt: resetAt, usedPercent: 80)
        let recovered = makeSnapshot(usedPercent: 40, resetAt: resetAt)
        guard let bootstrap = QuotaSnapshotContinuityPolicy.bootstrap(from: [spike]) else {
            return XCTFail("Expected the initial sample to produce bootstrap state")
        }
        var policy = QuotaSnapshotContinuityPolicy(
            trustedSnapshot: bootstrap.snapshot,
            isCorroborated: bootstrap.isCorroborated
        )

        XCTAssertFalse(bootstrap.isCorroborated)
        XCTAssertEqual(
            policy.evaluate(recovered, capturedAt: Date(timeIntervalSince1970: 1_000)),
            .pending
        )
        XCTAssertEqual(
            policy.evaluate(recovered, capturedAt: Date(timeIntervalSince1970: 1_060)),
            .pending
        )
        XCTAssertNotEqual(
            policy.evaluate(recovered, capturedAt: Date(timeIntervalSince1970: 1_090)),
            .pending
        )
        XCTAssertEqual(policy.trustedSnapshot, recovered)
    }

    func testContinuityPolicyDoesNotReplaceCorroboratedInitialBaseline() {
        let resetAt: TimeInterval = 20_000
        let baseline = makeSnapshot(usedPercent: 80, resetAt: resetAt)
        let lower = makeSnapshot(usedPercent: 40, resetAt: resetAt)
        var policy = QuotaSnapshotContinuityPolicy()

        XCTAssertNotEqual(
            policy.evaluate(baseline, capturedAt: Date(timeIntervalSince1970: 900)),
            .pending
        )
        XCTAssertNotEqual(
            policy.evaluate(baseline, capturedAt: Date(timeIntervalSince1970: 960)),
            .pending
        )
        for capturedAt in [1_000.0, 1_060.0, 1_090.0] {
            XCTAssertEqual(
                policy.evaluate(
                    lower,
                    capturedAt: Date(timeIntervalSince1970: capturedAt)
                ),
                .pending
            )
        }

        XCTAssertEqual(policy.trustedSnapshot, baseline)
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
            makeSample(capturedAt: 1_180, resetAt: oldReset.timeIntervalSince1970, usedPercent: 54),
            makeSample(capturedAt: 1_240, resetAt: dropoutReset.timeIntervalSince1970, usedPercent: 0),
        ]

        let snapshot = QuotaSnapshotContinuityPolicy.bootstrapSnapshot(from: samples)

        XCTAssertEqual(snapshot?.secondary?.usedPercent, 54)
        XCTAssertEqual(snapshot?.secondary?.resetDate, oldReset)
    }

    func testContinuityBootstrapUsesNewestConfirmedResetWhenOldWindowHasMoreSamples() {
        let oldReset: TimeInterval = 20_000
        let newReset: TimeInterval = 30_000
        let oldSamples = (0..<20).map { index in
            makeSample(
                capturedAt: 1_000 + TimeInterval(index * 60),
                resetAt: oldReset,
                usedPercent: 54
            )
        }
        let newSamples = [
            makeSample(capturedAt: 2_200, resetAt: newReset, usedPercent: 1),
            makeSample(capturedAt: 2_210, resetAt: newReset + 1, usedPercent: 1),
            makeSample(capturedAt: 2_260, resetAt: newReset, usedPercent: 1),
            makeSample(capturedAt: 2_320, resetAt: newReset, usedPercent: 1),
        ]

        let snapshot = QuotaSnapshotContinuityPolicy.bootstrapSnapshot(
            from: oldSamples + newSamples
        )

        XCTAssertEqual(snapshot?.secondary?.usedPercent, 1)
        XCTAssertEqual(snapshot?.secondary?.resetDate, Date(timeIntervalSince1970: newReset))
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

    func testContinuityRepairRemovesLiveResetTimestampDropout() {
        let trustedReset: TimeInterval = 20_000
        let samples = [
            makeSample(capturedAt: 1_000, resetAt: trustedReset, usedPercent: 13),
            makeSample(capturedAt: 1_360, resetAt: trustedReset + 190, usedPercent: 1),
            makeSample(capturedAt: 1_540, resetAt: trustedReset, usedPercent: 13),
        ]

        let repaired = QuotaSnapshotContinuityPolicy.repairedSamples(samples)

        XCTAssertEqual(repaired, [samples[0], samples[2]])
    }

    func testContinuityRepairRemovesConfirmedLengthUsageDetourInSameWindow() {
        let resetAt: TimeInterval = 20_000
        let samples = [
            makeSample(capturedAt: 1_000, resetAt: resetAt, usedPercent: 40),
            makeSample(capturedAt: 1_060, resetAt: resetAt, usedPercent: 40),
            makeSample(capturedAt: 1_840, resetAt: resetAt, usedPercent: 24),
            makeSample(capturedAt: 1_900, resetAt: resetAt, usedPercent: 24),
            makeSample(capturedAt: 1_960, resetAt: resetAt, usedPercent: 25),
            makeSample(capturedAt: 2_800, resetAt: resetAt, usedPercent: 40),
            makeSample(capturedAt: 2_860, resetAt: resetAt, usedPercent: 41),
            makeSample(capturedAt: 2_920, resetAt: resetAt, usedPercent: 41),
        ]

        let repaired = QuotaSnapshotContinuityPolicy.repairedSamples(samples)

        XCTAssertEqual(repaired, [samples[0], samples[1], samples[5], samples[6], samples[7]])
    }

    func testContinuityRepairRejectsHighSpikeAndKeepsPersistentNormalRun() {
        let resetAt: TimeInterval = 20_000
        let samples = [
            makeSample(capturedAt: 1_000, resetAt: resetAt, usedPercent: 40),
            makeSample(capturedAt: 1_060, resetAt: resetAt, usedPercent: 80),
            makeSample(capturedAt: 1_120, resetAt: resetAt, usedPercent: 41),
            makeSample(capturedAt: 1_180, resetAt: resetAt, usedPercent: 41),
            makeSample(capturedAt: 1_240, resetAt: resetAt, usedPercent: 42),
            makeSample(capturedAt: 1_300, resetAt: resetAt, usedPercent: 50),
        ]

        let repaired = QuotaSnapshotContinuityPolicy.repairedSamples(samples)

        XCTAssertEqual(
            repaired.map(\.weeklyUsedPercent),
            [40, 41, 41, 42, 42]
        )
        XCTAssertEqual(
            repaired.map(\.capturedAt),
            [1_000, 1_120, 1_180, 1_240, 1_300].map(Date.init(timeIntervalSince1970:))
        )
        XCTAssertEqual(QuotaSnapshotContinuityPolicy.repairedSamples(repaired), repaired)
    }

    func testCompactionKeepsChangesHeartbeatsAndLatestSample() {
        let samples = [
            makeSample(capturedAt: 0, usedPercent: 10),
            makeSample(capturedAt: 60, usedPercent: 10),
            makeSample(capturedAt: 120, usedPercent: 11),
            makeSample(capturedAt: 600, usedPercent: 11),
            makeSample(capturedAt: 1_020, usedPercent: 11),
            makeSample(capturedAt: 1_080, usedPercent: 11),
        ]

        let compacted = QuotaSampleStore.compactedSamples(samples, heartbeatInterval: 900)

        XCTAssertEqual(
            compacted.map(\.capturedAt),
            [0, 120, 600, 1_080].map(Date.init(timeIntervalSince1970:))
        )
    }

    func testCompactionPreservesEarlyResetConfirmationEvidence() {
        let trustedReset: TimeInterval = 10_000
        let newReset: TimeInterval = 20_000
        let samples = [
            makeSample(capturedAt: 1_000, resetAt: trustedReset, usedPercent: 42),
            makeSample(capturedAt: 1_060, resetAt: trustedReset, usedPercent: 43),
            makeSample(capturedAt: 1_120, resetAt: trustedReset, usedPercent: 43),
            makeSample(capturedAt: 1_180, resetAt: newReset, usedPercent: 0),
            makeSample(capturedAt: 1_240, resetAt: newReset, usedPercent: 0),
            makeSample(capturedAt: 1_300, resetAt: newReset, usedPercent: 0),
        ]

        let compacted = QuotaSampleStore.compactedSamples(samples)
        let newWindowSamples = compacted.filter {
            $0.weeklyResetsAt == Date(timeIntervalSince1970: newReset)
        }

        XCTAssertEqual(newWindowSamples.count, QuotaSnapshotContinuityPolicy.requiredConfirmationCount)
        XCTAssertEqual(
            QuotaSnapshotContinuityPolicy.repairedSamples(compacted),
            compacted
        )
    }

    func testCompactionKeepsResetAndFiveHourChanges() {
        let first = makeSample(capturedAt: 0, resetAt: 10_000, usedPercent: 10)
        let resetChanged = makeSample(capturedAt: 60, resetAt: 20_000, usedPercent: 10)
        let fiveHourChanged = QuotaSample(
            capturedAt: Date(timeIntervalSince1970: 120),
            limitId: resetChanged.limitId,
            limitName: resetChanged.limitName,
            weeklyUsedPercent: resetChanged.weeklyUsedPercent,
            weeklyWindowMinutes: resetChanged.weeklyWindowMinutes,
            weeklyResetsAt: resetChanged.weeklyResetsAt,
            fiveHourUsedPercent: 5,
            fiveHourWindowMinutes: resetChanged.fiveHourWindowMinutes,
            fiveHourResetsAt: resetChanged.fiveHourResetsAt,
            planType: resetChanged.planType,
            rateLimitReachedType: resetChanged.rateLimitReachedType
        )

        let compacted = QuotaSampleStore.compactedSamples(
            [first, resetChanged, fiveHourChanged],
            heartbeatInterval: 900
        )

        XCTAssertEqual(compacted, [first, resetChanged, fiveHourChanged])
    }

    func testCompactionIgnoresSmallResetTimestampJitter() {
        let first = makeSample(capturedAt: 0, resetAt: 10_000, usedPercent: 10)
        let jittered = makeSample(capturedAt: 60, resetAt: 10_004, usedPercent: 10)
        let latest = makeSample(capturedAt: 120, resetAt: 10_004, usedPercent: 10)

        let compacted = QuotaSampleStore.compactedSamples(
            [first, jittered, latest],
            heartbeatInterval: 900
        )

        XCTAssertEqual(compacted, [first, latest])
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
