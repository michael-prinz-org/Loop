//
//  DynamicISF.swift
//  Loop
//
//  Trio's Dynamic ISF (trio-oref determine-basal.js): insulin sensitivity from glucose and total daily dose (TDD).
//  Every past dose and carb entry uses the dynamic ISF at its own start time, a new dose the one at the current glucose.
//

import Foundation
import HealthKit
import LoopKit

enum DynamicISFFormula: Int, CaseIterable {
    case logarithmic
    case sigmoid
}

struct DynamicISFSettings: Equatable {
    var isEnabled = false
    var formula = DynamicISFFormula.logarithmic
    var adjustmentFactor = 0.8
    var adjustmentFactorSigmoid = 0.5
    /// Limits of the dynamic ratio (profile / dynamic insulin sensitivity).
    var minimumRatio = 0.7
    var maximumRatio = 1.2
    /// Share of the last 24 hours in the weighted TDD; the rest is the average of up to 10 days before.
    var tddWeight = 0.65
}

extension UserDefaults {
    enum DynamicISFKey: String {
        case enabled = "com.loopkit.algorithmExperiments.dynamicISFEnabled"
        case formula = "com.loopkit.algorithmExperiments.dynamicISFFormula"
        case adjustmentFactor = "com.loopkit.algorithmExperiments.dynamicISFAdjustmentFactor"
        case adjustmentFactorSigmoid = "com.loopkit.algorithmExperiments.dynamicISFAdjustmentFactorSigmoid"
        case minimumRatio = "com.loopkit.algorithmExperiments.dynamicISFMinimumRatio"
        case maximumRatio = "com.loopkit.algorithmExperiments.dynamicISFMaximumRatio"
        case tddWeight = "com.loopkit.algorithmExperiments.dynamicISFTDDWeight"
        case dailyTotals = "com.loopkit.Loop.dynamicISFDailyTotals"
    }

    var dynamicISFSettings: DynamicISFSettings {
        let defaults = DynamicISFSettings()
        let double = { (key: DynamicISFKey, fallback: Double) -> Double in
            self.object(forKey: key.rawValue) as? Double ?? fallback
        }
        return DynamicISFSettings(
            isEnabled: bool(forKey: DynamicISFKey.enabled.rawValue),
            formula: DynamicISFFormula(rawValue: integer(forKey: DynamicISFKey.formula.rawValue)) ?? defaults.formula,
            adjustmentFactor: double(.adjustmentFactor, defaults.adjustmentFactor),
            adjustmentFactorSigmoid: double(.adjustmentFactorSigmoid, defaults.adjustmentFactorSigmoid),
            minimumRatio: double(.minimumRatio, defaults.minimumRatio),
            maximumRatio: double(.maximumRatio, defaults.maximumRatio),
            tddWeight: double(.tddWeight, defaults.tddWeight)
        )
    }
}

/// Why Dynamic ISF leaves the profile's insulin sensitivity unchanged.
enum DynamicISFInactiveReason: Equatable {
    case disabled
    case integralRetrospectiveCorrection
    case unsupportedInsulin
    case invalidRatioLimits
    case missingTherapySettings
    case missingTotalDailyDose
    case missingGlucose
}

/// What decides whether and how Dynamic ISF runs; any change recomputes all effects.
struct DynamicISFConfiguration: Equatable {
    var settings: DynamicISFSettings
    var integralRetrospectiveCorrectionEnabled: Bool
    var insulinType: InsulinType?

    var inactiveReason: DynamicISFInactiveReason? {
        if !settings.isEnabled {
            return .disabled
        }
        if integralRetrospectiveCorrectionEnabled {
            return .integralRetrospectiveCorrection
        }
        if DynamicISFCalculator.insulinDivisor(for: insulinType) == nil {
            return .unsupportedInsulin
        }
        if settings.minimumRatio >= settings.maximumRatio {
            return .invalidRatioLimits
        }
        return nil
    }
}

