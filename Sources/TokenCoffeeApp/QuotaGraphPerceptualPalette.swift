import Foundation
import SwiftUI

struct QuotaGraphPerceptualPalette {
    // The previous 50% mixes measured 0.088 Delta E OK on the light band and
    // 0.072 on the dark band. Their midpoint preserves the average salience
    // while giving both markers the same perceptual contrast.
    static let intensityDeltaE = 0.08

    let plotBase: QuotaGraphLinearRGB
    let lightDay: QuotaGraphLinearRGB
    let darkDay: QuotaGraphLinearRGB
    let lightIntensity: QuotaGraphLinearRGB
    let darkIntensity: QuotaGraphLinearRGB

    init(plotBase: QuotaGraphLinearRGB) {
        self.plotBase = plotBase
        lightDay = plotBase.compositing(
            overlay: .white,
            opacity: 0.07
        )
        darkDay = plotBase.compositing(
            overlay: .black,
            opacity: 0.06
        )

        let orange = QuotaGraphLinearRGB(
            sRGBRed: 1.0,
            green: 0.55,
            blue: 0.12
        )
        lightIntensity = lightDay.movingToward(
            orange,
            perceptualDistance: Self.intensityDeltaE
        )
        darkIntensity = darkDay.movingToward(
            orange,
            perceptualDistance: Self.intensityDeltaE
        )
    }
}

struct QuotaGraphLinearRGB: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    static let white = QuotaGraphLinearRGB(red: 1, green: 1, blue: 1)
    static let black = QuotaGraphLinearRGB(red: 0, green: 0, blue: 0)

    init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    init(sRGBRed red: Double, green: Double, blue: Double) {
        self.init(
            red: Self.linearComponent(red),
            green: Self.linearComponent(green),
            blue: Self.linearComponent(blue)
        )
    }

    init(resolved: Color.Resolved) {
        self.init(
            red: Double(resolved.linearRed),
            green: Double(resolved.linearGreen),
            blue: Double(resolved.linearBlue)
        )
    }

    var color: Color {
        Color(
            .sRGBLinear,
            red: red,
            green: green,
            blue: blue
        )
    }

    var isInDisplayGamut: Bool {
        (0 ... 1).contains(red)
            && (0 ... 1).contains(green)
            && (0 ... 1).contains(blue)
    }

    func compositing(
        overlay: QuotaGraphLinearRGB,
        opacity: Double
    ) -> QuotaGraphLinearRGB {
        let amount = min(1, max(0, opacity))
        return QuotaGraphLinearRGB(
            sRGBRed: Self.sRGBComponent(overlay.red) * amount
                + Self.sRGBComponent(red) * (1 - amount),
            green: Self.sRGBComponent(overlay.green) * amount
                + Self.sRGBComponent(green) * (1 - amount),
            blue: Self.sRGBComponent(overlay.blue) * amount
                + Self.sRGBComponent(blue) * (1 - amount)
        )
    }

    func perceptualDistance(to other: QuotaGraphLinearRGB) -> Double {
        okLab.distance(to: other.okLab)
    }

    func movingToward(
        _ destination: QuotaGraphLinearRGB,
        perceptualDistance targetDistance: Double
    ) -> QuotaGraphLinearRGB {
        let start = okLab
        let end = destination.clampedToDisplayGamut.okLab
        let availableDistance = start.distance(to: end)
        guard availableDistance > 0 else {
            return self
        }

        let requestedDistance = min(availableDistance, max(0, targetDistance))
        guard requestedDistance > 0 else {
            return self
        }

        // An OKLab interpolation can briefly leave the sRGB display gamut even
        // when both endpoints are valid colors. Clamping that direct result
        // changes its Delta E. Solve against the post-clamp color so the final,
        // renderable marker still has the requested perceptual contrast.
        var lowerProgress = 0.0
        var upperProgress = 1.0
        var bestColor = self
        var bestError = requestedDistance

        for _ in 0 ..< 48 {
            let progress = (lowerProgress + upperProgress) / 2
            let candidate = start
                .interpolated(to: end, progress: progress)
                .linearRGB
                .clampedToDisplayGamut
            let distance = perceptualDistance(to: candidate)
            let error = abs(distance - requestedDistance)

            if error < bestError {
                bestColor = candidate
                bestError = error
            }

            if distance < requestedDistance {
                lowerProgress = progress
            } else {
                upperProgress = progress
            }
        }

        return bestColor
    }

    private var clampedToDisplayGamut: QuotaGraphLinearRGB {
        QuotaGraphLinearRGB(
            red: min(1, max(0, red)),
            green: min(1, max(0, green)),
            blue: min(1, max(0, blue))
        )
    }

    private var okLab: QuotaGraphOKLab {
        let long = 0.412_221_470_8 * red + 0.536_332_536_3 * green + 0.051_445_992_9 * blue
        let medium = 0.211_903_498_2 * red + 0.680_699_545_1 * green + 0.107_396_956_6 * blue
        let short = 0.088_302_461_9 * red + 0.281_718_837_6 * green + 0.629_978_700_5 * blue
        let longRoot = cbrt(long)
        let mediumRoot = cbrt(medium)
        let shortRoot = cbrt(short)

        return QuotaGraphOKLab(
            lightness: 0.210_454_255_3 * longRoot + 0.793_617_785 * mediumRoot - 0.004_072_046_8 * shortRoot,
            greenRed: 1.977_998_495_1 * longRoot - 2.428_592_205 * mediumRoot + 0.450_593_709_9 * shortRoot,
            blueYellow: 0.025_904_037_1 * longRoot + 0.782_771_766_2 * mediumRoot - 0.808_675_766 * shortRoot
        )
    }

    private static func linearComponent(_ component: Double) -> Double {
        let value = min(1, max(0, component))
        if value <= 0.040_45 {
            return value / 12.92
        }
        return pow((value + 0.055) / 1.055, 2.4)
    }

    private static func sRGBComponent(_ linearComponent: Double) -> Double {
        let value = min(1, max(0, linearComponent))
        if value <= 0.003_130_8 {
            return value * 12.92
        }
        return 1.055 * pow(value, 1 / 2.4) - 0.055
    }
}

