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

    private func counteraction(_ rate: Double) -> [InsulinEffectMonitorInput.Rate] {
        (0..<6).map { index in
            let end = now.addingTimeInterval(-Double(index) * 300)
            return InsulinEffectMonitorInput.Rate(start: end.addingTimeInterval(-300), end: end, rate: rate)
        }
    }

    private func input(readings: [InsulinEffectMonitorInput.Reading], counteraction rate: Double, insulinOnBoard: Double?, carbsOnBoard: Double, discrepancy: Double = 0) -> InsulinEffectMonitorInput {
        InsulinEffectMonitorInput(
            now: now,
            readings: readings,
            counteraction: counteraction(rate),
            discrepancies: [InsulinEffectMonitorInput.Change(end: now, change: discrepancy)],
            insulinOnBoard: insulinOnBoard,
            carbsOnBoard: carbsOnBoard,
            insulinSensitivity: 40,
            carbRatio: 10
        )
    }

    func testPizzaWithMissingInsulinRaisesAttentionEarly() {
        // 15 min into a 3.5 mg/dL/min rise with 9 U bolused and 70 g still on board.
        let values = Array(repeating: 123.0, count: 8) + [140, 158, 175]
        let result = InsulinEffectMonitor.assess(input(readings: readings(values), counteraction: 5, insulinOnBoard: 8, carbsOnBoard: 70), settings: settings)
        XCTAssertEqual(result.level, .attention)
        XCTAssertEqual(result.signals, [.fastRise, .unexplainedRise])
        XCTAssertEqual(result.riseRate ?? 0, 3.5, accuracy: 0.001)
        XCTAssertEqual(result.carbAllowanceRate ?? 0, 70 * 4 / 180, accuracy: 0.001)
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

    func testCorrectionNotWorkingIsAttention() {
        let values = Array(repeating: 250.0, count: 14)
        let result = InsulinEffectMonitor.assess(input(readings: readings(values), counteraction: 0.5, insulinOnBoard: 4, carbsOnBoard: 0), settings: settings)
        XCTAssertEqual(result.signals, [.correctionNotWorking])
        XCTAssertEqual(result.level, .attention)
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
}