/// Total daily doses in current pump units.
struct DynamicISFTotalDailyDose: Equatable {
    /// Delivered in the 24 hours before the date.
    var lastDay: Double
    /// Weighted blend of `lastDay` and the average of up to 10 full days before.
    var weighted: Double
    /// Average of up to 14 full days before; the sigmoid compares `weighted` with it.
    var average: Double
}

struct DynamicISFValue: Equatable {
    /// mg/dL per pump unit, including an active override.
    var sensitivity: Double
    /// The profile's insulin sensitivity it replaces, mg/dL per pump unit, including an active override.
    var profileSensitivity: Double
    /// Profile / dynamic insulin sensitivity after the limits and the hypo guard.
    var ratio: Double
    var unlimitedRatio: Double
}

enum DynamicISFCalculator {
    /// Trio: 120 minus the insulin's peak (rapid-acting 65 min, ultra-rapid 50 min); nil where Dynamic ISF is unavailable.
    static func insulinDivisor(for insulinType: InsulinType?) -> Double? {
        switch insulinType {
        case .afrezza?:
            return nil
        case .fiasp?, .lyumjev?:
            return 70
        case .novolog?, .humalog?, .apidra?, nil:
            return 55
        }
    }

    /// Profile / dynamic insulin sensitivity before the limits. `scheduledSensitivity` excludes overrides, in mg/dL per pump unit.
    static func unlimitedRatio(glucose: Double, correctionTarget: Double, scheduledSensitivity: Double, totalDailyDose: DynamicISFTotalDailyDose, divisor: Double, settings: DynamicISFSettings) -> Double {
        switch settings.formula {
        case .logarithmic:
            return scheduledSensitivity * settings.adjustmentFactor * totalDailyDose.weighted * log(glucose / divisor + 1) / 1800
        case .sigmoid:
            let minimum = min(settings.minimumRatio, 1)
            let maximum = max(settings.maximumRatio, 1)
            let maximumMinusOne = maximum == 1 ? 0.01 : maximum - 1
            // Makes the ratio 1 at the correction target.
            let offset = log((1 - minimum) / maximumMinusOne)
            let tddFactor = totalDailyDose.average > 0 ? totalDailyDose.weighted / totalDailyDose.average : 1
            let exponent = (glucose - correctionTarget) * 0.0555 * settings.adjustmentFactorSigmoid * tddFactor + offset
            return (maximum - minimum) / (1 + exp(-exponent)) + minimum
        }
    }

    /// `sensitivity` includes an active override, `scheduledSensitivity` does not; the override scales the result.
    /// nil for glucose or weighted TDD ≤ 0.
    static func value(glucose: Double, correctionTarget: Double, sensitivity: Double, scheduledSensitivity: Double, totalDailyDose: DynamicISFTotalDailyDose, divisor: Double, settings: DynamicISFSettings) -> DynamicISFValue? {
        guard glucose > 0, totalDailyDose.weighted > 0 else {
            return nil
        }
        let unlimited = unlimitedRatio(glucose: glucose, correctionTarget: correctionTarget, scheduledSensitivity: scheduledSensitivity, totalDailyDose: totalDailyDose, divisor: divisor, settings: settings)
        var ratio = min(max(unlimited, settings.minimumRatio), settings.maximumRatio)
        // Deviates from Trio: below the target the insulin sensitivity never exceeds the profile's.
        if glucose < correctionTarget {
            ratio = max(ratio, 1)
        }
        return DynamicISFValue(sensitivity: sensitivity / ratio, profileSensitivity: sensitivity, ratio: ratio, unlimitedRatio: unlimited)
    }
}

/// Insulin delivered in IU per calendar day, for the long-term part of the weighted TDD.
struct DynamicISFDailyTotal: Codable, Equatable {
    /// Start of the calendar day.
    let day: Date
    let internationalUnits: Double
}

