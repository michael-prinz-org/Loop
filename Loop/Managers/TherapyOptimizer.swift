//
//  TherapyOptimizer.swift
//  Loop
//
//  Autotune-style estimation of basal rates, insulin sensitivity and carb ratios.
//  Never changes dosing by itself: calculated values only reach Loop when the user creates a profile
//  from them and activates it.
//

import Foundation
import HealthKit
import LoopKit

/// One CGM interval (normally 5 min) with everything needed to classify and evaluate it.
struct TherapyOptimizerInterval: Codable, Equatable {
    let start: Date
    let end: Date
    /// mg/dL at the end of the interval
    let glucose: Double
    /// Insulin counteraction effect, mg/dL/min
    let counteraction: Double
    /// Expected glucose velocity from insulin net of the scheduled basal, mg/dL/min (negative = lowering)
    let insulinVelocity: Double
    /// grams
    let carbsOnBoard: Double
    /// Insulin sensitivity Loop used for its effect calculation, mg/dL/U
    let sensitivity: Double
    let isSuspended: Bool
    let isOverrideActive: Bool
}

struct TherapyOptimizerScheduleItem: Codable, Equatable {
    let startTime: TimeInterval
    let value: Double
}

/// Scheduled basal (U100 U/h) a dose was annotated with, i.e. what Loop's insulin effect was net of.
struct TherapyOptimizerBasalSegment: Codable, Equatable {
    let start: Date
    let end: Date
    let rate: Double

    static func rate(at date: Date, in segments: [TherapyOptimizerBasalSegment]) -> Double? {
        segments.last { $0.start <= date && date < $0.end }?.rate
    }
}

/// Input of one calendar day (all U100), kept for the whole retention so recalculation is not limited to Loop's local history.
struct TherapyOptimizerRawDay: Codable, Equatable {
    let day: Date
    /// Fallback where no basal segment covers a date.
    var basalSchedule: [TherapyOptimizerScheduleItem]
    /// From 3 h before the day to its end; optional so files written before this field existed still decode.
    var basalSegments: [TherapyOptimizerBasalSegment]?
    var intervals: [TherapyOptimizerInterval] = []
    var meals: [TherapyOptimizerMeal] = []

    init(day: Date, basalSchedule: [TherapyOptimizerScheduleItem]) {
        self.day = day
        self.basalSchedule = basalSchedule
    }

    func scheduledBasal(at date: Date, calendar: Calendar) -> Double {
        if let rate = TherapyOptimizerBasalSegment.rate(at: date, in: basalSegments ?? []) {
            return rate
        }
        let offset = date.timeIntervalSince(calendar.startOfDay(for: date))
        return (basalSchedule.last { $0.startTime <= offset } ?? basalSchedule.first)?.value ?? 0
    }
}

/// Loop's original records of one day, so later algorithm versions can derive everything again from scratch.
/// Insulin amounts and rates are U100 units, whatever insulin was in the pump.
struct TherapyOptimizerSourceDay: Codable {
    let day: Date
    /// U/h, mg/dL/U and g/U as set when the day was collected.
    var basalSchedule: [TherapyOptimizerScheduleItem]
    var sensitivitySchedule: [TherapyOptimizerScheduleItem]
    var carbRatioSchedule: [TherapyOptimizerScheduleItem]
    var glucose: [StoredGlucoseSample] = []
    var doses: [DoseEntry] = []
    var carbEntries: [StoredCarbEntry] = []
    var overrides: [DateInterval] = []

    init(day: Date, basalSchedule: [TherapyOptimizerScheduleItem], sensitivitySchedule: [TherapyOptimizerScheduleItem], carbRatioSchedule: [TherapyOptimizerScheduleItem]) {
        self.day = day
        self.basalSchedule = basalSchedule
        self.sensitivitySchedule = sensitivitySchedule
        self.carbRatioSchedule = carbRatioSchedule
    }
}

/// A completed meal window (one or more merged carb entries until carbs on board are absorbed).
struct TherapyOptimizerMeal: Codable, Equatable {
    let start: Date
    let end: Date
    /// grams
    let carbs: Double
    /// Boluses + net basal delivered in the window + net IOB at start - net IOB at end, U
    let netInsulin: Double
    /// Integral of the scheduled basal over the window, U
    let scheduledBasalUnits: Double
    let glucoseStart: Double
    let glucoseEnd: Double
    let minimumGlucose: Double
    let isOverrideActive: Bool
}

