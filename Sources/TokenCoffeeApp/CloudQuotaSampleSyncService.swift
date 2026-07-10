import CloudKit
import Foundation
import OSLog
import Security
import TokenCoffeeCore

private let cloudSyncLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.pardeike.TokenCoffee",
    category: "CloudSync"
)

struct QuotaSampleSyncOutcome: Sendable {
    let samples: [QuotaSample]
    let status: QuotaSyncStatus
}

actor CloudQuotaSampleSyncService {
    private enum Defaults {
        static let recordZoneName = "QuotaSamples"
        static let recordZoneID = CKRecordZone.ID(
            zoneName: recordZoneName,
            ownerName: CKCurrentUserDefaultName
        )
        static let normalSyncInterval: TimeInterval = 15 * 60
        static let catchUpSyncInterval: TimeInterval = 5 * 60
        static let transientRetryInterval: TimeInterval = 5 * 60
        static let zoneChangesResultsLimit = 400
        static let caughtUpPageLimit = 1
        static let catchUpPageLimit = 2
        static let cleanupBatchSize = 100
        static let recoveryUploadBatchSize = 200
        static let cleanupInterval: TimeInterval = 15 * 60
        static let legacyDefaultZonePageLimit = 2
    }

    private let retentionPolicy: QuotaSampleRetentionPolicy
    private let stateStore: CloudQuotaSampleSyncStateStore

    init(
        retentionPolicy: QuotaSampleRetentionPolicy = .standard,
        stateStore: CloudQuotaSampleSyncStateStore = .defaultStore()
    ) {
        self.retentionPolicy = retentionPolicy
        self.stateStore = stateStore
    }

    var isConfigured: Bool {
        Self.hasCloudKitEntitlement()
    }

    func sync(
        localSamples: [QuotaSample],
        currentSnapshot: RateLimitSnapshot? = nil
    ) async -> QuotaSampleSyncOutcome {
        let now = Date()
        let normalizedLocalSamples = QuotaSampleStore.mergedSamples(
            localSamples,
            policy: retentionPolicy,
            now: now
        )
        guard isConfigured else {
            cloudSyncLogger.info("Cloud quota sync skipped; CloudKit entitlement is not present")
            return QuotaSampleSyncOutcome(samples: normalizedLocalSamples, status: .localOnly)
        }

        var state = stateStore.load()
        let cleanupContext = CloudQuotaSampleCleanupContext(snapshot: currentSnapshot, now: now)
        if let retryAt = state.nextAllowedSyncAt,
           retryAt > now {
            cloudSyncLogger.info("Cloud quota sync paused by backoff until \(retryAt, privacy: .public)")
            return QuotaSampleSyncOutcome(
                samples: normalizedLocalSamples,
                status: CloudQuotaSampleSyncPolicy.status(for: state, now: now)
            )
        }

        guard CloudQuotaSampleSyncPolicy.shouldRunSync(state: state, cleanupContext: cleanupContext, now: now) else {
            cloudSyncLogger.debug("Cloud quota sync skipped by interval gate; caughtUp=\(state.isCaughtUp, privacy: .public)")
            return QuotaSampleSyncOutcome(
                samples: normalizedLocalSamples,
                status: CloudQuotaSampleSyncPolicy.status(for: state, now: now)
            )
        }

        state.lastUploadedSampleCapturedAt = CloudQuotaSampleSyncPolicy.initialUploadWatermark(
            existing: state.lastUploadedSampleCapturedAt,
            localSamples: normalizedLocalSamples
        )

        do {
            cloudSyncLogger.info(
                "Cloud quota sync started; localSamples=\(normalizedLocalSamples.count, privacy: .public) caughtUp=\(state.isCaughtUp, privacy: .public)"
            )
            let container = CKContainer.default()
            let accountStatus = try await fetchAccountStatus(container: container)
            guard accountStatus == .available else {
                cloudSyncLogger.warning(
                    "Cloud quota sync unavailable; accountStatus=\(accountStatus.quotaSyncDescription, privacy: .public)"
                )
                return QuotaSampleSyncOutcome(
                    samples: normalizedLocalSamples,
                    status: .unavailable(accountStatus.quotaSyncDescription)
                )
            }

            let database = container.privateCloudDatabase
            try await ensureRecordZoneExists(in: database)
            let fetchedRemoteRecords = try await fetchRemoteChanges(database: database, state: &state)
            let fetchedRemoteSamples = fetchedRemoteRecords.compactMap(\.sample)
            cloudSyncLogger.info(
                "Cloud quota sync fetched changes; remoteRecords=\(fetchedRemoteRecords.count, privacy: .public) decodedSamples=\(fetchedRemoteSamples.count, privacy: .public) indexedRemoteSamples=\(state.remoteSamplesByRecordName.count, privacy: .public) caughtUp=\(state.isCaughtUp, privacy: .public)"
            )

            let samplesToUpload = CloudQuotaSampleSyncPolicy.samplesToUpload(
                localSamples: normalizedLocalSamples,
                remoteRecordNames: Set(state.remoteSamplesByRecordName.keys),
                uploadWatermark: state.lastUploadedSampleCapturedAt,
                windowStartDate: cleanupContext?.windowStartDate,
                limit: Defaults.recoveryUploadBatchSize
            )
            cloudSyncLogger.info("Cloud quota sync upload batch prepared; samplesToUpload=\(samplesToUpload.count, privacy: .public)")
            try await applyChanges(saving: samplesToUpload, deleting: [], to: database)
            CloudQuotaSampleSyncPolicy.markUploaded(samplesToUpload, in: &state)

            var legacyDefaultZoneSamples: [QuotaSample] = []
            if let cleanupContext,
               CloudQuotaSampleSyncPolicy.shouldRunCleanup(state: state, context: cleanupContext, now: now) {
                let recordNamesToDelete = CloudQuotaSampleSyncPolicy.cleanupCandidateRecordNames(
                    remoteSamplesByRecordName: state.remoteSamplesByRecordName,
                    context: cleanupContext,
                    limit: Defaults.cleanupBatchSize
                )
                cloudSyncLogger.info(
                    "Cloud quota cleanup evaluated custom zone; cutoff=\(cleanupContext.windowStartDate, privacy: .public) candidates=\(recordNamesToDelete.count, privacy: .public)"
                )
                let recordIDsToDelete = recordNamesToDelete.map {
                    CKRecord.ID(recordName: $0, zoneID: Defaults.recordZoneID)
                }
                try await applyChanges(saving: [], deleting: recordIDsToDelete, to: database)
                CloudQuotaSampleSyncPolicy.markDeleted(recordNamesToDelete, at: now, in: &state)
                cloudSyncLogger.info("Cloud quota cleanup finished custom zone delete batch; deleted=\(recordIDsToDelete.count, privacy: .public)")
            }

            if let cleanupContext,
               CloudQuotaSampleSyncPolicy.shouldRunLegacyDefaultZoneScan(
                state: state,
                context: cleanupContext,
                now: now
               ) {
                let legacyResult = try await scanLegacyDefaultZone(
                    database: database,
                    state: &state,
                    context: cleanupContext,
                    now: now
                )
                legacyDefaultZoneSamples = legacyResult.samples
                cloudSyncLogger.info(
                    "Cloud quota legacy default-zone scan finished; bridgedSamples=\(legacyDefaultZoneSamples.count, privacy: .public) deleteCandidates=\(legacyResult.recordIDsToDelete.count, privacy: .public)"
                )
                try await applyChanges(saving: [], deleting: legacyResult.recordIDsToDelete, to: database)
                cloudSyncLogger.info("Cloud quota legacy default-zone delete batch finished; deleted=\(legacyResult.recordIDsToDelete.count, privacy: .public)")
            }

            let mergedSamples = QuotaSampleStore.mergedSamples(
                normalizedLocalSamples + fetchedRemoteSamples + legacyDefaultZoneSamples,
                policy: retentionPolicy,
                now: now
            )

            state.lastSuccessfulSyncAt = now
            state.nextAllowedSyncAt = nil
            state.nextAllowedSyncReason = nil
            try? stateStore.save(state)

            cloudSyncLogger.info(
                "Cloud quota sync finished; mergedSamples=\(mergedSamples.count, privacy: .public) indexedRemoteSamples=\(state.remoteSamplesByRecordName.count, privacy: .public) caughtUp=\(state.isCaughtUp, privacy: .public)"
            )
            return QuotaSampleSyncOutcome(
                samples: mergedSamples,
                status: CloudQuotaSampleSyncPolicy.status(for: state, now: now)
            )
        } catch {
            CloudQuotaSampleSyncPolicy.apply(error: error, now: now, to: &state)
            try? stateStore.save(state)
            cloudSyncLogger.error(
                "Cloud quota sync failed; error=\(error.localizedDescription, privacy: .public) retryAt=\(String(describing: state.nextAllowedSyncAt), privacy: .public)"
            )
            return QuotaSampleSyncOutcome(
                samples: normalizedLocalSamples,
                status: CloudQuotaSampleSyncPolicy.status(for: error, state: state, now: now)
            )
        }
    }

    private func fetchAccountStatus(container: CKContainer) async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { accountStatus, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: accountStatus)
                }
            }
        }
    }

    private func ensureRecordZoneExists(in database: CKDatabase) async throws {
        do {
            _ = try await fetchRecordZone(id: Defaults.recordZoneID, from: database)
            cloudSyncLogger.debug("Cloud quota custom zone already exists")
        } catch where error.isCloudKitZoneNotFound {
            cloudSyncLogger.info("Cloud quota custom zone missing; creating zone \(Defaults.recordZoneName, privacy: .public)")
            _ = try await saveRecordZone(CKRecordZone(zoneID: Defaults.recordZoneID), to: database)
            cloudSyncLogger.info("Cloud quota custom zone created")
        }
    }

    private func fetchRecordZone(id: CKRecordZone.ID, from database: CKDatabase) async throws -> CKRecordZone {
        try await withCheckedThrowingContinuation { continuation in
            database.fetch(withRecordZoneID: id) { zone, error in
                if let zone {
                    continuation.resume(returning: zone)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: CKError.errorDomain,
                        code: CKError.Code.zoneNotFound.rawValue
                    ))
                }
            }
        }
    }

    private func saveRecordZone(_ zone: CKRecordZone, to database: CKDatabase) async throws -> CKRecordZone {
        try await withCheckedThrowingContinuation { continuation in
            database.save(zone) { savedZone, error in
                if let savedZone {
                    continuation.resume(returning: savedZone)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: zone)
                }
            }
        }
    }

    private func fetchRemoteChanges(
        database: CKDatabase,
        state: inout CloudQuotaSampleSyncState
    ) async throws -> [CloudQuotaSampleRemoteRecord] {
        var token = Self.changeToken(from: state.zoneChangeTokenData)
        var fetchedRecords: [CloudQuotaSampleRemoteRecord] = []
        var moreComing = false
        let pageLimit = state.isCaughtUp ? Defaults.caughtUpPageLimit : Defaults.catchUpPageLimit

        for _ in 0..<pageLimit {
            let response = try await database.recordZoneChanges(
                inZoneWith: Defaults.recordZoneID,
                since: token,
                desiredKeys: CloudQuotaSampleRecord.desiredKeys,
                resultsLimit: Defaults.zoneChangesResultsLimit
            )

            for (recordID, result) in response.modificationResultsByID {
                let modification = try result.get()
                let record = modification.record
                guard record.recordType == CloudQuotaSampleRecord.recordType else {
                    continue
                }
                let sample = CloudQuotaSampleRecord.sample(from: record)
                let remoteRecord = CloudQuotaSampleRemoteRecord(recordID: recordID, sample: sample)
                fetchedRecords.append(remoteRecord)
                state.remoteSamplesByRecordName[recordID.recordName] = CloudQuotaSampleRemoteMetadata(
                    recordName: recordID.recordName,
                    sample: sample
                )
            }

            for deletion in response.deletions where deletion.recordType == CloudQuotaSampleRecord.recordType {
                state.remoteSamplesByRecordName.removeValue(forKey: deletion.recordID.recordName)
            }

            token = response.changeToken
            state.zoneChangeTokenData = try Self.archivedData(for: response.changeToken)
            moreComing = response.moreComing
            cloudSyncLogger.debug(
                "Cloud quota zone-change page fetched; modifications=\(response.modificationResultsByID.count, privacy: .public) deletions=\(response.deletions.count, privacy: .public) moreComing=\(moreComing, privacy: .public)"
            )
            if !moreComing {
                break
            }
        }

        state.isCaughtUp = !moreComing
        return fetchedRecords
    }

    private func scanLegacyDefaultZone(
        database: CKDatabase,
        state: inout CloudQuotaSampleSyncState,
        context: CloudQuotaSampleCleanupContext,
        now: Date
    ) async throws -> CloudQuotaSampleLegacyDefaultZoneResult {
        var cursor = Self.queryCursor(from: state.legacyDefaultZoneCursorData)
        var samples: [QuotaSample] = []
        var recordIDsToDelete: [CKRecord.ID] = []
        var reachedEnd = false

        cloudSyncLogger.info(
            "Cloud quota legacy default-zone scan started; cutoff=\(context.windowStartDate, privacy: .public) hasCursor=\(cursor != nil, privacy: .public)"
        )
        for _ in 0..<Defaults.legacyDefaultZonePageLimit {
            let response: (
                matchResults: [(CKRecord.ID, Result<CKRecord, any Error>)],
                queryCursor: CKQueryOperation.Cursor?
            )
            if let cursor {
                response = try await database.records(
                    continuingMatchFrom: cursor,
                    desiredKeys: CloudQuotaSampleRecord.desiredKeys,
                    resultsLimit: Defaults.zoneChangesResultsLimit
                )
            } else {
                response = try await database.records(
                    matching: CKQuery(recordType: CloudQuotaSampleRecord.recordType, predicate: NSPredicate(value: true)),
                    desiredKeys: CloudQuotaSampleRecord.desiredKeys,
                    resultsLimit: Defaults.zoneChangesResultsLimit
                )
            }

            for (recordID, result) in response.matchResults {
                let record = try result.get()
                guard record.recordID.zoneID == CKRecordZone.ID.default else {
                    continue
                }
                guard let sample = CloudQuotaSampleRecord.sample(from: record) else {
                    continue
                }

                if CloudQuotaSampleSyncPolicy.isCleanupCandidate(
                    CloudQuotaSampleRemoteMetadata(recordName: recordID.recordName, sample: sample),
                    context: context
                ) {
                    if recordIDsToDelete.count < Defaults.cleanupBatchSize {
                        recordIDsToDelete.append(recordID)
                    }
                } else {
                    samples.append(sample)
                }
            }

            cursor = response.queryCursor
            cloudSyncLogger.debug(
                "Cloud quota legacy default-zone page scanned; matches=\(response.matchResults.count, privacy: .public) bridgedSoFar=\(samples.count, privacy: .public) deleteCandidatesSoFar=\(recordIDsToDelete.count, privacy: .public) hasCursor=\(cursor != nil, privacy: .public)"
            )
            if recordIDsToDelete.isEmpty == false {
                state.legacyDefaultZoneCursorData = nil
                state.legacyDefaultZoneCompletedWindowStartDate = nil
                break
            } else if let cursor {
                state.legacyDefaultZoneCursorData = try Self.archivedData(for: cursor)
            } else {
                state.legacyDefaultZoneCursorData = nil
                state.legacyDefaultZoneCompletedWindowStartDate = context.windowStartDate
                reachedEnd = true
                break
            }
        }

        state.lastLegacyDefaultZoneScanAt = now
        if reachedEnd == false,
           state.legacyDefaultZoneCompletedWindowStartDate == context.windowStartDate {
            state.legacyDefaultZoneCompletedWindowStartDate = nil
        }

        return CloudQuotaSampleLegacyDefaultZoneResult(
            samples: samples,
            recordIDsToDelete: recordIDsToDelete
        )
    }

    private func applyChanges(
        saving samples: [QuotaSample],
        deleting recordIDs: [CKRecord.ID],
        to database: CKDatabase
    ) async throws {
        let records = samples.map { CloudQuotaSampleRecord.record(from: $0, zoneID: Defaults.recordZoneID) }
        try await modify(records: records, deleting: [], in: database)
        try await modify(records: [], deleting: recordIDs, in: database)
    }

    private func modify(records: [CKRecord], deleting recordIDs: [CKRecord.ID], in database: CKDatabase) async throws {
        guard records.isEmpty == false || recordIDs.isEmpty == false else {
            return
        }

        let batchSize = 200
        var recordStartIndex = 0
        while recordStartIndex < records.count {
            let endIndex = min(recordStartIndex + batchSize, records.count)
            let response = try await database.modifyRecords(
                saving: Array(records[recordStartIndex..<endIndex]),
                deleting: [],
                savePolicy: .changedKeys,
                atomically: false
            )
            for result in response.saveResults.values {
                _ = try result.get()
            }
            recordStartIndex = endIndex
        }

        var deleteStartIndex = 0
        while deleteStartIndex < recordIDs.count {
            let endIndex = min(deleteStartIndex + batchSize, recordIDs.count)
            let response = try await database.modifyRecords(
                saving: [],
                deleting: Array(recordIDs[deleteStartIndex..<endIndex]),
                savePolicy: .changedKeys,
                atomically: false
            )
            for result in response.deleteResults.values {
                _ = try result.get()
            }
            deleteStartIndex = endIndex
        }
    }

    private static func archivedData(for token: CKServerChangeToken) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
    }

    private static func changeToken(from data: Data?) -> CKServerChangeToken? {
        guard let data else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
    }

    private static func archivedData(for cursor: CKQueryOperation.Cursor) throws -> Data {
        try NSKeyedArchiver.archivedData(withRootObject: cursor, requiringSecureCoding: true)
    }

    private static func queryCursor(from data: Data?) -> CKQueryOperation.Cursor? {
        guard let data else {
            return nil
        }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKQueryOperation.Cursor.self, from: data)
    }

    private static func hasCloudKitEntitlement() -> Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let services = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.developer.icloud-services" as CFString,
                nil
              ) as? [String] else {
            return false
        }
        return services.contains("CloudKit")
    }
}

