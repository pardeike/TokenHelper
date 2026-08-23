import Combine
import Foundation
import TokenCoffeeCore

enum CodexSignInState: Equatable {
    case unknown
    case needsSignIn
    case startingSignIn
    case signingIn(CodexDeviceCodeLogin)
    case signedIn(CodexAccountSnapshot?)
    case failed(String)
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var powerMode: PowerSessionMode = .off
    @Published private(set) var screenBlackoutDelay: ScreenBlackoutDelay = .oneMinute
    @Published private(set) var powerErrorMessage: String?
    @Published private(set) var quotaSnapshot: RateLimitSnapshot?
    @Published private(set) var quotaSamples: [QuotaSample] = []
    @Published private(set) var projection = QuotaProjectionEngine.make(snapshot: nil, samples: [])
    @Published private(set) var graphSamples: [QuotaSample] = []
    @Published private(set) var lastQuotaRefresh: Date?
    @Published private(set) var lastQuotaErrorDate: Date?
    @Published private(set) var lastQuotaErrorMessage: String?
    @Published private(set) var isRefreshingQuota = false
    @Published private(set) var quotaSyncStatus: QuotaSyncStatus = .localOnly
    @Published private(set) var codexSignInState: CodexSignInState = .unknown
    @Published private(set) var isDemoModeEnabled = false

    private let powerController: PowerSessionController
    private let quotaClient: CodexRateLimitClient
    private let sampleStore: QuotaSampleStore
    private let sampleSyncService: CloudQuotaSampleSyncService
    private let failSafeInstaller: ClamshellFailSafeInstaller
    private let quotaContinuityGate = QuotaSnapshotContinuityGate()
    private let bundledDemoScenario: DemoQuotaScenario?
    private let startsInDemoMode: Bool
    private var refreshTimer: Timer?
    private var quotaClientEventTask: Task<Void, Never>?
    private var activeCodexLogin: CodexDeviceCodeLogin?
    private var hasStartedLiveRuntime = false
    private var hasInstalledFailSafe = false
    private var liveStateBeforeDemoMode: AppModelLiveState?

    init(
        powerController: PowerSessionController,
        quotaClient: CodexRateLimitClient,
        sampleStore: QuotaSampleStore,
        sampleSyncService: CloudQuotaSampleSyncService,
        failSafeInstaller: ClamshellFailSafeInstaller,
        demoScenario: DemoQuotaScenario? = nil,
        startsInDemoMode: Bool = false
    ) {
        self.powerController = powerController
        self.quotaClient = quotaClient
        self.sampleStore = sampleStore
        self.sampleSyncService = sampleSyncService
        self.failSafeInstaller = failSafeInstaller
        self.bundledDemoScenario = demoScenario
        self.startsInDemoMode = startsInDemoMode && demoScenario != nil
        self.isDemoModeEnabled = self.startsInDemoMode
        self.powerMode = self.startsInDemoMode ? .keepAwakeDisplay : TokenCoffeeDefaults.preferredPowerMode()
        self.screenBlackoutDelay = TokenCoffeeDefaults.preferredScreenBlackoutDelay()
    }

    var referenceDate: Date {
        if isDemoModeEnabled,
           let bundledDemoScenario {
            return bundledDemoScenario.now
        }
        return Date()
    }

    var isCodexLoggedIn: Bool {
        if case .signedIn = codexSignInState {
            return true
        }
        return false
    }

    var canToggleDemoMode: Bool {
        bundledDemoScenario != nil
    }

    var authenticationMenuTitle: String {
        isCodexLoggedIn ? "Log out" : "Log in"
    }

    var canPerformAuthenticationMenuAction: Bool {
        !codexSignInState.isLoginFlowActive
    }

    func start() {
        TokenCoffeeDefaults.setClosedDisplayModeEnabled(false)
        if isDemoModeEnabled,
           let bundledDemoScenario {
            applyDemoScenario(bundledDemoScenario)
            return
        }

        startLiveRuntime()
    }

