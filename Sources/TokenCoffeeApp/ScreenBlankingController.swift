import AppKit
import CoreGraphics
import TokenCoffeeCore

@MainActor
protocol ScreenBlackoutPresenting: AnyObject {
    var isVisible: Bool { get }

    func show()
    func hide()
    func refreshDisplays()
}

@MainActor
final class ScreenBlankingController: NSObject {
    private let checkInterval: TimeInterval
    private let idleTimeProvider: () -> TimeInterval
    private let presenter: ScreenBlackoutPresenting
    private var timer: Timer?
    private var isEnabled = false
    private var inactivityThreshold: TimeInterval?

    init(
        checkInterval: TimeInterval = 0.25,
        idleTimeProvider: @escaping () -> TimeInterval = {
            CGEventSource.secondsSinceLastEventType(
                .combinedSessionState,
                eventType: CGEventType(rawValue: UInt32.max)!
            )
        },
        presenter: ScreenBlackoutPresenting? = nil
    ) {
        self.checkInterval = checkInterval
        self.idleTimeProvider = idleTimeProvider
        self.presenter = presenter ?? ScreenBlackoutPresenter()
        super.init()
    }

    func setConfiguration(powerMode: PowerSessionMode, blackoutDelay: ScreenBlackoutDelay) {
        inactivityThreshold = blackoutDelay.inactivityThreshold
        let shouldEnable = powerMode == .keepAwakeDisplay && inactivityThreshold != nil

        if isEnabled != shouldEnable {
            setEnabled(shouldEnable)
        } else if shouldEnable {
            checkNow()
        }
    }

    private func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else {
            return
        }

        isEnabled = enabled
        if enabled {
            startMonitoring()
            checkNow()
        } else {
            stopMonitoring()
            presenter.hide()
        }
    }

    func shutdown() {
        isEnabled = false
        stopMonitoring()
        presenter.hide()
    }

    func checkNow() {
        guard isEnabled,
              let inactivityThreshold else {
            presenter.hide()
            return
        }

        if idleTimeProvider() >= inactivityThreshold {
            presenter.show()
        } else {
            presenter.hide()
        }
    }

    private func startMonitoring() {
        guard timer == nil else {
            return
        }

        let timer = Timer(
            timeInterval: checkInterval,
            target: self,
            selector: #selector(checkTimerFired(_:)),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    private func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func checkTimerFired(_ timer: Timer) {
        checkNow()
    }

    @objc private func screenParametersDidChange(_ notification: Notification) {
        presenter.refreshDisplays()
    }
}

@MainActor
final class ScreenBlackoutPresenter: ScreenBlackoutPresenting {
    private(set) var isVisible = false
    private let screensProvider: () -> [NSScreen]
    private let displayBoundsProvider: () -> [CGRect]
    private let moveCursor: (CGPoint) -> CGError
    private var windows: [NSWindow] = []

    init(
        screensProvider: @escaping () -> [NSScreen] = { NSScreen.screens },
        displayBoundsProvider: @escaping () -> [CGRect] = {
            ScreenBlackoutPresenter.activeDisplayBounds()
        },
        moveCursor: @escaping (CGPoint) -> CGError = { point in
            CGWarpMouseCursorPosition(point)
        }
    ) {
        self.screensProvider = screensProvider
        self.displayBoundsProvider = displayBoundsProvider
        self.moveCursor = moveCursor
    }

    func show() {
        guard !isVisible else {
            return
        }

        moveCursorToBottomRightOfRightmostDisplay()
        isVisible = true
        rebuildWindows()
    }

    func hide() {
        guard isVisible else {
            return
        }

        isVisible = false
        removeWindows()
    }

    func refreshDisplays() {
        guard isVisible else {
            return
        }

        rebuildWindows()
    }

    private func rebuildWindows() {
        removeWindows()
        windows = screensProvider().map(makeWindow(for:))
        windows.forEach { $0.orderFrontRegardless() }
    }

    private func moveCursorToBottomRightOfRightmostDisplay() {
        guard let rightmostBounds = displayBoundsProvider().max(by: { $0.maxX < $1.maxX }) else {
            NSLog("Token Coffee could not move the cursor because macOS reported no active displays.")
            return
        }

        let bottomRight = CGPoint(
            x: rightmostBounds.maxX - 1,
            y: rightmostBounds.maxY - 1
        )
        let cursorResult = moveCursor(bottomRight)
        if cursorResult != .success {
            NSLog("Token Coffee could not move the cursor, CoreGraphics error \(cursorResult.rawValue).")
        }
    }

    nonisolated private static func activeDisplayBounds() -> [CGRect] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success,
              displayCount > 0 else {
            return []
        }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount) == .success else {
            return []
        }

        return displayIDs.prefix(Int(displayCount)).map(CGDisplayBounds)
    }

    private func removeWindows() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }

    private func makeWindow(for screen: NSScreen) -> NSWindow {
        let window = ScreenBlackoutWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.setFrame(screen.frame, display: false)
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.hidesOnDeactivate = false
        window.animationBehavior = .none
        window.level = .screenSaver
        window.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let blackoutView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        blackoutView.wantsLayer = true
        blackoutView.layer?.backgroundColor = NSColor.black.cgColor
        window.contentView = blackoutView
        return window
    }
}

private final class ScreenBlackoutWindow: NSWindow {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