/// A rate weighted by the minutes it was observed.
struct TherapyOptimizerRateSum: Codable, Equatable {
    var weightedSum: Double = 0
    var minutes: Double = 0

    mutating func add(_ value: Double, minutes: Double) {
        weightedSum += value * minutes
        self.minutes += minutes
    }

    var mean: Double? {
        minutes > 0 ? weightedSum / minutes : nil
    }
}

/// Raw estimates while a day is open; reduced to median + count once the day is closed.
struct TherapyOptimizerEstimates: Codable, Equatable {
    var values: [Double] = []
    var compactedMedian: Double?
    var count = 0

    mutating func add(_ value: Double) {
        values.append(value)
        count += 1
    }

    var median: Double? {
        compactedMedian ?? TherapyOptimizerMath.median(values)
    }

    mutating func compact() {
        compactedMedian = median
        values = []
    }
}

/// All estimates attributed to one calendar day, per hour of day.
struct TherapyOptimizerDaySummary: Codable, Equatable {
    let day: Date
    var basalDeviation = Array(repeating: TherapyOptimizerRateSum(), count: 24)
    var sensitivity = Array(repeating: TherapyOptimizerEstimates(), count: 24)
    var sensitivityAllDay = TherapyOptimizerEstimates()
    var carbRatio = Array(repeating: TherapyOptimizerEstimates(), count: 24)
    var carbRatioAllDay = TherapyOptimizerEstimates()
    /// Optional so state saved before this field existed still decodes.
    var sensitivityByGlucose: [TherapyOptimizerEstimates]?
    var isCompacted = false

    init(day: Date) {
        self.day = day
    }

    mutating func compact() {
        for hour in 0..<24 {
            sensitivity[hour].compact()
            carbRatio[hour].compact()
        }
        sensitivityAllDay.compact()
        carbRatioAllDay.compact()
        sensitivityByGlucose = sensitivityByGlucose?.map { estimates in
            var estimates = estimates
            estimates.compact()
            return estimates
        }
        isCompacted = true
    }
}

/// Insulin sensitivity observed while glucose was within one range, relative to the overall value.
struct TherapyOptimizerGlucoseRangeSensitivity: Codable, Equatable {
    /// mg/dL/U
    var sensitivity: Double?
    var factor: Double?
    var dataDays: Int
}

/// 24 hourly values plus an all-day value, each with its start value and the number of days with data.
struct TherapyOptimizerValues: Codable, Equatable {
    var start: [Double]
    var calculated: [Double]
    var dataDays: [Int]
    var startAllDay: Double
    var calculatedAllDay: Double
    var dataDaysAllDay: Int

    init(hourly: [Double]) {
        start = hourly
        calculated = hourly
        dataDays = Array(repeating: 0, count: 24)
        startAllDay = hourly.isEmpty ? 0 : hourly.reduce(0, +) / Double(hourly.count)
        calculatedAllDay = startAllDay
        dataDaysAllDay = 0
    }

    mutating func resetCalculated() {
        calculated = start
        calculatedAllDay = startAllDay
        dataDays = Array(repeating: 0, count: 24)
        dataDaysAllDay = 0
    }

    /// Hours with too few days of data fall back to the all-day value.
    func exportHourly(minimumDataDays: Int) -> [Double] {
        (0..<24).map { dataDays[$0] >= minimumDataDays ? calculated[$0] : calculatedAllDay }
    }
}

struct TherapyOptimizerState: Codable, Equatable {
    static let windowOptions = [14, 30, 60, 90]
    static let retainedDays = 90

