import Foundation

public struct QuotaSample: Codable, Equatable, Sendable, Identifiable {
    public var id: String {
        syncIdentity
    }

    public var syncIdentity: String {
        "\(limitId)|\(Self.syncTimestamp(capturedAt))|\(Self.syncTimestamp(weeklyResetsAt))"
    }

    public var syncRecordName: String {
        "quota_\(Self.sanitizedIdentifier(limitId))_\(Self.syncTimestamp(capturedAt))_\(Self.syncTimestamp(weeklyResetsAt))"
    }

    public let capturedAt: Date
    public let limitId: String
    public let limitName: String?
    public let weeklyUsedPercent: Double
    public let weeklyWindowMinutes: Int?
    public let weeklyResetsAt: Date?
    public let fiveHourUsedPercent: Double?
    public let fiveHourWindowMinutes: Int?
    public let fiveHourResetsAt: Date?
    public let planType: String?
    public let rateLimitReachedType: String?

    public init(
        capturedAt: Date,
        limitId: String,
        limitName: String?,
        weeklyUsedPercent: Double,
        weeklyWindowMinutes: Int?,
        weeklyResetsAt: Date?,
        fiveHourUsedPercent: Double?,
        fiveHourWindowMinutes: Int?,
        fiveHourResetsAt: Date?,
        planType: String?,
        rateLimitReachedType: String?
    ) {
        self.capturedAt = Self.normalizedDate(capturedAt)
        self.limitId = limitId
        self.limitName = limitName
        self.weeklyUsedPercent = weeklyUsedPercent
        self.weeklyWindowMinutes = weeklyWindowMinutes
        self.weeklyResetsAt = weeklyResetsAt.map(Self.normalizedDate)
        self.fiveHourUsedPercent = fiveHourUsedPercent
        self.fiveHourWindowMinutes = fiveHourWindowMinutes
        self.fiveHourResetsAt = fiveHourResetsAt.map(Self.normalizedDate)
        self.planType = planType
        self.rateLimitReachedType = rateLimitReachedType
    }

    public init?(snapshot: RateLimitSnapshot, capturedAt: Date) {
        guard let weekly = snapshot.secondary else {
            return nil
        }

        self.init(
            capturedAt: capturedAt,
            limitId: snapshot.limitId ?? "codex",
            limitName: snapshot.limitName,
            weeklyUsedPercent: weekly.usedPercent,
            weeklyWindowMinutes: weekly.windowDurationMins,
            weeklyResetsAt: weekly.resetDate,
            fiveHourUsedPercent: snapshot.primary?.usedPercent,
            fiveHourWindowMinutes: snapshot.primary?.windowDurationMins,
            fiveHourResetsAt: snapshot.primary?.resetDate,
            planType: snapshot.planType,
            rateLimitReachedType: snapshot.rateLimitReachedType
        )
    }

    private static func syncTimestamp(_ date: Date?) -> Int64 {
        Int64((date?.timeIntervalSince1970 ?? 0).rounded())
    }

    private static func normalizedDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: TimeInterval(syncTimestamp(date)))
    }

    private static func sanitizedIdentifier(_ value: String) -> String {
        let characters = value.unicodeScalars.map { scalar in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "_"
        }
        return String(characters)
    }
}

public struct QuotaSnapshotObservation: Equatable, Sendable {
    public let snapshot: RateLimitSnapshot
    public let capturedAt: Date

    public init(snapshot: RateLimitSnapshot, capturedAt: Date) {
        self.snapshot = snapshot
        self.capturedAt = capturedAt
    }
}

public enum QuotaSnapshotContinuityDecision: Equatable, Sendable {
    case accepted([QuotaSnapshotObservation])
    case pending
}

public struct QuotaSnapshotContinuityPolicy: Sendable {
    public static let requiredConfirmationCount = 3
    public static let requiredConfirmationDuration: TimeInterval = 90

    public private(set) var trustedSnapshot: RateLimitSnapshot?
    private var candidateObservations: [QuotaSnapshotObservation] = []

    public init(trustedSnapshot: RateLimitSnapshot? = nil) {
        self.trustedSnapshot = trustedSnapshot
    }

    public mutating func reset(trustedSnapshot: RateLimitSnapshot?) {
        self.trustedSnapshot = trustedSnapshot
        candidateObservations = []
    }