struct CloudQuotaSampleSyncState: Codable, Equatable, Sendable {
    var zoneChangeTokenData: Data?
    var lastSuccessfulSyncAt: Date?
    var nextAllowedSyncAt: Date?
    var nextAllowedSyncReason: CloudQuotaSampleSyncBackoffReason?
    var lastUploadedSampleCapturedAt: Date?
    var isCaughtUp: Bool
    var lastCleanupAt: Date?
    var legacyDefaultZoneCursorData: Data?
    var lastLegacyDefaultZoneScanAt: Date?
    var legacyDefaultZoneCompletedWindowStartDate: Date?
    var remoteSamplesByRecordName: [String: CloudQuotaSampleRemoteMetadata]

    static let empty = CloudQuotaSampleSyncState(
        zoneChangeTokenData: nil,
        lastSuccessfulSyncAt: nil,
        nextAllowedSyncAt: nil,
        nextAllowedSyncReason: nil,
        lastUploadedSampleCapturedAt: nil,
        isCaughtUp: false,
        lastCleanupAt: nil,
        legacyDefaultZoneCursorData: nil,
        lastLegacyDefaultZoneScanAt: nil,
        legacyDefaultZoneCompletedWindowStartDate: nil,
        remoteSamplesByRecordName: [:]
    )
}

