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
    /// U
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
    /// U
    var insulinOnBoard: Double?
    /// g
    var carbsOnBoard: Double?
    /// mg/dL/U
    var insulinSensitivity: Double?
    /// g/U
    var carbRatio: Double?
}

struct InsulinEffectAssessment: Equatable {
    enum Signal {
        case fastRise
        case unexplainedRise
        case aboveForecast
        case correctionNotWorking
    }

    var level: InsulinEffectLevel
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
    var insulinOnBoard: Double?
    var carbsOnBoard: Double?

    static func unknown(at date: Date) -> InsulinEffectAssessment {
        InsulinEffectAssessment(level: .unknown, date: date)
    }
}

enum InsulinEffectMonitor {
    static let maximumReadingAge: TimeInterval = 15 * 60
    static let trendWindow: TimeInterval = 15 * 60
    static let minimumTrendReadings = 3
    static let correctionGlucose = 180.0
    static let correctionMaximumCarbs = 5.0
    static let lookback: TimeInterval = 90 * 60

    static func assess(_ input: InsulinEffectMonitorInput, settings: InsulinEffectMonitorSettings) -> InsulinEffectAssessment {
        guard settings.isEnabled,
              let latest = input.readings.last,
              input.now.timeIntervalSince(latest.date) <= maximumReadingAge,
              let insulinOnBoard = input.insulinOnBoard else {
            return .unknown(at: input.now)
        }
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

        var assessment = InsulinEffectAssessment(level: .normal, date: input.now)
        assessment.glucose = latest.glucose
        assessment.insulinOnBoard = insulinOnBoard
        assessment.carbsOnBoard = carbsOnBoard
        assessment.carbAllowanceRate = carbAllowanceRate
        assessment.riseRate = latest.trendRate ?? slope(of: recent)
        assessment.counteractionRate = meanRate(input.counteraction, from: latest.date.addingTimeInterval(-trendWindow), to: latest.date)
        assessment.discrepancy = input.discrepancies.last { $0.end > latest.date.addingTimeInterval(-10 * 60) }?.change
        if let hourAgo = input.readings.last(where: { $0.date <= latest.date.addingTimeInterval(-50 * 60) }),
           hourAgo.date >= latest.date.addingTimeInterval(-70 * 60) {
            assessment.hourChange = latest.glucose - hourAgo.glucose
        }

        let hasInsulin = insulinOnBoard >= settings.minimumInsulinOnBoard
        if let riseRate = assessment.riseRate, let allowance = carbAllowanceRate,
           hasInsulin, riseRate - allowance >= settings.riseRateThreshold {
            assessment.signals.insert(.fastRise)
        }
        if let counteraction = assessment.counteractionRate, let allowance = carbAllowanceRate,
           counteraction - allowance >= settings.unexplainedRateThreshold {
            assessment.signals.insert(.unexplainedRise)
        }
        if let discrepancy = assessment.discrepancy, discrepancy >= settings.discrepancyThreshold {
            assessment.signals.insert(.aboveForecast)
        }
        if let hourChange = assessment.hourChange, hourChange >= 0,
           latest.glucose >= correctionGlucose,
           insulinOnBoard >= 2 * settings.minimumInsulinOnBoard,
           carbsOnBoard <= correctionMaximumCarbs {
            assessment.signals.insert(.correctionNotWorking)
        }

        let signals = assessment.signals
        if signals.contains(.correctionNotWorking)
            || (signals.contains(.fastRise) && (signals.contains(.unexplainedRise) || signals.contains(.aboveForecast)))
            || (signals.contains(.unexplainedRise) && signals.contains(.aboveForecast)) {
            assessment.level = .attention
        } else if !signals.isEmpty {
            assessment.level = .watch
        }
        return assessment
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
        var weighted = 0.0
        var seconds = 0.0
        for rate in rates {
            let overlap = min(rate.end, end).timeIntervalSince(max(rate.start, start))
            guard overlap > 0 else { continue }
            weighted += rate.rate * overlap
            seconds += overlap
        }
        return seconds > 0 ? weighted / seconds : nil
    }
}

extension InsulinEffectMonitorInput {
    /// Call inside `getLoopState`: the state must not be used outside that closure. Readings are added separately.
    init(now: Date, state: LoopState, insulinSensitivity: InsulinSensitivitySchedule?, carbRatio: CarbRatioSchedule?) {
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
            carbRatio: carbRatio?.value(at: now)
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