    public mutating func evaluate(
        _ snapshot: RateLimitSnapshot,
        capturedAt: Date
    ) -> QuotaSnapshotContinuityDecision {
        let observation = QuotaSnapshotObservation(snapshot: snapshot, capturedAt: capturedAt)
        guard let trustedSnapshot else {
            self.trustedSnapshot = snapshot
            candidateObservations = []
            return .accepted([observation])
        }

        guard Self.requiresConfirmation(snapshot, after: trustedSnapshot, capturedAt: capturedAt) else {
            self.trustedSnapshot = snapshot
            candidateObservations = []
            return .accepted([observation])
        }

        if let candidate = candidateObservations.last,
           Self.sameCandidateWindow(candidate.snapshot, snapshot) {
            candidateObservations.append(observation)
        } else {
            candidateObservations = [observation]
        }

        guard let firstCandidate = candidateObservations.first,
              candidateObservations.count >= Self.requiredConfirmationCount,
              capturedAt.timeIntervalSince(firstCandidate.capturedAt) >= Self.requiredConfirmationDuration else {
            return .pending
        }

        let accepted = candidateObservations
        self.trustedSnapshot = snapshot
        candidateObservations = []
        return .accepted(accepted)
    }

    public static func bootstrapSnapshot(from samples: [QuotaSample]) -> RateLimitSnapshot? {
        guard let latestDate = samples.map(\.capturedAt).max() else {
            return nil
        }

        let cutoff = latestDate.addingTimeInterval(-24 * 60 * 60)
        let recentSamples = samples.filter {
            $0.capturedAt >= cutoff && $0.weeklyResetsAt != nil
        }
        let candidates = recentSamples.isEmpty ? samples : recentSamples
        let grouped = Dictionary(grouping: candidates.compactMap { sample -> (String, QuotaSample)? in
            guard let resetDate = sample.weeklyResetsAt else {
                return nil
            }
            let resetMinute = Int64((resetDate.timeIntervalSince1970 / 60).rounded())
            return ("\(sample.limitId)|\(resetMinute)", sample)
        }, by: \.0)

        let dominantGroup = grouped.values.max { lhs, rhs in
            if lhs.count == rhs.count {
                let lhsDate = lhs.map(\.1.capturedAt).max() ?? .distantPast
                let rhsDate = rhs.map(\.1.capturedAt).max() ?? .distantPast
                return lhsDate < rhsDate
            }
            return lhs.count < rhs.count
        }
        guard let sample = dominantGroup?.map(\.1).max(by: { $0.capturedAt < $1.capturedAt }) else {
            return nil
        }
        return snapshot(from: sample)
    }

    public static func repairedSamples(_ samples: [QuotaSample]) -> [QuotaSample] {
        let sortedSamples = samples.sorted { lhs, rhs in
            if lhs.capturedAt == rhs.capturedAt {
                return lhs.limitId < rhs.limitId
            }
            return lhs.capturedAt < rhs.capturedAt
        }
        let samplesByObservation = Dictionary(
            sortedSamples.map { (observationKey(sample: $0), $0) },
            uniquingKeysWith: { _, replacement in replacement }
        )
        var policiesByLimitId: [String: QuotaSnapshotContinuityPolicy] = [:]
        var repaired: [QuotaSample] = []

        for sample in sortedSamples {
            var policy = policiesByLimitId[sample.limitId] ?? QuotaSnapshotContinuityPolicy()
            let decision = policy.evaluate(snapshot(from: sample), capturedAt: sample.capturedAt)
            policiesByLimitId[sample.limitId] = policy
            guard case let .accepted(observations) = decision else {
                continue
            }
            repaired.append(contentsOf: observations.compactMap {
                samplesByObservation[observationKey(observation: $0)]
            })
        }

        return QuotaSampleStore.mergedSamples(
            repaired,
            policy: .countOnly(max(1, samples.count))
        )
    }

