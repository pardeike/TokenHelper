import AppKit
import Charts
import SwiftUI
import TokenCoffeeCore

struct DashboardView: View {
    @ObservedObject var model: AppModel
    let closeWindow: () -> Void
    let showAbout: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var selectedPowerMode: PowerSessionMode = .off

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            powerControls

            if let powerErrorMessage = model.powerErrorMessage {
                Text(powerErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            contentSection
        }
        .padding(EdgeInsets(top: 12, leading: 12, bottom: 4, trailing: 12))
        .frame(width: 480, height: 272, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var powerControls: some View {
        HStack(spacing: 8) {
            Picker("Power", selection: $selectedPowerMode) {
                Text("Off").tag(PowerSessionMode.off)
                Text("Keep Mac awake").tag(PowerSessionMode.keepAwake)
                Text("Keep screen on").tag(PowerSessionMode.keepAwakeDisplay)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .font(.system(size: 12, weight: .semibold))
            .frame(width: 340)
            .onAppear {
                selectedPowerMode = model.powerMode
            }
            .onChange(of: selectedPowerMode) { _, mode in
                guard mode != model.powerMode else {
                    return
                }
                Task { @MainActor in
                    model.setPowerMode(mode)
                }
            }
            .onReceive(model.$powerMode) { mode in
                guard mode != selectedPowerMode else {
                    return
                }
                selectedPowerMode = mode
            }

            Spacer(minLength: 0)

            PanelMenuButton(
                model: model,
                closeWindow: closeWindow,
                showAbout: showAbout
            )
            .frame(width: 22, height: 22)
            .help("Menu")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var contentSection: some View {
        if showsQuotaDashboard {
            quotaSection
        } else {
            codexAuthSection
        }
    }

    private var showsQuotaDashboard: Bool {
        switch model.codexSignInState {
        case .signedIn:
            return true
        case .unknown:
            return model.quotaSnapshot != nil
        case .needsSignIn, .startingSignIn, .signingIn, .failed:
            return false
        }
    }

    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            quotaReadout
            QuotaGraphView(
                samples: model.graphSamples,
                projection: model.projection,
                snapshot: model.quotaSnapshot,
                now: model.referenceDate
            )
            .frame(height: 146)
            .padding(.bottom, 4)
            quotaFooter
        }
    }

    private var quotaReadout: some View {
        let projection = model.projection
        let forecast = projection.cycleRunForecast
        let riskEstimate = forecast?.highProjectedWeeklyUsedPercentAtReset
            ?? projection.projectedWeeklyUsedPercentAtReset
        let readoutColor = riskEstimate.map(estimateColor) ?? paceColor(projection.paceState)
        return HStack(alignment: .lastTextBaseline, spacing: 8) {
            Text(percent(projection.currentWeeklyUsedPercent))
                .font(.system(size: 32, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(readoutColor)

            if let forecast {
                Text("estimate \(percentRange(low: forecast.lowProjectedWeeklyUsedPercentAtReset, high: forecast.highProjectedWeeklyUsedPercentAtReset))")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(estimateColor(forecast.highProjectedWeeklyUsedPercentAtReset))
                    .help("Low/high pattern forecast at renew")
            } else if let estimate = projection.projectedWeeklyUsedPercentAtReset {
                Text("estimate \(percent(estimate))")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(estimateColor(estimate))
                    .help("Fallback forecast at renew")
            }

            Spacer()

            HStack(spacing: 4) {
                Image(systemName: "calendar")
                Text(renewalValue)
            }
            .font(.headline.monospacedDigit())
            .foregroundStyle(.primary)
            .help(model.lastQuotaErrorMessage ?? "Weekly renew date")
        }
    }

    private var quotaFooter: some View {
        HStack(spacing: 10) {
            Label(primaryLegendValue, systemImage: "clock")
                .foregroundStyle(.secondary)
                .help("5h usage and reset time")

            if model.lastQuotaErrorDate != nil, let lastQuotaRefresh = model.lastQuotaRefresh {
                Label("stale \(DateFormatter.panelTime.string(from: lastQuotaRefresh))", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            if model.lastQuotaErrorDate != nil, let errorMessage = model.lastQuotaErrorMessage {
                Label(shortQuotaErrorMessage(errorMessage), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .help(errorMessage)
            }

            let syncStatusValue = syncStatusDisplay
            Label(syncStatusValue.text, systemImage: syncStatusValue.systemImage)
                .foregroundStyle(syncStatusValue.color)
                .help(syncStatusValue.help)

            Spacer(minLength: 0)

            Text(paceText(model.projection.paceState))
                .foregroundStyle(paceColor(model.projection.paceState))
        }
        .font(.caption.monospacedDigit())
        .lineLimit(1)
    }

    @ViewBuilder
    private var codexAuthSection: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 4)

            switch model.codexSignInState {
            case .unknown:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    authHeader(
                        title: "Checking Codex",
                        detail: "Looking for an existing ChatGPT sign-in."
                    )
                }

            case .needsSignIn:
                VStack(spacing: 14) {
                    authHeader(
                        systemImage: "person.crop.circle.badge.plus",
                        title: "Sign in to Codex",
                        detail: "Use your ChatGPT account to read Codex usage limits on this Mac."
                    )

                    Button {
                        model.beginCodexSignIn()
                    } label: {
                        Label("Sign in", systemImage: "arrow.right.circle.fill")
                            .frame(minWidth: 112)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Start ChatGPT device-code sign-in")
                }

            case .startingSignIn:
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    authHeader(
                        title: "Starting Sign-In",
                        detail: "Contacting Codex for a device code."
                    )
                }

            case let .signingIn(login):
                VStack(spacing: 10) {
                    authHeader(
                        systemImage: "keyboard",
                        title: "Token Coffee Device Code",
                        detail: "If ChatGPT asks for an Authenticator code, use your Authenticator app first."
                    )

                    Text(login.userCode ?? "Waiting...")
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                        .help("Codex device code")

                    Text("Enter this code only when the browser asks for a device code.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        Button {
                            if let url = login.verificationURL {
                                openURL(url)
                            }
                        } label: {
                            Label("Open", systemImage: "safari")
                                .frame(minWidth: 82)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(login.verificationURL == nil)
                        .help("Open Codex sign-in page")

                        Button {
                            copyCodexCode(login.userCode)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .frame(minWidth: 76)
                        }
                        .buttonStyle(.bordered)
                        .disabled(login.userCode == nil)
                        .help("Copy device code")

                        Button {
                            model.cancelCodexSignIn()
                        } label: {
                            Label("Cancel", systemImage: "xmark.circle")
                                .frame(minWidth: 82)
                        }
                        .buttonStyle(.bordered)
                        .help("Cancel Codex sign-in")
                    }
                    .controlSize(.regular)
                }

            case .signedIn:
                EmptyView()

            case let .failed(message):
                VStack(spacing: 14) {
                    authHeader(
                        systemImage: "exclamationmark.triangle",
                        title: "Sign-In Failed",
                        detail: shortSignInErrorMessage(message),
                        iconColor: .orange
                    )

                    Button {
                        model.beginCodexSignIn()
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .frame(minWidth: 112)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help(message)
                }
            }

            Spacer(minLength: 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 26)
    }

    private func authHeader(
        systemImage: String? = nil,
        title: String,
        detail: String,
        iconColor: Color = .blue
    ) -> some View {
        VStack(spacing: 7) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 28, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(iconColor)
            }

            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyCodexCode(_ code: String?) {
        guard let code else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    private func shortSignInErrorMessage(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("Login was not completed") {
            return "That sign-in expired before Codex finished it."
        }
        if message.localizedCaseInsensitiveContains("Timed out") {
            return "Codex did not respond in time. Try again."
        }
        if message.count <= 96 {
            return message
        }
        return "\(message.prefix(93))..."
    }

    private var syncStatusDisplay: (text: String, systemImage: String, color: Color, help: String) {
        switch model.quotaSyncStatus {
        case .localOnly:
            ("local", "externaldrive", .secondary, "CloudKit sync is disabled for this build")
        case .syncing:
            ("syncing", "arrow.triangle.2.circlepath", .secondary, "Syncing quota samples with iCloud")
        case let .synced(date):
            (
                "iCloud \(DateFormatter.panelTime.string(from: date))",
                "icloud",
                .secondary,
                "Quota samples synced with iCloud"
            )
        case let .rateLimited(date):
            if let date {
                ("sync paused", "clock", .orange, "CloudKit rate limited; retrying at \(DateFormatter.panelTime.string(from: date))")
            } else {
                ("sync paused", "clock", .orange, "CloudKit rate limited; retrying later")
            }
        case let .unavailable(message):
            ("iCloud off", "icloud.slash", .orange, message)
        case let .failed(message):
            ("sync failed", "exclamationmark.icloud", .orange, message)
        }
    }

    private var renewalValue: String {
        guard let resetDate = model.projection.weeklyResetDate else {
            switch model.codexSignInState {
            case .needsSignIn, .startingSignIn, .signingIn(_):
                return "sign in"
            case .unknown, .signedIn, .failed:
                break
            }
            return model.lastQuotaErrorDate == nil ? "--:--" : "offline"
        }
        return DateFormatter.panelDate.string(from: resetDate)
    }

    private var primaryLegendValue: String {
        guard let primary = model.quotaSnapshot?.primary else {
            return "5h --"
        }
        let reset = primary.resetDate.map { " -> \(DateFormatter.panelTime.string(from: $0))" } ?? ""
        return "5h \(percent(primary.usedPercent))\(reset)"
    }

    private func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }

    private func percentRange(low: Double, high: Double) -> String {
        let lowValue = Int(min(low, high).rounded())
        let highValue = Int(max(low, high).rounded())
        if lowValue == highValue {
            return "\(lowValue)%"
        }
        return "\(lowValue)-\(highValue)%"
    }

    private func paceText(_ state: QuotaPaceState) -> String {
        switch state {
        case .noData:
            "no data"
        case .fine:
            "ok"
        case .watch:
            "careful"
        case .slowDown:
            "slow down"
        }
    }

    private func paceColor(_ state: QuotaPaceState) -> Color {
        switch state {
        case .noData:
            .secondary
        case .fine:
            .green
        case .watch:
            .orange
        case .slowDown:
            .red
        }
    }

    private func estimateColor(_ estimate: Double) -> Color {
        if estimate >= 100 {
            return .red
        }
        if estimate >= 90 {
            return .orange
        }
        return .green
    }

    private func shortQuotaErrorMessage(_ message: String) -> String {
        if message.localizedCaseInsensitiveContains("Timed out") {
            return "Codex timeout"
        }
        if message.localizedCaseInsensitiveContains("process exited") {
            return "Codex exited"
        }
        if message.localizedCaseInsensitiveContains("process is not running") {
            return "Codex stopped"
        }
        if message.count <= 32 {
            return message
        }
        return "\(message.prefix(29))..."
    }
}

private struct QuotaGraphView: View {
    let samples: [QuotaSample]
    let projection: QuotaProjection
    let snapshot: RateLimitSnapshot?
    let now: Date

    var body: some View {
        if let resetDate = projection.weeklyResetDate {
            let startDate = QuotaHistoryWindow.startDate(resetDate: resetDate)
            let dayBands = QuotaGraphTimeAxis.dayBands(startDate: startDate, resetDate: resetDate)
            let plotStartDate = dayBands.first?.startDate ?? startDate
            let plotEndDate = dayBands.last?.endDate ?? resetDate
            Chart {
                ForEach(dayBands) { band in
                    RectangleMark(
                        xStart: .value("Start", band.startDate),
                        xEnd: .value("End", band.endDate),
                        yStart: .value("Low", 0),
                        yEnd: .value("High", graphCeiling)
                    )
                    .foregroundStyle(band.isHighlighted ? Color.primary.opacity(0.035) : Color.clear)
                }

                ForEach(intensityBands(startDate: startDate, resetDate: resetDate)) { band in
                    RectangleMark(
                        xStart: .value("Intensity Start", band.startDate),
                        xEnd: .value("Intensity End", band.endDate),
                        yStart: .value("Low", 0),
                        yEnd: .value("High", graphCeiling)
                    )
                    .foregroundStyle(Color.orange.opacity(0.13))
                }

                if plotStartDate < startDate {
                    RectangleMark(
                        xStart: .value("Before Window", plotStartDate),
                        xEnd: .value("Window Start", startDate),
                        yStart: .value("Low", 0),
                        yEnd: .value("High", graphCeiling)
                    )
                    .foregroundStyle(Color.black.opacity(0.28))
                }

                if resetDate < plotEndDate {
                    RectangleMark(
                        xStart: .value("Window End", resetDate),
                        xEnd: .value("After Window", plotEndDate),
                        yStart: .value("Low", 0),
                        yEnd: .value("High", graphCeiling)
                    )
                    .foregroundStyle(Color.black.opacity(0.28))
                }

                ForEach(QuotaGraphTimeAxis.dayBoundaries(startDate: plotStartDate, resetDate: plotEndDate)) { boundary in
                    RuleMark(x: .value("Day", boundary.date))
                        .foregroundStyle(.secondary.opacity(0.16))
                        .lineStyle(StrokeStyle(lineWidth: 0.5))
                }

                RuleMark(x: .value("Window Start", startDate))
                    .foregroundStyle(.secondary.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1, lineCap: .butt))

                ForEach(actualPoints) { point in
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Percent", point.percent),
                        series: .value("Series", point.series)
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }

                ForEach(actualPoints) { point in
                    PointMark(
                        x: .value("Time", point.date),
                        y: .value("Percent", point.percent)
                    )
                    .foregroundStyle(.blue)
                    .symbolSize(12)
                }

                if projection.cycleRunForecast == nil,
                   let projected = projection.projectedWeeklyUsedPercentAtReset {
                    ForEach(projectionSegments(now: now, resetDate: resetDate, projected: projected)) { segment in
                        ForEach(segment.points) { point in
                            LineMark(
                                x: .value("Time", point.date),
                                y: .value("Percent", point.percent),
                                series: .value("Series", segment.id)
                            )
                            .foregroundStyle(segment.color)
                            .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        }
                    }
                }

                RuleMark(y: .value("Limit", 100))
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))

                RuleMark(x: .value("Deadline", resetDate))
                    .foregroundStyle(.red.opacity(0.85))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .butt))
            }
            .chartXScale(domain: plotStartDate ... plotEndDate)
            .chartYScale(domain: 0 ... graphCeiling)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.secondary.opacity(0.32))
                    AxisTick(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(.secondary.opacity(0.4))
                    if let number = value.as(Double.self) {
                        AxisValueLabel {
                            Text("\(Int(number))")
                                .font(.system(size: 9, weight: .medium).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .offset(y: number == 0 ? -4 : 0)
                        }
                    }
                }
            }
            .chartPlotStyle { plotArea in
                plotArea.overlay {
                    if let cycleForecast = projection.cycleRunForecast {
                        CycleForecastCorridorOverlay(
                            forecast: cycleForecast,
                            plotStartDate: plotStartDate,
                            plotEndDate: plotEndDate,
                            ceiling: graphCeiling
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
            .clipped()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary.opacity(0.35))
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func intensityBands(startDate: Date, resetDate: Date) -> [IntensityBand] {
        guard let forecast = projection.cycleRunForecast else {
            return []
        }

        return forecast.observedIntensityRuns.enumerated().compactMap { index, run in
            let bandStart = max(startDate, run.startDate)
            let bandEnd = min(resetDate, run.endDate)
            guard bandEnd.timeIntervalSince(bandStart) >= 60 else {
                return nil
            }
            return IntensityBand(index: index, startDate: bandStart, endDate: bandEnd)
        }
    }

    private var actualPoints: [GraphPoint] {
        let stored = samples.map {
            GraphPoint(date: $0.capturedAt, percent: graphPercent($0.weeklyUsedPercent), series: "actual")
        }
        if stored.isEmpty,
           let weekly = snapshot?.secondary {
            return [GraphPoint(date: now, percent: graphPercent(weekly.usedPercent), series: "actual")]
        }
        return stored
    }

    private func projectionSegments(now: Date, resetDate: Date, projected: Double) -> [ProjectionSegment] {
        let current = projection.currentWeeklyUsedPercent
        let totalDuration = resetDate.timeIntervalSince(now)
        guard totalDuration > 0,
              current < graphCeiling else {
            return []
        }

        let startPoint = GraphPoint(date: now, percent: graphPercent(current), series: "projected-safe")
        let visibleEndPoint = visibleProjectionEndPoint(
            now: now,
            resetDate: resetDate,
            current: current,
            projected: projected
        )

        if current >= 100 {
            return [ProjectionSegment(id: "projected-over", color: Color.red.opacity(0.6), points: [startPoint, visibleEndPoint])]
        }

        if projected <= current {
            return [ProjectionSegment(id: "projected-safe", color: Color.yellow.opacity(0.36), points: [startPoint, visibleEndPoint])]
        }

        guard projected > 100 else {
            return [ProjectionSegment(id: "projected-safe", color: Color.yellow.opacity(0.36), points: [startPoint, visibleEndPoint])]
        }

        let crossingFraction = (100 - current) / (projected - current)
        let crossingDate = now.addingTimeInterval(totalDuration * crossingFraction)
        let crossingPoint = GraphPoint(date: crossingDate, percent: 100, series: "projected-crossing")
        return [
            ProjectionSegment(id: "projected-safe", color: Color.yellow.opacity(0.36), points: [startPoint, crossingPoint]),
            ProjectionSegment(id: "projected-over", color: Color.red.opacity(0.6), points: [crossingPoint, visibleEndPoint])
        ]
    }

    private func visibleProjectionEndPoint(
        now: Date,
        resetDate: Date,
        current: Double,
        projected: Double
    ) -> GraphPoint {
        guard projected > graphCeiling,
              projected > current else {
            return GraphPoint(date: resetDate, percent: graphPercent(projected), series: "projected-limit")
        }

        let totalDuration = resetDate.timeIntervalSince(now)
        let ceilingFraction = (graphCeiling - current) / (projected - current)
        let ceilingDate = now.addingTimeInterval(totalDuration * ceilingFraction)
        return GraphPoint(date: ceilingDate, percent: graphCeiling, series: "projected-ceiling")
    }

    private func graphPercent(_ value: Double) -> Double {
        min(graphCeiling, max(0, value))
    }

    private var graphCeiling: Double {
        let projectedHigh = projection.cycleRunForecast?.highProjectedWeeklyUsedPercentAtReset
            ?? projection.projectedWeeklyUsedPercentAtReset
            ?? projection.currentWeeklyUsedPercent
        guard projectedHigh > 100 else {
            return 105
        }
        let roundedHeadroom = ((projectedHigh - 100) / 10).rounded(.up) * 10
        return min(130, max(105, 100 + roundedHeadroom / 2))
    }
}

enum QuotaGraphTimeAxis {
    private static let cycleDuration: TimeInterval = 24 * 60 * 60

    static func dayBands(
        startDate: Date,
        resetDate: Date,
        calendar: Calendar = .current
    ) -> [QuotaGraphDayBand] {
        guard startDate < resetDate else {
            return []
        }

        var bands: [QuotaGraphDayBand] = []
        var bandStart = cycleBoundary(onOrBefore: startDate, calendar: calendar)
        let firstDayOrdinal = calendar.ordinality(of: .day, in: .era, for: bandStart) ?? 0
        var index = 0

        while bandStart < resetDate {
            let bandEnd = bandStart.addingTimeInterval(cycleDuration)
            bands.append(
                QuotaGraphDayBand(
                    index: index,
                    startDate: bandStart,
                    endDate: bandEnd,
                    isHighlighted: (firstDayOrdinal + index).isMultiple(of: 2)
                )
            )

            bandStart = bandEnd
            index += 1
        }

        return bands
    }

    static func dayBoundaries(
        startDate: Date,
        resetDate: Date,
        calendar: Calendar = .current
    ) -> [QuotaGraphDayBoundary] {
        guard startDate < resetDate else {
            return []
        }

        var boundaries: [QuotaGraphDayBoundary] = []
        var boundary = cycleBoundary(onOrBefore: startDate, calendar: calendar)
            .addingTimeInterval(cycleDuration)
        var index = 0

        while boundary < resetDate {
            boundaries.append(QuotaGraphDayBoundary(index: index, date: boundary))
            boundary = boundary.addingTimeInterval(cycleDuration)
            index += 1
        }

        return boundaries
    }

    private static func cycleBoundary(onOrBefore date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }
}

struct QuotaGraphDayBand: Equatable, Identifiable {
    let index: Int
    let startDate: Date
    let endDate: Date
    let isHighlighted: Bool

    var id: Int { index }
}

struct QuotaGraphDayBoundary: Equatable, Identifiable {
    let index: Int
    let date: Date

    var id: Int { index }
}

private struct IntensityBand: Identifiable {
    let index: Int
    let startDate: Date
    let endDate: Date

    var id: Int { index }
}

private struct ProjectionSegment: Identifiable {
    let id: String
    let color: Color
    let points: [GraphPoint]
}

private struct GraphPoint: Identifiable {
    let date: Date
    let percent: Double
    let series: String

    var id: String {
        "\(series)-\(date.timeIntervalSince1970)"
    }
}

private struct CycleForecastCorridorOverlay: View {
    let forecast: QuotaCycleRunForecast
    let plotStartDate: Date
    let plotEndDate: Date
    let ceiling: Double

    var body: some View {
        GeometryReader { proxy in
            Canvas { context, size in
                guard size.width > 0,
                      size.height > 0,
                      plotEndDate > plotStartDate else {
                    return
                }

                let lowSegments = forecast.lowLineSegments.isEmpty
                    ? forecast.lineSegments
                    : forecast.lowLineSegments
                let highSegments = forecast.highLineSegments.isEmpty
                    ? forecast.lineSegments
                    : forecast.highLineSegments
                guard lowSegments.isEmpty == false,
                      highSegments.isEmpty == false else {
                    return
                }

                let safeRange = 0.0 ... limitPercent
                let overLimitRange = (limitPercent + percentEpsilon) ... ceiling
                let safeLowLine = linePath(from: lowSegments, visiblePercentRange: safeRange, in: size)
                let safeHighLine = linePath(from: highSegments, visiblePercentRange: safeRange, in: size)
                let overLimitLowLine = linePath(from: lowSegments, visiblePercentRange: overLimitRange, in: size)
                let overLimitHighLine = linePath(from: highSegments, visiblePercentRange: overLimitRange, in: size)
                let fill = splitFillPaths(between: lowSegments, and: highSegments, in: size)

                var safeFillContext = context
                safeFillContext.opacity = corridorOpacity
                safeFillContext.drawLayer { layer in
                    layer.fill(fill.safe, with: .color(predictionFillColor))
                }

                context.stroke(safeLowLine, with: .color(predictionLowerLineColor), style: lineStyle)
                context.stroke(safeHighLine, with: .color(predictionUpperLineColor), style: lineStyle)

                var overLimitFillContext = context
                overLimitFillContext.opacity = overLimitOpacity
                overLimitFillContext.drawLayer { layer in
                    layer.fill(fill.overLimit, with: .color(.red))
                }

                context.stroke(overLimitLowLine, with: .color(.red), style: lineStyle)
                context.stroke(overLimitHighLine, with: .color(.red), style: lineStyle)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }

    private func linePath(
        from segments: [QuotaForecastLineSegment],
        visiblePercentRange: ClosedRange<Double>,
        in size: CGSize
    ) -> Path {
        var path = Path()
        let sortedSegments = segments
            .sorted { $0.startDate < $1.startDate }
            .filter { $0.endDate > $0.startDate }
        var previousEndPoint: CGPoint?
        for segment in sortedSegments {
            guard let clipped = clippedLineInterval(segment, to: visiblePercentRange) else {
                previousEndPoint = nil
                continue
            }

            let startPoint = plotPoint(date: clipped.startDate, percent: clipped.startPercent, in: size)
            let endPoint = plotPoint(date: clipped.endDate, percent: clipped.endPercent, in: size)
            if let previousEndPoint,
               distance(from: previousEndPoint, to: startPoint) < 0.5 {
                path.addLine(to: startPoint)
            } else {
                path.move(to: startPoint)
            }
            path.addLine(to: endPoint)
            previousEndPoint = endPoint
        }
        return path
    }

    private func clippedLineInterval(
        _ segment: QuotaForecastLineSegment,
        to visiblePercentRange: ClosedRange<Double>
    ) -> ForecastLineInterval? {
        let startPercent = segment.startUsedPercent
        let endPercent = segment.endUsedPercent
        let lowerBound = visiblePercentRange.lowerBound
        let upperBound = visiblePercentRange.upperBound
        let minimumPercent = min(startPercent, endPercent)
        let maximumPercent = max(startPercent, endPercent)
        guard maximumPercent >= lowerBound,
              minimumPercent <= upperBound else {
            return nil
        }

        let percentDelta = endPercent - startPercent
        var startProgress = 0.0
        var endProgress = 1.0

        if abs(percentDelta) <= percentEpsilon {
            guard visiblePercentRange.contains(startPercent) else {
                return nil
            }
        } else if percentDelta > 0 {
            startProgress = max(startProgress, (lowerBound - startPercent) / percentDelta)
            endProgress = min(endProgress, (upperBound - startPercent) / percentDelta)
        } else {
            startProgress = max(startProgress, (upperBound - startPercent) / percentDelta)
            endProgress = min(endProgress, (lowerBound - startPercent) / percentDelta)
        }

        startProgress = min(1, max(0, startProgress))
        endProgress = min(1, max(0, endProgress))
        guard endProgress >= startProgress else {
            return nil
        }

        let segmentDuration = segment.endDate.timeIntervalSince(segment.startDate)
        return ForecastLineInterval(
            startDate: segment.startDate.addingTimeInterval(segmentDuration * startProgress),
            endDate: segment.startDate.addingTimeInterval(segmentDuration * endProgress),
            startPercent: startPercent + percentDelta * startProgress,
            endPercent: startPercent + percentDelta * endProgress
        )
    }

    private func distance(from firstPoint: CGPoint, to secondPoint: CGPoint) -> Double {
        let xDistance = firstPoint.x - secondPoint.x
        let yDistance = firstPoint.y - secondPoint.y
        return sqrt(xDistance * xDistance + yDistance * yDistance)
    }

    private func splitFillPaths(
        between firstSegments: [QuotaForecastLineSegment],
        and secondSegments: [QuotaForecastLineSegment],
        in size: CGSize
    ) -> ForecastSplitFillPaths {
        let firstSorted = firstSegments.sorted { $0.startDate < $1.startDate }
        let secondSorted = secondSegments.sorted { $0.startDate < $1.startDate }
        let dates = splitDates(firstSorted + secondSorted, firstSegments: firstSorted, secondSegments: secondSorted)

        return ForecastSplitFillPaths(
            safe: fillPath(
                for: dates,
                firstSegments: firstSorted,
                secondSegments: secondSorted,
                visiblePercentRange: 0 ... limitPercent,
                in: size
            ),
            overLimit: fillPath(
                for: dates,
                firstSegments: firstSorted,
                secondSegments: secondSorted,
                visiblePercentRange: limitPercent ... ceiling,
                in: size
            )
        )
    }

    private func fillPath(
        for dates: [Date],
        firstSegments: [QuotaForecastLineSegment],
        secondSegments: [QuotaForecastLineSegment],
        visiblePercentRange: ClosedRange<Double>,
        in size: CGSize
    ) -> Path {
        var runs: [[ForecastBandPoint]] = []
        var currentRun: [ForecastBandPoint] = []

        for date in dates {
            guard let point = visibleBandPoint(
                date: date,
                firstSegments: firstSegments,
                secondSegments: secondSegments,
                visiblePercentRange: visiblePercentRange,
                in: size
            ) else {
                if currentRun.isEmpty == false {
                    runs.append(currentRun)
                    currentRun = []
                }
                continue
            }
            currentRun.append(point)
        }

        if currentRun.isEmpty == false {
            runs.append(currentRun)
        }

        var path = Path()
        for run in runs where run.count >= 2 {
            path.addPath(fillPath(from: run))
        }
        return path
    }

    private func fillPath(from fillPoints: [ForecastBandPoint]) -> Path {
        var path = Path()
        guard let firstPoint = fillPoints.first else {
            return path
        }

        path.move(to: CGPoint(x: firstPoint.x, y: firstPoint.topY))
        for point in fillPoints.dropFirst() {
            path.addLine(to: CGPoint(x: point.x, y: point.topY))
        }
        for point in fillPoints.reversed() {
            path.addLine(to: CGPoint(x: point.x, y: point.bottomY))
        }
        path.closeSubpath()
        return path
    }

    private func visibleBandPoint(
        date: Date,
        firstSegments: [QuotaForecastLineSegment],
        secondSegments: [QuotaForecastLineSegment],
        visiblePercentRange: ClosedRange<Double>,
        in size: CGSize
    ) -> ForecastBandPoint? {
        guard let firstPercent = percent(at: date, in: firstSegments),
              let secondPercent = percent(at: date, in: secondSegments) else {
            return nil
        }

        let lowerPercent = min(firstPercent, secondPercent)
        let upperPercent = max(firstPercent, secondPercent)
        let visibleLowerPercent = max(lowerPercent, visiblePercentRange.lowerBound)
        let visibleUpperPercent = min(upperPercent, visiblePercentRange.upperBound)
        guard visibleUpperPercent + percentEpsilon >= visibleLowerPercent else {
            return nil
        }

        let band = visibleBand(
            firstY: y(percent: visibleUpperPercent, in: size),
            secondY: y(percent: visibleLowerPercent, in: size),
            in: size
        )
        return ForecastBandPoint(
            x: x(date: date, in: size),
            topY: band.topY,
            bottomY: band.bottomY
        )
    }

    private func plotPoint(date: Date, percent: Double, in size: CGSize) -> CGPoint {
        CGPoint(
            x: x(date: date, in: size),
            y: y(percent: percent, in: size)
        )
    }

    private func x(date: Date, in size: CGSize) -> Double {
        let duration = plotEndDate.timeIntervalSince(plotStartDate)
        let fraction = date.timeIntervalSince(plotStartDate) / duration
        return min(1, max(0, fraction)) * size.width
    }

    private func y(percent: Double, in size: CGSize) -> Double {
        let value = min(ceiling, max(0, percent))
        return size.height * (1 - value / ceiling)
    }

    private func visibleBand(firstY: Double, secondY: Double, in size: CGSize) -> ForecastBandPointY {
        var topY = min(firstY, secondY)
        var bottomY = max(firstY, secondY)
        guard bottomY - topY < forecastLineWidth else {
            return ForecastBandPointY(topY: topY, bottomY: bottomY)
        }

        let centerY = (topY + bottomY) / 2
        topY = centerY - forecastLineWidth / 2
        bottomY = centerY + forecastLineWidth / 2
        if topY < 0 {
            bottomY = min(size.height, bottomY - topY)
            topY = 0
        }
        if bottomY > size.height {
            topY = max(0, topY - (bottomY - size.height))
            bottomY = size.height
        }
        return ForecastBandPointY(topY: topY, bottomY: bottomY)
    }

    private func percent(at date: Date, in segments: [QuotaForecastLineSegment]) -> Double? {
        guard let first = segments.first else {
            return nil
        }
        if date <= first.startDate {
            return first.startUsedPercent
        }

        for segment in segments {
            if date <= segment.startDate {
                return segment.startUsedPercent
            }
            if date <= segment.endDate {
                let duration = segment.endDate.timeIntervalSince(segment.startDate)
                guard duration > 0 else {
                    return segment.endUsedPercent
                }
                let progress = date.timeIntervalSince(segment.startDate) / duration
                return segment.startUsedPercent + (segment.endUsedPercent - segment.startUsedPercent) * progress
            }
        }

        return segments.last?.endUsedPercent
    }

    private func uniqueDates(_ dates: [Date]) -> [Date] {
        var unique: [Date] = []
        for date in dates.sorted() {
            guard let last = unique.last,
                  abs(date.timeIntervalSince(last)) < 0.5 else {
                unique.append(date)
                continue
            }
        }
        return unique
    }

    private func splitDates(
        _ segments: [QuotaForecastLineSegment],
        firstSegments: [QuotaForecastLineSegment],
        secondSegments: [QuotaForecastLineSegment]
    ) -> [Date] {
        var dates = segments.flatMap { [$0.startDate, $0.endDate] }
        dates += segments.compactMap { crossingDate(in: $0, at: limitPercent) }
        dates += segments.compactMap { crossingDate(in: $0, at: ceiling) }

        for date in dates {
            guard let firstPercent = percent(at: date, in: firstSegments),
                  let secondPercent = percent(at: date, in: secondSegments) else {
                continue
            }
            if min(firstPercent, secondPercent) < limitPercent,
               max(firstPercent, secondPercent) > limitPercent {
                dates.append(date)
            }
        }
        return uniqueDates(dates)
    }

    private func crossingDate(
        in segment: QuotaForecastLineSegment,
        at percent: Double
    ) -> Date? {
        let startPercent = segment.startUsedPercent
        let endPercent = segment.endUsedPercent
        guard (startPercent < percent && endPercent > percent)
                || (startPercent > percent && endPercent < percent) else {
            return nil
        }

        let percentDelta = endPercent - startPercent
        guard abs(percentDelta) > 0.0001 else {
            return nil
        }

        let progress = (percent - startPercent) / percentDelta
        return segment.startDate.addingTimeInterval(
            segment.endDate.timeIntervalSince(segment.startDate) * progress
        )
    }

    private var lineStyle: StrokeStyle {
        StrokeStyle(lineWidth: forecastLineWidth, lineCap: .round, lineJoin: .round)
    }

    private var predictionFillColor: Color {
        Color(red: 0.12, green: 0.56, blue: 0.94)
    }

    private var predictionLowerLineColor: Color {
        Color(red: 0.063, green: 0.725, blue: 0.506)
    }

    private var predictionUpperLineColor: Color {
        Color(red: 0.961, green: 0.620, blue: 0.043)
    }

    private let corridorOpacity = 0.24
    private let overLimitOpacity = 0.42
    private let forecastLineWidth = 2.4
    private let limitPercent = 100.0
    private let percentEpsilon = 0.0001
}

private struct ForecastBandPoint {
    let x: Double
    let topY: Double
    let bottomY: Double
}

private struct ForecastBandPointY {
    let topY: Double
    let bottomY: Double
}

private struct ForecastSplitFillPaths {
    let safe: Path
    let overLimit: Path
}

private struct ForecastLineInterval {
    let startDate: Date
    let endDate: Date
    let startPercent: Double
    let endPercent: Double
}

private extension DateFormatter {
    @MainActor
    static let panelDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    @MainActor
    static let panelTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