enum CloudQuotaSampleSyncBackoffReason: String, Codable, Equatable, Sendable {
    case rateLimited
    case transientFailure
    case changeTokenReset
}

struct CloudQuotaSampleSyncStateStore: Sendable {
    let fileURL: URL

    static func defaultStore(fileManager: FileManager = .default) -> CloudQuotaSampleSyncStateStore {
        let directoryURL: URL
        if let baseURL = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            directoryURL = baseURL.appendingPathComponent("TokenCoffee", isDirectory: true)
        } else {
            directoryURL = fileManager.temporaryDirectory.appendingPathComponent("TokenCoffee", isDirectory: true)
        }
        return CloudQuotaSampleSyncStateStore(
            fileURL: directoryURL.appendingPathComponent("quota-cloud-sync-state.json")
        )
    }

    func load(fileManager: FileManager = .default) -> CloudQuotaSampleSyncState {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            return .empty
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(CloudQuotaSampleSyncState.self, from: data)) ?? .empty
    }

    func save(_ state: CloudQuotaSampleSyncState, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: [.atomic])
    }
}

struct CloudQuotaSampleRemoteMetadata: Codable, Equatable, Sendable {
    let recordName: String
    let capturedAt: Date?
    let limitId: String?
    let weeklyResetsAt: Date?

