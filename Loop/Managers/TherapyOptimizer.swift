//
//  TherapyOptimizer.swift
//  Loop
//
//  Autotune-style estimation of basal rates, insulin sensitivity and carb ratios, all in U100.
//  Skipped: carbs on board, overrides until 4 h after their end, suspends, lows and unannounced meals
//  (fast counteraction or a 30-minute rise). On a 20-minute smoothed glucose delta, intervals where extra
//  insulin dominates form insulin sensitivity episodes (>= 30 min, >= 20 mg/dL insulin effect; one estimate
//  each, weighted by that effect); the rest estimate basal, attributed 1-3 h back. At each daily update basal
//  needs 3 data days per hour, is shrunk toward the profile and smoothed with its neighbour hours; carb ratios
//  are total carbs over total insulin of at least 3 meals around each hour. Every value moves at most 10 %
//  a day within 0.7...1.3 x the profile.
//  Calculated values reach Loop when the user applies them to a profile; the glucose-dependent factor also through
//  a profile's "Use for Corrections", limited to the correction share of a recommendation.
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
    /// Overrides from 4 h before the day to its end; optional so files written before this field existed still decode.
    var overrides: [DateInterval]?

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

/// A completed meal window (one or more merged carb entries until carbs are absorbed and glucose has settled).
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
    /// Carb entries merged into the meal; nil in meals stored before this field existed.
    var entryCount: Int? = nil
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

/// Raw estimates while a day is open; reduced to weighted median, count and weight once the day is closed.
struct TherapyOptimizerEstimates: Codable, Equatable {
    var values: [Double] = []
    /// nil (state saved before weights existed) counts 1 per value.
    var weights: [Double]?
    var compactedMedian: Double?
    var count = 0
    var totalWeight: Double?

    mutating func add(_ value: Double, weight: Double = 1) {
        weights = (weights ?? Array(repeating: 1, count: values.count)) + [weight]
        values.append(value)
        totalWeight = self.weight + weight
        count += 1
    }

    var median: Double? {
        compactedMedian ?? TherapyOptimizerMath.weightedMedian(values.enumerated().map { (value: $0.element, weight: weights?[$0.offset] ?? 1) })
    }

    var weight: Double {
        totalWeight ?? Double(count)
    }

    mutating func compact() {
        compactedMedian = median
        values = []
        weights = nil
    }
}

/// All estimates attributed to one calendar day, per hour of day.
struct TherapyOptimizerDaySummary: Codable, Equatable {
    let day: Date
    var basalDeviation = Array(repeating: TherapyOptimizerRateSum(), count: 24)
    var sensitivity = Array(repeating: TherapyOptimizerEstimates(), count: 24)
    var sensitivityAllDay = TherapyOptimizerEstimates()
    /// Optional so state saved before this field existed still decodes.
    var sensitivityByGlucose: [TherapyOptimizerEstimates]?
    /// Completed meals starting this day, evaluated at each daily update; optional like above.
    var meals: [TherapyOptimizerMeal]?
    var isCompacted = false

    init(day: Date) {
        self.day = day
    }

    mutating func compact() {
        for hour in 0..<24 {
            sensitivity[hour].compact()
        }
        sensitivityAllDay.compact()
        sensitivityByGlucose = sensitivityByGlucose?.map { estimates in
            var estimates = estimates
            estimates.compact()
            return estimates
        }
        isCompacted = true
    }
}

/// Consecutive intervals where extra insulin dominated; yields one insulin sensitivity estimate.
struct TherapyOptimizerSensitivityEpisode: Codable, Equatable {
    let start: Date
    var end: Date
    var minutes = 0.0
    /// Glucose change net of the basal error, mg/dL
    var observed = 0.0
    /// Glucose change Loop expected from insulin (BGI), mg/dL; negative
    var expected = 0.0
    /// Sum of sensitivity x expected, for the BGI-weighted sensitivity Loop used
    var sensitivityTimesExpected = 0.0

    init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    mutating func add(observed: Double, expected: Double, sensitivity: Double, minutes: Double, end: Date) {
        self.observed += observed
        self.expected += expected
        self.sensitivityTimesExpected += sensitivity * expected
        self.minutes += minutes
        self.end = end
    }