    private static func requiresConfirmation(
        _ snapshot: RateLimitSnapshot,
        after trustedSnapshot: RateLimitSnapshot,
        capturedAt: Date
    ) -> Bool {
        guard snapshot.limitId == trustedSnapshot.limitId,
              let weekly = snapshot.secondary,
              let trustedWeekly = trustedSnapshot.secondary else {
            return false
        }

        let usageDecreased = weekly.usedPercent + usageTolerance < trustedWeekly.usedPercent
        guard usageDecreased else {
            return false
        }

        guard let resetDate = weekly.resetDate,
              let trustedResetDate = trustedWeekly.resetDate else {
            return true
        }

        let oldWindowHasReset = capturedAt >= trustedResetDate.addingTimeInterval(-scheduledResetGrace)
            && resetDate > trustedResetDate.addingTimeInterval(resetTolerance)
        return oldWindowHasReset == false
    }

    private static func sameCandidateWindow(
        _ lhs: RateLimitSnapshot,
        _ rhs: RateLimitSnapshot
    ) -> Bool {
        guard lhs.limitId == rhs.limitId,
              let lhsWeekly = lhs.secondary,
              let rhsWeekly = rhs.secondary else {
            return false
        }
        switch (lhsWeekly.resetDate, rhsWeekly.resetDate) {
        case let (lhsReset?, rhsReset?):
            return abs(lhsReset.timeIntervalSince(rhsReset)) <= resetTolerance
        case (nil, nil):
            return true
        case (_?, nil), (nil, _?):
            return false
        }
    }

    private static func snapshot(from sample: QuotaSample) -> RateLimitSnapshot {
        RateLimitSnapshot(
            limitId: sample.limitId,
            limitName: sample.limitName,
            primary: sample.fiveHourUsedPercent.map {
                RateLimitWindow(
                    usedPercent: $0,
                    windowDurationMins: sample.fiveHourWindowMinutes,
                    resetsAt: sample.fiveHourResetsAt.map { Int($0.timeIntervalSince1970.rounded()) }
                )
            },
            secondary: RateLimitWindow(
                usedPercent: sample.weeklyUsedPercent,
                windowDurationMins: sample.weeklyWindowMinutes,
                resetsAt: sample.weeklyResetsAt.map { Int($0.timeIntervalSince1970.rounded()) }
            ),
            credits: nil,
            planType: sample.planType,
            rateLimitReachedType: sample.rateLimitReachedType
        )
    }

    private static func observationKey(sample: QuotaSample) -> String {
        "\(sample.limitId)|\(Int64(sample.capturedAt.timeIntervalSince1970.rounded()))|\(Int64((sample.weeklyResetsAt?.timeIntervalSince1970 ?? 0).rounded()))"
    }

    private static func observationKey(observation: QuotaSnapshotObservation) -> String {
        "\(observation.snapshot.limitId ?? "codex")|\(Int64(observation.capturedAt.timeIntervalSince1970.rounded()))|\(Int64((observation.snapshot.secondary?.resetDate?.timeIntervalSince1970 ?? 0).rounded()))"
    }

    private static let usageTolerance = 0.001
    private static let resetTolerance: TimeInterval = 5
    private static let scheduledResetGrace: TimeInterval = 60
}

public struct QuotaSampleRetentionPolicy: Equatable, Sendable {
    public static let standard = QuotaSampleRetentionPolicy(
        maximumSampleAge: 14 * 24 * 60 * 60,
        maximumSampleCount: 25_000
    )

    public let maximumSampleAge: TimeInterval?
    public let maximumSampleCount: Int

    public init(maximumSampleAge: TimeInterval?, maximumSampleCount: Int) {
        self.maximumSampleAge = maximumSampleAge
        self.maximumSampleCount = max(1, maximumSampleCount)
    }

    public static func countOnly(_ maximumSampleCount: Int) -> QuotaSampleRetentionPolicy {
        QuotaSampleRetentionPolicy(maximumSampleAge: nil, maximumSampleCount: maximumSampleCount)
    }
}