    init(recordName: String, sample: QuotaSample?) {
        self.recordName = recordName
        capturedAt = sample?.capturedAt
        limitId = sample?.limitId
        weeklyResetsAt = sample?.weeklyResetsAt
    }
}

private struct CloudQuotaSampleLegacyDefaultZoneResult: Sendable {
    let samples: [QuotaSample]
    let recordIDsToDelete: [CKRecord.ID]
}

struct CloudQuotaSampleCleanupContext: Equatable, Sendable {
    let windowStartDate: Date

    init?(snapshot: RateLimitSnapshot?, now: Date) {
        guard let snapshot,
              let weekly = snapshot.secondary,
              let resetDate = weekly.resetDate else {
            return nil
        }

        let snapshotWindowStart = QuotaHistoryWindow.startDate(resetDate: resetDate)
        let rollingSafetyStart = now.addingTimeInterval(-7 * 24 * 60 * 60)
        windowStartDate = min(snapshotWindowStart, rollingSafetyStart)
        guard snapshotWindowStart <= now else {
            return nil
        }
    }

    init(windowStartDate: Date) {
        self.windowStartDate = windowStartDate
    }
}

enum CloudQuotaSampleSyncPolicy {
    private static let normalSyncInterval: TimeInterval = 15 * 60
    private static let catchUpSyncInterval: TimeInterval = 5 * 60
    private static let cleanupInterval: TimeInterval = 15 * 60
    private static let cleanupCatchUpInterval: TimeInterval = 2 * 60
    private static let transientRetryInterval: TimeInterval = 5 * 60

