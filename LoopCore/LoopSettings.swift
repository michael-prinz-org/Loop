//
//  LoopSettings.swift
//  Loop
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import HealthKit
import LoopKit

public extension AutomaticDosingStrategy {
    var title: String {
        switch self {
        case .tempBasalOnly:
            return LocalizedString("Temp Basal Only", comment: "Title string for temp basal only dosing strategy")
        case .automaticBolus:
            return LocalizedString("Automatic Bolus", comment: "Title string for automatic bolus dosing strategy")
        }
    }
}

public struct LoopSettings: Equatable {
    public var isScheduleOverrideInfiniteWorkout: Bool {
        guard let scheduleOverride = scheduleOverride else { return false }
        return scheduleOverride.context == .legacyWorkout && scheduleOverride.duration.isInfinite
    }
    
    public var dosingEnabled = false

    public var glucoseTargetRangeSchedule: GlucoseRangeSchedule?

    public var insulinSensitivitySchedule: InsulinSensitivitySchedule?

    public var basalRateSchedule: BasalRateSchedule?

    public var carbRatioSchedule: CarbRatioSchedule?

    public var preMealTargetRange: ClosedRange<HKQuantity>?

    public var legacyWorkoutTargetRange: ClosedRange<HKQuantity>?

    public var overridePresets: [TemporaryScheduleOverridePreset] = []

    public var scheduleOverride: TemporaryScheduleOverride? {
        didSet {
            if let newValue = scheduleOverride, newValue.context == .preMeal {
                preconditionFailure("The `scheduleOverride` field should not be used for a pre-meal target range override; use `preMealOverride` instead")
            }

            if scheduleOverride?.context == .legacyWorkout {
                preMealOverride = nil
            }
        }
    }

    public var preMealOverride: TemporaryScheduleOverride? {
        didSet {
            if let newValue = preMealOverride, newValue.context != .preMeal || newValue.settings.insulinNeedsScaleFactor != nil {
                preconditionFailure("The `preMealOverride` field should be used only for a pre-meal target range override")
            }
            
            if preMealOverride != nil, scheduleOverride?.context == .legacyWorkout {
                scheduleOverride = nil
            }
        }
    }

    public var maximumBasalRatePerHour: Double?

    public var maximumBolus: Double?

    public var suspendThreshold: GlucoseThreshold? = nil
    
    public var automaticDosingStrategy: AutomaticDosingStrategy = .tempBasalOnly

    public var defaultRapidActingModel: ExponentialInsulinModelPreset?

    /// Smallest allowed value for `customLoopInterval`.
    public static let minimumCustomLoopInterval: TimeInterval = .minutes(5)

    /// Largest allowed value for `customLoopInterval`.
    public static let maximumCustomLoopInterval: TimeInterval = .minutes(60)

    /// Default value for `customLoopInterval` when the user has not chosen one yet.
    public static let defaultCustomLoopInterval: TimeInterval = .minutes(15)

    /// Interval above which the loop can no longer keep pump data within `inputDataRecencyInterval`
    /// between syncs, so insulin adjustments are noticeably delayed.
    public static let customLoopIntervalWarningThreshold: TimeInterval = .minutes(13)

    public static func clampedCustomLoopInterval(_ interval: TimeInterval) -> TimeInterval {
        min(max(interval, minimumCustomLoopInterval), maximumCustomLoopInterval)
    }

    /// When `true`, pump communication is throttled to `customLoopInterval`. The loop cycle itself keeps
    /// running on every CGM reading, but automatic doses are only enacted on cycles that are allowed to
    /// communicate with the pump.
    public var customLoopIntervalEnabled = false

    /// User-configured pump communication interval, applied when `customLoopIntervalEnabled` is `true`. Clamped to `minimumCustomLoopInterval...maximumCustomLoopInterval`.
    public var customLoopInterval: TimeInterval = LoopSettings.defaultCustomLoopInterval

    /// When `true`, routine (non-dose) pod communication is suppressed while the app is in the background.
    /// Independent of `customLoopIntervalEnabled` and of closed loop; never blocks an automatic dose.
    public var suppressPodCommunicationInBackground = false