    private func startLiveRuntime() {
        guard !hasStartedLiveRuntime else {
            return
        }

        hasStartedLiveRuntime = true
        if powerMode != .off {
            applyPowerConfiguration()
        }
        startQuotaClientEvents()
        let loadedSamples = (try? sampleStore.load()) ?? []
        quotaSamples = QuotaSampleStore.compactedSamples(
            QuotaSnapshotContinuityPolicy.repairedSamples(loadedSamples)
        )
        if quotaSamples != loadedSamples {
            try? sampleStore.write(quotaSamples)
        }
        let bootstrap = QuotaSnapshotContinuityPolicy.bootstrap(from: quotaSamples)
        quotaContinuityGate.reset(
            trustedSnapshot: bootstrap?.snapshot,
            isCorroborated: bootstrap?.isCorroborated ?? false
        )
        quotaSnapshot = bootstrap?.snapshot
        updateDerivedQuotaDisplay()
        refreshQuota()
        scheduleRefreshTimer()
    }

    func shutdown() {
        refreshTimer?.invalidate()
        quotaClientEventTask?.cancel()
        try? powerController.apply(mode: .off)
        TokenCoffeeDefaults.setClosedDisplayModeEnabled(false)
        let quotaClient = quotaClient
        Task {
            await quotaClient.stop()
        }
    }

    func setPanelVisible(_ visible: Bool) {
        if visible, !isDemoModeEnabled, shouldRefreshQuotaOnPanelOpen(now: Date()) {
            refreshQuota()
        }
    }

    func setPowerMode(_ mode: PowerSessionMode) {
        if startsInDemoMode && isDemoModeEnabled {
            powerMode = .keepAwakeDisplay
            return
        }

        guard powerMode != mode else {
            return
        }
        powerMode = mode
        TokenCoffeeDefaults.setPreferredPowerMode(mode)
        applyPowerConfiguration()
    }

    func setScreenBlackoutDelay(_ delay: ScreenBlackoutDelay) {
        guard screenBlackoutDelay != delay else {
            return
        }
        screenBlackoutDelay = delay
        TokenCoffeeDefaults.setPreferredScreenBlackoutDelay(delay)
    }

    func refreshQuota() {
        guard !isDemoModeEnabled else {
            return
        }
        guard !isRefreshingQuota else {
            return
        }

        isRefreshingQuota = true
        let client = quotaClient
        let store = sampleStore
        let syncService = sampleSyncService
        let continuityGate = quotaContinuityGate

        Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                await Self.fetchQuotaSnapshot(
                    client: client,
                    store: store,
                    syncService: syncService,
                    continuityGate: continuityGate
                )
            }.value

            guard let self else {
                return
            }
            guard !self.isDemoModeEnabled else {
                return
            }