    static func shouldRunSync(
        state: CloudQuotaSampleSyncState,
        cleanupContext: CloudQuotaSampleCleanupContext? = nil,
        now: Date
    ) -> Bool {
        guard let lastSuccessfulSyncAt = state.lastSuccessfulSyncAt else {
            return true
        }
        let interval = syncInterval(state: state, cleanupContext: cleanupContext)
        return now.timeIntervalSince(lastSuccessfulSyncAt) >= interval
    }

    static func shouldRunCleanup(
        state: CloudQuotaSampleSyncState,
        context: CloudQuotaSampleCleanupContext,
        now: Date
    ) -> Bool {
        guard state.isCaughtUp,
              state.nextAllowedSyncAt.map({ $0 > now }) != true else {
            return false
        }
        guard hasPendingCustomZoneCleanup(state: state, context: context) else {
            return false
        }
        guard let lastCleanupAt = state.lastCleanupAt else {
            return true
        }
        return now.timeIntervalSince(lastCleanupAt) >= cleanupCatchUpInterval
    }

    static func shouldRunLegacyDefaultZoneScan(
        state: CloudQuotaSampleSyncState,
        context: CloudQuotaSampleCleanupContext,
        now: Date
    ) -> Bool {
        guard state.isCaughtUp,
              state.nextAllowedSyncAt.map({ $0 > now }) != true else {
            return false
        }
        if state.legacyDefaultZoneCursorData == nil,
           state.legacyDefaultZoneCompletedWindowStartDate == context.windowStartDate {
            return false
        }
        guard let lastLegacyDefaultZoneScanAt = state.lastLegacyDefaultZoneScanAt else {
            return true
        }
        return now.timeIntervalSince(lastLegacyDefaultZoneScanAt) >= cleanupCatchUpInterval
    }