/// Normalized doses in current pump units, with the date from which they are complete.
struct DynamicISFInsulinHistory {
    /// Data starting this much after the requested start still counts as complete (e.g. a pod change gap).
    static let completenessTolerance: TimeInterval = .hours(1)

    private struct Delivery {
        let start: Date
        let end: Date
        let units: Double
    }

    let doses: [DoseEntry]
    let dataStart: Date
    /// Sorted by end date, with running totals, so every total costs O(log n) instead of O(n).
    private let deliveries: [Delivery]
    private let unitsEndedBefore: [Double]
    private let longestDeliveryDuration: TimeInterval

    /// `doses` as returned for a query from `fetchStart`.
    init(doses: [DoseEntry], fetchStart: Date) {
        let insulinDoses = doses.filter { $0.type != .suspend && $0.type != .resume }
        let deliveries = insulinDoses
            .map { Delivery(start: $0.startDate, end: max($0.startDate, $0.endDate), units: $0.unitsInDeliverableIncrements) }
            .sorted { $0.end < $1.end }
        self.doses = insulinDoses
        self.dataStart = max(fetchStart, doses.map { $0.startDate }.min() ?? .distantFuture)
        self.deliveries = deliveries
        self.unitsEndedBefore = deliveries.reduce(into: [0]) { sums, delivery in
            sums.append(sums[sums.count - 1] + delivery.units)
        }
        self.longestDeliveryDuration = deliveries.map { $0.end.timeIntervalSince($0.start) }.max() ?? 0
    }

    /// Pump units delivered between `start` and `end`; nil without data covering `start`.
    func delivered(from start: Date, to end: Date) -> Double? {
        guard dataStart <= start.addingTimeInterval(Self.completenessTolerance) else {
            return nil
        }
        return delivered(before: end) - delivered(before: start)
    }

    /// Pump units delivered before `date`; a dose in progress counts pro rata.
    private func delivered(before date: Date) -> Double {
        var low = 0
        var high = deliveries.count
        while low < high {
            let middle = (low + high) / 2
            if deliveries[middle].end < date {
                low = middle + 1
            } else {
                high = middle
            }
        }
        var total = unitsEndedBefore[low]
        for delivery in deliveries[low...] {
            // Later doses start at or after `date`.
            guard delivery.end.timeIntervalSince(date) < longestDeliveryDuration else {
                break
            }
            if delivery.start < date {
                total += delivery.units * date.timeIntervalSince(delivery.start) / delivery.end.timeIntervalSince(delivery.start)
            }
        }
        return total
    }

    /// IU of every complete calendar day before today.
    func dailyTotals(before now: Date, unitsPerPumpUnit: Double, calendar: Calendar) -> [DynamicISFDailyTotal] {
        var totals: [DynamicISFDailyTotal] = []
        let today = calendar.startOfDay(for: now)
        var day = calendar.startOfDay(for: dataStart)
        while day < today, let next = calendar.date(byAdding: .day, value: 1, to: day) {
            if let units = delivered(from: day, to: next) {
                totals.append(DynamicISFDailyTotal(day: day, internationalUnits: units * unitsPerPumpUnit))
            }
            day = next
        }
        return totals
    }
}

/// Persisted daily totals (14 days).
final class DynamicISFDailyTotalsStore {
    static let retainedDays = 14
    static let weightedAverageDays = 10

    private let defaults: UserDefaults?
    private let lockedTotals: Locked<[DynamicISFDailyTotal]>

