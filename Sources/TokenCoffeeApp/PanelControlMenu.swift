import AppKit
import SwiftUI
import TokenCoffeeCore
import UniformTypeIdentifiers

@MainActor
enum PanelControlMenu {
    static func present(
        anchor: NSView,
        event: NSEvent?,
        model: AppModel,
        closeWindow: @escaping () -> Void,
        showAbout: @escaping () -> Void
    ) {
        let modifierFlags = event?.modifierFlags ?? NSEvent.modifierFlags
        let menu = NSMenu()
        menu.autoenablesItems = false

        menu.addItem(actionItem(title: "About") {
            showAbout()
        })
        menu.addItem(.separator())

        menu.addItem(screenBlackoutMenuItem(selectedDelay: model.screenBlackoutDelay) { delay in
            model.setScreenBlackoutDelay(delay)
        })
        menu.addItem(.separator())

        let authenticationItem = actionItem(title: model.authenticationMenuTitle) {
            model.performAuthenticationMenuAction()
        }
        authenticationItem.isEnabled = model.canPerformAuthenticationMenuAction
        menu.addItem(authenticationItem)

        menu.addItem(actionItem(title: "Close Window") {
            closeWindow()
        })
        menu.addItem(actionItem(title: "Quit Token Coffee") {
            NSApp.terminate(nil)
        })

        if modifierFlags.contains(.option) {
            menu.addItem(.separator())
            menu.addItem(actionItem(title: "Export Forecast Diagnostics...") {
                exportForecastDiagnostics(model: model)
            })

            let demoItem = actionItem(title: "TOGGLE DEMO") {
                model.toggleDemoMode()
            }
            demoItem.isEnabled = model.canToggleDemoMode
            menu.addItem(demoItem)
        }

        let popupPoint = NSPoint(x: anchor.bounds.minX, y: anchor.bounds.minY - 4)
        menu.popUp(positioning: nil, at: popupPoint, in: anchor)
    }

    static func screenBlackoutMenuItem(
        selectedDelay: ScreenBlackoutDelay,
        onSelect: @escaping (ScreenBlackoutDelay) -> Void
    ) -> NSMenuItem {
        let item = NSMenuItem(title: "Black out Screen", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Black out Screen")
        submenu.autoenablesItems = false

        for delay in ScreenBlackoutDelay.allCases {
            let option = actionItem(title: menuTitle(for: delay)) {
                onSelect(delay)
            }
            option.state = delay == selectedDelay ? .on : .off
            submenu.addItem(option)
        }

        item.submenu = submenu
        return item
    }

    private static func actionItem(title: String, handler: @escaping () -> Void) -> NSMenuItem {
        ActionMenuItem(title: title, handler: handler)
    }

    private static func menuTitle(for delay: ScreenBlackoutDelay) -> String {
        switch delay {
        case .off:
            "Off"
        case .oneMinute:
            "1min idle"
        case .twoMinutes:
            "2min idle"
        case .fiveMinutes:
            "5min idle"
        case .tenMinutes:
            "10min idle"
        case .oneHour:
            "1h idle"
        }
    }

    private static func exportForecastDiagnostics(model: AppModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "TokenCoffee-ForecastDiagnostics-\(filenameTimestamp()).json"

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }

        do {
            let data = try model.forecastDiagnosticsData()
            try data.write(to: url, options: .atomic)
        } catch {
            showExportError(error)
        }
    }

    private static func filenameTimestamp(date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func showExportError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not export forecast diagnostics."
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

}

private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(
            title: title,
            action: #selector(performAction(_:)),
            keyEquivalent: ""
        )
        target = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        handler()
    }
}

struct PanelMenuButton: NSViewRepresentable {
    let model: AppModel
    let closeWindow: () -> Void
    let showAbout: () -> Void

    func makeNSView(context: Context) -> PanelMenuButtonView {
        PanelMenuButtonView()
    }

    func updateNSView(_ nsView: PanelMenuButtonView, context: Context) {
        nsView.onPress = { buttonView, event in
            PanelControlMenu.present(
                anchor: buttonView,
                event: event,
                model: model,
                closeWindow: closeWindow,
                showAbout: showAbout
            )
        }
    }
}

final class PanelMenuButtonView: NSControl {
    var onPress: (@MainActor (PanelMenuButtonView, NSEvent?) -> Void)?

    private var isHovered = false {
        didSet {
            needsDisplay = true
        }
    }

    private var isPressed = false {
        didSet {
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Menu")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Menu")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 22, height: 22)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self
        ))
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        onPress?(self, event)
        isPressed = false
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?(self, nil)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let fillAlpha = isHovered || isPressed ? 0.12 : 0.08
        NSColor.labelColor.withAlphaComponent(fillAlpha).setFill()
        NSBezierPath(ovalIn: bounds).fill()

        let strokeAlpha = isHovered || isPressed ? 0.54 : 0.38
        NSColor.labelColor.withAlphaComponent(strokeAlpha).setFill()

        let lineWidth: CGFloat = 10
        let lineHeight: CGFloat = 1.8
        let x = bounds.midX - lineWidth / 2
        let offsets: [CGFloat] = [-3.5, 0, 3.5]

        for offset in offsets {
            let y = bounds.midY + offset - lineHeight / 2
            let path = NSBezierPath(
                roundedRect: NSRect(x: x, y: y, width: lineWidth, height: lineHeight),
                xRadius: lineHeight / 2,
                yRadius: lineHeight / 2
            )
            path.fill()
        }
    }
}