private struct QuotaGraphOKLab {
    let lightness: Double
    let greenRed: Double
    let blueYellow: Double

    func distance(to other: QuotaGraphOKLab) -> Double {
        let lightnessDifference = other.lightness - lightness
        let greenRedDifference = other.greenRed - greenRed
        let blueYellowDifference = other.blueYellow - blueYellow
        return sqrt(
            lightnessDifference * lightnessDifference
                + greenRedDifference * greenRedDifference
                + blueYellowDifference * blueYellowDifference
        )
    }

    func interpolated(
        to other: QuotaGraphOKLab,
        progress: Double
    ) -> QuotaGraphOKLab {
        QuotaGraphOKLab(
            lightness: lightness + (other.lightness - lightness) * progress,
            greenRed: greenRed + (other.greenRed - greenRed) * progress,
            blueYellow: blueYellow + (other.blueYellow - blueYellow) * progress
        )
    }

    var linearRGB: QuotaGraphLinearRGB {
        let longRoot = lightness + 0.396_337_777_4 * greenRed + 0.215_803_757_3 * blueYellow
        let mediumRoot = lightness - 0.105_561_345_8 * greenRed - 0.063_854_172_8 * blueYellow
        let shortRoot = lightness - 0.089_484_177_5 * greenRed - 1.291_485_548 * blueYellow
        let long = longRoot * longRoot * longRoot
        let medium = mediumRoot * mediumRoot * mediumRoot
        let short = shortRoot * shortRoot * shortRoot

        return QuotaGraphLinearRGB(
            red: 4.076_741_662_1 * long - 3.307_711_591_3 * medium + 0.230_969_929_2 * short,
            green: -1.268_438_004_6 * long + 2.609_757_401_1 * medium - 0.341_319_396_5 * short,
            blue: -0.004_196_086_3 * long - 0.703_418_614_7 * medium + 1.707_614_701 * short
        )
    }
}
