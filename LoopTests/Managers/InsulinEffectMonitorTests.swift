//
//  InsulinEffectMonitorTests.swift
//  LoopTests
//

import XCTest
import LoopCore
@testable import Loop

final class InsulinEffectMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_699_920_000)
    private let settings = InsulinEffectMonitorSettings()

    /// One reading every 5 min, `values` ending at `end` (default now).
    private func readings(_ values: [Double], endingMinutesAgo: Double = 0) -> [InsulinEffectMonitorInput.Reading] {
        let end = now.addingTimeInterval(-endingMinutesAgo * 60)
        return values.enumerated().map { index, value in
            InsulinEffectMonitorInput.Reading(date: end.addingTimeInterval(-Double(values.count - 1 - index) * 300), glucose: value, trendRate: nil)
        }
    }

    /// 13 five-minute intervals (65 min) of constant counteraction ending now.
    private func counteraction(_ rate: Double) -> [InsulinEffectMonitorInput.Rate] {
        (0..<13).map { index in
            let end = now.addingTimeInterval(-Double(index) * 300)
            return InsulinEffectMonitorInput.Rate(start: end.addingTimeInterval(-300), end: end, rate: rate)
        }
    }

    private func input(readings: [InsulinEffectMonitorInput.Reading], counteraction rate: Double, insulinOnBoard: Double?, carbsOnBoard: Double, discrepancy: Double = 0, unitsPerPumpUnit: Double = 1) -> InsulinEffectMonitorInput {
        InsulinEffectMonitorInput(
            now: now,
            readings: readings,
            counteraction: counteraction(rate),
            discrepancies: [InsulinEffectMonitorInput.Change(end: now, change: discrepancy)],
            insulinOnBoard: insulinOnBoard,
            carbsOnBoard: carbsOnBoard,
            insulinSensitivity: 40,
            carbRatio: 10,
            unitsPerPumpUnit: unitsPerPumpUnit
        )
    }

    /// 13 readings over the last hour, linear from `start` to `end`.
    private func hour(from start: Double, to end: Double) -> [InsulinEffectMonitorInput.Reading] {
        readings((0...12).map { start + (end - start) * Double($0) / 12 })
    }

    private func assessment(level: InsulinEffectLevel, minutesAgo: Double = 0) -> InsulinEffectAssessment {
        InsulinEffectAssessment(level: level, signalLevel: level, date: now.addingTimeInterval(-minutesAgo * 60))
    }

    func testPizzaWithMissingInsulinIsAtMostWatchWhileCarbsAreOnBoard() {
        // 15 min into a 3.5 mg/dL/min rise with 9 U bolused and 70 g still on board.
        let values = Array(repeating: 123.0, count: 8) + [140, 158, 175]
        let result = InsulinEffectMonitor.assess(input(readings: readings(values), counteraction: 5, insulinOnBoard: 8, carbsOnBoard: 70), settings: settings)
        XCTAssertEqual(result.signals, [.fastRise, .unexplainedRise])
        XCTAssertEqual(result.level, .watch)
        XCTAssertEqual(result.riseRate ?? 0, 3.48, accuracy: 0.001)
        XCTAssertEqual(result.carbAllowanceRate ?? 0, 70 * 4 / 180, accuracy: 0.001)
    }

    func testCarbsAboveFiveGramsCapAtWatch() {
        let values = Array(repeating: 150.0, count: 8) + [155, 160, 165]
        let atLimit = InsulinEffectMonitor.assess(input(readings: readings(values), counteraction: 3, insulinOnBoard: 2, carbsOnBoard: 5, discrepancy: 40), settings: settings)
        XCTAssertEqual(atLimit.signals, [.unexplainedRise, .aboveForecast])
        XCTAssertEqual(atLimit.level, .attention)

        let above = InsulinEffectMonitor.assess(input(readings: readings(values), counteraction: 3, insulinOnBoard: 2, carbsOnBoard: 5.1, discrepancy: 40), settings: settings)
        XCTAssertEqual(above.signals, [.unexplainedRise, .aboveForecast])
        XCTAssertEqual(above.level, .watch)
    }

    func testNormalMealStaysNormal() {
        let values = Array(repeating: 110.0, count: 8) + [117.5, 125, 132.5]
        let result = InsulinEffectMonitor.assess(input(readings: readings(values), counteraction: 2.5, insulinOnBoard: 5, carbsOnBoard: 50), settings: settings)
        XCTAssertEqual(result.level, .normal)
        XCTAssertTrue(result.signals.isEmpty)
    }

    func testSingleSignalIsWatch() {
        let values = Array(repeating: 150.0, count: 8) + [155, 160, 165]
        let result = InsulinEffectMonitor.assess(input(readings: readings(values), counteraction: 3, insulinOnBoard: 2, carbsOnBoard: 0), settings: settings)
        XCTAssertEqual(result.signals, [.unexplainedRise])
        XCTAssertEqual(result.level, .watch)
    }

    func testRiseAboveForecastConfirmsUnexplainedRise() {
        let values = Array(repeating: 150.0, count: 8) + [155, 160, 165]
        let result = InsulinEffectMonitor.assess(input(readings: readings(values), counteraction: 3, insulinOnBoard: 2, carbsOnBoard: 0, discrepancy: 40), settings: settings)
        XCTAssertEqual(result.signals, [.unexplainedRise, .aboveForecast])
        XCTAssertEqual(result.level, .attention)
    }

    func testFallingGlucoseIsNotAnUnexpectedRise() {
        let values = Array(repeating: 170.0, count: 8) + [165, 160, 155]
        let result = InsulinEffectMonitor.assess(input(readings: readings(values), counteraction: 3, insulinOnBoard: 3, carbsOnBoard: 0, discrepancy: 40), settings: settings)
        XCTAssertTrue(result.signals.isEmpty)
        XCTAssertEqual(result.level, .normal)
    }

    func testMissingInsulinEffectIsAttention() {
        // 4 U on board, 250 -> 249 in an hour although insulin should have lowered glucose by 61 mg/dL.
        let result = InsulinEffectMonitor.assess(input(readings: hour(from: 250, to: 249), counteraction: 1, insulinOnBoard: 4, carbsOnBoard: 0), settings: settings)
        XCTAssertEqual(result.signals, [.correctionNotWorking])
        XCTAssertEqual(result.level, .attention)
        XCTAssertEqual(result.hourChange ?? 0, -1, accuracy: 0.001)
        XCTAssertEqual(result.expectedHourDrop ?? 0, 61, accuracy: 0.001)
    }

    func testFreshCorrectionDoesNotSignal() {
        // Flat at 200 for an hour, 2.5 U bolused 5 min ago: no insulin effect was expected yet.
        let result = InsulinEffectMonitor.assess(input(readings: hour(from: 200, to: 200), counteraction: 0, insulinOnBoard: 2.5, carbsOnBoard: 0), settings: settings)
        XCTAssertTrue(result.signals.isEmpty)
        XCTAssertEqual(result.level, .normal)
    }

    func testCorrectionThresholdOnExpectedDrop() {
        // Counteraction x 60 min = expected drop when glucose stays flat.
        let atThreshold = InsulinEffectMonitor.assess(input(readings: hour(from: 250, to: 250), counteraction: 0.5, insulinOnBoard: 2, carbsOnBoard: 0), settings: settings)
        XCTAssertEqual(atThreshold.expectedHourDrop ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(atThreshold.signals, [.correctionNotWorking])

        let below = InsulinEffectMonitor.assess(input(readings: hour(from: 250, to: 250), counteraction: 0.48, insulinOnBoard: 2, carbsOnBoard: 0), settings: settings)
        XCTAssertTrue(below.signals.isEmpty)
    }

    func testCorrectionThresholdOnOccurredDrop() {
        // Expected 60 + 30 = 90; a drop of exactly a third (30) still signals, 31 does not.
        let third = InsulinEffectMonitor.assess(input(readings: hour(from: 280, to: 250), counteraction: 1, insulinOnBoard: 2, carbsOnBoard: 0), settings: settings)
        XCTAssertEqual(third.signals, [.correctionNotWorking])

        let more = InsulinEffectMonitor.assess(input(readings: hour(from: 281, to: 250), counteraction: 1, insulinOnBoard: 2, carbsOnBoard: 0), settings: settings)
        XCTAssertTrue(more.signals.isEmpty)
    }

    func testCorrectionThresholdOnGlucoseAndCarbs() {
        let atGlucose = InsulinEffectMonitor.assess(input(readings: hour(from: 180, to: 180), counteraction: 1, insulinOnBoard: 2, carbsOnBoard: 5), settings: settings)
        XCTAssertEqual(atGlucose.signals, [.correctionNotWorking])

        let belowGlucose = InsulinEffectMonitor.assess(input(readings: hour(from: 179, to: 179), counteraction: 1, insulinOnBoard: 2, carbsOnBoard: 0), settings: settings)
        XCTAssertTrue(belowGlucose.signals.isEmpty)

        let withCarbs = InsulinEffectMonitor.assess(input(readings: hour(from: 180, to: 180), counteraction: 1, insulinOnBoard: 2, carbsOnBoard: 5.1), settings: settings)
        XCTAssertTrue(withCarbs.signals.isEmpty)
    }

    func testOneMissingReadingStillAssesses() {
        // Readings 15, 5 and 0 min ago; the one 10 min ago is missing.
        let values = [InsulinEffectMonitorInput.Reading(date: now.addingTimeInterval(-15 * 60), glucose: 145, trendRate: nil)] + readings([150, 155])
        let result = InsulinEffectMonitor.assess(input(readings: values, counteraction: 0, insulinOnBoard: 2, carbsOnBoard: 0), settings: settings)
        XCTAssertEqual(result.level, .normal)
    }

    func testInsulinThresholdIsInInternationalUnits() {
        // 0.6 pump units of U200 = 1.2 IU, above the 1 IU minimum; the same pump units of U100 are below.
        let values = Array(repeating: 123.0, count: 8) + [140, 158, 175]
        let u200 = InsulinEffectMonitor.assess(input(readings: readings(values), counteraction: 0, insulinOnBoard: 0.6, carbsOnBoard: 0, unitsPerPumpUnit: 2), settings: settings)
        XCTAssertTrue(u200.signals.contains(.fastRise))
        XCTAssertEqual(u200.insulinOnBoard ?? 0, 1.2, accuracy: 0.001)

        let u100 = InsulinEffectMonitor.assess(input(readings: readings(values), counteraction: 0, insulinOnBoard: 0.6, carbsOnBoard: 0), settings: settings)
        XCTAssertFalse(u100.signals.contains(.fastRise))
    }

    func testLevelRisesOnlyAfterTwoEvaluations() {
        let first = InsulinEffectMonitor.persisting(assessment(level: .attention), after: assessment(level: .normal, minutesAgo: 5))
        XCTAssertEqual(first.level, .normal)
        XCTAssertEqual(first.signalLevel, .attention)

        let second = InsulinEffectMonitor.persisting(assessment(level: .attention), after: first)
        XCTAssertEqual(second.level, .attention)

        let afterWatch = InsulinEffectMonitor.persisting(assessment(level: .attention), after: assessment(level: .watch, minutesAgo: 5))
        XCTAssertEqual(afterWatch.level, .watch)
    }

    func testLevelFallsImmediately() {
        let result = InsulinEffectMonitor.persisting(assessment(level: .normal), after: assessment(level: .attention, minutesAgo: 5))
        XCTAssertEqual(result.level, .normal)
    }

    func testPersistenceNeedsRecentKnownPreviousEvaluation() {
        XCTAssertEqual(InsulinEffectMonitor.persisting(assessment(level: .attention), after: nil).level, .normal)
        XCTAssertEqual(InsulinEffectMonitor.persisting(assessment(level: .attention), after: assessment(level: .attention, minutesAgo: 20)).level, .normal)
        XCTAssertEqual(InsulinEffectMonitor.persisting(assessment(level: .attention), after: assessment(level: .unknown, minutesAgo: 5)).level, .normal)
        XCTAssertEqual(InsulinEffectMonitor.persisting(assessment(level: .unknown), after: assessment(level: .attention, minutesAgo: 5)).level, .unknown)
    }

    func testFastRiseNeedsActiveInsulin() {
        let values = Array(repeating: 123.0, count: 8) + [140, 158, 175]
        let result = InsulinEffectMonitor.assess(input(readings: readings(values), counteraction: 0, insulinOnBoard: 0.5, carbsOnBoard: 0), settings: settings)
        XCTAssertFalse(result.signals.contains(.fastRise))
    }

    func testSensorTrendRateIsPreferred() {
        var values = readings(Array(repeating: 123.0, count: 11))
        let last = values.removeLast()
        values.append(InsulinEffectMonitorInput.Reading(date: last.date, glucose: last.glucose, trendRate: 4))
        let result = InsulinEffectMonitor.assess(input(readings: values, counteraction: 0, insulinOnBoard: 2, carbsOnBoard: 0), settings: settings)
        XCTAssertEqual(result.riseRate, 4)
        XCTAssertEqual(result.level, .watch)
    }

    func testStaleSensorIsUnknown() {
        let result = InsulinEffectMonitor.assess(input(readings: readings([120, 140, 160], endingMinutesAgo: 20), counteraction: 5, insulinOnBoard: 8, carbsOnBoard: 0), settings: settings)
        XCTAssertEqual(result.level, .unknown)
    }

    func testTooFewReadingsIsUnknown() {
        let result = InsulinEffectMonitor.assess(input(readings: readings([140, 175]), counteraction: 5, insulinOnBoard: 8, carbsOnBoard: 0), settings: settings)
        XCTAssertEqual(result.level, .unknown)
    }

    func testDisabledIsUnknown() {
        var disabled = settings
        disabled.isEnabled = false
        let values = Array(repeating: 123.0, count: 8) + [140, 158, 175]
        let result = InsulinEffectMonitor.assess(input(readings: readings(values), counteraction: 5, insulinOnBoard: 8, carbsOnBoard: 70), settings: disabled)
        XCTAssertEqual(result.level, .unknown)
    }

    func testWatchContextCarriesWarningOnly() {
        let context = WatchContext()
        context.insulinEffectLevel = .attention
        XCTAssertEqual(WatchContext(rawValue: context.rawValue)?.insulinEffectLevel, .attention)

        context.insulinEffectLevel = nil
        XCTAssertNil(WatchContext(rawValue: context.rawValue)?.insulinEffectLevel)
    }

    func testWatchContextCarriesInsulinConcentration() {
        let context = WatchContext()
        XCTAssertNil(WatchContext(rawValue: context.rawValue)?.insulinConcentrationLabel)

        context.insulinConcentrationLabel = "U200"
        XCTAssertEqual(WatchContext(rawValue: context.rawValue)?.insulinConcentrationLabel, "U200")
    }
}