            self.isRefreshingQuota = false
            switch result {
            case let .success(.updated(fetchResult)):
                self.quotaSnapshot = fetchResult.snapshot
                self.quotaSamples = fetchResult.samples
                self.projection = fetchResult.derivedDisplay.projection
                self.graphSamples = fetchResult.derivedDisplay.graphSamples
                self.lastQuotaRefresh = fetchResult.capturedAt
                self.lastQuotaErrorDate = nil
                self.lastQuotaErrorMessage = nil
                self.codexSignInState = .signedIn(fetchResult.account)
                self.quotaSyncStatus = fetchResult.syncStatus
            case let .success(.pendingConfirmation(account)):
                self.lastQuotaErrorDate = nil
                self.lastQuotaErrorMessage = nil
                self.codexSignInState = .signedIn(account)
            case let .failure(error):
                if error as? CodexRateLimitClient.ClientError == .needsSignIn {
                    guard !self.codexSignInState.isLoginFlowActive else {
                        return
                    }
                    self.activeCodexLogin = nil
                    self.codexSignInState = .needsSignIn
                    self.lastQuotaErrorDate = nil
                    self.lastQuotaErrorMessage = nil
                } else {
                    self.lastQuotaErrorDate = Date()
                    self.lastQuotaErrorMessage = error.localizedDescription
                }
            }
        }
    }

    func beginCodexSignIn() {
        guard !isDemoModeEnabled else {
            return
        }
        guard !codexSignInState.isLoginFlowActive else {
            return
        }

        let shouldResetBeforeStart = codexSignInState.shouldResetClientBeforeLoginStart
        let previousLogin = activeCodexLogin
        activeCodexLogin = nil
        codexSignInState = .startingSignIn
        lastQuotaErrorDate = nil
        lastQuotaErrorMessage = nil

        let client = quotaClient
        Task { [weak self] in
            if let loginId = previousLogin?.loginId {
                await client.cancelLogin(loginId: loginId)
            }
            if shouldResetBeforeStart {
                await client.stop()
            }

            do {
                let login = try await Self.beginDeviceCodeLoginWithOneRestart(client: client)
                guard let self else {
                    return
                }
                guard !self.isDemoModeEnabled else {
                    return
                }
                self.activeCodexLogin = login
                self.codexSignInState = .signingIn(login)
                self.lastQuotaErrorDate = nil
                self.lastQuotaErrorMessage = nil
            } catch {
                guard let self else {
                    return
                }
                guard !self.isDemoModeEnabled else {
                    return
                }
                let message = Self.loginErrorMessage(for: error)
                if Self.isRestartableLoginStartFailure(error) {
                    await client.stop()
                }
                self.activeCodexLogin = nil
                self.codexSignInState = .failed(message)
                self.lastQuotaErrorDate = Date()
                self.lastQuotaErrorMessage = message
            }
        }
    }

    func cancelCodexSignIn() {
        let stateLoginId: String? = if case let .signingIn(login) = codexSignInState {
            login.loginId
        } else {
            nil
        }
        let loginId = activeCodexLogin?.loginId ?? stateLoginId

        activeCodexLogin = nil
        codexSignInState = .needsSignIn
        let client = quotaClient
        Task {
            await client.cancelLogin(loginId: loginId)
            if loginId == nil {
                await client.stop()
            }
        }
    }

    func logoutCodex() {
        if isDemoModeEnabled {
            disableDemoMode()
            return
        }

        guard isCodexLoggedIn else {
            return
        }

        activeCodexLogin = nil
        quotaContinuityGate.reset(trustedSnapshot: nil)
        quotaSnapshot = nil
        lastQuotaErrorDate = nil
        lastQuotaErrorMessage = nil
        codexSignInState = .needsSignIn

        let client = quotaClient
        Task { [weak self] in
            do {
                try await client.logout()
                await client.stop()
            } catch {
                await client.stop()
                guard let self else {
                    return
                }
                self.lastQuotaErrorDate = Date()
                self.lastQuotaErrorMessage = error.localizedDescription
                self.codexSignInState = .failed(error.localizedDescription)
            }
        }
    }

    func toggleDemoMode() {
        guard let bundledDemoScenario else {
            return
        }

        if isDemoModeEnabled {
            disableDemoMode()
        } else {
            enableDemoMode(bundledDemoScenario)
        }
    }

    func performAuthenticationMenuAction() {
        if isCodexLoggedIn {
            logoutCodex()
        } else {
            beginCodexSignIn()
        }
    }

    func forecastDiagnosticsData() throws -> Data {
        try QuotaForecastDiagnosticExporter.makeDiagnosticsData(
            snapshot: quotaSnapshot,
            samples: quotaSamples,
            now: referenceDate,
            syncStatusDescription: quotaSyncStatus.diagnosticDescription
        )
    }

    private nonisolated static func beginDeviceCodeLoginWithOneRestart(
        client: CodexRateLimitClient
    ) async throws -> CodexDeviceCodeLogin {
        do {
            return try await client.beginDeviceCodeLogin()
        } catch {
            guard isRestartableLoginStartFailure(error) else {
                throw error
            }
            await client.stop()
            return try await client.beginDeviceCodeLogin()
        }
    }

    private nonisolated static func isRestartableLoginStartFailure(_ error: Error) -> Bool {
        error.localizedDescription.localizedCaseInsensitiveContains("Login was not completed")
    }

    private nonisolated static func loginErrorMessage(for error: Error) -> String {
        if isRestartableLoginStartFailure(error) {
            return "Previous Codex sign-in was not completed. Try signing in again."
        }
        return error.localizedDescription
    }

    private nonisolated static func fetchQuotaSnapshot(
        client: CodexRateLimitClient,
        store: QuotaSampleStore,
        syncService: CloudQuotaSampleSyncService,
        continuityGate: QuotaSnapshotContinuityGate
    ) async -> Result<QuotaFetchOutcome, Error> {
        do {
            let fetchResult = try await client.fetch()
            let response = fetchResult.response
            let capturedAt = Date()
            let decision = continuityGate.evaluate(response.codexSnapshot, capturedAt: capturedAt)
            guard case let .accepted(observations) = decision,
                  let snapshot = observations.last?.snapshot else {
                return .success(.pendingConfirmation(fetchResult.account))
            }

            var samples = (try? store.load()) ?? []
            let acceptedSamples = observations.compactMap {
                QuotaSample(snapshot: $0.snapshot, capturedAt: $0.capturedAt)
            }
            if acceptedSamples.isEmpty == false {
                // Continuity confirmation needs the complete observation run.
                // CloudQuotaSampleSyncService validates all ingress boundaries
                // before compacting the trusted result for persistence.
                samples = QuotaSampleStore.mergedSamples(samples + acceptedSamples)
            }

            let syncOutcome = await syncService.sync(localSamples: samples, currentSnapshot: snapshot)
            // The sync service owns the CloudKit ingress trust boundary and
            // returns a continuity-repaired, compacted result. Revalidating that
            // compacted result would discard the evidence that confirmed a reset.
            let persistedSamples = syncOutcome.samples
            try? store.write(persistedSamples)
            let derivedDisplay = makeDerivedQuotaDisplay(
                snapshot: snapshot,
                samples: persistedSamples,
                now: capturedAt
            )
            return .success(.updated(QuotaFetchResult(
                snapshot: snapshot,
                samples: persistedSamples,
                derivedDisplay: derivedDisplay,
                capturedAt: capturedAt,
                account: fetchResult.account,
                syncStatus: syncOutcome.status
            )))
        } catch {
            return .failure(error)
        }
    }

    private func applyPowerConfiguration() {
        do {
            if powerMode != .off {
                installFailSafeIfPossible()
            }
            try powerController.apply(mode: powerMode)
            powerErrorMessage = nil
        } catch {
            powerErrorMessage = error.localizedDescription
        }
    }

    private func installFailSafeIfPossible() {
        guard !hasInstalledFailSafe,
              let executableURL = Bundle.main.executableURL else {
            return
        }

        do {
            try failSafeInstaller.install(bundleExecutableURL: executableURL)
            hasInstalledFailSafe = true
        } catch {
            NSLog("Token Coffee could not install clamshell fail-safe: \(error.localizedDescription)")
        }
    }

    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let interval: TimeInterval = 60
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshQuota()
            }
        }
        refreshTimer?.tolerance = min(30, interval / 4)
    }

    private func shouldRefreshQuotaOnPanelOpen(now: Date) -> Bool {
        guard !isRefreshingQuota else {
            return false
        }
        guard let lastQuotaRefresh else {
            return true
        }
        return now.timeIntervalSince(lastQuotaRefresh) >= Self.panelOpenRefreshMinimumAge
    }

    private func updateDerivedQuotaDisplay(now: Date? = nil) {
        let derivedDisplay = Self.makeDerivedQuotaDisplay(
            snapshot: quotaSnapshot,
            samples: quotaSamples,
            now: now ?? referenceDate
        )
        projection = derivedDisplay.projection
        graphSamples = derivedDisplay.graphSamples
    }

    private nonisolated static func makeDerivedQuotaDisplay(
        snapshot: RateLimitSnapshot?,
        samples: [QuotaSample],
        now: Date
    ) -> QuotaDerivedDisplay {
        QuotaDerivedDisplay(
            projection: QuotaProjectionEngine.make(snapshot: snapshot, samples: samples, now: now),
            graphSamples: displayGraphSamples(snapshot: snapshot, samples: samples, now: now)
        )
    }

    private nonisolated static func displayGraphSamples(
        snapshot: RateLimitSnapshot?,
        samples: [QuotaSample],
        now: Date
    ) -> [QuotaSample] {
        guard let snapshot,
              let weekly = snapshot.secondary,
              let resetDate = weekly.resetDate else {
            return []
        }

        let startDate = QuotaHistoryWindow.startDate(resetDate: resetDate)
        let limitId = snapshot.limitId ?? "codex"
        let displaySamples = samples
            .filter { $0.limitId == limitId && $0.capturedAt >= startDate && $0.capturedAt <= now }
            .sorted { $0.capturedAt < $1.capturedAt }
        return QuotaGraphDisplaySampler.displaySamples(from: displaySamples)
    }

    private func startQuotaClientEvents() {
        guard quotaClientEventTask == nil else {
            return
        }

        let events = quotaClient.events
        quotaClientEventTask = Task { [weak self] in
            for await event in events {
                self?.handleQuotaClientEvent(event)
            }
        }
    }

    private func handleQuotaClientEvent(_ event: CodexRateLimitEvent) {
        guard !isDemoModeEnabled else {
            return
        }

        switch event {
        case let .accountChanged(account):
            if let account {
                activeCodexLogin = nil
                codexSignInState = .signedIn(account)
            } else if codexSignInState.isLoginFlowActive {
                break
            } else {
                activeCodexLogin = nil
                codexSignInState = .needsSignIn
            }

        case .needsSignIn:
            if codexSignInState.isLoginFlowActive {
                break
            }
            activeCodexLogin = nil
            codexSignInState = .needsSignIn

        case let .loginStarted(login):
            activeCodexLogin = login
            codexSignInState = .signingIn(login)

        case let .loginCompleted(success, errorMessage):
            activeCodexLogin = nil
            if success {
                quotaContinuityGate.reset(trustedSnapshot: nil)
                codexSignInState = .unknown
                refreshQuota()
            } else {
                let message = errorMessage ?? "Codex sign-in failed."
                codexSignInState = .failed(message)
                lastQuotaErrorDate = Date()
                lastQuotaErrorMessage = message
                let client = quotaClient
                Task {
                    await client.stop()
                }
            }

        case .rateLimitsChanged:
            break

        case let .diagnostic(message):
            if lastQuotaErrorDate != nil || quotaSnapshot == nil {
                lastQuotaErrorMessage = message
            }
        }
    }

    private func enableDemoMode(_ scenario: DemoQuotaScenario) {
        liveStateBeforeDemoMode = AppModelLiveState(
            powerErrorMessage: powerErrorMessage,
            quotaSnapshot: quotaSnapshot,
            quotaSamples: quotaSamples,
            projection: projection,
            graphSamples: graphSamples,
            lastQuotaRefresh: lastQuotaRefresh,
            lastQuotaErrorDate: lastQuotaErrorDate,
            lastQuotaErrorMessage: lastQuotaErrorMessage,
            quotaSyncStatus: quotaSyncStatus,
            codexSignInState: codexSignInState,
            activeCodexLogin: activeCodexLogin
        )
        isDemoModeEnabled = true
        applyDemoScenario(scenario, clearsPowerError: false)
    }

    private func disableDemoMode() {
        guard isDemoModeEnabled else {
            return
        }

        isDemoModeEnabled = false

        if let liveStateBeforeDemoMode {
            quotaSnapshot = liveStateBeforeDemoMode.quotaSnapshot
            powerErrorMessage = liveStateBeforeDemoMode.powerErrorMessage
            quotaSamples = liveStateBeforeDemoMode.quotaSamples
            projection = liveStateBeforeDemoMode.projection
            graphSamples = liveStateBeforeDemoMode.graphSamples
            lastQuotaRefresh = liveStateBeforeDemoMode.lastQuotaRefresh
            lastQuotaErrorDate = liveStateBeforeDemoMode.lastQuotaErrorDate
            lastQuotaErrorMessage = liveStateBeforeDemoMode.lastQuotaErrorMessage
            quotaSyncStatus = liveStateBeforeDemoMode.quotaSyncStatus
            codexSignInState = liveStateBeforeDemoMode.codexSignInState
            activeCodexLogin = liveStateBeforeDemoMode.activeCodexLogin
            isRefreshingQuota = false
            self.liveStateBeforeDemoMode = nil
        } else {
            quotaSnapshot = nil
            quotaSamples = (try? sampleStore.load()) ?? []
            updateDerivedQuotaDisplay()
            lastQuotaRefresh = nil
            lastQuotaErrorDate = nil
            lastQuotaErrorMessage = nil
            isRefreshingQuota = false
            quotaSyncStatus = .localOnly
            activeCodexLogin = nil
            codexSignInState = .unknown
        }

        if hasStartedLiveRuntime {
            refreshQuota()
        } else {
            startLiveRuntime()
        }
    }

    private func applyDemoScenario(_ scenario: DemoQuotaScenario, clearsPowerError: Bool = true) {
        if clearsPowerError {
            powerErrorMessage = nil
        }
        quotaSnapshot = scenario.snapshot
        quotaSamples = scenario.samples
        updateDerivedQuotaDisplay(now: scenario.now)
        lastQuotaRefresh = scenario.now
        lastQuotaErrorDate = nil
        lastQuotaErrorMessage = nil
        isRefreshingQuota = false
        quotaSyncStatus = .localOnly
        activeCodexLogin = nil
        codexSignInState = .signedIn(scenario.account)
    }

    private static let panelOpenRefreshMinimumAge: TimeInterval = 30
}