    private static func syncInterval(
        state: CloudQuotaSampleSyncState,
        cleanupContext: CloudQuotaSampleCleanupContext?
    ) -> TimeInterval {
        guard state.isCaughtUp else {
            return catchUpSyncInterval
        }
        if let cleanupContext,
           hasPendingCleanupWork(state: state, context: cleanupContext) {
            return cleanupCatchUpInterval
        }
        return normalSyncInterval
    }

    private static func hasPendingCleanupWork(
        state: CloudQuotaSampleSyncState,
        context: CloudQuotaSampleCleanupContext
    ) -> Bool {
        hasPendingCustomZoneCleanup(state: state, context: context)
            || state.legacyDefaultZoneCursorData != nil
            || state.legacyDefaultZoneCompletedWindowStartDate != context.windowStartDate
    }

    private static func hasPendingCustomZoneCleanup(
        state: CloudQuotaSampleSyncState,
        context: CloudQuotaSampleCleanupContext
    ) -> Bool {
        state.remoteSamplesByRecordName.values.contains {
            isCleanupCandidate($0, context: context)
        }
    }

    static func initialUploadWatermark(existing: Date?, localSamples: [QuotaSample]) -> Date? {
        if let existing {
            return existing
        }
        return localSamples.map(\.capturedAt).max()
    }

    static func samplesToUpload(
        localSamples: [QuotaSample],
        remoteRecordNames: Set<String>,
        uploadWatermark: Date?,
        windowStartDate: Date? = nil,
        limit: Int = .max
    ) -> [QuotaSample] {
        guard let uploadWatermark else {
            return []
        }
        let missingSamples = localSamples
            .filter { sample in
                windowStartDate.map { sample.capturedAt >= $0 } ?? true
            }
            .filter { remoteRecordNames.contains($0.syncRecordName) == false }
        let newSamples = missingSamples
            .filter { $0.capturedAt > uploadWatermark }
            .sorted { $0.capturedAt < $1.capturedAt }
        let recoverySamples = missingSamples
            .filter { $0.capturedAt <= uploadWatermark }
            .sorted { $0.capturedAt > $1.capturedAt }
        return Array((newSamples + recoverySamples).prefix(max(0, limit)))
    }

    static func markUploaded(_ samples: [QuotaSample], in state: inout CloudQuotaSampleSyncState) {
        guard samples.isEmpty == false else {
            return
        }
        for sample in samples {
            state.remoteSamplesByRecordName[sample.syncRecordName] = CloudQuotaSampleRemoteMetadata(
                recordName: sample.syncRecordName,
                sample: sample
            )
        }
        let newestUploaded = samples.map(\.capturedAt).max()
        if let newestUploaded,
           state.lastUploadedSampleCapturedAt.map({ newestUploaded > $0 }) != false {
            state.lastUploadedSampleCapturedAt = newestUploaded
        }
    }

    static func cleanupCandidateRecordNames(
        remoteSamplesByRecordName: [String: CloudQuotaSampleRemoteMetadata],
        context: CloudQuotaSampleCleanupContext,
        limit: Int
    ) -> [String] {
        remoteSamplesByRecordName.values
            .filter { isCleanupCandidate($0, context: context) }
            .sorted {
                switch ($0.capturedAt, $1.capturedAt) {
                case let (lhs?, rhs?):
                    if lhs == rhs {
                        return $0.recordName < $1.recordName
                    }
                    return lhs < rhs
                case (nil, nil):
                    return $0.recordName < $1.recordName
                case (nil, _?):
                    return true
                case (_?, nil):
                    return false
                }
            }
            .prefix(max(0, limit))
            .map(\.recordName)
    }