    /// Without `defaults` the totals are only kept in memory.
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        let data = defaults?.data(forKey: UserDefaults.DynamicISFKey.dailyTotals.rawValue)
        lockedTotals = Locked(data.flatMap { try? JSONDecoder().decode([DynamicISFDailyTotal].self, from: $0) } ?? [])
    }

    var totals: [DynamicISFDailyTotal] {
        lockedTotals.value
    }

    /// Whether yesterday's total is still missing.
    func needsUpdate(now: Date, calendar: Calendar) -> Bool {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else {
            return false
        }
        return !totals.contains { $0.day == yesterday }
    }

    /// Replaces the stored days found in `newTotals` and drops days older than `retainedDays`.
    func store(_ newTotals: [DynamicISFDailyTotal], now: Date, calendar: Calendar) {
        let oldest = calendar.date(byAdding: .day, value: -Self.retainedDays, to: calendar.startOfDay(for: now)) ?? .distantPast
        let days = Set(newTotals.map { $0.day })
        let totals = lockedTotals.mutate { totals in
            totals = (totals.filter { !days.contains($0.day) } + newTotals)
                .filter { $0.day >= oldest }
                .sorted { $0.day < $1.day }
        }
        if let data = try? JSONEncoder().encode(totals) {
            defaults?.set(data, forKey: UserDefaults.DynamicISFKey.dailyTotals.rawValue)
        }
    }

    /// TDD at `date`: the last 24 hours blended with the full days before `date`'s day.
    static func totalDailyDose(at date: Date, history: DynamicISFInsulinHistory, dailyTotals: [DynamicISFDailyTotal], unitsPerPumpUnit: Double, weight: Double, calendar: Calendar) -> DynamicISFTotalDailyDose? {
        guard let lastDay = history.delivered(from: date.addingTimeInterval(.hours(-24)), to: date), lastDay > 0 else {
            return nil
        }
        let day = calendar.startOfDay(for: date)
        let earlier = { (days: Int) -> [Double] in
            let first = calendar.date(byAdding: .day, value: -days, to: day) ?? day
            return dailyTotals.filter { $0.day >= first && $0.day < day }.map { $0.internationalUnits / unitsPerPumpUnit }
        }
        let mean = { (values: [Double]) in values.isEmpty ? lastDay : values.reduce(0, +) / Double(values.count) }
        return DynamicISFTotalDailyDose(
            lastDay: lastDay,
            weighted: weight * lastDay + (1 - weight) * mean(earlier(weightedAverageDays)),
            average: mean(earlier(retainedDays))
        )
    }
}

/// Everything needed for Dynamic ISF at any point in time of one loop update.
struct DynamicISFContext {
    /// Older glucose leaves the profile's insulin sensitivity in place.
    static let glucoseMaximumAge: TimeInterval = .minutes(15)
    /// Dose history before the earliest insulin effect (24 h) and its duration, plus 24 h for the TDD.
    static let doseHistoryDuration: TimeInterval = .hours(55)
    static let glucoseHistoryDuration: TimeInterval = .hours(31)

    /// When the context was built; later dates (e.g. future carb entries) use the dynamic ISF of this moment.
    let referenceDate: Date
    let settings: DynamicISFSettings
    let divisor: Double
    let history: DynamicISFInsulinHistory
    /// Sorted by date, mg/dL.
    let glucose: [(date: Date, value: Double)]
    /// Including override history.
    let sensitivitySchedule: InsulinSensitivitySchedule
    let scheduledSensitivitySchedule: InsulinSensitivitySchedule
    let correctionRange: GlucoseRangeSchedule
    let totalDailyDose: (Date) -> DynamicISFTotalDailyDose?

