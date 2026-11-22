//
//  InsulinEffectMonitor.swift
//  Loop
//
//  Flags glucose rising although insulin should be lowering it (e.g. a leaking cannula).
//  Display-only: nothing in here changes dosing.
//

import Foundation
import HealthKit
import LoopCore
import LoopKit

struct InsulinEffectMonitorSettings: Codable, Equatable {
    var isEnabled = true
    /// mg/dL/min the sensor may rise beyond what the carbs on board allow
    var riseRateThreshold = 1.5
    /// IU
    var minimumInsulinOnBoard = 1.0
    /// mg/dL/min of insulin counteraction beyond what the carbs on board allow
    var unexplainedRateThreshold = 2.0
    /// mg/dL above Loop's forecast within 30 min
    var discrepancyThreshold = 30.0
    /// Carbs on board are allowed to raise glucose as if all were absorbed within this many minutes.
    var carbAllowanceMinutes = 180.0
}

struct InsulinEffectMonitorInput {
    struct Reading {
        let date: Date
        /// mg/dL
        let glucose: Double
        /// mg/dL/min, as reported by the sensor
        let trendRate: Double?
    }

    struct Rate {
        let start: Date
        let end: Date
        /// mg/dL/min
        let rate: Double
    }

    struct Change {
        let end: Date
        /// mg/dL
        let change: Double
    }

    var now: Date
    /// Chronological
    var readings: [Reading]
    var counteraction: [Rate]
    var discrepancies: [Change]
    /// Pump units
    var insulinOnBoard: Double?
    /// g
    var carbsOnBoard: Double?
    /// mg/dL/U
    var insulinSensitivity: Double?
    /// g/U
    var carbRatio: Double?
    var unitsPerPumpUnit: Double = 1
}

struct InsulinEffectAssessment: Equatable {
    enum Signal {
        case fastRise
        case unexplainedRise
        case aboveForecast
        case correctionNotWorking
    }

    /// Shown level: rises only once `signalLevel` has held for two evaluations.
    var level: InsulinEffectLevel
    /// Level of this evaluation alone
    var signalLevel: InsulinEffectLevel
    var signals: Set<Signal> = []
    var date: Date
    /// mg/dL
    var glucose: Double?
    /// mg/dL/min
    var riseRate: Double?
    /// mg/dL/min
    var counteractionRate: Double?
    /// mg/dL/min
    var carbAllowanceRate: Double?
    /// mg/dL
    var discrepancy: Double?
    /// mg/dL
    var hourChange: Double?
    /// mg/dL the insulin of the last hour should have lowered glucose by
    var expectedHourDrop: Double?
    /// IU
    var insulinOnBoard: Double?
    var carbsOnBoard: Double?

    static func unknown(at date: Date) -> InsulinEffectAssessment {
        InsulinEffectAssessment(level: .unknown, signalLevel: .unknown, date: date)
    }
}

enum InsulinEffectMonitor {
    static let maximumReadingAge: TimeInterval = 15 * 60
    static let trendWindow: TimeInterval = 20 * 60
    static let minimumTrendReadings = 3
    static let correctionGlucose = 180.0
    static let minimumExpectedHourDrop = 30.0
    /// Above this, rises may be meal rises: at most `.watch`.
    static let maximumCarbsOnBoard = 5.0
    static let lookback: TimeInterval = 90 * 60