    static func isCleanupCandidate(
        _ metadata: CloudQuotaSampleRemoteMetadata,
        context: CloudQuotaSampleCleanupContext
    ) -> Bool {
        guard let capturedAt = metadata.capturedAt else {
            return false
        }
        return capturedAt < context.windowStartDate
    }

    static func markDeleted(
        _ recordNames: [String],
        at date: Date,
        in state: inout CloudQuotaSampleSyncState
    ) {
        for recordName in recordNames {
            state.remoteSamplesByRecordName.removeValue(forKey: recordName)
        }
        if recordNames.isEmpty == false {
            state.lastCleanupAt = date
        }
    }

    static func apply(error: Error, now: Date, to state: inout CloudQuotaSampleSyncState) {
        if error.isCloudKitChangeTokenExpired {
            state.zoneChangeTokenData = nil
            state.remoteSamplesByRecordName = [:]
            state.isCaughtUp = false
            state.nextAllowedSyncAt = now.addingTimeInterval(catchUpSyncInterval)
            state.nextAllowedSyncReason = .changeTokenReset
            return
        }

        if let retryAt = retryDate(for: error, now: now) {
            state.nextAllowedSyncAt = retryAt
            state.nextAllowedSyncReason = error.isCloudKitRequestRateLimited ? .rateLimited : .transientFailure
        } else if error.isCloudKitTransient {
            state.nextAllowedSyncAt = now.addingTimeInterval(transientRetryInterval)
            state.nextAllowedSyncReason = .transientFailure
        } else {
            state.nextAllowedSyncAt = nil
            state.nextAllowedSyncReason = nil
        }
    }

    static func retryDate(for error: Error, now: Date) -> Date? {
        let nsError = error as NSError
        guard nsError.domain == CKError.errorDomain else {
            return nil
        }
        if let seconds = nsError.userInfo[CKErrorRetryAfterKey] as? TimeInterval {
            return now.addingTimeInterval(max(1, seconds))
        }
        if let seconds = nsError.userInfo[CKErrorRetryAfterKey] as? NSNumber {
            return now.addingTimeInterval(max(1, seconds.doubleValue))
        }
        guard let code = CKError.Code(rawValue: nsError.code),
              code == .requestRateLimited else {
            return nil
        }
        return now.addingTimeInterval(transientRetryInterval)
    }

    static func status(for state: CloudQuotaSampleSyncState, now: Date) -> QuotaSyncStatus {
        if let retryAt = state.nextAllowedSyncAt,
           retryAt > now {
            switch state.nextAllowedSyncReason {
            case .rateLimited:
                return .rateLimited(retryAt)
            case .changeTokenReset:
                return .failed("CloudKit sync state reset; retrying")
            case .transientFailure, nil:
                return .failed("CloudKit temporarily unavailable; retrying")
            }
        }
        if state.isCaughtUp == false,
           state.lastSuccessfulSyncAt != nil {
            return .syncing
        }
        if let lastSuccessfulSyncAt = state.lastSuccessfulSyncAt {
            return .synced(lastSuccessfulSyncAt)
        }
        return .syncing
    }

    static func status(for error: Error, state: CloudQuotaSampleSyncState, now: Date) -> QuotaSyncStatus {
        if error.isCloudKitRequestRateLimited {
            return .rateLimited(state.nextAllowedSyncAt)
        }
        if error.isCloudKitChangeTokenExpired {
            return .failed("CloudKit sync state reset; retrying")
        }
        return .failed(error.quotaSyncDescription)
    }
}

private struct CloudQuotaSampleRemoteRecord: Sendable {
    let recordID: CKRecord.ID
    let sample: QuotaSample?

    var recordName: String {
        recordID.recordName
    }
}

private enum CloudQuotaSampleRecord {
    static let recordType = "QuotaSample"
    static let desiredKeys: [CKRecord.FieldKey] = [
        Field.capturedAt,
        Field.limitId,
        Field.limitName,
        Field.weeklyUsedPercent,
        Field.weeklyWindowMinutes,
        Field.weeklyResetsAt,
        Field.fiveHourUsedPercent,
        Field.fiveHourWindowMinutes,
        Field.fiveHourResetsAt,
        Field.planType,
        Field.rateLimitReachedType
    ]

