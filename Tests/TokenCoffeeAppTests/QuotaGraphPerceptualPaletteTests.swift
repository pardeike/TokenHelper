import XCTest
@testable import Token_Coffee

final class QuotaGraphPerceptualPaletteTests: XCTestCase {
    func testDayBandsPreserveDisplaySpaceOpacityAppearance() {
        let plotBaseSRGB = 0.118
        let palette = QuotaGraphPerceptualPalette(
            plotBase: QuotaGraphLinearRGB(
                sRGBRed: plotBaseSRGB,
                green: plotBaseSRGB,
                blue: plotBaseSRGB
            )
        )

        assertEqualComponents(
            palette.lightDay,
            QuotaGraphLinearRGB(
                sRGBRed: plotBaseSRGB * 0.93 + 0.07,
                green: plotBaseSRGB * 0.93 + 0.07,
                blue: plotBaseSRGB * 0.93 + 0.07
            )
        )
        assertEqualComponents(
            palette.darkDay,
            QuotaGraphLinearRGB(
                sRGBRed: plotBaseSRGB * 0.94,
                green: plotBaseSRGB * 0.94,
                blue: plotBaseSRGB * 0.94
            )
        )
    }

    func testIntensityBandsHaveEqualPerceptualContrastInDarkAppearance() {
        assertEqualPerceptualContrast(
            plotBase: QuotaGraphLinearRGB(
                sRGBRed: 0.118,
                green: 0.118,
                blue: 0.118
            )
        )
    }

    func testIntensityBandsHaveEqualPerceptualContrastInLightAppearance() {
        assertEqualPerceptualContrast(
            plotBase: QuotaGraphLinearRGB(
                sRGBRed: 1,
                green: 1,
                blue: 1
            )
        )
    }

    private func assertEqualPerceptualContrast(
        plotBase: QuotaGraphLinearRGB,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let palette = QuotaGraphPerceptualPalette(plotBase: plotBase)
        let lightContrast = palette.lightDay.perceptualDistance(to: palette.lightIntensity)
        let darkContrast = palette.darkDay.perceptualDistance(to: palette.darkIntensity)

        XCTAssertEqual(
            lightContrast,
            QuotaGraphPerceptualPalette.intensityDeltaE,
            accuracy: 0.000_001,
            file: file,
            line: line
        )
        XCTAssertEqual(
            darkContrast,
            QuotaGraphPerceptualPalette.intensityDeltaE,
            accuracy: 0.000_001,
            file: file,
            line: line
        )
        XCTAssertEqual(
            lightContrast,
            darkContrast,
            accuracy: 0.000_001,
            file: file,
            line: line
        )
        XCTAssertTrue(palette.lightIntensity.isInDisplayGamut, file: file, line: line)
        XCTAssertTrue(palette.darkIntensity.isInDisplayGamut, file: file, line: line)
    }

    private func assertEqualComponents(
        _ actual: QuotaGraphLinearRGB,
        _ expected: QuotaGraphLinearRGB,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.red, expected.red, accuracy: 0.000_000_000_001, file: file, line: line)
        XCTAssertEqual(actual.green, expected.green, accuracy: 0.000_000_000_001, file: file, line: line)
        XCTAssertEqual(actual.blue, expected.blue, accuracy: 0.000_000_000_001, file: file, line: line)
    }
}
