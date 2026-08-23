import AppKit
import Combine
import TokenCoffeeCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var statusPanelController: StatusPanelController?
    private var screenBlankingController: ScreenBlankingController?
    private var screenBlankingCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        guard !Self.isRunningUnitTests else {
            return
        }

        let sampleStore = (try? QuotaSampleStore.defaultStore()) ?? QuotaSampleStore(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("tokencoffee-quota-samples.jsonl")
        )
        let powerController = PowerSessionController()
        let startsInDemoMode = CommandLine.arguments.contains("--demo")
        let demoScenario = Self.bundledDemoScenario(logErrors: startsInDemoMode)
        let model = AppModel(
            powerController: powerController,
            quotaClient: CodexRateLimitClient(),
            sampleStore: sampleStore,
            sampleSyncService: CloudQuotaSampleSyncService(),
            failSafeInstaller: ClamshellFailSafeInstaller(),
            demoScenario: demoScenario,
            startsInDemoMode: startsInDemoMode
        )
        let screenBlankingController = ScreenBlankingController()
        self.model = model
        self.statusPanelController = StatusPanelController(model: model)
        self.screenBlankingController = screenBlankingController
        self.screenBlankingCancellable = Publishers.CombineLatest(
            model.$powerMode,
            model.$screenBlackoutDelay
        )
            .sink { [weak screenBlankingController] configuration in
                let (powerMode, blackoutDelay) = configuration
                Task { @MainActor in
                    screenBlankingController?.setConfiguration(
                        powerMode: powerMode,
                        blackoutDelay: blackoutDelay
                    )
                }
            }
        DispatchQueue.main.async { [weak model] in
            model?.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        screenBlankingCancellable?.cancel()
        screenBlankingController?.shutdown()
        model?.shutdown()
    }

    private static func bundledDemoScenario(logErrors: Bool) -> DemoQuotaScenario? {
        guard let url = Bundle.main.url(forResource: "DemoQuotaData", withExtension: "json") else {
            if logErrors {
                NSLog("Token Coffee demo mode requested, but DemoQuotaData.json is missing.")
            }
            return nil
        }

        do {
            let data = try Data(contentsOf: url)
            let demoData = try JSONDecoder().decode(DemoQuotaData.self, from: data)
            return try demoData.makeScenario()
        } catch {
            if logErrors {
                NSLog("Token Coffee demo mode requested, but demo data could not be loaded: \(error.localizedDescription)")
            }
            return nil
        }
    }

    private static var isRunningUnitTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