    static func assess(_ input: InsulinEffectMonitorInput, settings: InsulinEffectMonitorSettings) -> InsulinEffectAssessment {
        guard settings.isEnabled,
              let latest = input.readings.last,
              input.now.timeIntervalSince(latest.date) <= maximumReadingAge,
              let pumpInsulinOnBoard = input.insulinOnBoard else {
            return .unknown(at: input.now)
        }
        let insulinOnBoard = pumpInsulinOnBoard * input.unitsPerPumpUnit
        let recent = input.readings.filter { $0.date > latest.date.addingTimeInterval(-trendWindow) }
        guard recent.count >= minimumTrendReadings else {
            return .unknown(at: input.now)
        }

        let carbsOnBoard = input.carbsOnBoard ?? 0
        var carbAllowanceRate: Double?
        if carbsOnBoard <= 0 {
            carbAllowanceRate = 0
        } else if let sensitivity = input.insulinSensitivity, let carbRatio = input.carbRatio, carbRatio > 0 {
            carbAllowanceRate = carbsOnBoard * sensitivity / carbRatio / settings.carbAllowanceMinutes
        }

        var assessment = InsulinEffectAssessment(level: .normal, signalLevel: .normal, date: input.now)
        assessment.glucose = latest.glucose
        assessment.insulinOnBoard = insulinOnBoard
        assessment.carbsOnBoard = carbsOnBoard
        assessment.carbAllowanceRate = carbAllowanceRate
        assessment.riseRate = latest.trendRate ?? slope(of: recent)
        assessment.counteractionRate = meanRate(input.counteraction, from: latest.date.addingTimeInterval(-trendWindow), to: latest.date)
        assessment.discrepancy = input.discrepancies.last { $0.end > latest.date.addingTimeInterval(-10 * 60) }?.change
        let hourAgo = input.readings
            .filter { (TimeInterval.minutes(50)...TimeInterval.minutes(70)).contains(latest.date.timeIntervalSince($0.date)) }
            .min { abs(latest.date.timeIntervalSince($0.date) - .hours(1)) < abs(latest.date.timeIntervalSince($1.date) - .hours(1)) }
        if let hourAgo {
            let hourChange = latest.glucose - hourAgo.glucose
            assessment.hourChange = hourChange
            // Counteraction is the observed change minus the insulin effect, so the insulin effect is what remains.
            assessment.expectedHourDrop = integral(input.counteraction, from: hourAgo.date, to: latest.date) - hourChange
        }

        let hasInsulin = insulinOnBoard >= settings.minimumInsulinOnBoard
        // Falling slower than forecast is not a rise; only a correction that stalls (checked below) matters then.
        let isRising = (assessment.riseRate ?? 0) > 0
        if let riseRate = assessment.riseRate, let allowance = carbAllowanceRate,
           hasInsulin, riseRate - allowance >= settings.riseRateThreshold {
            assessment.signals.insert(.fastRise)
        }
        if isRising, let counteraction = assessment.counteractionRate, let allowance = carbAllowanceRate,
           counteraction - allowance >= settings.unexplainedRateThreshold {
            assessment.signals.insert(.unexplainedRise)
        }
        if isRising, let discrepancy = assessment.discrepancy, discrepancy >= settings.discrepancyThreshold {
            assessment.signals.insert(.aboveForecast)
        }
        if let hourChange = assessment.hourChange, let expectedDrop = assessment.expectedHourDrop,
           expectedDrop >= minimumExpectedHourDrop,
           -hourChange <= expectedDrop / 3,
           latest.glucose >= correctionGlucose,
           carbsOnBoard <= maximumCarbsOnBoard {
            assessment.signals.insert(.correctionNotWorking)
        }

        let signals = assessment.signals
        var level = InsulinEffectLevel.normal
        if signals.contains(.correctionNotWorking)
            || (signals.contains(.fastRise) && (signals.contains(.unexplainedRise) || signals.contains(.aboveForecast)))
            || (signals.contains(.unexplainedRise) && signals.contains(.aboveForecast)) {
            level = .attention
        } else if !signals.isEmpty {
            level = .watch
        }
        if carbsOnBoard > maximumCarbsOnBoard {
            level = min(level, .watch)
        }
        assessment.level = level
        assessment.signalLevel = level
        return assessment
    }

    /// Lets `current` rise above the previous evaluation only when the previous one, at most `maximumReadingAge` old,
    /// already signalled at least that level. Falls immediately.
    static func persisting(_ current: InsulinEffectAssessment, after previous: InsulinEffectAssessment?) -> InsulinEffectAssessment {
        guard current.signalLevel != .unknown else {
            return current
        }
        var heldLevel = InsulinEffectLevel.normal
        if let previous, current.date.timeIntervalSince(previous.date) <= maximumReadingAge {
            heldLevel = max(previous.signalLevel, .normal)
        }
        var result = current
        result.level = min(current.signalLevel, heldLevel)
        return result
    }