    enum Field {
        static let capturedAt = "capturedAt"
        static let limitId = "limitId"
        static let limitName = "limitName"
        static let weeklyUsedPercent = "weeklyUsedPercent"
        static let weeklyWindowMinutes = "weeklyWindowMinutes"
        static let weeklyResetsAt = "weeklyResetsAt"
        static let fiveHourUsedPercent = "fiveHourUsedPercent"
        static let fiveHourWindowMinutes = "fiveHourWindowMinutes"
        static let fiveHourResetsAt = "fiveHourResetsAt"
        static let planType = "planType"
        static let rateLimitReachedType = "rateLimitReachedType"
    }

    static func record(from sample: QuotaSample, zoneID: CKRecordZone.ID) -> CKRecord {
        let recordID = CKRecord.ID(recordName: sample.syncRecordName, zoneID: zoneID)
        let record = CKRecord(recordType: recordType, recordID: recordID)
        record[Field.capturedAt] = sample.capturedAt
        record[Field.limitId] = sample.limitId
        record[Field.limitName] = sample.limitName
        record[Field.weeklyUsedPercent] = sample.weeklyUsedPercent
        record[Field.weeklyWindowMinutes] = sample.weeklyWindowMinutes
        record[Field.weeklyResetsAt] = sample.weeklyResetsAt
        record[Field.fiveHourUsedPercent] = sample.fiveHourUsedPercent
        record[Field.fiveHourWindowMinutes] = sample.fiveHourWindowMinutes
        record[Field.fiveHourResetsAt] = sample.fiveHourResetsAt
        record[Field.planType] = sample.planType
        record[Field.rateLimitReachedType] = sample.rateLimitReachedType
        return record
    }

    static func sample(from record: CKRecord) -> QuotaSample? {
        let capturedAt: Date? = record[Field.capturedAt]
        let limitId: String? = record[Field.limitId]
        let weeklyUsedPercent: Double? = record[Field.weeklyUsedPercent]
        guard let capturedAt,
              let limitId,
              let weeklyUsedPercent else {
            return nil
        }

        return QuotaSample(
            capturedAt: capturedAt,
            limitId: limitId,
            limitName: record[Field.limitName],
            weeklyUsedPercent: weeklyUsedPercent,
            weeklyWindowMinutes: record[Field.weeklyWindowMinutes],
            weeklyResetsAt: record[Field.weeklyResetsAt],
            fiveHourUsedPercent: record[Field.fiveHourUsedPercent],
            fiveHourWindowMinutes: record[Field.fiveHourWindowMinutes],
            fiveHourResetsAt: record[Field.fiveHourResetsAt],
            planType: record[Field.planType],
            rateLimitReachedType: record[Field.rateLimitReachedType]
        )
    }
}

private extension CKAccountStatus {
    var quotaSyncDescription: String {
        switch self {
        case .available:
            "available"
        case .couldNotDetermine:
            "iCloud unavailable"
        case .noAccount:
            "no iCloud account"
        case .restricted:
            "iCloud restricted"
        case .temporarilyUnavailable:
            "iCloud temporarily unavailable"
        @unknown default:
            "iCloud unavailable"
        }
    }
}

private extension Error {
    var isCloudKitRequestRateLimited: Bool {
        let nsError = self as NSError
        return nsError.domain == CKError.errorDomain
            && CKError.Code(rawValue: nsError.code) == .requestRateLimited
    }

    var isCloudKitChangeTokenExpired: Bool {
        let nsError = self as NSError
        return nsError.domain == CKError.errorDomain
            && CKError.Code(rawValue: nsError.code) == .changeTokenExpired
    }

    var isCloudKitZoneNotFound: Bool {
        let nsError = self as NSError
        return nsError.domain == CKError.errorDomain
            && CKError.Code(rawValue: nsError.code) == .zoneNotFound
    }

    var isCloudKitTransient: Bool {
        let nsError = self as NSError
        guard nsError.domain == CKError.errorDomain,
              let ckError = CKError.Code(rawValue: nsError.code) else {
            return false
        }
        switch ckError {
        case .networkUnavailable, .networkFailure, .serviceUnavailable, .requestRateLimited:
            return true
        default:
            return false
        }
    }

    var quotaSyncDescription: String {
        let nsError = self as NSError
        if nsError.domain == CKError.errorDomain,
           let ckError = CKError.Code(rawValue: nsError.code) {
            switch ckError {
            case .notAuthenticated:
                return "not signed in to iCloud"
            case .networkUnavailable, .networkFailure, .serviceUnavailable:
                return "CloudKit temporarily unavailable"
            case .requestRateLimited:
                return "CloudKit rate limited"
            case .permissionFailure:
                return "CloudKit permission denied"
            default:
                break
            }
        }
        return localizedDescription
    }
}