    var startedAt: Date
    var timeZone: TimeZone
    var windowDays = 30
    var basal: TherapyOptimizerValues
    /// mg/dL/U
    var sensitivity: TherapyOptimizerValues
    /// g/U
    var carbRatio: TherapyOptimizerValues
    /// Persisted form of `sensitivityUnit`
    private var sensitivityUnitString: String
    var summaries: [TherapyOptimizerDaySummary] = []
    var overrideIntervals: [DateInterval] = []
    var lastProcessedDate: Date
    var mealCutoffDate: Date
    var lastDailyUpdate: Date?
    var hypoHoldUntil: Date?
    var unexplainedRiseSince: Date?
    /// Counteraction of the last few intervals, mg/dL/min; smooths CGM noise for the unannounced-meal check.
    var recentCounteraction: [Double]?
    /// One entry per `TherapyOptimizerEngine.glucoseRangeUpperBounds` range; display-only.
    var sensitivityByGlucose: [TherapyOptimizerGlucoseRangeSensitivity]?

    /// All values are in U100 units.
    init(startedAt: Date, timeZone: TimeZone, basal: [Double], sensitivity: [Double], carbRatio: [Double], sensitivityUnit: HKUnit, processingStart: Date) {
        self.startedAt = startedAt
        self.timeZone = timeZone
        self.basal = TherapyOptimizerValues(hourly: basal)
        self.sensitivity = TherapyOptimizerValues(hourly: sensitivity)
        self.carbRatio = TherapyOptimizerValues(hourly: carbRatio)
        self.sensitivityUnitString = sensitivityUnit.unitString
        self.lastProcessedDate = processingStart
        self.mealCutoffDate = processingStart
    }