    public static let defaultGlucoseUrgentLow: Double = 54
    public static let defaultGlucoseLow: Double = 70
    public static let defaultGlucoseHigh: Double = 180
    public static let defaultGlucoseUrgentHigh: Double = 250

    /// Bounds accepted by the glucose display range editor, in mg/dL.
    public static let glucoseDisplayRangeBounds: ClosedRange<Double> = 40...400

    /// Thresholds, in mg/dL, that colour glucose values on the watch complication. Independent of the
    /// therapy correction range and of Loop's own CGM status colours.
    public var glucoseUrgentLow: Double = LoopSettings.defaultGlucoseUrgentLow
    public var glucoseLow: Double = LoopSettings.defaultGlucoseLow
    public var glucoseHigh: Double = LoopSettings.defaultGlucoseHigh
    public var glucoseUrgentHigh: Double = LoopSettings.defaultGlucoseUrgentHigh

    public var glucoseUnit: HKUnit? {
        return glucoseTargetRangeSchedule?.unit
    }

    public init(
        dosingEnabled: Bool = false,
        glucoseTargetRangeSchedule: GlucoseRangeSchedule? = nil,
        insulinSensitivitySchedule: InsulinSensitivitySchedule? = nil,
        basalRateSchedule: BasalRateSchedule? = nil,
        carbRatioSchedule: CarbRatioSchedule? = nil,
        preMealTargetRange: ClosedRange<HKQuantity>? = nil,
        legacyWorkoutTargetRange: ClosedRange<HKQuantity>? = nil,
        overridePresets: [TemporaryScheduleOverridePreset]? = nil,
        scheduleOverride: TemporaryScheduleOverride? = nil,
        preMealOverride: TemporaryScheduleOverride? = nil,
        maximumBasalRatePerHour: Double? = nil,
        maximumBolus: Double? = nil,
        suspendThreshold: GlucoseThreshold? = nil,
        automaticDosingStrategy: AutomaticDosingStrategy = .tempBasalOnly,
        customLoopIntervalEnabled: Bool = false,
        customLoopInterval: TimeInterval = LoopSettings.defaultCustomLoopInterval,
        suppressPodCommunicationInBackground: Bool = false,
        defaultRapidActingModel: ExponentialInsulinModelPreset? = nil
    ) {
        self.dosingEnabled = dosingEnabled
        self.glucoseTargetRangeSchedule = glucoseTargetRangeSchedule
        self.insulinSensitivitySchedule = insulinSensitivitySchedule
        self.basalRateSchedule = basalRateSchedule
        self.carbRatioSchedule = carbRatioSchedule
        self.preMealTargetRange = preMealTargetRange
        self.legacyWorkoutTargetRange = legacyWorkoutTargetRange
        self.overridePresets = overridePresets ?? []
        self.scheduleOverride = scheduleOverride
        self.preMealOverride = preMealOverride
        self.maximumBasalRatePerHour = maximumBasalRatePerHour
        self.maximumBolus = maximumBolus
        self.suspendThreshold = suspendThreshold
        self.automaticDosingStrategy = automaticDosingStrategy
        self.customLoopIntervalEnabled = customLoopIntervalEnabled
        self.customLoopInterval = customLoopInterval
        self.suppressPodCommunicationInBackground = suppressPodCommunicationInBackground
        self.defaultRapidActingModel = defaultRapidActingModel
    }
}

extension LoopSettings {
    /// The interval at which loop cycles are expected to complete. When a custom loop interval is
    /// enabled this reflects the user-configured, clamped interval; otherwise it falls back to the
    /// default loop cadence. Used to scale loop-status freshness so the indicator does not turn
    /// yellow/red before the next cycle is due.
    public var effectiveLoopInterval: TimeInterval {
        guard customLoopIntervalEnabled else {
            return LoopCompletionFreshness.defaultLoopInterval
        }
        return LoopSettings.clampedCustomLoopInterval(customLoopInterval)
    }

