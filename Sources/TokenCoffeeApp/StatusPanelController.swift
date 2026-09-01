import AppKit
import Combine
import SwiftUI
import TokenCoffeeCore

private enum StatusPanelAction {
    case open
    case focus
    case close
}

@MainActor
final class StatusPanelController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let panel: NSPanel
    private var cancellables: Set<AnyCancellable> = []
    private var shouldIgnoreNextExpandedInterfaceEnd = false
    private var pendingExpandedInterfaceAction: StatusPanelAction?
    private var panelWasFocused = false
    private var ignoreStatusItemActionUntil: Date?

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.panel = PersistentPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 272),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        super.init()

        if let button = statusItem.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            updateStatusIcon(for: model.powerMode)
            button.target = self
            button.action = #selector(togglePanel)
            installExpandedInterfaceDelegateIfAvailable()
        }

        model.$powerMode
            .dropFirst()
            .sink { [weak self] mode in
                Task { @MainActor [weak self] in
                    self?.updateStatusIcon(for: mode)
                }
            }
            .store(in: &cancellables)

        panel.delegate = self
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: DashboardView(
            model: model,
            closeWindow: { [weak self] in
                self?.closePanel()
            },
            showAbout: {
                Self.showAboutPanel()
            }
        ))
    }

    @objc private func togglePanel() {
        if shouldIgnoreStatusItemAction() {
            return
        }

        togglePanelFromStatusItem()

        if let expandedInterfaceSession = currentExpandedInterfaceSession() {
            cancelExpandedInterfaceSession(expandedInterfaceSession)
        }
    }

    private func togglePanelFromStatusItem() {
        performPanelAction(panelActionForStatusItem())
    }

    private func panelActionForStatusItem() -> StatusPanelAction {
        guard panel.isVisible else {
            return .open
        }
        return panelWasFocused ? .close : .focus
    }

    private func performPanelAction(_ action: StatusPanelAction) {
        switch action {
        case .open:
            openPanel()
        case .focus:
            focusPanel()
        case .close:
            closePanelWithoutCancellingStatusItem()
        }
    }

    func windowWillClose(_ notification: Notification) {
        panelWasFocused = false
        model.setPanelVisible(false)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        panelWasFocused = true
    }

    func windowDidResignKey(_ notification: Notification) {
        if isStatusItemInteractionInProgress {
            return
        }
        panelWasFocused = false
    }

    private var isStatusItemInteractionInProgress: Bool {
        guard let button = statusItem.button else {
            return false
        }
        if button.isHighlighted {
            return true
        }
        if NSEvent.pressedMouseButtons & 1 != 0,
           let buttonWindow = button.window {
            let buttonFrameInWindow = button.convert(button.bounds, to: nil)
            let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
            if buttonFrameOnScreen.contains(NSEvent.mouseLocation) {
                return true
            }
        }
        return false
    }

    private func closePanel() {
        if let expandedInterfaceSession = currentExpandedInterfaceSession() {
            cancelExpandedInterfaceSession(expandedInterfaceSession)
        }

        closePanelWithoutCancellingStatusItem()
    }

    private func openPanel() {
        positionPanel()
        focusPanel()
        model.setPanelVisible(true)
    }

    private func focusPanel() {
        panelWasFocused = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closePanelWithoutCancellingStatusItem() {
        panelWasFocused = false
        panel.orderOut(nil)
        model.setPanelVisible(false)
    }

    private func installExpandedInterfaceDelegateIfAvailable() {
        let selector = NSSelectorFromString("setExpandedInterfaceDelegate:")
        guard statusItem.responds(to: selector) else {
            return
        }

        statusItem.setValue(self, forKey: "expandedInterfaceDelegate")
    }

    private func currentExpandedInterfaceSession() -> NSObject? {
        let selector = NSSelectorFromString("expandedInterfaceSession")
        guard statusItem.responds(to: selector) else {
            return nil
        }

        return statusItem.value(forKey: "expandedInterfaceSession") as? NSObject
    }

    private func cancelExpandedInterfaceSession(_ expandedInterfaceSession: NSObject) {
        shouldIgnoreNextExpandedInterfaceEnd = true
        let selector = NSSelectorFromString("cancel")
        if expandedInterfaceSession.responds(to: selector) {
            _ = expandedInterfaceSession.perform(selector)
        }
        clearStatusItemHighlight()
        DispatchQueue.main.async { [weak self] in
            self?.clearStatusItemHighlight()
        }
    }

    private func clearStatusItemHighlight() {
        statusItem.button?.highlight(false)
    }

    private func suppressStatusItemActionFallback() {
        let deadline = Date().addingTimeInterval(0.25)
        ignoreStatusItemActionUntil = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard self?.ignoreStatusItemActionUntil == deadline else {
                return
            }
            self?.ignoreStatusItemActionUntil = nil
        }
    }

    private func shouldIgnoreStatusItemAction() -> Bool {
        guard let deadline = ignoreStatusItemActionUntil else {
            return false
        }

        if Date() < deadline {
            return true
        }

        ignoreStatusItemActionUntil = nil
        return false
    }

    private static func showAboutPanel() {
        let options: [NSApplication.AboutPanelOptionKey: Any] = [
            .credits: aboutCredits()
        ]

        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    private static func aboutCredits() -> NSAttributedString {
        let text = NSMutableAttributedString()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let baseAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraphStyle
        ]

        append(
            "Token Coffee is an independent utility for viewing Codex quota status.\n",
            to: text,
            attributes: baseAttributes
        )
        append(
            "Copyright Andreas Pardeike\n",
            to: text,
            attributes: baseAttributes
        )
        append(
            "Codex is not a product of Andreas Pardeike.\n\n",
            to: text,
            attributes: baseAttributes
        )
        append("Support: ", to: text, attributes: baseAttributes)
        append(
            "https://github.com/pardeike/TokenCoffee/blob/main/SUPPORT.md\n\n",
            to: text,
            attributes: linkAttributes(
                url: URL(string: "https://github.com/pardeike/TokenCoffee/blob/main/SUPPORT.md")!,
                baseAttributes: baseAttributes
            )
        )
        append("Privacy Policy: ", to: text, attributes: baseAttributes)
        append(
            "https://github.com/pardeike/TokenCoffee/blob/main/PRIVACY.md",
            to: text,
            attributes: linkAttributes(
                url: URL(string: "https://github.com/pardeike/TokenCoffee/blob/main/PRIVACY.md")!,
                baseAttributes: baseAttributes
            )
        )

        return text
    }

    private static func append(
        _ string: String,
        to text: NSMutableAttributedString,
        attributes: [NSAttributedString.Key: Any]
    ) {
        text.append(NSAttributedString(string: string, attributes: attributes))
    }

    private static func linkAttributes(
        url: URL,
        baseAttributes: [NSAttributedString.Key: Any]
    ) -> [NSAttributedString.Key: Any] {
        var attributes = baseAttributes
        attributes[.link] = url
        attributes[.foregroundColor] = NSColor.linkColor
        attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        return attributes
    }

    private func positionPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else {
            panel.center()
            return
        }

        let buttonFrameInWindow = button.convert(button.bounds, to: nil)
        let buttonFrameOnScreen = buttonWindow.convertToScreen(buttonFrameInWindow)
        let panelSize = panel.frame.size
        let visibleFrame = screen.visibleFrame
        let proposedX = buttonFrameOnScreen.midX - panelSize.width / 2
        let x = min(max(proposedX, visibleFrame.minX + 8), visibleFrame.maxX - panelSize.width - 8)
        let y = buttonFrameOnScreen.minY - panelSize.height - 8
        panel.setFrameOrigin(NSPoint(x: x, y: max(y, visibleFrame.minY + 8)))
    }

    private func updateStatusIcon(for mode: PowerSessionMode) {
        guard let button = statusItem.button else {
            return
        }

        let isActive = mode != .off
        button.title = ""
        button.image = StatusItemIcon.makeImage(isActive: isActive)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = isActive ? "Keeping awake" : "Idle"
    }
}