    func latestGlucose(at date: Date) -> Double? {
        var low = 0
        var high = glucose.count
        while low < high {
            let middle = (low + high) / 2
            if glucose[middle].date <= date {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low > 0, date.timeIntervalSince(glucose[low - 1].date) <= Self.glucoseMaximumAge else {
            return nil
        }
        return glucose[low - 1].value
    }

    func correctionTarget(at date: Date) -> Double {
        correctionRange.quantityRange(at: date).averageValue(for: .milligramsPerDeciliter)
    }

    /// nil where the profile's insulin sensitivity applies; `glucose` (mg/dL) replaces the CGM value, e.g. a manual reading.
    func value(at date: Date, glucose: Double? = nil) -> DynamicISFValue? {
        let date = min(date, referenceDate)
        guard let glucose = glucose ?? latestGlucose(at: date),
              let totalDailyDose = totalDailyDose(date) else {
            return nil
        }
        return DynamicISFCalculator.value(
            glucose: glucose,
            correctionTarget: correctionTarget(at: date),
            sensitivity: sensitivitySchedule.quantity(at: date).doubleValue(for: .milligramsPerDeciliter),
            scheduledSensitivity: scheduledSensitivitySchedule.quantity(at: date).doubleValue(for: .milligramsPerDeciliter),
            totalDailyDose: totalDailyDose,
            divisor: divisor,
            settings: settings
        )
    }

    /// mg/dL per pump unit, the profile's where Dynamic ISF has no value.
    func sensitivity(at date: Date) -> Double {
        value(at: date)?.sensitivity ?? sensitivitySchedule.quantity(at: date).doubleValue(for: .milligramsPerDeciliter)
    }

    func carbEntrySensitivity(at date: Date) -> HKQuantity? {
        value(at: date).map { HKQuantity(unit: .milligramsPerDeciliter, doubleValue: $0.sensitivity) }
    }

    /// Like `DoseStore.getGlucoseEffects(start:end:basalDosingEnd:)`, with each dose's Dynamic ISF.
    func insulinEffects(start: Date, basalDosingEnd: Date?, insulinModelProvider: InsulinModelProvider, longestEffectDuration: TimeInterval) -> [GlucoseEffect] {
        let doses = history.doses.filterDateRange(start.addingTimeInterval(-longestEffectDuration), nil).map { dose -> DoseEntry in
            dose.type == .bolus ? dose : dose.trimmed(to: basalDosingEnd)
        }
        return doses.glucoseEffects(
            insulinModelProvider: insulinModelProvider,
            longestEffectDuration: longestEffectDuration,
            insulinSensitivityForDose: { sensitivity(at: $0.startDate) },
            from: start
        ).filterDateRange(start, nil)
    }

    /// For doses starting now: the dynamic ISF at `glucose` (mg/dL) as a constant schedule in `profile`'s unit.
    func dosingSchedule(_ profile: InsulinSensitivitySchedule, at date: Date, glucose: Double?) -> (schedule: InsulinSensitivitySchedule, value: DynamicISFValue)? {
        guard let value = value(at: date, glucose: glucose) else {
            return nil
        }
        let sensitivity = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: value.sensitivity).doubleValue(for: profile.unit)
        guard let schedule = InsulinSensitivitySchedule(unit: profile.unit, dailyItems: [RepeatingScheduleValue(startTime: 0, value: sensitivity)], timeZone: profile.timeZone) else {
            return nil
        }
        return (schedule, value)
    }
}

/// The Dynamic ISF of the last loop update and of the last bolus recommendation, for display.
struct DynamicISFStatus: Equatable {
    var date: Date
    var inactiveReason: DynamicISFInactiveReason?
    /// The pump's insulin, also while the switch is off, so the settings screen can tell whether Dynamic ISF is available.
    var insulinType: InsulinType?
    var glucose: Double?
    var totalDailyDose: DynamicISFTotalDailyDose?
    var value: DynamicISFValue?
}

final class DynamicISFState: ObservableObject {
    static let shared = DynamicISFState()

    @Published private(set) var status: DynamicISFStatus?
    /// Set when a bolus recommendation used Dynamic ISF, cleared when it did not.
    @Published private(set) var bolusValue: DynamicISFValue?

    func publish(_ status: DynamicISFStatus) {
        DispatchQueue.main.async {
            self.status = status
        }
    }

    func publishBolusValue(_ value: DynamicISFValue?) {
        DispatchQueue.main.async {
            self.bolusValue = value
        }
    }
}