    public func effectiveGlucoseTargetRangeSchedule(presumingMealEntry: Bool = false) -> GlucoseRangeSchedule?  {
        
        let preMealOverride = presumingMealEntry ? nil : self.preMealOverride
        
        let currentEffectiveOverride: TemporaryScheduleOverride?
        switch (preMealOverride, scheduleOverride) {
        case (let preMealOverride?, nil):
            currentEffectiveOverride = preMealOverride
        case (nil, let scheduleOverride?):
            currentEffectiveOverride = scheduleOverride
        case (let preMealOverride?, let scheduleOverride?):
            currentEffectiveOverride = preMealOverride.scheduledEndDate > Date()
                ? preMealOverride
                : scheduleOverride
        case (nil, nil):
            currentEffectiveOverride = nil
        }

        if let effectiveOverride = currentEffectiveOverride {
            return glucoseTargetRangeSchedule?.applyingOverride(effectiveOverride)
        } else {
            return glucoseTargetRangeSchedule
        }
    }

    public func scheduleOverrideEnabled(at date: Date = Date()) -> Bool {
        return scheduleOverride?.isActive(at: date) == true
    }

    public func nonPreMealOverrideEnabled(at date: Date = Date()) -> Bool {
        return scheduleOverride?.isActive(at: date) == true
    }

    public func preMealTargetEnabled(at date: Date = Date()) -> Bool {
        return preMealOverride?.isActive(at: date) == true
    }

    public func futureOverrideEnabled(relativeTo date: Date = Date()) -> Bool {
        guard let scheduleOverride = scheduleOverride else { return false }
        return scheduleOverride.startDate > date
    }

    public mutating func enablePreMealOverride(at date: Date = Date(), for duration: TimeInterval) {
        preMealOverride = makePreMealOverride(beginningAt: date, for: duration)
    }

    private func makePreMealOverride(beginningAt date: Date = Date(), for duration: TimeInterval) -> TemporaryScheduleOverride? {
        guard let preMealTargetRange = preMealTargetRange else {
            return nil
        }
        return TemporaryScheduleOverride(
            context: .preMeal,
            settings: TemporaryScheduleOverrideSettings(targetRange: preMealTargetRange),
            startDate: date,
            duration: .finite(duration),
            enactTrigger: .local,
            syncIdentifier: UUID()
        )
    }

    public mutating func enableLegacyWorkoutOverride(at date: Date = Date(), for duration: TimeInterval) {
        scheduleOverride = legacyWorkoutOverride(beginningAt: date, for: duration)
        preMealOverride = nil
    }

    public mutating func legacyWorkoutOverride(beginningAt date: Date = Date(), for duration: TimeInterval) -> TemporaryScheduleOverride? {
        guard let legacyWorkoutTargetRange = legacyWorkoutTargetRange else {
            return nil
        }

        return TemporaryScheduleOverride(
            context: .legacyWorkout,
            settings: TemporaryScheduleOverrideSettings(targetRange: legacyWorkoutTargetRange),
            startDate: date,
            duration: duration.isInfinite ? .indefinite : .finite(duration),
            enactTrigger: .local,
            syncIdentifier: UUID()
        )
    }

    public mutating func clearOverride(matching context: TemporaryScheduleOverride.Context? = nil) {
        if context == .preMeal {
            preMealOverride = nil
            return
        }

        guard let scheduleOverride = scheduleOverride else { return }
        
        if let context = context {
            if scheduleOverride.context == context {
                self.scheduleOverride = nil
            }
        } else {
            self.scheduleOverride = nil
        }
    }
}

extension LoopSettings: RawRepresentable {
    public typealias RawValue = [String: Any]
    private static let version = 1
    fileprivate static let codingGlucoseUnit = HKUnit.milligramsPerDeciliter

