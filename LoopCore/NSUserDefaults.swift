//
//  NSUserDefaults.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 8/30/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import Foundation
import LoopKit
import HealthKit


extension UserDefaults {

    private enum Key: String {
        case overrideHistory = "com.loopkit.overrideHistory"
        case lastBedtimeQuery = "com.loopkit.Loop.lastBedtimeQuery"
        case bedtime = "com.loopkit.Loop.bedtime"
        case lastProfileExpirationAlertDate = "com.loopkit.Loop.lastProfileExpirationAlertDate"
        case allowDebugFeatures = "com.loopkit.Loop.allowDebugFeatures"
        case allowExperimentalFeatures = "com.loopkit.Loop.allowExperimentalFeatures"
        case allowSimulators = "com.loopkit.Loop.allowSimulators"
        case LastMissedMealNotification = "com.loopkit.Loop.lastMissedMealNotification"
        case userRequestedLoopReset = "com.loopkit.Loop.userRequestedLoopReset"
        case liveActivity = "com.loopkit.Loop.liveActivity"
        case customLoopIntervalEnabled = "com.loopkit.Loop.customLoopIntervalEnabled"
        case customLoopInterval = "com.loopkit.Loop.customLoopInterval"
        case suppressPodCommunicationInBackground = "com.loopkit.Loop.suppressPodCommunicationInBackground"
        case glucoseUrgentLow = "com.loopkit.Loop.glucoseUrgentLow"
        case glucoseLow = "com.loopkit.Loop.glucoseLow"
        case glucoseHigh = "com.loopkit.Loop.glucoseHigh"
        case glucoseUrgentHigh = "com.loopkit.Loop.glucoseUrgentHigh"
    }

    public static let appGroup = UserDefaults(suiteName: Bundle.main.appGroupSuiteName)

    public var legacyBasalRateSchedule: BasalRateSchedule? {
        get {
            if let rawValue = dictionary(forKey: "com.loudnate.Naterade.BasalRateSchedule") {
                return BasalRateSchedule(rawValue: rawValue)
            } else {
                return nil
            }
        }
    }

    public var legacyCarbRatioSchedule: CarbRatioSchedule? {
        get {
            if let rawValue = dictionary(forKey: "com.loudnate.Naterade.CarbRatioSchedule") {
                return CarbRatioSchedule(rawValue: rawValue)
            } else {
                return nil
            }
        }
    }

    public var legacyDefaultRapidActingModel: ExponentialInsulinModelPreset? {
        get {
            if let rawValue = string(forKey: "com.loopkit.Loop.defaultRapidActingModel") {
                return ExponentialInsulinModelPreset(rawValue: rawValue)
            }
            
            return nil
        }
    }

    public var legacyLoopSettings: LoopSettings? {
        get {
            if let rawValue = dictionary(forKey: "com.loopkit.Loop.loopSettings") {
                return LoopSettings(rawValue: rawValue)
            } else {
                return nil
            }
        }
    }

    public var legacyInsulinSensitivitySchedule: InsulinSensitivitySchedule? {
        get {
            if let rawValue = dictionary(forKey: "com.loudnate.Naterade.InsulinSensitivitySchedule") {
                return InsulinSensitivitySchedule(rawValue: rawValue)
            } else {
                return nil
            }
        }
    }

    public var overrideHistory: TemporaryScheduleOverrideHistory? {
        get {
            if let rawValue = object(forKey: Key.overrideHistory.rawValue) as? TemporaryScheduleOverrideHistory.RawValue {
                return TemporaryScheduleOverrideHistory(rawValue: rawValue)
            } else {
                return nil
            }
        }
        set {
            set(newValue?.rawValue, forKey: Key.overrideHistory.rawValue)
        }
    }
    
    public var lastBedtimeQuery: Date? {
        get {
            return object(forKey: Key.lastBedtimeQuery.rawValue) as? Date
        }
        set {
            set(newValue, forKey: Key.lastBedtimeQuery.rawValue)
        }
    }
    
    public var bedtime: Date? {
        get {
            return object(forKey: Key.bedtime.rawValue) as? Date
        }
        set {
            set(newValue, forKey: Key.bedtime.rawValue)
        }
    }
    
    public var lastProfileExpirationAlertDate: Date? {
        get {
            return object(forKey: Key.lastProfileExpirationAlertDate.rawValue) as? Date
        }
        set {
            set(newValue, forKey: Key.lastProfileExpirationAlertDate.rawValue)
        }
    }
    
    public var lastMissedMealNotification: MissedMealNotification? {
        get {
            let decoder = JSONDecoder()
            guard let data = object(forKey: Key.LastMissedMealNotification.rawValue) as? Data else {
                return nil
            }
            return try? decoder.decode(MissedMealNotification.self, from: data)
        }
        set {
            do {
                if let newValue = newValue {
                    let encoder = JSONEncoder()
                    let data = try encoder.encode(newValue)
                    set(data, forKey: Key.LastMissedMealNotification.rawValue)
                } else {
                    set(nil, forKey: Key.LastMissedMealNotification.rawValue)
                }
            } catch {
                assertionFailure("Unable to encode MissedMealNotification")
            }
        }
    }
    
