//
//  TherapyOptimizerTests.swift
//  LoopTests
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

final class TherapyOptimizerTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 2023-11-14 00:00:00 UTC
    private let day0 = Date(timeIntervalSince1970: 1_699_920_000)
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 24 * 3600

    private func makeState(basal: Double = 1.0, sensitivity: Double = 50, carbRatio: Double = 10) -> TherapyOptimizerState {
        TherapyOptimizerState(
            startedAt: day0,
            timeZone: utc,
            basal: Array(repeating: basal, count: 24),
            sensitivity: Array(repeating: sensitivity, count: 24),
            carbRatio: Array(repeating: carbRatio, count: 24),
            sensitivityUnitString: HKUnit.milligramsPerDeciliter.unitString,
            processingStart: day0
        )
    }

    private func interval(at start: Date, counteraction: Double = 0, insulinVelocity: Double = 0, carbsOnBoard: Double = 0, manualBolusIOB: Double = 0, netAdjustment: Double = 0, glucose: Double = 120, override: Bool = false) -> TherapyOptimizerInterval {
        TherapyOptimizerInterval(
            start: start,
            end: start.addingTimeInterval(300),
            glucose: glucose,
            counteraction: counteraction,
            insulinVelocity: insulinVelocity,
            carbsOnBoard: carbsOnBoard,
            manualBolusInsulinOnBoard: manualBolusIOB,
            netAdjustment: netAdjustment,
            sensitivity: 50,
            isSuspended: false,
            isOverrideActive: override
        )
    }

    /// 02:00-05:00 on the given day; a counteraction of 0.4167 mg/dL/min at ISF 50 means +0.5 U/h basal need.
    private func nightIntervals(onDay index: Int, counteraction: Double = 0.5 * 50 / 60, netAdjustment: Double = 0.5, transform: (TherapyOptimizerInterval) -> TherapyOptimizerInterval = { $0 }) -> [TherapyOptimizerInterval] {
        let start = day0.addingTimeInterval(Double(index) * day + 2 * hour)
        return (0..<36).map { transform(interval(at: start.addingTimeInterval(Double($0) * 300), counteraction: counteraction, netAdjustment: netAdjustment)) }
    }

    private var noContributions: (TherapyOptimizerState) -> Bool {
        { state in
            state.summaries.allSatisfy { summary in
                summary.basalDeviation.allSatisfy { $0.minutes == 0 }
                    && summary.basalAdjustment.allSatisfy { $0.minutes == 0 }
                    && summary.sensitivityAllDay.count == 0
            }
        }
    }

    // MARK: - Basal

    func testBasalRisesAtMostTenPercentPerDayAndStopsAtUpperLimit() {
        var state = makeState()
        for index in 0..<20 {
            TherapyOptimizerEngine.ingest(nightIntervals(onDay: index), scheduledBasal: { _ in 1.0 }, into: &state)
            TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(Double(index + 1) * day))
            if index == 0 {
                XCTAssertEqual(state.basal.calculated[1], 1.1, accuracy: 0.0001)
            }
        }
        XCTAssertEqual(state.basal.calculated[1], 1.3, accuracy: 0.0001)
        XCTAssertEqual(state.basal.calculated[12], 1.0, accuracy: 0.0001)
    }

    func testBasalHoldsWhenSignalsDisagree() {
        var state = makeState()
        TherapyOptimizerEngine.ingest(nightIntervals(onDay: 0, netAdjustment: -0.5), scheduledBasal: { _ in 1.0 }, into: &state)
        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(day))
        XCTAssertEqual(state.basal.calculated[1], 1.0, accuracy: 0.0001)
        XCTAssertEqual(state.basal.dataDays[1], 1)
    }

    func testBasalAttributionLandsOneToThreeHoursEarlier() {
        var state = makeState()
        TherapyOptimizerEngine.ingest([interval(at: day0.addingTimeInterval(10 * hour))], scheduledBasal: { _ in 1.0 }, into: &state)
        let summary = state.summaries[0]
        for slot in 0..<24 {
            XCTAssertEqual(summary.basalDeviation[slot].minutes, [7, 8, 9].contains(slot) ? 5.0 / 3 : 0, accuracy: 0.0001, "deviation slot \(slot)")
            XCTAssertEqual(summary.basalAdjustment[slot].minutes, slot == 9 ? 5 : 0, accuracy: 0.0001, "adjustment slot \(slot)")
        }
    }

    func testExcludedPeriodsContributeNothing() {
        let cases: [(String, (TherapyOptimizerInterval) -> TherapyOptimizerInterval)] = [
            ("carbs", { self.interval(at: $0.start, counteraction: $0.counteraction, carbsOnBoard: 10) }),
            ("manual bolus", { self.interval(at: $0.start, counteraction: $0.counteraction, manualBolusIOB: 1) }),
            ("override", { self.interval(at: $0.start, counteraction: $0.counteraction, override: true) }),
            ("hypo", { self.interval(at: $0.start, counteraction: $0.counteraction, glucose: 60) }),
            ("unexplained rise", { self.interval(at: $0.start, counteraction: 1.5) }),
        ]
        for (name, transform) in cases {
            var state = makeState()
            TherapyOptimizerEngine.ingest(nightIntervals(onDay: 0, transform: transform), scheduledBasal: { _ in 1.0 }, into: &state)
            XCTAssertTrue(noContributions(state), name)
        }
    }

    // MARK: - Insulin sensitivity

    func testSensitivityChangesOnlyObservedHourAndAllDay() {
        var state = makeState()
        let start = day0.addingTimeInterval(22 * hour)
        // Glucose drops 1.5x as fast as the insulin effect predicts.
        let intervals = (0..<12).map { interval(at: start.addingTimeInterval(Double($0) * 300), counteraction: -0.5, insulinVelocity: -1.0) }
        TherapyOptimizerEngine.ingest(intervals, scheduledBasal: { _ in 1.0 }, into: &state)
        XCTAssertEqual(state.summaries[0].sensitivity[22].median ?? 0, 75, accuracy: 0.0001)

        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(day))
        XCTAssertEqual(state.sensitivity.calculated[22], 55, accuracy: 0.0001)
        XCTAssertEqual(state.sensitivity.calculatedAllDay, 55, accuracy: 0.0001)
        XCTAssertEqual(state.sensitivity.calculated[10], 50, accuracy: 0.0001)
    }

    func testSensitivityNeedsEnoughIntervals() {
        var state = makeState()
        let start = day0.addingTimeInterval(22 * hour)
        let intervals = (0..<5).map { interval(at: start.addingTimeInterval(Double($0) * 300), counteraction: -0.5, insulinVelocity: -1.0) }
        TherapyOptimizerEngine.ingest(intervals, scheduledBasal: { _ in 1.0 }, into: &state)
        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(day))
        XCTAssertEqual(state.sensitivity.calculated[22], 50, accuracy: 0.0001)
        XCTAssertEqual(state.sensitivity.calculatedAllDay, 50, accuracy: 0.0001)
    }

    // MARK: - Carb ratio

    func testSensitivityFactorPerGlucoseRange() {
        var state = makeState()
        let start = day0.addingTimeInterval(20 * hour)
        // 120 mg/dL: falls as predicted (estimate 50). 200 mg/dL: falls only 0.8x as fast (estimate 40).
        let normal = (0..<20).map { interval(at: start.addingTimeInterval(Double($0) * 300), counteraction: 0, insulinVelocity: -1.0, glucose: 120) }
        let high = (20..<30).map { interval(at: start.addingTimeInterval(Double($0) * 300), counteraction: 0.2, insulinVelocity: -1.0, glucose: 200) }
        TherapyOptimizerEngine.ingest(normal + high, scheduledBasal: { _ in 1.0 }, into: &state)
        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(day))

        let ranges = state.sensitivityByGlucose ?? []
        XCTAssertEqual(ranges.count, 5)
        XCTAssertEqual(ranges[2].factor ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(ranges[3].factor ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(ranges[3].sensitivity ?? 0, 40, accuracy: 0.0001)
        XCTAssertNil(ranges[0].factor)
        XCTAssertEqual(ranges[0].dataDays, 0)
    }

    func testStateWithoutGlucoseRangesStillDecodes() throws {
        var state = makeState()
        state.summaries = [TherapyOptimizerDaySummary(day: day0)]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json.removeValue(forKey: "sensitivityByGlucose")
        var summaries = json["summaries"] as! [[String: Any]]
        summaries[0].removeValue(forKey: "sensitivityByGlucose")
        json["summaries"] = summaries
        let decoded = try JSONDecoder().decode(TherapyOptimizerState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.summaries[0].sensitivityByGlucose)
    }

    // MARK: - Carb ratio

    func testMealEstimatesCarbRatio() {
        var state = makeState()
        let start = day0.addingTimeInterval(12 * hour)
        let meal = TherapyOptimizerMeal(
            start: start,
            end: start.addingTimeInterval(3 * hour),
            carbs: 60,
            netInsulin: 5,
            scheduledBasalUnits: 3,
            glucoseStart: 120,
            glucoseEnd: 120,
            minimumGlucose: 110,
            isOverrideActive: false
        )
        TherapyOptimizerEngine.ingest([meal], into: &state)
        XCTAssertEqual(state.summaries[0].carbRatio[12].median ?? 0, 12, accuracy: 0.0001)
        XCTAssertEqual(state.summaries[0].carbRatioAllDay.median ?? 0, 12, accuracy: 0.0001)

        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(day))
        XCTAssertEqual(state.carbRatio.calculated[12], 11, accuracy: 0.0001)
        XCTAssertEqual(state.carbRatio.calculatedAllDay, 11, accuracy: 0.0001)
    }

    func testRescueCarbsAreIgnored() {
        var state = makeState()
        let start = day0.addingTimeInterval(12 * hour)
        let meal = TherapyOptimizerMeal(start: start, end: start.addingTimeInterval(3 * hour), carbs: 15, netInsulin: 1, scheduledBasalUnits: 3, glucoseStart: 65, glucoseEnd: 110, minimumGlucose: 60, isOverrideActive: false)
        TherapyOptimizerEngine.ingest([meal], into: &state)
        XCTAssertTrue(state.summaries.isEmpty)
    }

    // MARK: - Window, retention, export

    func testWindowSelectsDays() {
        var state = makeState()
        for index in 0..<40 {
            var summary = TherapyOptimizerDaySummary(day: day0.addingTimeInterval(Double(index) * day))
            let value = index < 30 ? 1.5 : 0.95
            summary.basalDeviation[5].add(value, minutes: 60)
            summary.basalAdjustment[5].add(value, minutes: 60)
            state.summaries.append(summary)
        }
        let updateDay = day0.addingTimeInterval(40 * day)

        var wide = state
        TherapyOptimizerEngine.applyDailyUpdate(to: &wide, on: updateDay)
        XCTAssertEqual(wide.basal.calculated[5], 1.1, accuracy: 0.0001)
        XCTAssertEqual(wide.basal.dataDays[5], 30)

        var narrow = state
        narrow.windowDays = 14
        TherapyOptimizerEngine.applyDailyUpdate(to: &narrow, on: updateDay)
        XCTAssertEqual(narrow.basal.calculated[5], 0.95, accuracy: 0.0001)
        XCTAssertEqual(narrow.basal.dataDays[5], 14)
    }

    func testCompactAndPrune() {
        var state = makeState()
        var old = TherapyOptimizerDaySummary(day: day0)
        old.sensitivityAllDay.add(40)
        old.sensitivityAllDay.add(60)
        var closed = TherapyOptimizerDaySummary(day: day0.addingTimeInterval(95 * day))
        closed.sensitivityAllDay.add(40)
        closed.sensitivityAllDay.add(60)
        state.summaries = [old, closed]

        TherapyOptimizerEngine.compactAndPrune(&state, now: day0.addingTimeInterval(100 * day))
        XCTAssertEqual(state.summaries.count, 1)
        XCTAssertTrue(state.summaries[0].isCompacted)
        XCTAssertTrue(state.summaries[0].sensitivityAllDay.values.isEmpty)
        XCTAssertEqual(state.summaries[0].sensitivityAllDay.median ?? 0, 50, accuracy: 0.0001)
        XCTAssertEqual(state.summaries[0].sensitivityAllDay.count, 2)
    }

    func testHourlyExportFallsBackToAllDayValue() {
        var state = makeState()
        state.sensitivity.calculated = Array(repeating: 50, count: 24)
        state.sensitivity.calculated[7] = 60
        state.sensitivity.dataDays[7] = 5
        state.sensitivity.calculatedAllDay = 55

        let hourly = state.calculatedSensitivitySchedule(hourly: true)
        XCTAssertEqual(hourly?.items.map { $0.value }, [55, 60, 55])
        XCTAssertEqual(hourly?.items.map { $0.startTime }, [0, 7 * hour, 8 * hour])

        let allDay = state.calculatedSensitivitySchedule(hourly: false)
        XCTAssertEqual(allDay?.items.map { $0.value }, [55])
    }

    func testBasalExportRoundsAndRespectsMaximum() {
        var state = makeState()
        state.basal.calculated = Array(repeating: 1.03, count: 24)
        state.basal.calculated[3] = 1.4

        let schedule = state.calculatedBasalSchedule(maximumBasalRate: 1.2, maximumEntryCount: 24)
        XCTAssertEqual(schedule?.items.count, 3)
        XCTAssertEqual(schedule?.items[0].value, Double(21) / 20)
        XCTAssertEqual(schedule?.items[1].value, Double(24) / 20)
    }

    func testBasalExportProducesExactPumpRates() {
        var state = makeState()
        state.basal.calculated = Array(repeating: 0.72, count: 24)
        state.basal.calculated[12] = 0.73
        state.basal.calculated[13] = 0.15

        let values = state.calculatedBasalSchedule(maximumBasalRate: nil, maximumEntryCount: nil)?.items.map { $0.value }
        XCTAssertEqual(values, [Double(14) / 20, Double(15) / 20, Double(3) / 20, Double(14) / 20])
    }

    func testStateRoundTripsThroughJSON() throws {
        var state = makeState()
        TherapyOptimizerEngine.ingest(nightIntervals(onDay: 0), scheduledBasal: { _ in 1.0 }, into: &state)
        state.overrideIntervals = [DateInterval(start: day0, duration: hour)]
        let decoded = try JSONDecoder().decode(TherapyOptimizerState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
    }
}