private extension QuotaSyncStatus {
    var diagnosticDescription: String {
        switch self {
        case .localOnly:
            "localOnly"
        case .syncing:
            "syncing"
        case let .synced(date):
            "synced \(date.formatted(.iso8601))"
        case let .rateLimited(date):
            if let date {
                "rateLimited until \(date.formatted(.iso8601))"
            } else {
                "rateLimited"
            }
        case let .unavailable(message):
            "unavailable: \(message)"
        case let .failed(message):
            "failed: \(message)"
        }
    }
}

private struct AppModelLiveState {
    let powerErrorMessage: String?
    let quotaSnapshot: RateLimitSnapshot?
    let quotaSamples: [QuotaSample]
    let projection: QuotaProjection
    let graphSamples: [QuotaSample]
    let lastQuotaRefresh: Date?
    let lastQuotaErrorDate: Date?
    let lastQuotaErrorMessage: String?
    let quotaSyncStatus: QuotaSyncStatus
    let codexSignInState: CodexSignInState
    let activeCodexLogin: CodexDeviceCodeLogin?
}

private enum QuotaFetchOutcome: Sendable {
    case updated(QuotaFetchResult)
    case pendingConfirmation(CodexAccountSnapshot?)
}

private struct QuotaFetchResult: Sendable {
    let snapshot: RateLimitSnapshot
    let samples: [QuotaSample]
    let derivedDisplay: QuotaDerivedDisplay
    let capturedAt: Date
    let account: CodexAccountSnapshot?
    let syncStatus: QuotaSyncStatus
}

final class QuotaSnapshotContinuityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var policy = QuotaSnapshotContinuityPolicy()

    func reset(
        trustedSnapshot: RateLimitSnapshot?,
        isCorroborated: Bool = true
    ) {
        lock.withLock {
            policy.reset(
                trustedSnapshot: trustedSnapshot,
                isCorroborated: isCorroborated
            )
        }
    }

    func evaluate(
        _ snapshot: RateLimitSnapshot,
        capturedAt: Date
    ) -> QuotaSnapshotContinuityDecision {
        lock.withLock {
            policy.evaluate(snapshot, capturedAt: capturedAt)
        }
    }
}

private struct QuotaDerivedDisplay: Sendable {
    let projection: QuotaProjection
    let graphSamples: [QuotaSample]
}

enum QuotaGraphDisplaySampler {
    static let maximumPointCount = 480

    static func displaySamples(
        from samples: [QuotaSample],
        maximumPointCount: Int = maximumPointCount
    ) -> [QuotaSample] {
        guard samples.count > maximumPointCount else {
            return samples
        }
        guard maximumPointCount > 1 else {
            return samples.last.map { [$0] } ?? []
        }

        let lastIndex = samples.count - 1
        let step = Double(lastIndex) / Double(maximumPointCount - 1)
        var sampled: [QuotaSample] = []
        sampled.reserveCapacity(maximumPointCount)

        var previousIndex = -1
        for outputIndex in 0..<maximumPointCount {
            let sourceIndex = min(lastIndex, Int((Double(outputIndex) * step).rounded()))
            guard sourceIndex != previousIndex else {
                continue
            }
            sampled.append(samples[sourceIndex])
            previousIndex = sourceIndex
        }

        if sampled.last != samples[lastIndex] {
            if sampled.count >= maximumPointCount {
                sampled[sampled.count - 1] = samples[lastIndex]
            } else {
                sampled.append(samples[lastIndex])
            }
        }

        return sampled
    }
}

private extension CodexSignInState {
    var isLoginFlowActive: Bool {
        switch self {
        case .startingSignIn, .signingIn:
            return true
        case .unknown, .needsSignIn, .signedIn, .failed:
            return false
        }
    }

    var shouldResetClientBeforeLoginStart: Bool {
        if case .failed = self {
            return true
        }
        return false
    }
}