    var middle: Date {
        start.addingTimeInterval(end.timeIntervalSince(start) / 2)
    }

    /// nil while too short or too little insulin effect to rise above CGM noise.
    var estimate: Double? {
        guard minutes >= TherapyOptimizerEngine.sensitivityEpisodeMinimumMinutes,
              -expected >= TherapyOptimizerEngine.sensitivityEpisodeMinimumEffect else { return nil }
        let range = TherapyOptimizerEngine.sensitivityRatioRange
        let ratio = min(max(observed / expected, range.lowerBound), range.upperBound)
        return sensitivityTimesExpected / expected * ratio
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

    /// Calculated all-day value relative to the profile's all-day value; 1 with too few days of data.
    var allDayFactor: Double {
        startAllDay != 0 && dataDaysAllDay >= TherapyOptimizerEngine.reliableHourDataDays ? calculatedAllDay / startAllDay : 1
    }

    /// The profile's hourly values with the all-day change, so an hourly profile keeps its shape.
    var scaledStart: [Double] {
        start.map { $0 * allDayFactor }
    }

    /// Hours with too few days of data keep the profile's value with the all-day change.
    func effectiveHourly(_ hour: Int, minimumDataDays: Int) -> Double {
        dataDays[hour] >= minimumDataDays ? calculated[hour] : start[hour] * allDayFactor
    }

    func exportHourly(minimumDataDays: Int) -> [Double] {
        (0..<24).map { effectiveHourly($0, minimumDataDays: minimumDataDays) }
    }
}

struct TherapyOptimizerState: Codable, Equatable {
    static let windowOptions = [14, 30, 60, 90]
    static let retainedDays = 90

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
    /// Glucose change of the last 30 minutes of intervals, mg/dL each.
    var recentGlucoseChange: [Double]?
    var openSensitivityEpisode: TherapyOptimizerSensitivityEpisode?
    /// One per glucose range; an episode's intervals also count separately per range.
    var openSensitivityEpisodesByGlucose: [TherapyOptimizerSensitivityEpisode?]?
    /// One entry per `TherapyOptimizerEngine.glucoseRangeUpperBounds` range; dosing reads them via `dosingSensitivityFactor`.
    var sensitivityByGlucose: [TherapyOptimizerGlucoseRangeSensitivity]?
    /// Overall observed sensitivity the per-range factors are relative to.
    var sensitivityByGlucoseReference: TherapyOptimizerGlucoseRangeSensitivity?

    /// All values are in U100 units.
    init(timeZone: TimeZone, basal: [Double], sensitivity: [Double], carbRatio: [Double], sensitivityUnit: HKUnit, processingStart: Date) {
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

    /// Whether both states start from the same therapy settings.
    func hasSameStartValues(as other: TherapyOptimizerState) -> Bool {
        let equal = { (lhs: [Double], rhs: [Double]) in lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) < 1e-9 } }
        return equal(basal.start, other.basal.start)
            && equal(sensitivity.start, other.sensitivity.start)
            && equal(carbRatio.start, other.carbRatio.start)
            && sensitivityUnitString == other.sensitivityUnitString
            && timeZone == other.timeZone
    }

    /// Forgets what earlier intervals left open, before processing restarts at another point in time.
    mutating func resetIntervalContext() {
        hypoHoldUntil = nil
        unexplainedRiseSince = nil
        recentCounteraction = nil
        recentGlucoseChange = nil
        openSensitivityEpisode = nil
        openSensitivityEpisodesByGlucose = nil
    }
}

enum TherapyOptimizerMath {
    /// With equal weights this is the ordinary median.
    static func weightedMedian(_ samples: [(value: Double, weight: Double)]) -> Double? {
        let sorted = samples.filter { $0.weight > 0 }.sorted { $0.value < $1.value }
        let total = sorted.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var cumulative = 0.0
        for (index, sample) in sorted.enumerated() {
            cumulative += sample.weight
            if abs(cumulative - total / 2) <= total * 1e-9, index + 1 < sorted.count {
                return (sample.value + sorted[index + 1].value) / 2
            }
            if cumulative >= total / 2 {
                return sample.value
            }
        }
        return sorted.last?.value
    }