    public init?(rawValue: RawValue) {
        guard
            let version = rawValue["version"] as? Int,
            version == LoopSettings.version
        else {
            return nil
        }

        if let dosingEnabled = rawValue["dosingEnabled"] as? Bool {
            self.dosingEnabled = dosingEnabled
        }

        if let glucoseRangeScheduleRawValue = rawValue["glucoseTargetRangeSchedule"] as? GlucoseRangeSchedule.RawValue {
            self.glucoseTargetRangeSchedule = GlucoseRangeSchedule(rawValue: glucoseRangeScheduleRawValue)

            // Migrate the glucose range schedule override targets
            if let overrideRangesRawValue = glucoseRangeScheduleRawValue["overrideRanges"] as? [String: DoubleRange.RawValue] {
                if let preMealTargetRawValue = overrideRangesRawValue["preMeal"] {
                    self.preMealTargetRange = DoubleRange(rawValue: preMealTargetRawValue)?.quantityRange(for: LoopSettings.codingGlucoseUnit)
                }
                if let legacyWorkoutTargetRawValue = overrideRangesRawValue["workout"] {
                    self.legacyWorkoutTargetRange = DoubleRange(rawValue: legacyWorkoutTargetRawValue)?.quantityRange(for: LoopSettings.codingGlucoseUnit)
                }
            }
        }

        if let rawPreMealTargetRange = rawValue["preMealTargetRange"] as? DoubleRange.RawValue {
            self.preMealTargetRange = DoubleRange(rawValue: rawPreMealTargetRange)?.quantityRange(for: LoopSettings.codingGlucoseUnit)
        }

        if let rawLegacyWorkoutTargetRange = rawValue["legacyWorkoutTargetRange"] as? DoubleRange.RawValue {
            self.legacyWorkoutTargetRange = DoubleRange(rawValue: rawLegacyWorkoutTargetRange)?.quantityRange(for: LoopSettings.codingGlucoseUnit)
        }

        if let rawPresets = rawValue["overridePresets"] as? [TemporaryScheduleOverridePreset.RawValue] {
            self.overridePresets = rawPresets.compactMap(TemporaryScheduleOverridePreset.init(rawValue:))
        }

        if let rawPreMealOverride = rawValue["preMealOverride"] as? TemporaryScheduleOverride.RawValue {
            self.preMealOverride = TemporaryScheduleOverride(rawValue: rawPreMealOverride)
        }

        if let rawOverride = rawValue["scheduleOverride"] as? TemporaryScheduleOverride.RawValue {
            self.scheduleOverride = TemporaryScheduleOverride(rawValue: rawOverride)
        }

        self.maximumBasalRatePerHour = rawValue["maximumBasalRatePerHour"] as? Double

        self.maximumBolus = rawValue["maximumBolus"] as? Double

        if let rawThreshold = rawValue["minimumBGGuard"] as? GlucoseThreshold.RawValue {
            self.suspendThreshold = GlucoseThreshold(rawValue: rawThreshold)
        }
        
        if let rawDosingStrategy = rawValue["dosingStrategy"] as? AutomaticDosingStrategy.RawValue,
            let automaticDosingStrategy = AutomaticDosingStrategy(rawValue: rawDosingStrategy)
        {
            self.automaticDosingStrategy = automaticDosingStrategy
        }

        if let customLoopIntervalEnabled = rawValue["customLoopIntervalEnabled"] as? Bool {
            self.customLoopIntervalEnabled = customLoopIntervalEnabled
        }

        if let customLoopInterval = rawValue["customLoopInterval"] as? TimeInterval {
            self.customLoopInterval = LoopSettings.clampedCustomLoopInterval(customLoopInterval)
        }

        if let suppressPodCommunicationInBackground = rawValue["suppressPodCommunicationInBackground"] as? Bool {
            self.suppressPodCommunicationInBackground = suppressPodCommunicationInBackground
        }

        if let value = (rawValue["glucoseUrgentLow"] as? Double) ?? (rawValue["glucoseDisplayUrgentLow"] as? Double) {
            self.glucoseUrgentLow = value
        }
        if let value = (rawValue["glucoseLow"] as? Double) ?? (rawValue["glucoseDisplayLow"] as? Double) {
            self.glucoseLow = value
        }
        if let value = (rawValue["glucoseHigh"] as? Double) ?? (rawValue["glucoseDisplayHigh"] as? Double) {
            self.glucoseHigh = value
        }
        if let value = (rawValue["glucoseUrgentHigh"] as? Double) ?? (rawValue["glucoseDisplayUrgentHigh"] as? Double) {
            self.glucoseUrgentHigh = value
        }
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            "version": LoopSettings.version,
            "dosingEnabled": dosingEnabled,
            "overridePresets": overridePresets.map { $0.rawValue }
        ]