    /// Least-squares slope, mg/dL/min.
    static func slope(of readings: [InsulinEffectMonitorInput.Reading]) -> Double? {
        guard readings.count >= 2, let first = readings.first?.date else { return nil }
        let points = readings.map { (x: $0.date.timeIntervalSince(first) / 60, y: $0.glucose) }
        let meanX = points.reduce(0) { $0 + $1.x } / Double(points.count)
        let meanY = points.reduce(0) { $0 + $1.y } / Double(points.count)
        let denominator = points.reduce(0) { $0 + ($1.x - meanX) * ($1.x - meanX) }
        guard denominator > 0 else { return nil }
        return points.reduce(0) { $0 + ($1.x - meanX) * ($1.y - meanY) } / denominator
    }

    /// Time-weighted mean of the rates overlapping the range.
    static func meanRate(_ rates: [InsulinEffectMonitorInput.Rate], from start: Date, to end: Date) -> Double? {
        let seconds = rates.reduce(0) { $0 + overlap(of: $1, from: start, to: end) }
        return seconds > 0 ? integral(rates, from: start, to: end) * 60 / seconds : nil
    }

    /// Sum of rate x overlapping minutes, mg/dL.
    static func integral(_ rates: [InsulinEffectMonitorInput.Rate], from start: Date, to end: Date) -> Double {
        rates.reduce(0) { $0 + $1.rate * overlap(of: $1, from: start, to: end) / 60 }
    }

    private static func overlap(of rate: InsulinEffectMonitorInput.Rate, from start: Date, to end: Date) -> TimeInterval {
        max(0, min(rate.end, end).timeIntervalSince(max(rate.start, start)))
    }
}

extension InsulinEffectMonitorInput {
    /// Call on the loop's data queue: the state must not be used outside it. Readings are added separately.
    init(now: Date, state: LoopState, insulinSensitivity: InsulinSensitivitySchedule?, carbRatio: CarbRatioSchedule?, unitsPerPumpUnit: Double) {
        let mgdl = HKUnit.milligramsPerDeciliter
        let mgdlPerMinute = mgdl.unitDivided(by: .minute())
        let start = now.addingTimeInterval(-InsulinEffectMonitor.lookback)
        self.init(
            now: now,
            readings: [],
            counteraction: state.insulinCounteractionEffects
                .filter { $0.endDate >= start }
                .map { Rate(start: $0.startDate, end: $0.endDate, rate: $0.quantity.doubleValue(for: mgdlPerMinute)) },
            discrepancies: (state.retrospectiveGlucoseDiscrepancies ?? [])
                .filter { $0.endDate >= start }
                .map { Change(end: $0.endDate, change: $0.quantity.doubleValue(for: mgdl)) },
            insulinOnBoard: state.insulinOnBoard?.value,
            carbsOnBoard: state.carbsOnBoard?.quantity.doubleValue(for: .gram()),
            insulinSensitivity: insulinSensitivity?.quantity(at: now).doubleValue(for: mgdl),
            carbRatio: carbRatio?.value(at: now),
            unitsPerPumpUnit: unitsPerPumpUnit
        )
    }

    /// Sensor readings of the lookback window, chronological; calibrations and manual entries are skipped.
    static func readings(from samples: [StoredGlucoseSample], now: Date) -> [Reading] {
        let mgdl = HKUnit.milligramsPerDeciliter
        let mgdlPerMinute = mgdl.unitDivided(by: .minute())
        let start = now.addingTimeInterval(-InsulinEffectMonitor.lookback)
        return samples
            .filter { $0.startDate >= start && !$0.isDisplayOnly && !$0.wasUserEntered }
            .sorted { $0.startDate < $1.startDate }
            .map { Reading(date: $0.startDate, glucose: $0.quantity.doubleValue(for: mgdl), trendRate: $0.trendRate?.doubleValue(for: mgdlPerMinute)) }
    }
}