extension StatusPanelController {
    @objc(statusItem:didBeginExpandedInterfaceSession:)
    func statusItem(
        _ statusItem: NSStatusItem,
        didBeginExpandedInterfaceSession expandedInterfaceSession: NSObject
    ) {
        suppressStatusItemActionFallback()
        pendingExpandedInterfaceAction = panelActionForStatusItem()
        cancelExpandedInterfaceSession(expandedInterfaceSession)
    }

    @objc(statusItemDidEndExpandedInterfaceSession:animated:)
    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        if shouldIgnoreNextExpandedInterfaceEnd {
            shouldIgnoreNextExpandedInterfaceEnd = false
            if let action = pendingExpandedInterfaceAction {
                pendingExpandedInterfaceAction = nil
                DispatchQueue.main.async { [weak self] in
                    self?.performPanelAction(action)
                }
            }
            return
        }

        pendingExpandedInterfaceAction = nil
        closePanelWithoutCancellingStatusItem()
    }
}

private enum StatusItemIcon {
    private static let imageSize = NSSize(width: 22, height: 18)

    static func makeImage(isActive: Bool) -> NSImage {
        let imageName = isActive ? "StatusIconOn" : "StatusIconOff"
        if let source = NSImage(named: NSImage.Name(imageName)),
           let image = source.copy() as? NSImage {
            image.isTemplate = true
            image.size = imageSize
            return image
        }

        if let fallback = NSImage(
            systemSymbolName: isActive ? "cup.and.saucer.fill" : "cup.and.saucer",
            accessibilityDescription: nil
        ) {
            fallback.isTemplate = true
            fallback.size = imageSize
            return fallback
        }

        let empty = NSImage(size: imageSize)
        empty.isTemplate = true
        return empty
    }
}

private final class PersistentPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