        raw["glucoseTargetRangeSchedule"] = glucoseTargetRangeSchedule?.rawValue
        raw["preMealTargetRange"] = preMealTargetRange?.doubleRange(for: LoopSettings.codingGlucoseUnit).rawValue
        raw["legacyWorkoutTargetRange"] = legacyWorkoutTargetRange?.doubleRange(for: LoopSettings.codingGlucoseUnit).rawValue
        raw["preMealOverride"] = preMealOverride?.rawValue
        raw["scheduleOverride"] = scheduleOverride?.rawValue
        raw["maximumBasalRatePerHour"] = maximumBasalRatePerHour
        raw["maximumBolus"] = maximumBolus
        raw["minimumBGGuard"] = suspendThreshold?.rawValue
        raw["dosingStrategy"] = automaticDosingStrategy.rawValue
        raw["customLoopIntervalEnabled"] = customLoopIntervalEnabled
        raw["customLoopInterval"] = customLoopInterval
        raw["suppressPodCommunicationInBackground"] = suppressPodCommunicationInBackground
        raw["glucoseUrgentLow"] = glucoseUrgentLow
        raw["glucoseLow"] = glucoseLow
        raw["glucoseHigh"] = glucoseHigh
        raw["glucoseUrgentHigh"] = glucoseUrgentHigh
        
        return raw
    }
}

/// How a glucose value should be presented relative to the user's configured display range.
public enum GlucoseDisplayTier: Int {
    case inRange
    case outOfRange
    case urgent
}

/// The four thresholds, in mg/dL, that colour glucose values on the watch complication.
public struct GlucoseDisplayRange: Equatable {
    public var urgentLow: Double
    public var low: Double
    public var high: Double
    public var urgentHigh: Double

    /// Smallest gap enforced between adjacent thresholds, in mg/dL.
    private static let minimumSeparation: Double = 1

    public init(urgentLow: Double = LoopSettings.defaultGlucoseUrgentLow,
                low: Double = LoopSettings.defaultGlucoseLow,
                high: Double = LoopSettings.defaultGlucoseHigh,
                urgentHigh: Double = LoopSettings.defaultGlucoseUrgentHigh)
    {
        let bounds = LoopSettings.glucoseDisplayRangeBounds
        self.urgentLow = min(max(urgentLow, bounds.lowerBound), bounds.upperBound)
        self.low = max(low, self.urgentLow + Self.minimumSeparation)
        self.high = max(high, self.low + Self.minimumSeparation)
        self.urgentHigh = min(max(urgentHigh, self.high + Self.minimumSeparation), bounds.upperBound)
    }
}

extension LoopSettings {
    public var glucoseDisplayRange: GlucoseDisplayRange {
        get {
            GlucoseDisplayRange(urgentLow: glucoseUrgentLow,
                                low: glucoseLow,
                                high: glucoseHigh,
                                urgentHigh: glucoseUrgentHigh)
        }
        set {
            glucoseUrgentLow = newValue.urgentLow
            glucoseLow = newValue.low
            glucoseHigh = newValue.high
            glucoseUrgentHigh = newValue.urgentHigh
        }
    }

    /// Where `quantity` falls relative to the configured display thresholds.
    public func glucoseDisplayTier(for quantity: HKQuantity) -> GlucoseDisplayTier {
        let value = quantity.doubleValue(for: .milligramsPerDeciliter)

        if value < glucoseUrgentLow || value > glucoseUrgentHigh {
            return .urgent
        }
        if value < glucoseLow || value > glucoseHigh {
            return .outOfRange
        }
        return .inRange
    }

    /// Tier for a predicted value, which is judged against the correction range rather than the display
    /// range: green means Loop expects to land in target. The urgent thresholds still apply.
    public func glucoseDisplayTier(forPredicted quantity: HKQuantity, at date: Date) -> GlucoseDisplayTier {
        let value = quantity.doubleValue(for: .milligramsPerDeciliter)

        if value < glucoseUrgentLow || value > glucoseUrgentHigh {
            return .urgent
        }

        guard let targetRange = effectiveGlucoseTargetRangeSchedule()?.quantityRange(at: date) else {
            return glucoseDisplayTier(for: quantity)
        }

        return targetRange.contains(quantity) ? .inRange : .outOfRange
    }
}