    public var allowDebugFeatures: Bool {
        get {
            bool(forKey: Key.allowDebugFeatures.rawValue)
        }
        set {
            set(newValue, forKey: Key.allowDebugFeatures.rawValue)
        }
    }

    public var allowExperimentalFeatures: Bool {
        return bool(forKey: Key.allowExperimentalFeatures.rawValue)
    }
    
    public var allowSimulators: Bool {
        return bool(forKey: Key.allowSimulators.rawValue)
    }
    
    public var userRequestedLoopReset: Bool {
        get {
            bool(forKey: Key.userRequestedLoopReset.rawValue)
        }
        set {
            setValue(newValue, forKey: Key.userRequestedLoopReset.rawValue)
        }
    }
    
    public var liveActivity: LiveActivitySettings? {
        get {
            let decoder = JSONDecoder()
            guard let data = object(forKey: Key.liveActivity.rawValue) as? Data else {
                return nil
            }
            return try? decoder.decode(LiveActivitySettings.self, from: data)
        }
        set {
            do {
                if let newValue = newValue {
                    let encoder = JSONEncoder()
                    let data = try encoder.encode(newValue)
                    set(data, forKey: Key.liveActivity.rawValue)
                } else {
                    set(nil, forKey: Key.liveActivity.rawValue)
                }
            } catch {
                assertionFailure("Unable to encode MissedMealNotification")
            }
        }
    }

    public func removeLegacyLoopSettings() {
        removeObject(forKey: "com.loudnate.Naterade.BasalRateSchedule")
        removeObject(forKey: "com.loudnate.Naterade.CarbRatioSchedule")
        removeObject(forKey: "com.loudnate.Naterade.InsulinSensitivitySchedule")
        removeObject(forKey: "com.loopkit.Loop.defaultRapidActingModel")
        removeObject(forKey: "com.loopkit.Loop.loopSettings")
    }
}


// MARK: - Settings not carried by StoredSettings
//
// `StoredSettings` lives in LoopKit and cannot be extended here, so these fork-specific settings are
// persisted in the app group instead. They are read back in `SettingsManager.loopSettings`.
extension UserDefaults {
    public var customLoopIntervalEnabled: Bool {
        get {
            bool(forKey: Key.customLoopIntervalEnabled.rawValue)
        }
        set {
            set(newValue, forKey: Key.customLoopIntervalEnabled.rawValue)
        }
    }

    public var customLoopInterval: TimeInterval {
        get {
            guard let interval = object(forKey: Key.customLoopInterval.rawValue) as? TimeInterval else {
                return LoopSettings.defaultCustomLoopInterval
            }
            return LoopSettings.clampedCustomLoopInterval(interval)
        }
        set {
            set(LoopSettings.clampedCustomLoopInterval(newValue), forKey: Key.customLoopInterval.rawValue)
        }
    }

    public var suppressPodCommunicationInBackground: Bool {
        get {
            bool(forKey: Key.suppressPodCommunicationInBackground.rawValue)
        }
        set {
            set(newValue, forKey: Key.suppressPodCommunicationInBackground.rawValue)
        }
    }

    /// Mirrors `LoopSettings.effectiveLoopInterval` for callers that have no access to `LoopSettings`.
    public var effectiveLoopInterval: TimeInterval {
        guard customLoopIntervalEnabled else {
            return LoopCompletionFreshness.defaultLoopInterval
        }
        return customLoopInterval
    }

    public var glucoseUrgentLow: Double {
        get { glucoseThreshold(.glucoseUrgentLow, legacyKey: "com.loopkit.Loop.glucoseDisplayUrgentLow", default: LoopSettings.defaultGlucoseUrgentLow) }
        set { set(newValue, forKey: Key.glucoseUrgentLow.rawValue) }
    }

    public var glucoseLow: Double {
        get { glucoseThreshold(.glucoseLow, legacyKey: "com.loopkit.Loop.glucoseDisplayLow", default: LoopSettings.defaultGlucoseLow) }
        set { set(newValue, forKey: Key.glucoseLow.rawValue) }
    }

    public var glucoseHigh: Double {
        get { glucoseThreshold(.glucoseHigh, legacyKey: "com.loopkit.Loop.glucoseDisplayHigh", default: LoopSettings.defaultGlucoseHigh) }
        set { set(newValue, forKey: Key.glucoseHigh.rawValue) }
    }

    public var glucoseUrgentHigh: Double {
        get { glucoseThreshold(.glucoseUrgentHigh, legacyKey: "com.loopkit.Loop.glucoseDisplayUrgentHigh", default: LoopSettings.defaultGlucoseUrgentHigh) }
        set { set(newValue, forKey: Key.glucoseUrgentHigh.rawValue) }
    }

    private func glucoseThreshold(_ key: Key, legacyKey: String, default defaultValue: Double) -> Double {
        return (object(forKey: key.rawValue) as? Double)
            ?? (object(forKey: legacyKey) as? Double)
            ?? defaultValue
    }
}