    /// Unit of the user's insulin sensitivity schedule, used for display and export
    var sensitivityUnit: HKUnit {
        HKUnit(from: sensitivityUnitString)
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

enum TherapyOptimizerMath {
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    static func weightedMedian(_ samples: [(value: Double, weight: Double)]) -> Double? {
        let sorted = samples.filter { $0.weight > 0 }.sorted { $0.value < $1.value }
        let total = sorted.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var cumulative = 0.0
        for sample in sorted {
            cumulative += sample.weight
            if cumulative >= total / 2 {
                return sample.value
            }
        }
        return sorted.last?.value
    }

    /// Value of a daily schedule at each full hour.
    static func hourlyValues(_ items: [RepeatingScheduleValue<Double>]) -> [Double] {
        let sorted = items.sorted { $0.startTime < $1.startTime }
        return (0..<24).map { (hour: Int) -> Double in
            let offset = TimeInterval(hour * 3600)
            return (sorted.last { $0.startTime <= offset } ?? sorted.first)?.value ?? 0
        }
    }

    /// One schedule item per hour, merging equal neighbours.
    static func scheduleItems(_ hourly: [Double]) -> [RepeatingScheduleValue<Double>] {
        var items: [RepeatingScheduleValue<Double>] = []
        for (hour, value) in hourly.enumerated() where items.last?.value != value {
            items.append(RepeatingScheduleValue(startTime: TimeInterval(hour * 3600), value: value))
        }
        return items
    }

    /// Integral of an hourly rate over the range, in 5-minute steps.
    static func units(from start: Date, to end: Date, rate: (Date) -> Double) -> Double {
        var units = 0.0
        var date = start
        while date < end {
            let next = min(end, date.addingTimeInterval(5 * 60))
            units += rate(date) * next.timeIntervalSince(date) / 3600
            date = next
        }
        return units
    }
}

enum TherapyOptimizerEngine {
    static let maximumDailyChange = 0.10
    static let lowerLimit = 0.7
    static let upperLimit = 1.3
    static let basalMinimumMinutes = 15.0
    static let sensitivityMinimumHourly = 3
    static let sensitivityMinimumAllDay = 6
    static let carbRatioMinimum = 1
    static let reliableHourDataDays = 3

    static let hypoThreshold = 70.0
    static let hypoHold: TimeInterval = 60 * 60
    /// Mean counteraction (mg/dL/min) over `unexplainedRiseIntervals` without carbs that marks an unannounced meal.
    /// A dawn rise stays well below this even while Loop is correcting it.
    static let unexplainedRiseThreshold = 1.5
    static let unexplainedRiseIntervals = 3
    static let unexplainedRiseMaximum: TimeInterval = 3 * 60 * 60
    static let sensitivityRatioRange = 0.25...4.0
    static let carbRatioRange = 3.0...40.0
    static let minimumMealInsulin = 0.3
    /// mg/dL; values at or above the last bound fall into an extra top range.
    static let glucoseRangeUpperBounds: [Double] = [70, 100, 180, 250]
    static var glucoseRangeCount: Int { glucoseRangeUpperBounds.count + 1 }
    static let glucoseRangeMinimumDaily = 3

    static func glucoseRangeIndex(for glucose: Double) -> Int {
        glucoseRangeUpperBounds.firstIndex { glucose < $0 } ?? glucoseRangeUpperBounds.count
    }

    // MARK: - Ingestion

    static func ingest(_ intervals: [TherapyOptimizerInterval], scheduledBasal: (Date) -> Double, into state: inout TherapyOptimizerState) {
        let calendar = state.calendar
        var recent = state.recentCounteraction ?? []
        defer { state.recentCounteraction = recent }
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            let minutes = interval.end.timeIntervalSince(interval.start) / 60
            guard minutes >= 2, minutes <= 10 else { continue }

            if interval.glucose < hypoThreshold {
                state.hypoHoldUntil = interval.end.addingTimeInterval(hypoHold)
            }
            recent = Array((recent + [interval.counteraction]).suffix(unexplainedRiseIntervals))
            let recentRise = recent.reduce(0, +) / Double(recent.count)
            if let since = state.unexplainedRiseSince,
               recentRise <= 0 || interval.start.timeIntervalSince(since) > unexplainedRiseMaximum {
                state.unexplainedRiseSince = nil
            } else if state.unexplainedRiseSince == nil, interval.carbsOnBoard <= 0, recentRise > unexplainedRiseThreshold {
                state.unexplainedRiseSince = interval.start
            }

            let isHypoHold = state.hypoHoldUntil.map { interval.start < $0 } ?? false
            guard !interval.isOverrideActive, !interval.isSuspended, !isHypoHold,
                  state.unexplainedRiseSince == nil, interval.carbsOnBoard <= 0, interval.sensitivity > 0 else {
                continue
            }

            // Autotune categorisation: ISF only while extra insulin clearly dominates the scheduled basal and glucose is
            // not rising faster than twice the insulin effect; such a rise without carbs is a basal deficit, whoever corrected it.
            let glucoseVelocity = interval.counteraction + interval.insulinVelocity
            let basalVelocity = scheduledBasal(interval.start) * interval.sensitivity / 60
            let isRising = glucoseVelocity > 0 && glucoseVelocity > -2 * interval.insulinVelocity
            if -4 * interval.insulinVelocity > basalVelocity, !isRising {
                addSensitivityEstimate(for: interval, scheduledBasal: scheduledBasal, calendar: calendar, into: &state)
            } else {
                addBasalEstimates(for: interval, minutes: minutes, scheduledBasal: scheduledBasal, calendar: calendar, into: &state)
            }
        }
    }

    /// Basal need shows up in glucose 1-3 h later, so it is attributed to those earlier hours.
    /// Counteraction nets out all delivered insulin (Loop or manual), so this holds in open and closed loop alike.
    private static func addBasalEstimates(for interval: TherapyOptimizerInterval, minutes: Double, scheduledBasal: (Date) -> Double, calendar: Calendar, into state: inout TherapyOptimizerState) {
        let need = interval.counteraction * 60 / interval.sensitivity
        for hoursBack in 1...3 {
            let date = interval.start.addingTimeInterval(-Double(hoursBack) * 3600)
            let index = summaryIndex(for: date, calendar: calendar, in: &state)
            state.summaries[index].basalDeviation[calendar.component(.hour, from: date)].add(scheduledBasal(date) + need, minutes: minutes / 3)
        }
    }

    private static func addSensitivityEstimate(for interval: TherapyOptimizerInterval, scheduledBasal: (Date) -> Double, calendar: Calendar, into state: inout TherapyOptimizerState) {
        // Remove the part of the deviation explained by the (already estimated) basal error.
        var basalError = 0.0
        for hoursBack in 1...3 {
            let date = interval.start.addingTimeInterval(-Double(hoursBack) * 3600)
            basalError += state.basal.calculated[calendar.component(.hour, from: date)] - scheduledBasal(date)
        }
        let basalErrorVelocity = basalError / 3 * interval.sensitivity / 60
        let observed = interval.counteraction + interval.insulinVelocity - basalErrorVelocity
        // Clamp instead of dropping outliers: dropping only the weak side biased the median toward stronger insulin.
        let ratio = min(max(observed / interval.insulinVelocity, sensitivityRatioRange.lowerBound), sensitivityRatioRange.upperBound)

        let estimate = interval.sensitivity * ratio
        let index = summaryIndex(for: interval.start, calendar: calendar, in: &state)
        state.summaries[index].sensitivity[calendar.component(.hour, from: interval.start)].add(estimate)
        state.summaries[index].sensitivityAllDay.add(estimate)

        var byGlucose = state.summaries[index].sensitivityByGlucose ?? Array(repeating: TherapyOptimizerEstimates(), count: glucoseRangeCount)
        byGlucose[glucoseRangeIndex(for: interval.glucose)].add(estimate)
        state.summaries[index].sensitivityByGlucose = byGlucose
    }

    static func ingest(_ meals: [TherapyOptimizerMeal], into state: inout TherapyOptimizerState) {
        let calendar = state.calendar
        for meal in meals where !meal.isOverrideActive && meal.minimumGlucose >= hypoThreshold && meal.carbs > 0 {
            let insulin = meal.netInsulin
                + meal.scheduledBasalUnits - calculatedBasalUnits(from: meal.start, to: meal.end, state: state, calendar: calendar)
                + (meal.glucoseEnd - meal.glucoseStart) / state.sensitivity.calculatedAllDay
            guard insulin > minimumMealInsulin else { continue }
            let ratio = meal.carbs / insulin
            guard carbRatioRange.contains(ratio) else { continue }

            let index = summaryIndex(for: meal.start, calendar: calendar, in: &state)
            state.summaries[index].carbRatio[calendar.component(.hour, from: meal.start)].add(ratio)
            state.summaries[index].carbRatioAllDay.add(ratio)
        }
    }

    static func calculatedBasalUnits(from start: Date, to end: Date, state: TherapyOptimizerState, calendar: Calendar) -> Double {
        TherapyOptimizerMath.units(from: start, to: end) { state.basal.calculated[calendar.component(.hour, from: $0)] }
    }

    private static func summaryIndex(for date: Date, calendar: Calendar, in state: inout TherapyOptimizerState) -> Int {
        let day = calendar.startOfDay(for: date)
        if let index = state.summaries.firstIndex(where: { $0.day == day }) {
            return index
        }
        let index = state.summaries.firstIndex(where: { $0.day > day }) ?? state.summaries.endIndex
        state.summaries.insert(TherapyOptimizerDaySummary(day: day), at: index)
        return index
    }

    // MARK: - Daily update

    /// Moves every calculated value toward the median of the daily estimates in the window before `date`.
    static func applyDailyUpdate(to state: inout TherapyOptimizerState, on date: Date) {
        let calendar = state.calendar
        let day = calendar.startOfDay(for: date)
        guard let windowStart = calendar.date(byAdding: .day, value: -state.windowDays, to: day) else { return }
        let window = state.summaries.filter { $0.day >= windowStart && $0.day < day }

        for hour in 0..<24 {
            let deviation = rateSamples(window.map { $0.basalDeviation[hour] })
            state.basal.dataDays[hour] = deviation.count
            if let target = TherapyOptimizerMath.weightedMedian(deviation) {
                state.basal.calculated[hour] = step(state.basal.calculated[hour], toward: target, start: state.basal.start[hour])
            }

            let sensitivity = estimateSamples(window.map { $0.sensitivity[hour] }, minimumCount: sensitivityMinimumHourly)
            state.sensitivity.dataDays[hour] = sensitivity.count
            if let target = TherapyOptimizerMath.weightedMedian(sensitivity) {
                state.sensitivity.calculated[hour] = step(state.sensitivity.calculated[hour], toward: target, start: state.sensitivity.start[hour])
            }

            let carbRatio = estimateSamples(window.map { $0.carbRatio[hour] }, minimumCount: carbRatioMinimum)
            state.carbRatio.dataDays[hour] = carbRatio.count
            if let target = TherapyOptimizerMath.weightedMedian(carbRatio) {
                state.carbRatio.calculated[hour] = step(state.carbRatio.calculated[hour], toward: target, start: state.carbRatio.start[hour])
            }
        }

        let sensitivityAllDay = estimateSamples(window.map { $0.sensitivityAllDay }, minimumCount: sensitivityMinimumAllDay)
        state.sensitivity.dataDaysAllDay = sensitivityAllDay.count
        if let target = TherapyOptimizerMath.weightedMedian(sensitivityAllDay) {
            state.sensitivity.calculatedAllDay = step(state.sensitivity.calculatedAllDay, toward: target, start: state.sensitivity.startAllDay)
        }

        let carbRatioAllDay = estimateSamples(window.map { $0.carbRatioAllDay }, minimumCount: carbRatioMinimum)
        state.carbRatio.dataDaysAllDay = carbRatioAllDay.count
        if let target = TherapyOptimizerMath.weightedMedian(carbRatioAllDay) {
            state.carbRatio.calculatedAllDay = step(state.carbRatio.calculatedAllDay, toward: target, start: state.carbRatio.startAllDay)
        }

        let overallSensitivity = TherapyOptimizerMath.weightedMedian(estimateSamples(window.map { $0.sensitivityAllDay }, minimumCount: 1))
        state.sensitivityByGlucose = (0..<glucoseRangeCount).map { (range: Int) -> TherapyOptimizerGlucoseRangeSensitivity in
            let samples = estimateSamples(window.compactMap { $0.sensitivityByGlucose?[range] }, minimumCount: glucoseRangeMinimumDaily)
            let sensitivity = TherapyOptimizerMath.weightedMedian(samples)
            let factor = sensitivity.flatMap { value in overallSensitivity.map { value / $0 } }
            return TherapyOptimizerGlucoseRangeSensitivity(sensitivity: sensitivity, factor: factor, dataDays: samples.count)
        }

        state.lastDailyUpdate = day
    }

    private static func rateSamples(_ sums: [TherapyOptimizerRateSum]) -> [(value: Double, weight: Double)] {
        sums.compactMap { (sum: TherapyOptimizerRateSum) -> (value: Double, weight: Double)? in
            guard sum.minutes >= basalMinimumMinutes, let mean = sum.mean else { return nil }
            return (value: mean, weight: sum.minutes)
        }
    }

    private static func estimateSamples(_ estimates: [TherapyOptimizerEstimates], minimumCount: Int) -> [(value: Double, weight: Double)] {
        estimates.compactMap { (estimate: TherapyOptimizerEstimates) -> (value: Double, weight: Double)? in
            guard estimate.count >= minimumCount, let median = estimate.median else { return nil }
            return (value: median, weight: Double(estimate.count))
        }
    }

    static func step(_ current: Double, toward target: Double, start: Double) -> Double {
        let maximumStep = abs(current) * maximumDailyChange
        let moved = current + min(max(target - current, -maximumStep), maximumStep)
        return min(max(moved, start * lowerLimit), start * upperLimit)
    }

    /// Restarts from the start values and rebuilds day by day: the daily update first, then that day's stored input.
    /// Summaries of days before the first stored day (collected before input was stored) are kept as they are.
    static func replay(_ state: inout TherapyOptimizerState, rawDays: [TherapyOptimizerRawDay], through date: Date) {
        state.basal.resetCalculated()
        state.sensitivity.resetCalculated()
        state.carbRatio.resetCalculated()
        state.lastDailyUpdate = nil
        state.sensitivityByGlucose = nil
        state.hypoHoldUntil = nil
        state.unexplainedRiseSince = nil
        state.recentCounteraction = nil

        let calendar = state.calendar
        let rawByDay = Dictionary(rawDays.map { ($0.day, $0) }, uniquingKeysWith: { $1 })
        let firstRawDay = rawByDay.keys.min() ?? .distantFuture
        let preserved = state.summaries.filter { $0.day < firstRawDay }
        state.summaries = preserved

        guard let firstDay = [preserved.first?.day, rawByDay.keys.min()].compactMap({ $0 }).min() else { return }
        let today = calendar.startOfDay(for: date)
        var day = firstDay
        while day <= today {
            if day > firstDay {
                applyDailyUpdate(to: &state, on: day)
            }
            if let raw = rawByDay[day] {
                ingest(raw.intervals, scheduledBasal: { raw.scheduledBasal(at: $0, calendar: calendar) }, into: &state)
                ingest(raw.meals, into: &state)
                // Back-attribution must not add to preserved days again on every replay.
                state.summaries.removeAll { $0.day < firstRawDay }
                state.summaries.insert(contentsOf: preserved, at: 0)
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
    }

    static func compactAndPrune(_ state: inout TherapyOptimizerState, now: Date) {
        let calendar = state.calendar
        let today = calendar.startOfDay(for: now)
        if let pruneBefore = calendar.date(byAdding: .day, value: -TherapyOptimizerState.retainedDays, to: today) {
            state.summaries.removeAll { $0.day < pruneBefore }
        }
        // Late contributions (attributed back up to 3 h, meals up to 10 h) have arrived after two days.
        if let closeBefore = calendar.date(byAdding: .day, value: -1, to: today) {
            for index in state.summaries.indices where !state.summaries[index].isCompacted && state.summaries[index].day < closeBefore {
                state.summaries[index].compact()
            }
        }
        state.overrideIntervals.removeAll { $0.end < now.addingTimeInterval(-8 * 24 * 3600) }
    }
}

// MARK: - Export

extension TherapyOptimizerState {
    /// Converts mg/dL/U into the user's sensitivity unit.
    func displaySensitivity(_ milligramsPerDeciliter: Double) -> Double {
        HKQuantity(unit: .milligramsPerDeciliter, doubleValue: milligramsPerDeciliter).doubleValue(for: sensitivityUnit)
    }

    /// Rounded to 0.05 U/h, which every supported pump can deliver.
    func calculatedBasalSchedule(maximumBasalRate: Double?, maximumEntryCount: Int?) -> BasalRateSchedule? {
        // Dividing (not multiplying by 0.05) yields the exact doubles pumps list as supported rates (n / 20).
        let hourly = basal.calculated.map { value -> Double in
            let rounded = max(0, (value * 20).rounded() / 20)
            guard let maximumBasalRate = maximumBasalRate else { return rounded }
            return min(rounded, (maximumBasalRate * 20 + 1e-9).rounded(.down) / 20)
        }
        var items = TherapyOptimizerMath.scheduleItems(hourly)
        if let maximumEntryCount = maximumEntryCount, maximumEntryCount > 0 {
            while items.count > maximumEntryCount, items.count > 1 {
                let index = (1..<items.count).min { abs(items[$0].value - items[$0 - 1].value) < abs(items[$1].value - items[$1 - 1].value) }!
                items.remove(at: index)
            }
        }
        return BasalRateSchedule(dailyItems: items, timeZone: timeZone)
    }

    func calculatedSensitivitySchedule(hourly: Bool) -> InsulinSensitivitySchedule? {
        let values = hourly ? sensitivity.exportHourly(minimumDataDays: TherapyOptimizerEngine.reliableHourDataDays) : Array(repeating: sensitivity.calculatedAllDay, count: 24)
        let unit = sensitivityUnit
        let stepsPerUnit = unit == .milligramsPerDeciliter ? 1.0 : 10.0
        let rounded = values.map { (displaySensitivity($0) * stepsPerUnit).rounded() / stepsPerUnit }
        return InsulinSensitivitySchedule(unit: unit, dailyItems: TherapyOptimizerMath.scheduleItems(rounded), timeZone: timeZone)
    }

    func calculatedCarbRatioSchedule(hourly: Bool) -> CarbRatioSchedule? {
        let values = hourly ? carbRatio.exportHourly(minimumDataDays: TherapyOptimizerEngine.reliableHourDataDays) : Array(repeating: carbRatio.calculatedAllDay, count: 24)
        let rounded = values.map { ($0 * 10).rounded() / 10 }
        return CarbRatioSchedule(unit: .gram(), dailyItems: TherapyOptimizerMath.scheduleItems(rounded), timeZone: timeZone)
    }
}