public struct QuotaSampleStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultStore(fileManager: FileManager = .default) throws -> QuotaSampleStore {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directoryURL = baseURL.appendingPathComponent("TokenCoffee", isDirectory: true)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return QuotaSampleStore(fileURL: directoryURL.appendingPathComponent("quota-samples.jsonl"))
    }

    public func append(_ sample: QuotaSample, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: fileURL.path) {
            fileManager.createFile(atPath: fileURL.path, contents: nil)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(sample)
        data.append(0x0A)

        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }

    public func load(
        policy: QuotaSampleRetentionPolicy = .standard,
        now: Date = Date()
    ) throws -> [QuotaSample] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }

        let data = try Data(contentsOf: fileURL)
        let content = String(decoding: data, as: UTF8.self)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let lines = content.split(whereSeparator: \.isNewline)
        let samples = lines.compactMap { line in
            try? decoder.decode(QuotaSample.self, from: Data(line.utf8))
        }
        return Self.mergedSamples(samples, policy: policy, now: now)
    }

    public func load(limit: Int) throws -> [QuotaSample] {
        try load(policy: .countOnly(limit))
    }

    @discardableResult
    public func merge(
        _ samples: [QuotaSample],
        policy: QuotaSampleRetentionPolicy = .standard,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> [QuotaSample] {
        let localSamples = (try? load(policy: .countOnly(policy.maximumSampleCount * 2), now: now)) ?? []
        let merged = Self.mergedSamples(localSamples + samples, policy: policy, now: now)
        try write(merged, fileManager: fileManager)
        return merged
    }

    @discardableResult
    public func merge(_ samples: [QuotaSample], limit: Int, fileManager: FileManager = .default) throws -> [QuotaSample] {
        try merge(samples, policy: .countOnly(limit), fileManager: fileManager)
    }

    public func write(_ samples: [QuotaSample], fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try samples.reduce(into: Data()) { partialResult, sample in
            partialResult.append(try encoder.encode(sample))
            partialResult.append(0x0A)
        }

        try data.write(to: fileURL, options: [.atomic])
    }

    public static func mergedSamples(
        _ samples: [QuotaSample],
        policy: QuotaSampleRetentionPolicy = .standard,
        now: Date = Date()
    ) -> [QuotaSample] {
        let cutoffDate = policy.maximumSampleAge.map { now.addingTimeInterval(-$0) }
        let retainedSamples = samples.filter { sample in
            guard let cutoffDate else {
                return true
            }
            return sample.capturedAt >= cutoffDate
        }
        let unique = Dictionary(retainedSamples.map { ($0.syncIdentity, $0) }, uniquingKeysWith: { current, replacement in
            replacement.capturedAt >= current.capturedAt ? replacement : current
        })
        let sorted = unique.values.sorted {
            if $0.capturedAt == $1.capturedAt {
                return $0.limitId < $1.limitId
            }
            return $0.capturedAt < $1.capturedAt
        }
        return Array(sorted.suffix(policy.maximumSampleCount))
    }

    public static func mergedSamples(_ samples: [QuotaSample], limit: Int) -> [QuotaSample] {
        mergedSamples(samples, policy: .countOnly(limit))
    }

    public static func compactedSamples(
        _ samples: [QuotaSample],
        heartbeatInterval: TimeInterval = 15 * 60
    ) -> [QuotaSample] {
        let compacted = Dictionary(grouping: samples, by: \.limitId).values.flatMap { limitSamples in
            let sorted = limitSamples.sorted { $0.capturedAt < $1.capturedAt }
            guard let first = sorted.first else {
                return [QuotaSample]()
            }

            var retained = [first]
            for sample in sorted.dropFirst() {
                guard let previous = retained.last else {
                    retained.append(sample)
                    continue
                }
                if sample.hasMaterialDifference(from: previous)
                    || sample.capturedAt.timeIntervalSince(previous.capturedAt) >= heartbeatInterval {
                    retained.append(sample)
                }
            }

            if let latest = sorted.last,
               retained.last?.syncIdentity != latest.syncIdentity {
                retained.append(latest)
            }
            return retained
        }

        return compacted.sorted {
            if $0.capturedAt == $1.capturedAt {
                return $0.limitId < $1.limitId
            }
            return $0.capturedAt < $1.capturedAt
        }
    }
}

private extension QuotaSample {
    func hasMaterialDifference(from other: QuotaSample) -> Bool {
        limitName != other.limitName
            || weeklyUsedPercent != other.weeklyUsedPercent
            || weeklyWindowMinutes != other.weeklyWindowMinutes
            || resetDateDiffers(weeklyResetsAt, other.weeklyResetsAt)
            || fiveHourUsedPercent != other.fiveHourUsedPercent
            || planType != other.planType
            || rateLimitReachedType != other.rateLimitReachedType
    }

    private func resetDateDiffers(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            abs(lhs.timeIntervalSince(rhs)) > 5
        case (nil, nil):
            false
        case (_?, nil), (nil, _?):
            true
        }
    }
}
