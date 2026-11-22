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

    private func makeState(basal: Double = 1.0, sensitivity: Double = 50, carbRatio: Double = 10, timeZone: TimeZone? = nil) -> TherapyOptimizerState {
        TherapyOptimizerState(
            timeZone: timeZone ?? utc,
            basal: Array(repeating: basal, count: 24),
            sensitivity: Array(repeating: sensitivity, count: 24),
            carbRatio: Array(repeating: carbRatio, count: 24),
            sensitivityUnit: .milligramsPerDeciliter,
            processingStart: day0
        )
    }

    private func interval(at start: Date, counteraction: Double = 0, insulinVelocity: Double = 0, carbsOnBoard: Double = 0, glucose: Double = 120, sensitivity: Double = 50, override: Bool = false) -> TherapyOptimizerInterval {
        TherapyOptimizerInterval(
            start: start,
            end: start.addingTimeInterval(300),
            glucose: glucose,
            counteraction: counteraction,
            insulinVelocity: insulinVelocity,
            carbsOnBoard: carbsOnBoard,
            sensitivity: sensitivity,
            isSuspended: false,
            isOverrideActive: override
        )
    }

    /// `count` 5-minute intervals from `start`.
    private func series(from start: Date, count: Int, make: (Date) -> TherapyOptimizerInterval) -> [TherapyOptimizerInterval] {
        (0..<count).map { make(start.addingTimeInterval(Double($0) * 300)) }
    }

    /// 3 h meal whose insulin exactly covered `carbs` at ratio `carbs / netInsulin` (basal and glucose cancel out).
    private func meal(onDay index: Int, atHour mealHour: Double = 12, carbs: Double = 60, netInsulin: Double = 5, glucoseStart: Double = 120, minimumGlucose: Double = 110, entryCount: Int? = 1) -> TherapyOptimizerMeal {
        let start = day0.addingTimeInterval(Double(index) * day + mealHour * hour)
        return TherapyOptimizerMeal(
            start: start,
            end: start.addingTimeInterval(3 * hour),
            carbs: carbs,
            netInsulin: netInsulin,
            scheduledBasalUnits: 3,
            glucoseStart: glucoseStart,
            glucoseEnd: glucoseStart,
            minimumGlucose: minimumGlucose,
            isOverrideActive: false,
            entryCount: entryCount
        )
    }

    private func basalMinutes(_ state: TherapyOptimizerState) -> Double {
        state.summaries.reduce(0) { total, summary in total + summary.basalDeviation.reduce(0) { $0 + $1.minutes } }
    }

    /// Reproducible noise.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// 02:00-05:00 on the given day; a counteraction of 0.4167 mg/dL/min at ISF 50 means +0.5 U/h basal need.
    private func nightIntervals(onDay index: Int, counteraction: Double = 0.5 * 50 / 60, transform: (TherapyOptimizerInterval) -> TherapyOptimizerInterval = { $0 }) -> [TherapyOptimizerInterval] {
        let start = day0.addingTimeInterval(Double(index) * day + 2 * hour)
        return (0..<36).map { transform(interval(at: start.addingTimeInterval(Double($0) * 300), counteraction: counteraction)) }
    }

    private var noContributions: (TherapyOptimizerState) -> Bool {
        { state in
            state.summaries.allSatisfy { summary in
                summary.basalDeviation.allSatisfy { $0.minutes == 0 }
                    && summary.sensitivityAllDay.count == 0
            }
        }
    }

    // MARK: - Basal

    func testBasalNeedsThreeDaysRisesAtMostTenPercentPerDayAndStopsAtUpperLimit() {
        var state = makeState()
        for index in 0..<20 {
            TherapyOptimizerEngine.ingest(nightIntervals(onDay: index), scheduledBasal: { _ in 1.0 }, into: &state)
            TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(Double(index + 1) * day))
            if index < 2 {
                XCTAssertEqual(state.basal.calculated[1], 1.0, accuracy: 0.0001, "day \(index)")
            } else if index == 2 {
                XCTAssertEqual(state.basal.calculated[1], 1.1, accuracy: 0.0001)
            }
        }
        XCTAssertEqual(state.basal.calculated[1], 1.3, accuracy: 0.0001)
        XCTAssertEqual(state.basal.calculated[12], 1.0, accuracy: 0.0001)
    }

    func testBasalOutlierDayDoesNotMoveValue() {
        var state = makeState()
        for index in 0..<10 {
            var summary = TherapyOptimizerDaySummary(day: day0.addingTimeInterval(Double(index) * day))
            for hour in 4...6 {
                summary.basalDeviation[hour].add(index == 7 ? 2.0 : 1.0, minutes: 60)
            }
            state.summaries.append(summary)
        }
        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(10 * day))
        XCTAssertEqual(state.basal.calculated[5], 1.0, accuracy: 0.0001)
        XCTAssertEqual(state.basal.dataDays[5], 10)
    }

    /// Shrinkage toward the profile and smoothing with neighbour hours without data both damp a single hour.
    func testBasalIsShrunkAndSmoothedWithNeighbours() {
        var state = makeState()
        for index in 0..<7 {
            var summary = TherapyOptimizerDaySummary(day: day0.addingTimeInterval(Double(index) * day))
            summary.basalDeviation[5].add(1.08, minutes: 60)
            state.summaries.append(summary)
        }
        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(7 * day))
        // Target 1 + 0.08 * 7 / 14 = 1.04, smoothed with 1.0 on both sides: 1.02.
        XCTAssertEqual(state.basal.calculated[5], 1.02, accuracy: 0.0001)
        XCTAssertEqual(state.basal.calculated[4], 1.0, accuracy: 0.0001)
    }

    func testBasalAttributionLandsOneToThreeHoursEarlier() {
        var state = makeState()
        TherapyOptimizerEngine.ingest([interval(at: day0.addingTimeInterval(10 * hour))], scheduledBasal: { _ in 1.0 }, into: &state)
        let summary = state.summaries[0]
        for slot in 0..<24 {
            XCTAssertEqual(summary.basalDeviation[slot].minutes, [7, 8, 9].contains(slot) ? 5.0 / 3 : 0, accuracy: 0.0001, "deviation slot \(slot)")
        }
    }

    func testExcludedPeriodsContributeNothing() {
        let cases: [(String, (TherapyOptimizerInterval) -> TherapyOptimizerInterval)] = [
            ("carbs", { self.interval(at: $0.start, counteraction: $0.counteraction, carbsOnBoard: 10) }),
            ("override", { self.interval(at: $0.start, counteraction: $0.counteraction, override: true) }),
            ("hypo", { self.interval(at: $0.start, counteraction: $0.counteraction, glucose: 60) }),
            ("unexplained rise", { self.interval(at: $0.start, counteraction: 2.0) }),
        ]
        for (name, transform) in cases {
            var state = makeState()
            TherapyOptimizerEngine.ingest(nightIntervals(onDay: 0, transform: transform), scheduledBasal: { _ in 1.0 }, into: &state)
            XCTAssertTrue(noContributions(state), name)
        }
    }

    func testIntervalsUntilFourHoursAfterOverrideAreExcluded() {
        var state = makeState()
        let override = DateInterval(start: day0.addingTimeInterval(hour), end: day0.addingTimeInterval(2 * hour))
        // 02:00-05:00 lies within 4 h after the override; 06:00-06:30 does not.
        let late = series(from: day0.addingTimeInterval(6 * hour), count: 6) { self.interval(at: $0, counteraction: 0.5 * 50 / 60) }
        TherapyOptimizerEngine.ingest(nightIntervals(onDay: 0) + late, scheduledBasal: { _ in 1.0 }, overrides: [override], into: &state)
        XCTAssertEqual(basalMinutes(state), 6 * 5, accuracy: 0.0001)
    }

    /// Dawn phenomenon: glucose rises without carbs while Loop adds insulin; this must raise basal, not lower ISF.
    func testRiseWhileLoopCorrectsCountsAsBasal() {
        var state = makeState()
        for index in 0..<3 {
            // Glucose +0.7 mg/dL/min despite a Loop insulin effect of -0.3 mg/dL/min.
            let rise = series(from: day0.addingTimeInterval(Double(index) * day + 5 * hour), count: 36) { self.interval(at: $0, counteraction: 1.0, insulinVelocity: -0.3) }
            TherapyOptimizerEngine.ingest(rise, scheduledBasal: { _ in 1.0 }, into: &state)
            XCTAssertNil(state.unexplainedRiseSince)
            TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(Double(index + 1) * day))
        }
        XCTAssertTrue(state.summaries.allSatisfy { $0.sensitivityAllDay.count == 0 })
        XCTAssertEqual(state.basal.calculated[5], 1.1, accuracy: 0.0001)
        XCTAssertEqual(state.basal.dataDays[4], 3)
    }

    func testSingleNoisyReadingDoesNotMarkUnannouncedMeal() {
        var state = makeState()
        let start = day0.addingTimeInterval(2 * hour)
        let intervals = (0..<36).map { interval(at: start.addingTimeInterval(Double($0) * 300), counteraction: $0 == 10 ? 2.5 : 0) }
        TherapyOptimizerEngine.ingest(intervals, scheduledBasal: { _ in 1.0 }, into: &state)
        XCTAssertEqual(basalMinutes(state), 36 * 5, accuracy: 0.0001)
    }

    /// +1 mg/dL/min stays below the counteraction threshold but rises 25 mg/dL within 30 minutes.
    func testSlowSnackIsDetectedByThirtyMinuteRise() {
        var state = makeState()
        let snack = series(from: day0.addingTimeInterval(14 * hour), count: 36) { self.interval(at: $0, counteraction: 1.0) }
        TherapyOptimizerEngine.ingest(snack, scheduledBasal: { _ in 1.0 }, into: &state)
        XCTAssertNotNil(state.unexplainedRiseSince)
        XCTAssertEqual(basalMinutes(state), 4 * 5, accuracy: 0.0001)
    }

    // MARK: - Insulin sensitivity

    func testSensitivityEpisodeChangesOnlyObservedHourAndAllDay() {
        var state = makeState()
        // One hour where glucose drops 1.5x as fast as the insulin effect predicts.
        let episode = series(from: day0.addingTimeInterval(22 * hour), count: 12) { self.interval(at: $0, counteraction: -0.5, insulinVelocity: -1.0) }
        TherapyOptimizerEngine.ingest(episode, scheduledBasal: { _ in 1.0 }, into: &state)
        XCTAssertNil(state.openSensitivityEpisode)
        XCTAssertEqual(state.summaries[0].sensitivity[22].count, 1)
        XCTAssertEqual(state.summaries[0].sensitivity[22].median ?? 0, 75, accuracy: 0.0001)

        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(day))
        XCTAssertEqual(state.sensitivity.calculated[22], 55, accuracy: 0.0001)
        XCTAssertEqual(state.sensitivity.calculatedAllDay, 55, accuracy: 0.0001)
        XCTAssertEqual(state.sensitivity.calculated[10], 50, accuracy: 0.0001)
    }

    func testShortOrWeakEpisodesAreIgnored() {
        var state = makeState()
        // 25 minutes, then 35 minutes with only 17.5 mg/dL insulin effect, separated by a basal interval.
        let short = series(from: day0.addingTimeInterval(10 * hour), count: 5) { self.interval(at: $0, insulinVelocity: -1.0) }
        let separator = [interval(at: day0.addingTimeInterval(10 * hour + 25 * 60))]
        let weak = series(from: day0.addingTimeInterval(10 * hour + 30 * 60), count: 7) { self.interval(at: $0, insulinVelocity: -0.5) }
        TherapyOptimizerEngine.ingest(short + separator + weak + [interval(at: day0.addingTimeInterval(11 * hour + 5 * 60))], scheduledBasal: { _ in 1.0 }, into: &state)
        XCTAssertTrue(state.summaries.allSatisfy { $0.sensitivityAllDay.count == 0 })
    }

    /// An episode open at the end of one ingest continues with the next one, as when processing resumes.
    func testEpisodeContinuesAcrossIngestCalls() {
        var state = makeState()
        let episode = series(from: day0.addingTimeInterval(22 * hour), count: 12) { self.interval(at: $0, counteraction: -0.5, insulinVelocity: -1.0) }
        TherapyOptimizerEngine.ingest(Array(episode.prefix(5)), scheduledBasal: { _ in 1.0 }, into: &state)
        XCTAssertNotNil(state.openSensitivityEpisode)
        TherapyOptimizerEngine.ingest(Array(episode.dropFirst(5)), scheduledBasal: { _ in 1.0 }, into: &state)
        XCTAssertEqual(state.summaries[0].sensitivityAllDay.median ?? 0, 75, accuracy: 0.0001)
    }

    /// True ISF 50, profile ISF 40, basal 0.5 U/h as needed; CGM in whole mg/dL with up to ±2 mg/dL noise.
    func testSensitivityWithinTenPercentUnderCGMNoise() {
        var state = makeState(basal: 0.5, sensitivity: 40)
        var generator = SeededGenerator(state: 42)
        var all: [TherapyOptimizerInterval] = []
        for index in 0..<5 {
            let start = day0.addingTimeInterval(Double(index) * day + 14 * hour)
            let insulinVelocity = -0.8
            var trueGlucose = 220.0
            var previousReading = (trueGlucose + Double.random(in: -2...2, using: &generator)).rounded()
            for step in 0..<24 {
                trueGlucose += insulinVelocity * 50 / 40 * 5
                let reading = (trueGlucose + Double.random(in: -2...2, using: &generator)).rounded()
                let observedVelocity = (reading - previousReading) / 5
                previousReading = reading
                all.append(interval(at: start.addingTimeInterval(Double(step) * 300), counteraction: observedVelocity - insulinVelocity, insulinVelocity: insulinVelocity, glucose: reading, sensitivity: 40))
            }
        }
        TherapyOptimizerEngine.ingest(all, scheduledBasal: { _ in 0.5 }, into: &state)

        let estimates = state.summaries.flatMap { $0.sensitivityAllDay.values }
        XCTAssertEqual(estimates.count, 10)
        for estimate in estimates {
            XCTAssertEqual(estimate, 50, accuracy: 5)
        }
        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(5 * day))
        XCTAssertEqual(state.sensitivity.dataDaysAllDay, 5)
        XCTAssertEqual(state.sensitivity.calculatedAllDay, 44, accuracy: 0.0001)
    }

    /// Near the classification threshold (|BGI| about 0.75 mg/dL per 5 min) an hour can't rise above CGM noise.
    func testWeakInsulinEffectUnderCGMNoiseGivesNoEstimate() {
        var state = makeState(basal: 0.5)
        var generator = SeededGenerator(state: 7)
        let insulinVelocity = -0.15
        var trueGlucose = 150.0
        var previousReading = trueGlucose.rounded()
        let weak = series(from: day0.addingTimeInterval(14 * hour), count: 36) { start in
            trueGlucose += insulinVelocity * 5
            let reading = (trueGlucose + Double.random(in: -2...2, using: &generator)).rounded()
            defer { previousReading = reading }
            return self.interval(at: start, counteraction: (reading - previousReading) / 5 - insulinVelocity, insulinVelocity: insulinVelocity, glucose: reading)
        }
        TherapyOptimizerEngine.ingest(weak, scheduledBasal: { _ in 0.5 }, into: &state)
        XCTAssertTrue(state.summaries.allSatisfy { $0.sensitivityAllDay.count == 0 })
    }

    func testSensitivityFactorPerGlucoseRange() {
        var state = makeState()
        // 120 mg/dL: falls as predicted for 3 h (estimate 50). 200 mg/dL: falls only 0.8x as fast for 1 h (estimate 40).
        let normal = series(from: day0.addingTimeInterval(19 * hour), count: 36) { self.interval(at: $0, insulinVelocity: -1.0, glucose: 120) }
        let high = series(from: day0.addingTimeInterval(22 * hour), count: 12) { self.interval(at: $0, counteraction: 0.2, insulinVelocity: -1.0, glucose: 200) }
        TherapyOptimizerEngine.ingest(normal + high, scheduledBasal: { _ in 1.0 }, into: &state)
        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(day))

        let ranges = state.sensitivityByGlucose ?? []
        XCTAssertEqual(ranges.count, 5)
        XCTAssertEqual(state.sensitivityByGlucoseReference?.sensitivity ?? 0, 50, accuracy: 0.0001)
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

    /// State written before episodes and meal-based carb ratios: unweighted estimates, carb ratio estimates, startedAt.
    func testLegacyStateStillDecodes() throws {
        var summary = TherapyOptimizerDaySummary(day: day0)
        summary.sensitivityAllDay.add(40)
        var state = makeState()
        state.summaries = [summary]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json["startedAt"] = 0
        var summaries = json["summaries"] as! [[String: Any]]
        summaries[0]["carbRatioAllDay"] = ["values": [12.0], "count": 1] as [String: Any]
        summaries[0]["sensitivityAllDay"] = ["values": [40.0, 60.0], "count": 2] as [String: Any]
        summaries[0].removeValue(forKey: "meals")
        json["summaries"] = summaries
        let decoded = try JSONDecoder().decode(TherapyOptimizerState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.summaries[0].meals)
        XCTAssertEqual(decoded.summaries[0].sensitivityAllDay.median ?? 0, 50, accuracy: 0.0001)
        XCTAssertEqual(decoded.summaries[0].sensitivityAllDay.weight, 2, accuracy: 0.0001)
    }

    // MARK: - Carb ratio

    func testCarbRatioFromThreeMealsAtDailyUpdate() {
        var state = makeState()
        TherapyOptimizerEngine.ingest((0..<3).map { meal(onDay: $0) }, into: &state)
        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(3 * day))
        XCTAssertEqual(state.carbRatio.calculated[12], 11, accuracy: 0.0001)
        XCTAssertEqual(state.carbRatio.calculated[13], 11, accuracy: 0.0001)
        XCTAssertEqual(state.carbRatio.calculated[15], 10, accuracy: 0.0001)
        XCTAssertEqual(state.carbRatio.dataDays[12], 3)
        XCTAssertEqual(state.carbRatio.calculatedAllDay, 11, accuracy: 0.0001)
        XCTAssertEqual(state.carbRatio.dataDaysAllDay, 3)
    }

    func testCarbRatioNeedsThreeMeals() {
        var state = makeState()
        TherapyOptimizerEngine.ingest((0..<2).map { meal(onDay: $0) }, into: &state)
        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(3 * day))
        XCTAssertEqual(state.carbRatio.calculated[12], 10, accuracy: 0.0001)
        XCTAssertEqual(state.carbRatio.dataDays[12], 2)
    }

    /// 120 g over 12 U is 10 g/U, although two of three meals alone would say 20 g/U.
    func testCarbRatioIsTotalCarbsOverTotalInsulin() {
        var state = makeState(carbRatio: 12)
        let meals = [meal(onDay: 0, carbs: 80, netInsulin: 10), meal(onDay: 1, carbs: 20, netInsulin: 1), meal(onDay: 2, carbs: 20, netInsulin: 1)]
        TherapyOptimizerEngine.ingest(meals, into: &state)
        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(3 * day))
        XCTAssertEqual(state.carbRatio.calculatedAllDay, 10.8, accuracy: 0.0001)
    }

    func testSmallMealsAndRescueCarbsAreIgnored() {
        for (name, make) in [("small", { (day: Int) in self.meal(onDay: day, carbs: 10, netInsulin: 1) }),
                             ("rescue", { (day: Int) in self.meal(onDay: day, glucoseStart: 65, minimumGlucose: 60) })] {
            var state = makeState()
            TherapyOptimizerEngine.ingest((0..<3).map(make), into: &state)
            TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(3 * day))
            XCTAssertEqual(state.carbRatio.dataDaysAllDay, 0, name)
            XCTAssertEqual(state.carbRatio.calculatedAllDay, 10, accuracy: 0.0001, name)
        }
    }

    /// A low after a single entry shows a too aggressive ratio; with more entries the extra carbs may be rescue carbs.
    func testMealEndingLowCountsOnlyWithSingleEntry() {
        for (entryCount, expectedDays) in [(Int?.some(1), 3), (2, 0), (nil, 0)] {
            var state = makeState()
            TherapyOptimizerEngine.ingest((0..<3).map { meal(onDay: $0, minimumGlucose: 60, entryCount: entryCount) }, into: &state)
            TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(3 * day))
            XCTAssertEqual(state.carbRatio.dataDaysAllDay, expectedDays, "entries \(String(describing: entryCount))")
        }
    }

    func testMealStillRunningAtUpdateCountsFromNextUpdate() {
        var state = makeState()
        TherapyOptimizerEngine.ingest([meal(onDay: 0), meal(onDay: 1), meal(onDay: 2, atHour: 22)], into: &state)
        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(3 * day))
        XCTAssertEqual(state.carbRatio.dataDaysAllDay, 2)
        TherapyOptimizerEngine.applyDailyUpdate(to: &state, on: day0.addingTimeInterval(4 * day))
        XCTAssertEqual(state.carbRatio.dataDaysAllDay, 3)
    }

    // MARK: - Meal windows

    /// Readings every 5 minutes from 1 h before `start`; carbs on board 20 g until `carbsUntil`.
    private func buildMeals(start: Date, entries: [(start: Date, grams: Double)], end: Date, carbsUntil: TimeInterval, glucose: (TimeInterval) -> Double = { _ in 120 }, insulinOnBoard: (TimeInterval) -> Double = { _ in 0 }, doses: [DoseEntry] = []) -> (meals: [TherapyOptimizerMeal], cutoff: Date) {
        let offsets = stride(from: -hour, through: end.timeIntervalSince(start), by: 300).map { $0 }
        return TherapyOptimizer.buildMeals(
            entries: entries,
            end: end,
            carbsOnBoard: offsets.map { (date: start.addingTimeInterval($0), grams: $0 < carbsUntil ? 20 : 0) },
            glucose: offsets.map { (date: start.addingTimeInterval($0), value: glucose($0)) },
            doses: doses,
            netInsulinOnBoard: offsets.map { (date: start.addingTimeInterval($0), units: insulinOnBoard($0)) },
            scheduledBasal: { _ in 1.0 },
            unitScale: 1,
            overrides: []
        )
    }

    func testMealWindowEndsOnlyWithLittleInsulinOnBoard() {
        let start = day0.addingTimeInterval(12 * hour)
        let built = buildMeals(start: start, entries: [(start: start, grams: 50)], end: start.addingTimeInterval(8 * hour), carbsUntil: 2 * hour, insulinOnBoard: { $0 < 3 * self.hour + 55 * 60 ? 2 : 0.5 })
        XCTAssertEqual(built.meals.count, 1)
        XCTAssertEqual(built.meals.first?.end, start.addingTimeInterval(4 * hour))
        XCTAssertEqual(built.cutoff, start.addingTimeInterval(8 * hour))
    }

    func testMealWindowEndsOnlyWithStableGlucose() {
        let start = day0.addingTimeInterval(12 * hour)
        // Falls 1 mg/dL per minute until 3:30, then flat: the 15-minute change first drops to 10 at 3:35.
        let glucose = { (offset: TimeInterval) in 120 + max(0, 210 * 60 - offset) / 60 }
        let built = buildMeals(start: start, entries: [(start: start, grams: 50)], end: start.addingTimeInterval(8 * hour), carbsUntil: 2 * hour, glucose: glucose)
        XCTAssertEqual(built.meals.first?.end, start.addingTimeInterval(3 * hour + 35 * 60))
        // Mean of the readings at 3:25, 3:30 and 3:35.
        XCTAssertEqual(built.meals.first?.glucoseEnd ?? 0, (125 + 120 + 120) / 3, accuracy: 0.0001)
    }

    /// A pre-bolus counts through insulin on board at the start; a bolus at the start is counted once.
    func testMealInsulinIncludesPreBolusAndStartInsulinOnBoard() {
        let start = day0.addingTimeInterval(12 * hour)
        let doses = [
            DoseEntry(type: .bolus, startDate: start.addingTimeInterval(-15 * 60), endDate: start.addingTimeInterval(-15 * 60), value: 4, unit: .units),
            DoseEntry(type: .bolus, startDate: start, endDate: start, value: 2, unit: .units),
            DoseEntry(type: .bolus, startDate: start.addingTimeInterval(30 * 60), endDate: start.addingTimeInterval(30 * 60), value: 1, unit: .units),
        ]
        let insulinOnBoard = { (offset: TimeInterval) -> Double in
            switch offset {
            case ..<(-15 * 60): return 0
            case ..<0: return 4
            case ..<(2 * self.hour + 55 * 60): return 7
            default: return 0
            }
        }
        let built = buildMeals(start: start, entries: [(start: start, grams: 70)], end: start.addingTimeInterval(8 * hour), carbsUntil: 2 * hour, insulinOnBoard: insulinOnBoard, doses: doses)
        XCTAssertEqual(built.meals.first?.end, start.addingTimeInterval(3 * hour))
        XCTAssertEqual(built.meals.first?.netInsulin ?? 0, 2 + 1 + 4, accuracy: 0.0001)
    }

    func testMealGroupsEntriesAndAveragesThreeReadings() {
        let start = day0.addingTimeInterval(12 * hour)
        let glucose = { (offset: TimeInterval) -> Double in
            switch offset {
            case -10 * 60: return 110
            case -5 * 60: return 120
            case 0: return 160
            default: return 130
            }
        }
        let entries = [(start: start, grams: 40.0), (start: start.addingTimeInterval(hour), grams: 20.0)]
        let built = buildMeals(start: start, entries: entries, end: start.addingTimeInterval(8 * hour), carbsUntil: 2 * hour, glucose: glucose)
        XCTAssertEqual(built.meals.count, 1)
        XCTAssertEqual(built.meals.first?.carbs, 60)
        XCTAssertEqual(built.meals.first?.entryCount, 2)
        XCTAssertEqual(built.meals.first?.glucoseStart ?? 0, 130, accuracy: 0.0001)
    }

    func testUnsettledMealWaitsForLaterData() {
        let start = day0.addingTimeInterval(12 * hour)
        let built = buildMeals(start: start, entries: [(start: start, grams: 50)], end: start.addingTimeInterval(4 * hour), carbsUntil: 5 * hour)
        XCTAssertTrue(built.meals.isEmpty)
        XCTAssertEqual(built.cutoff, start)
    }

    // MARK: - Replay from stored days

    private func rawDay(_ index: Int, intervals: [TherapyOptimizerInterval]) -> TherapyOptimizerRawDay {
        var raw = TherapyOptimizerRawDay(day: day0.addingTimeInterval(Double(index) * day), basalSchedule: [TherapyOptimizerScheduleItem(startTime: 0, value: 1.0)])
        raw.intervals = intervals
        return raw
    }

    func testReplayFromStoredDaysMatchesLiveProcessing() {
        var older = TherapyOptimizerDaySummary(day: day0)
        older.basalDeviation[12].add(1.2, minutes: 60)
        var live = makeState()
        live.summaries = [older]
        // Corrections from 23:45 to 00:45 continue across the stored days.
        let corrections = (1...2).flatMap { index in
            series(from: day0.addingTimeInterval(Double(index) * day + 23.75 * hour), count: 12) { self.interval(at: $0, counteraction: -0.3, insulinVelocity: -1.0) }
        }
        TherapyOptimizerEngine.applyDailyUpdate(to: &live, on: day0)
        var rawDays: [TherapyOptimizerRawDay] = []
        for index in 1...3 {
            let dayStart = day0.addingTimeInterval(Double(index) * day)
            let basal = series(from: dayStart.addingTimeInterval(10 * hour), count: 36) { self.interval(at: $0, counteraction: 0.4) }
            var raw = rawDay(index, intervals: (basal + corrections.filter { $0.start >= dayStart && $0.start < dayStart.addingTimeInterval(day) }).sorted { $0.start < $1.start })
            raw.meals = [meal(onDay: index, carbs: 50 + Double(index) * 5)]
            TherapyOptimizerEngine.applyDailyUpdate(to: &live, on: raw.day)
            TherapyOptimizerEngine.ingest(raw.intervals, scheduledBasal: { _ in 1.0 }, into: &live)
            TherapyOptimizerEngine.ingest(raw.meals, into: &live)
            rawDays.append(raw)
        }
        let through = day0.addingTimeInterval(4 * day)
        TherapyOptimizerEngine.applyDailyUpdate(to: &live, on: through)
        XCTAssertEqual(live.carbRatio.dataDaysAllDay, 3)
        XCTAssertGreaterThan(live.summaries.reduce(0) { $0 + $1.sensitivityAllDay.count }, 0)

        var replayed = live
        TherapyOptimizerEngine.replay(&replayed, rawDays: rawDays, through: through)
        XCTAssertEqual(replayed, live)
    }

    func testReplayReadsStoredDaysWithoutNewerFields() throws {
        var raw = rawDay(1, intervals: nightIntervals(onDay: 1))
        raw.meals = [meal(onDay: 1)]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(raw)) as! [String: Any]
        json.removeValue(forKey: "basalSegments")
        json.removeValue(forKey: "overrides")
        var meals = json["meals"] as! [[String: Any]]
        meals[0].removeValue(forKey: "entryCount")
        json["meals"] = meals
        let legacy = try JSONDecoder().decode(TherapyOptimizerRawDay.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.overrides)
        XCTAssertNil(legacy.meals[0].entryCount)

        var state = makeState()
        TherapyOptimizerEngine.replay(&state, rawDays: [legacy], through: day0.addingTimeInterval(2 * day))
        XCTAssertEqual(basalMinutes(state), 36 * 5, accuracy: 0.0001)
        XCTAssertEqual(state.summaries.flatMap { $0.meals ?? [] }.count, 1)
    }

    func testStoredDaysRoundTripThroughJSON() throws {
        var raw = rawDay(0, intervals: nightIntervals(onDay: 0))
        raw.meals = [meal(onDay: 0)]
        raw.basalSegments = [TherapyOptimizerBasalSegment(start: day0, end: day0.addingTimeInterval(hour), rate: 0.8)]
        raw.overrides = [DateInterval(start: day0, duration: hour)]
        XCTAssertEqual(try JSONDecoder().decode(TherapyOptimizerRawDay.self, from: JSONEncoder().encode(raw)), raw)

        var source = TherapyOptimizerSourceDay(
            day: day0,
            basalSchedule: [TherapyOptimizerScheduleItem(startTime: 0, value: 1.0)],
            sensitivitySchedule: [TherapyOptimizerScheduleItem(startTime: 0, value: 50)],
            carbRatioSchedule: [TherapyOptimizerScheduleItem(startTime: 0, value: 10)]
        )
        source.doses = [DoseEntry(type: .bolus, startDate: day0, endDate: day0, value: 2, unit: .units)]
        source.overrides = [DateInterval(start: day0, duration: hour)]
        let decoded = try JSONDecoder().decode(TherapyOptimizerSourceDay.self, from: JSONEncoder().encode(source))
        XCTAssertEqual(decoded.day, source.day)
        XCTAssertEqual(decoded.basalSchedule, source.basalSchedule)
        XCTAssertEqual(decoded.sensitivitySchedule, source.sensitivitySchedule)
        XCTAssertEqual(decoded.carbRatioSchedule, source.carbRatioSchedule)
        XCTAssertEqual(decoded.doses, source.doses)
        XCTAssertEqual(decoded.overrides, source.overrides)
    }

    /// Days stored at UTC midnight are found again after moving to New York, one summary per date.
    func testReplayAfterTimeZoneChange() {
        let rawDays = (0..<3).map { rawDay($0, intervals: nightIntervals(onDay: $0)) }
        var state = makeState(timeZone: TimeZone(identifier: "America/New_York")!)
        TherapyOptimizerEngine.replay(&state, rawDays: rawDays, through: day0.addingTimeInterval(3 * day))
        XCTAssertEqual(basalMinutes(state), 3 * 36 * 5, accuracy: 0.0001)
        let keys = state.summaries.map { TherapyOptimizerMath.dayKey($0.day, calendar: state.calendar) }
        XCTAssertEqual(keys, Array(Set(keys)).sorted())
    }

    func testSummaryOfOtherTimeZoneIsReusedForSameDate() {
        var state = makeState(timeZone: TimeZone(identifier: "America/New_York")!)
        // 2023-11-14 at UTC midnight is still 2023-11-13 in New York, but the stored day means the 14th.
        state.summaries = [TherapyOptimizerDaySummary(day: day0)]
        let noon = state.calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day0.addingTimeInterval(12 * hour))!
        TherapyOptimizerEngine.ingest([interval(at: noon.addingTimeInterval(3 * hour))], scheduledBasal: { _ in 1.0 }, into: &state)
        XCTAssertEqual(state.summaries.count, 1)
        XCTAssertEqual(state.summaries[0].basalDeviation[12].minutes, 5.0 / 3, accuracy: 0.0001)
    }

    func testTimeZoneIsPartOfStartValues() {
        XCTAssertTrue(makeState().hasSameStartValues(as: makeState()))
        XCTAssertFalse(makeState().hasSameStartValues(as: makeState(timeZone: TimeZone(identifier: "Europe/Berlin")!)))
    }

    func testStoredDayUsesAnnotatedBasalBeforeSchedule() {
        let utcCalendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = utc
            return calendar
        }()
        var raw = rawDay(0, intervals: [])
        // E.g. U200 0.4 U/h before a switch, stored as 0.8 U100 U/h.
        raw.basalSegments = [TherapyOptimizerBasalSegment(start: day0.addingTimeInterval(2 * hour), end: day0.addingTimeInterval(3 * hour), rate: 0.8)]
        XCTAssertEqual(raw.scheduledBasal(at: day0.addingTimeInterval(2.5 * hour), calendar: utcCalendar), 0.8)
        XCTAssertEqual(raw.scheduledBasal(at: day0.addingTimeInterval(3 * hour), calendar: utcCalendar), 1.0)
    }

    func testRepeatedReplayDoesNotAddToOlderSummaries() {
        var older = TherapyOptimizerDaySummary(day: day0)
        older.basalDeviation[12].add(1.2, minutes: 60)
        var state = makeState()
        state.summaries = [older]
        // 02:00-05:00 also attributes back to 23:00 of the older day.
        let rawDays = [rawDay(1, intervals: nightIntervals(onDay: 1))]
        TherapyOptimizerEngine.replay(&state, rawDays: rawDays, through: day0.addingTimeInterval(2 * day))
        let once = state
        TherapyOptimizerEngine.replay(&state, rawDays: rawDays, through: day0.addingTimeInterval(2 * day))
        XCTAssertEqual(state, once)
        XCTAssertEqual(state.summaries.first, older)
    }

    // MARK: - Window, retention, export

    func testWindowSelectsDays() {
        var state = makeState()
        for index in 0..<40 {
            var summary = TherapyOptimizerDaySummary(day: day0.addingTimeInterval(Double(index) * day))
            let value = index < 30 ? 1.5 : 0.95
            summary.basalDeviation[5].add(value, minutes: 60)
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
        // Median 0.95 shrunk with 14 of 21 parts to 0.9667, smoothed with 1.0 on both sides.
        XCTAssertEqual(narrow.basal.calculated[5], 1 - 0.05 * 14 / 21 / 2, accuracy: 0.0001)
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
        state.sensitivity.dataDaysAllDay = 5

        let hourly = state.calculatedSensitivitySchedule(hourly: true)
        XCTAssertEqual(hourly?.items.map { $0.value }, [55, 60, 55])
        XCTAssertEqual(hourly?.items.map { $0.startTime }, [0, 7 * hour, 8 * hour])

        let allDay = state.calculatedSensitivitySchedule(hourly: false)
        XCTAssertEqual(allDay?.items.map { $0.value }, [55])
    }

    func testValuesWithFewerThanThreeDataDaysAreNotExported() {
        var state = makeState()
        state.basal.calculated = Array(repeating: 1.2, count: 24)
        state.basal.dataDays = Array(repeating: 2, count: 24)
        state.basal.dataDays[6] = 3
        XCTAssertEqual(state.calculatedBasalSchedule(maximumBasalRate: nil, maximumEntryCount: nil)?.items.map { $0.value }, [1.0, 1.2, 1.0])

        state.sensitivity.calculatedAllDay = 60
        state.sensitivity.dataDaysAllDay = 2
        XCTAssertEqual(state.calculatedSensitivitySchedule(hourly: false)?.items.map { $0.value }, [50])
        state.carbRatio.calculated = Array(repeating: 12, count: 24)
        state.carbRatio.dataDays = Array(repeating: 2, count: 24)
        XCTAssertEqual(state.calculatedCarbRatioSchedule(hourly: true)?.items.map { $0.value }, [10])
    }

    func testBasalExportRoundsAndRespectsMaximum() {
        var state = makeState()
        state.basal.calculated = Array(repeating: 1.03, count: 24)
        state.basal.calculated[3] = 1.4
        state.basal.dataDays = Array(repeating: 3, count: 24)

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
        state.basal.dataDays = Array(repeating: 3, count: 24)

        let values = state.calculatedBasalSchedule(maximumBasalRate: nil, maximumEntryCount: nil)?.items.map { $0.value }
        XCTAssertEqual(values, [Double(14) / 20, Double(15) / 20, Double(3) / 20, Double(14) / 20])
    }

    func testSettingValueForOneHourSplitsAndMergesSchedule() {
        let items = [RepeatingScheduleValue(startTime: 0, value: 1.0), RepeatingScheduleValue(startTime: 6 * hour, value: 1.2)]

        let night = TherapyOptimizerMath.settingValue(1.1, forHour: 1, in: items)
        XCTAssertEqual(night.map { $0.startTime }, [0, hour, 2 * hour, 6 * hour])
        XCTAssertEqual(night.map { $0.value }, [1.0, 1.1, 1.0, 1.2])

        let beforeChange = TherapyOptimizerMath.settingValue(1.2, forHour: 5, in: items)
        XCTAssertEqual(beforeChange.map { $0.startTime }, [0, 5 * hour])
        XCTAssertEqual(beforeChange.map { $0.value }, [1.0, 1.2])
    }

    func testAllDayChangeKeepsHourlyProfileShape() {
        var state = makeState(sensitivity: 50)
        state.sensitivity = TherapyOptimizerValues(hourly: (0..<24).map { $0 < 12 ? 40.0 : 60.0 })
        state.sensitivity.calculatedAllDay = 55
        state.sensitivity.dataDaysAllDay = 5
        state.sensitivity.calculated[3] = 30
        state.sensitivity.dataDays[3] = 5

        XCTAssertEqual(state.sensitivity.scaledStart[0], 44, accuracy: 0.0001)
        XCTAssertEqual(state.sensitivity.scaledStart[20], 66, accuracy: 0.0001)
        let hourly = state.sensitivity.exportHourly(minimumDataDays: TherapyOptimizerEngine.reliableHourDataDays)
        XCTAssertEqual(hourly[3], 30, accuracy: 0.0001)
        XCTAssertEqual(hourly[4], 44, accuracy: 0.0001)
        XCTAssertEqual(hourly[13], 66, accuracy: 0.0001)
    }

    func testUnitsIntegratesHourlyRate() {
        let units = TherapyOptimizerMath.units(from: day0, to: day0.addingTimeInterval(2 * hour + 150)) { $0 < self.day0.addingTimeInterval(self.hour) ? 1.2 : 0.6 }
        XCTAssertEqual(units, 1.2 + 0.6 + 0.6 * 150 / 3600, accuracy: 0.0001)
    }

    func testStateWithConcentrationTimelineStillDecodes() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(makeState())) as! [String: Any]
        json["concentrationTimeline"] = [["start": 0, "concentration": 200]]
        let decoded = try JSONDecoder().decode(TherapyOptimizerState.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, makeState())
        XCTAssertEqual(decoded.sensitivityUnit, .milligramsPerDeciliter)
    }

    func testStateRoundTripsThroughJSON() throws {
        var state = makeState()
        TherapyOptimizerEngine.ingest(nightIntervals(onDay: 0), scheduledBasal: { _ in 1.0 }, into: &state)
        TherapyOptimizerEngine.ingest(series(from: day0.addingTimeInterval(10 * hour), count: 5) { self.interval(at: $0, insulinVelocity: -1.0) }, scheduledBasal: { _ in 1.0 }, into: &state)
        XCTAssertNotNil(state.openSensitivityEpisode)
        state.overrideIntervals = [DateInterval(start: day0, duration: hour)]
        let decoded = try JSONDecoder().decode(TherapyOptimizerState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
    }

    // MARK: - Glucose-dependent factor

    private func factorState(_ factors: [Double?], dataDays: Int = 1_000_000, latestDay: Date? = nil) -> TherapyOptimizerState {
        var state = makeState()
        state.summaries = [TherapyOptimizerDaySummary(day: latestDay ?? day0)]
        state.sensitivityByGlucoseReference = TherapyOptimizerGlucoseRangeSensitivity(sensitivity: 50, factor: 1, dataDays: dataDays)
        state.sensitivityByGlucose = factors.map { TherapyOptimizerGlucoseRangeSensitivity(sensitivity: nil, factor: $0, dataDays: dataDays) }
        return state
    }

    private func factor(_ glucose: Double, _ state: TherapyOptimizerState, now: Date? = nil) -> Double? {
        TherapyOptimizerEngine.dosingSensitivityFactor(forGlucose: glucose, in: state, now: now ?? day0.addingTimeInterval(day))
    }

    func testFactorIsContinuousAcrossRangeBorders() {
        let state = factorState([nil, 1.2, 1.0, 0.85, 1.1])
        for border in [100.0, 180, 250] {
            XCTAssertEqual(factor(border - 0.01, state) ?? 0, factor(border + 0.01, state) ?? 1, accuracy: 0.001, "at \(border)")
        }
        XCTAssertEqual(factor(140, state) ?? 0, 1.0, accuracy: 0.001)
        XCTAssertEqual(factor(177.5, state) ?? 0, 0.925, accuracy: 0.001)
        XCTAssertEqual(factor(70, state) ?? 0, 1.2, accuracy: 0.001)
        XCTAssertEqual(factor(400, state) ?? 0, 1.1, accuracy: 0.001)
    }

    func testFactorShrinksTowardOneWithFewDataDays() {
        XCTAssertEqual(factor(215, factorState(Array(repeating: 0.9, count: 5), dataDays: 14)) ?? 0, 0.95, accuracy: 0.0001)
        XCTAssertEqual(factor(215, factorState([nil, nil, nil, nil, nil], dataDays: 14)) ?? 0, 1.0, accuracy: 0.0001)
    }

    func testFactorIsClamped() {
        XCTAssertEqual(factor(215, factorState(Array(repeating: 0.5, count: 5))) ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(factor(215, factorState(Array(repeating: 2.0, count: 5))) ?? 0, 1.2, accuracy: 0.0001)
    }

    func testNoFactorBelowSeventyWithTooFewDaysOrStaleData() {
        let state = factorState(Array(repeating: 0.9, count: 5))
        XCTAssertNil(factor(69.9, state))
        XCTAssertNotNil(factor(70, state))
        XCTAssertNil(factor(150, factorState(Array(repeating: 0.9, count: 5), dataDays: 2)))
        XCTAssertNotNil(factor(150, state, now: day0.addingTimeInterval(3 * day)))
        XCTAssertNil(factor(150, state, now: day0.addingTimeInterval(3 * day + 1)))
    }

    func testGridRounding() {
        XCTAssertEqual(TherapyOptimizerMath.roundedToGrid(0.125, stepsPerUnit: 20), 0.15)
        XCTAssertEqual(TherapyOptimizerMath.roundedToGrid(0.149, stepsPerUnit: 20, rule: .down), 0.1)
        // 0.05 * 0.7 / 0.7 is just below 0.05 in floating point; rounding down keeps 0.05.
        XCTAssertEqual(TherapyOptimizerMath.roundedToGrid(0.05 * 0.7 / 0.7, stepsPerUnit: 20, rule: .down), 0.05)
        XCTAssertEqual(TherapyOptimizerMath.roundedToGrid(12.34, stepsPerUnit: 10), 12.3)
    }
}