    /// Calendar date (yyyy-MM-dd) of a day start, also for days started in another time zone.
    static func dayKey(_ dayStart: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: dayStart.addingTimeInterval(12 * 3600))
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
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

    /// Grids of the schedule editors: 0.05 U/h, 0.1 g/U, 1 mg/dL/U or 0.1 mmol/L/U.
    static let basalStepsPerUnit: Double = 20
    static let carbRatioStepsPerUnit: Double = 10

    static func sensitivityStepsPerUnit(_ unit: HKUnit) -> Double {
        unit == .milligramsPerDeciliter ? 1 : 10
    }

    /// Dividing (not multiplying by the step) yields the exact doubles pumps and editors list (n / steps).
    static func roundedToGrid(_ value: Double, stepsPerUnit: Double, rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> Double {
        let steps = value * stepsPerUnit
        // Rounding down must not lose a grid value that floating point puts just below it.
        return (rule == .down ? steps + 1e-9 : steps).rounded(rule) / stepsPerUnit
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

    /// `items` with `value` from `hour` to the next full hour.
    static func settingValue(_ value: Double, forHour hour: Int, in items: [RepeatingScheduleValue<Double>]) -> [RepeatingScheduleValue<Double>] {
        let sorted = items.sorted { $0.startTime < $1.startTime }
        let start = TimeInterval(hour * 3600)
        let end = start + 3600
        let valueAtEnd = (sorted.last { $0.startTime <= end } ?? sorted.first)?.value
        var result = sorted.filter { $0.startTime < start || $0.startTime >= end }
        result.append(RepeatingScheduleValue(startTime: start, value: value))
        if end < 24 * 3600, !sorted.contains(where: { $0.startTime == end }), let valueAtEnd = valueAtEnd {
            result.append(RepeatingScheduleValue(startTime: end, value: valueAtEnd))
        }
        result.sort { $0.startTime < $1.startTime }
        var merged: [RepeatingScheduleValue<Double>] = []
        for item in result where merged.last?.value != item.value {
            merged.append(item)
        }
        return merged
    }
}

enum TherapyOptimizerEngine {
    static let maximumDailyChange = 0.10
    static let lowerLimit = 0.7
    static let upperLimit = 1.3
    static let basalMinimumMinutes = 15.0
    /// Days of data at which a basal estimate counts half; fewer days stay closer to the profile.
    static let basalShrinkageDays = 7.0
    static let sensitivityMinimumHourly = 1
    static let sensitivityMinimumAllDay = 1
    static let reliableHourDataDays = 3

    static let hypoThreshold = 70.0
    static let hypoHold: TimeInterval = 60 * 60
    /// Mean counteraction (mg/dL/min) over `unexplainedRiseIntervals` without carbs that marks an unannounced meal.
    /// A dawn rise stays well below this even while Loop is correcting it.
    static let unexplainedRiseThreshold = 1.5
    static let unexplainedRiseIntervals = 3
    /// Glucose rise (mg/dL) within 30 minutes without carbs that also marks an unannounced meal.
    static let unexplainedRiseIn30Minutes = 25.0
    static let unexplainedRiseMaximum: TimeInterval = 3 * 60 * 60
    static let riseIntervals = 6
    static let smoothingIntervals = 4
    static let overrideAftereffect: TimeInterval = 4 * 3600
    static let sensitivityEpisodeMinimumMinutes = 30.0
    static let sensitivityEpisodeMaximumMinutes = 60.0
    static let sensitivityEpisodeMinimumEffect = 20.0
    static let sensitivityEpisodeMaximumGap: TimeInterval = 10 * 60
    static let sensitivityRatioRange = 0.25...4.0
    static let carbRatioRange = 3.0...40.0
    static let minimumMealInsulin = 0.3
    static let minimumMealCarbs = 15.0
    static let carbRatioMinimumMeals = 3
    /// Meals starting within this many hours of an hour count for its carb ratio.
    static let carbRatioBlockHours = 1
    /// mg/dL; values at or above the last bound fall into an extra top range.
    static let glucoseRangeUpperBounds: [Double] = [70, 100, 180, 250]
    static var glucoseRangeCount: Int { glucoseRangeUpperBounds.count + 1 }
    /// mg/dL; centre of each range from 70 up, between which the dosing factor is interpolated.
    static let glucoseRangeCentres: [Double] = [85, 140, 215, 285]
    static let glucoseRangeMinimumDaily = 1
    /// Limits of the glucose-dependent factor when it is used for correction dosing.
    static let dosingSensitivityFactorRange = 0.8...1.2
    static let dosingSensitivityShrinkageDays = 14.0
    static let dosingSensitivityMaximumAge: TimeInterval = 3 * 24 * 3600

    static func glucoseRangeIndex(for glucose: Double) -> Int {
        glucoseRangeUpperBounds.firstIndex { glucose < $0 } ?? glucoseRangeUpperBounds.count
    }

    /// Whether an override or its after-effect (4 h, insulin dosed with its settings) touches the range.
    static func isAffected(by overrides: [DateInterval], from start: Date, to end: Date) -> Bool {
        overrides.contains { $0.start < end && $0.end.addingTimeInterval(overrideAftereffect) > start }
    }

    // MARK: - Ingestion

    static func ingest(_ intervals: [TherapyOptimizerInterval], scheduledBasal: (Date) -> Double, overrides: [DateInterval] = [], into state: inout TherapyOptimizerState) {
        let calendar = state.calendar
        var recent = state.recentCounteraction ?? []
        var changes = state.recentGlucoseChange ?? []
        defer {
            state.recentCounteraction = recent
            state.recentGlucoseChange = changes
        }
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            let minutes = interval.end.timeIntervalSince(interval.start) / 60
            guard minutes >= 2, minutes <= 10 else { continue }
            closeSensitivityEpisodes(calendar: calendar, in: &state) { interval.start.timeIntervalSince($0.end) > sensitivityEpisodeMaximumGap }

            if interval.glucose < hypoThreshold {
                state.hypoHoldUntil = interval.end.addingTimeInterval(hypoHold)
            }
            recent = Array((recent + [interval.counteraction]).suffix(unexplainedRiseIntervals))
            changes = Array((changes + [(interval.counteraction + interval.insulinVelocity) * minutes]).suffix(riseIntervals))
            let recentRise = recent.reduce(0, +) / Double(recent.count)
            let isUnexplainedRise = recentRise > unexplainedRiseThreshold || changes.reduce(0, +) >= unexplainedRiseIn30Minutes
            if let since = state.unexplainedRiseSince,
               recentRise <= 0 || interval.start.timeIntervalSince(since) > unexplainedRiseMaximum {
                state.unexplainedRiseSince = nil
            } else if state.unexplainedRiseSince == nil, interval.carbsOnBoard <= 0, isUnexplainedRise {
                state.unexplainedRiseSince = interval.start
            }

            let isHypoHold = state.hypoHoldUntil.map { interval.start < $0 } ?? false
            let isAfterOverride = isAffected(by: overrides, from: interval.start, to: interval.end)
            guard !interval.isOverrideActive, !isAfterOverride, !interval.isSuspended, !isHypoHold,
                  state.unexplainedRiseSince == nil, interval.carbsOnBoard <= 0, interval.sensitivity > 0 else {
                closeSensitivityEpisodes(calendar: calendar, in: &state)
                continue
            }

            // Autotune categorisation: ISF only while extra insulin clearly dominates the scheduled basal and glucose is
            // not rising faster than twice the insulin effect; such a rise without carbs is a basal deficit, whoever corrected it.
            let smoothedVelocity = changes.suffix(smoothingIntervals).reduce(0, +) / (Double(min(changes.count, smoothingIntervals)) * 5)
            let basalVelocity = scheduledBasal(interval.start) * interval.sensitivity / 60
            let isRising = smoothedVelocity > 0 && smoothedVelocity > -2 * interval.insulinVelocity
            if -4 * interval.insulinVelocity > basalVelocity, !isRising {
                addToSensitivityEpisodes(interval, minutes: minutes, scheduledBasal: scheduledBasal, calendar: calendar, into: &state)
            } else {
                closeSensitivityEpisodes(calendar: calendar, in: &state)
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

    private static func addToSensitivityEpisodes(_ interval: TherapyOptimizerInterval, minutes: Double, scheduledBasal: (Date) -> Double, calendar: Calendar, into state: inout TherapyOptimizerState) {
        // Remove the part of the deviation explained by the (already estimated) basal error.
        var basalError = 0.0
        for hoursBack in 1...3 {
            let date = interval.start.addingTimeInterval(-Double(hoursBack) * 3600)
            basalError += state.basal.calculated[calendar.component(.hour, from: date)] - scheduledBasal(date)
        }
        let basalErrorVelocity = basalError / 3 * interval.sensitivity / 60
        let observed = (interval.counteraction + interval.insulinVelocity - basalErrorVelocity) * minutes
        let expected = interval.insulinVelocity * minutes

        var total = state.openSensitivityEpisode ?? TherapyOptimizerSensitivityEpisode(start: interval.start, end: interval.end)
        total.add(observed: observed, expected: expected, sensitivity: interval.sensitivity, minutes: minutes, end: interval.end)
        state.openSensitivityEpisode = total

        let range = glucoseRangeIndex(for: interval.glucose)
        var byGlucose = state.openSensitivityEpisodesByGlucose ?? Array(repeating: nil, count: glucoseRangeCount)
        var part = byGlucose[range] ?? TherapyOptimizerSensitivityEpisode(start: interval.start, end: interval.end)
        part.add(observed: observed, expected: expected, sensitivity: interval.sensitivity, minutes: minutes, end: interval.end)
        byGlucose[range] = part
        state.openSensitivityEpisodesByGlucose = byGlucose

        closeSensitivityEpisodes(calendar: calendar, in: &state) { $0.minutes >= sensitivityEpisodeMaximumMinutes }
    }

    /// Turns the open episodes matching `shouldClose` into estimates, attributed to the day and hour of their middle.
    private static func closeSensitivityEpisodes(calendar: Calendar, in state: inout TherapyOptimizerState, where shouldClose: (TherapyOptimizerSensitivityEpisode) -> Bool = { _ in true }) {
        if let episode = state.openSensitivityEpisode, shouldClose(episode) {
            state.openSensitivityEpisode = nil
            if let estimate = episode.estimate {
                let index = summaryIndex(for: episode.middle, calendar: calendar, in: &state)
                state.summaries[index].sensitivity[calendar.component(.hour, from: episode.middle)].add(estimate, weight: -episode.expected)
                state.summaries[index].sensitivityAllDay.add(estimate, weight: -episode.expected)
            }
        }
        guard var byGlucose = state.openSensitivityEpisodesByGlucose else { return }
        for range in byGlucose.indices {
            guard let episode = byGlucose[range], shouldClose(episode) else { continue }
            byGlucose[range] = nil
            if let estimate = episode.estimate {
                let index = summaryIndex(for: episode.middle, calendar: calendar, in: &state)
                var estimates = state.summaries[index].sensitivityByGlucose ?? Array(repeating: TherapyOptimizerEstimates(), count: glucoseRangeCount)
                estimates[range].add(estimate, weight: -episode.expected)
                state.summaries[index].sensitivityByGlucose = estimates
            }
        }
        state.openSensitivityEpisodesByGlucose = byGlucose.contains { $0 != nil } ? byGlucose : nil
    }

    /// Meals are kept per day and evaluated with the then current basal and sensitivity at each daily update.
    static func ingest(_ meals: [TherapyOptimizerMeal], into state: inout TherapyOptimizerState) {
        let calendar = state.calendar
        for meal in meals {
            let index = summaryIndex(for: meal.start, calendar: calendar, in: &state)
            let others = (state.summaries[index].meals ?? []).filter { $0.start != meal.start }
            state.summaries[index].meals = (others + [meal]).sorted { $0.start < $1.start }
        }
    }

    /// Insulin the meal needed, or nil when the meal can't tell the carb ratio.
    static func mealInsulin(_ meal: TherapyOptimizerMeal, state: TherapyOptimizerState, calendar: Calendar) -> Double? {
        // A low after a single entry shows a too aggressive ratio; with more entries the extra carbs could be rescue carbs.
        guard !meal.isOverrideActive, meal.carbs >= minimumMealCarbs, meal.glucoseStart >= hypoThreshold,
              meal.minimumGlucose >= hypoThreshold || meal.entryCount == 1 else {
            return nil
        }
        let insulin = meal.netInsulin
            + meal.scheduledBasalUnits - calculatedBasalUnits(from: meal.start, to: meal.end, state: state, calendar: calendar)
            + (meal.glucoseEnd - meal.glucoseStart) / state.sensitivity.effectiveHourly(calendar.component(.hour, from: meal.start), minimumDataDays: reliableHourDataDays)
        guard insulin > minimumMealInsulin, carbRatioRange.contains(meal.carbs / insulin) else { return nil }
        return insulin
    }

    static func calculatedBasalUnits(from start: Date, to end: Date, state: TherapyOptimizerState, calendar: Calendar) -> Double {
        TherapyOptimizerMath.units(from: start, to: end) { state.basal.calculated[calendar.component(.hour, from: $0)] }
    }

    private static func summaryIndex(for date: Date, calendar: Calendar, in state: inout TherapyOptimizerState) -> Int {
        let day = calendar.startOfDay(for: date)
        if let index = state.summaries.lastIndex(where: { $0.day == day }) {
            return index
        }
        let key = TherapyOptimizerMath.dayKey(day, calendar: calendar)
        if let index = state.summaries.lastIndex(where: { TherapyOptimizerMath.dayKey($0.day, calendar: calendar) == key }) {
            return index
        }
        let index = state.summaries.firstIndex(where: { $0.day > day }) ?? state.summaries.endIndex
        state.summaries.insert(TherapyOptimizerDaySummary(day: day), at: index)
        return index
    }

    // MARK: - Daily update

    /// Moves every calculated value toward the estimates of the window before `date`.
    static func applyDailyUpdate(to state: inout TherapyOptimizerState, on date: Date) {
        let calendar = state.calendar
        let day = calendar.startOfDay(for: date)
        guard let windowStart = calendar.date(byAdding: .day, value: -state.windowDays, to: day) else { return }
        let firstKey = TherapyOptimizerMath.dayKey(windowStart, calendar: calendar)
        let endKey = TherapyOptimizerMath.dayKey(day, calendar: calendar)
        let window = state.summaries.filter {
            let key = TherapyOptimizerMath.dayKey($0.day, calendar: calendar)
            return key >= firstKey && key < endKey
        }

        // Hours without data keep the profile's value, so they also hold their neighbours back.
        let basalTargets = (0..<24).map { (hour: Int) -> Double in
            let deviation = rateSamples(window.map { $0.basalDeviation[hour] })
            state.basal.dataDays[hour] = deviation.count
            let start = state.basal.start[hour]
            guard let median = TherapyOptimizerMath.weightedMedian(deviation) else { return start }
            let days = Double(deviation.count)
            return start + (median - start) * days / (days + basalShrinkageDays)
        }
        for hour in 0..<24 where state.basal.dataDays[hour] >= reliableHourDataDays {
            let target = 0.25 * basalTargets[(hour + 23) % 24] + 0.5 * basalTargets[hour] + 0.25 * basalTargets[(hour + 1) % 24]
            state.basal.calculated[hour] = step(state.basal.calculated[hour], toward: target, start: state.basal.start[hour])
        }

        for hour in 0..<24 {
            let sensitivity = estimateSamples(window.map { $0.sensitivity[hour] }, minimumCount: sensitivityMinimumHourly)
            state.sensitivity.dataDays[hour] = sensitivity.count
            if let target = TherapyOptimizerMath.weightedMedian(sensitivity) {
                state.sensitivity.calculated[hour] = step(state.sensitivity.calculated[hour], toward: target, start: state.sensitivity.start[hour])
            }
        }

        let sensitivityAllDay = estimateSamples(window.map { $0.sensitivityAllDay }, minimumCount: sensitivityMinimumAllDay)
        state.sensitivity.dataDaysAllDay = sensitivityAllDay.count
        if let target = TherapyOptimizerMath.weightedMedian(sensitivityAllDay) {
            state.sensitivity.calculatedAllDay = step(state.sensitivity.calculatedAllDay, toward: target, start: state.sensitivity.startAllDay)
        }

        // Meals still running at `day` count from the next update on, as in live processing.
        let meals: [(meal: TherapyOptimizerMeal, insulin: Double)] = window.flatMap { $0.meals ?? [] }
            .filter { $0.end <= day }
            .compactMap { meal in mealInsulin(meal, state: state, calendar: calendar).map { (meal: meal, insulin: $0) } }
        let evaluateCarbRatio = { (block: [(meal: TherapyOptimizerMeal, insulin: Double)]) -> (target: Double?, dataDays: Int) in
            let dataDays = Set(block.map { TherapyOptimizerMath.dayKey(calendar.startOfDay(for: $0.meal.start), calendar: calendar) }).count
            guard block.count >= carbRatioMinimumMeals else { return (nil, dataDays) }
            return (block.reduce(0) { $0 + $1.meal.carbs } / block.reduce(0) { $0 + $1.insulin }, dataDays)
        }
        for hour in 0..<24 {
            let block = meals.filter {
                let distance = abs(calendar.component(.hour, from: $0.meal.start) - hour)
                return min(distance, 24 - distance) <= carbRatioBlockHours
            }
            let carbRatio = evaluateCarbRatio(block)
            state.carbRatio.dataDays[hour] = carbRatio.dataDays
            if let target = carbRatio.target {
                state.carbRatio.calculated[hour] = step(state.carbRatio.calculated[hour], toward: target, start: state.carbRatio.start[hour])
            }
        }
        let carbRatioAllDay = evaluateCarbRatio(meals)
        state.carbRatio.dataDaysAllDay = carbRatioAllDay.dataDays
        if let target = carbRatioAllDay.target {
            state.carbRatio.calculatedAllDay = step(state.carbRatio.calculatedAllDay, toward: target, start: state.carbRatio.startAllDay)
        }

        let overallSamples = estimateSamples(window.map { $0.sensitivityAllDay }, minimumCount: 1)
        let overallSensitivity = TherapyOptimizerMath.weightedMedian(overallSamples)
        state.sensitivityByGlucoseReference = overallSensitivity.map { TherapyOptimizerGlucoseRangeSensitivity(sensitivity: $0, factor: 1, dataDays: overallSamples.count) }
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
            return (value: median, weight: estimate.weight)
        }
    }

    static func step(_ current: Double, toward target: Double, start: Double) -> Double {
        let maximumStep = abs(current) * maximumDailyChange
        let moved = current + min(max(target - current, -maximumStep), maximumStep)
        return min(max(moved, start * lowerLimit), start * upperLimit)
    }

    /// Restarts from the start values and rebuilds day by day: the daily update first, then that day's stored input.
    /// Summaries of days before the first stored day (collected before input was stored) are kept as they are.
    /// `date` is how far live processing got, so the last daily update matches it.
    static func replay(_ state: inout TherapyOptimizerState, rawDays: [TherapyOptimizerRawDay], through date: Date) {
        state.basal.resetCalculated()
        state.sensitivity.resetCalculated()
        state.carbRatio.resetCalculated()
        state.lastDailyUpdate = nil
        state.sensitivityByGlucose = nil
        state.sensitivityByGlucoseReference = nil
        state.resetIntervalContext()

        let calendar = state.calendar
        let key = { (day: Date) in TherapyOptimizerMath.dayKey(day, calendar: calendar) }
        let rawByKey = Dictionary(rawDays.map { (key($0.day), $0) }, uniquingKeysWith: { $1 })
        let firstRawKey = rawByKey.keys.min()
        let isPreserved = { (summary: TherapyOptimizerDaySummary) in firstRawKey.map { key(summary.day) < $0 } ?? true }
        let preserved = state.summaries.filter(isPreserved)
        state.summaries = preserved
        // Days stored before overrides were stored rely on those still recorded.
        let overrides = rawDays.flatMap { $0.overrides ?? [] } + state.overrideIntervals

        // Midday of a stored day start is on the same date in the current time zone.
        let firstDates = preserved.prefix(1).map { $0.day } + rawDays.map { $0.day }
        guard let firstDay = firstDates.map({ calendar.startOfDay(for: $0.addingTimeInterval(12 * 3600)) }).min() else { return }
        let today = calendar.startOfDay(for: date)
        var day = firstDay
        while day <= today {
            applyDailyUpdate(to: &state, on: day)
            if let raw = rawByKey[key(day)] {
                ingest(raw.intervals, scheduledBasal: { raw.scheduledBasal(at: $0, calendar: calendar) }, overrides: overrides, into: &state)
                ingest(raw.meals, into: &state)
                // Back-attribution must not add to preserved days again on every replay.
                state.summaries.removeAll(where: isPreserved)
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

    // MARK: - Glucose-dependent factor

    /// Factor for the insulin sensitivity at `glucose`: interpolated between range centres, each range shrunk toward 1
    /// by its days of data. nil below 70 mg/dL, with too few days of data or when the latest day started over 3 days ago.
    static func dosingSensitivityFactor(forGlucose glucose: Double, in state: TherapyOptimizerState, now: Date) -> Double? {
        guard glucose >= hypoThreshold,
              let reference = state.sensitivityByGlucoseReference, reference.dataDays >= reliableHourDataDays,
              let ranges = state.sensitivityByGlucose,
              let latestDay = state.summaries.last?.day,
              now.timeIntervalSince(latestDay) <= dosingSensitivityMaximumAge else {
            return nil
        }
        let factors = glucoseRangeCentres.indices.map { (centre: Int) -> Double in
            let range = centre + 1
            guard range < ranges.count, let factor = ranges[range].factor else { return 1 }
            let days = Double(ranges[range].dataDays)
            return 1 + (factor - 1) * days / (days + dosingSensitivityShrinkageDays)
        }
        let centres = glucoseRangeCentres
        let factor: Double
        if let upper = centres.firstIndex(where: { glucose < $0 }) {
            if upper == 0 {
                factor = factors[0]
            } else {
                let fraction = (glucose - centres[upper - 1]) / (centres[upper] - centres[upper - 1])
                factor = factors[upper - 1] + (factors[upper] - factors[upper - 1]) * fraction
            }
        } else {
            factor = factors[factors.count - 1]
        }
        return min(max(factor, dosingSensitivityFactorRange.lowerBound), dosingSensitivityFactorRange.upperBound)
    }
}

// MARK: - Export

extension TherapyOptimizerState {
    /// Converts mg/dL/U into the user's sensitivity unit.
    func displaySensitivity(_ milligramsPerDeciliter: Double) -> Double {
        HKQuantity(unit: .milligramsPerDeciliter, doubleValue: milligramsPerDeciliter).doubleValue(for: sensitivityUnit)
    }

    /// Rounded to 0.05 U/h, which every supported pump can deliver; hours with too few days of data keep the profile.
    func calculatedBasalSchedule(maximumBasalRate: Double?, maximumEntryCount: Int?) -> BasalRateSchedule? {
        let steps = TherapyOptimizerMath.basalStepsPerUnit
        let hourly = basal.exportHourly(minimumDataDays: TherapyOptimizerEngine.reliableHourDataDays).map { value -> Double in
            let rounded = max(0, TherapyOptimizerMath.roundedToGrid(value, stepsPerUnit: steps))
            guard let maximumBasalRate = maximumBasalRate else { return rounded }
            return min(rounded, TherapyOptimizerMath.roundedToGrid(maximumBasalRate, stepsPerUnit: steps, rule: .down))
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
        let values = hourly ? sensitivity.exportHourly(minimumDataDays: TherapyOptimizerEngine.reliableHourDataDays) : sensitivity.scaledStart
        let unit = sensitivityUnit
        let stepsPerUnit = TherapyOptimizerMath.sensitivityStepsPerUnit(unit)
        let rounded = values.map { TherapyOptimizerMath.roundedToGrid(displaySensitivity($0), stepsPerUnit: stepsPerUnit) }
        return InsulinSensitivitySchedule(unit: unit, dailyItems: TherapyOptimizerMath.scheduleItems(rounded), timeZone: timeZone)
    }

    func calculatedCarbRatioSchedule(hourly: Bool) -> CarbRatioSchedule? {
        let values = hourly ? carbRatio.exportHourly(minimumDataDays: TherapyOptimizerEngine.reliableHourDataDays) : carbRatio.scaledStart
        let rounded = values.map { TherapyOptimizerMath.roundedToGrid($0, stepsPerUnit: TherapyOptimizerMath.carbRatioStepsPerUnit) }
        return CarbRatioSchedule(unit: .gram(), dailyItems: TherapyOptimizerMath.scheduleItems(rounded), timeZone: timeZone)
    }
}
