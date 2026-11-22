//
//  UserDefaults+Loop.swift
//  Loop
//
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit


extension UserDefaults {
    private enum Key: String {
        case legacyPumpManagerState = "com.loopkit.Loop.PumpManagerState"
        case legacyCGMManagerState = "com.loopkit.Loop.CGMManagerState"
        case legacyServicesState = "com.loopkit.Loop.ServicesState"
        case loopNotRunningNotifications = "com.loopkit.Loop.loopNotRunningNotifications"
        case inFlightAutomaticDose = "com.loopkit.Loop.inFlightAutomaticDose"
        case favoriteFoods = "com.loopkit.Loop.favoriteFoods"
        case therapyProfiles = "com.loopkit.Loop.therapyProfiles"
        case activeTherapyProfileID = "com.loopkit.Loop.activeTherapyProfileID"
        case insulinConcentrationChanges = "com.loopkit.Loop.insulinConcentrationChanges"
        case insulinEffectMonitorSettings = "com.loopkit.Loop.insulinEffectMonitorSettings"
        case profilesShowingCalculatedValues = "com.loopkit.Loop.profilesShowingCalculatedValues"
    }

    /// Therapy profiles whose detail view shows the calculated profile.
    var profilesShowingCalculatedValues: Set<UUID> {
        get { Set((stringArray(forKey: Key.profilesShowingCalculatedValues.rawValue) ?? []).compactMap(UUID.init(uuidString:))) }
        set { set(newValue.map { $0.uuidString }, forKey: Key.profilesShowingCalculatedValues.rawValue) }
    }

    var legacyPumpManagerRawValue: PumpManager.RawValue? {
        get {
            return dictionary(forKey: Key.legacyPumpManagerState.rawValue)
        }
    }
    func clearLegacyPumpManagerRawValue() {
        set(nil, forKey: Key.legacyPumpManagerState.rawValue)
    }


    var legacyCGMManagerRawValue: CGMManager.RawValue? {
        get {
            return dictionary(forKey: Key.legacyCGMManagerState.rawValue)
        }
    }

    func clearLegacyCGMManagerRawValue() {
        set(nil, forKey: Key.legacyCGMManagerState.rawValue)
    }

    var legacyServicesState: [Service.RawStateValue] {
        get {
            return array(forKey: Key.legacyServicesState.rawValue) as? [[String: Any]] ?? []
        }
    }

    func clearLegacyServicesState() {
        set(nil, forKey: Key.legacyServicesState.rawValue)
    }

    var inFlightAutomaticDose: AutomaticDoseRecommendation? {
        get {
            let decoder = JSONDecoder()
            guard let data = object(forKey: Key.inFlightAutomaticDose.rawValue) as? Data else {
                return nil
            }
            return try? decoder.decode(AutomaticDoseRecommendation.self, from: data)
        }
        set {
            do {
                if let newValue = newValue {
                    let encoder = JSONEncoder()
                    let data = try encoder.encode(newValue)
                    set(data, forKey: Key.inFlightAutomaticDose.rawValue)
                } else {
                    set(nil, forKey: Key.inFlightAutomaticDose.rawValue)
                }
            } catch {
                assertionFailure("Unable to encode AutomaticDoseRecommendation")
            }
        }
    }

    var loopNotRunningNotifications: [StoredLoopNotRunningNotification] {
        get {
            let decoder = JSONDecoder()
            guard let data = object(forKey: Key.loopNotRunningNotifications.rawValue) as? Data else {
                return []
            }
            return (try? decoder.decode([StoredLoopNotRunningNotification].self, from: data)) ?? []
        }
        set {
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(newValue)
                set(data, forKey: Key.loopNotRunningNotifications.rawValue)
            } catch {
                assertionFailure("Unable to encode Loop not running notification")
            }
        }
    }
    
    var favoriteFoods: [StoredFavoriteFood] {
        get {
            let decoder = JSONDecoder()
            guard let data = object(forKey: Key.favoriteFoods.rawValue) as? Data else {
                return []
            }
            return (try? decoder.decode([StoredFavoriteFood].self, from: data)) ?? []
        }
        set {
            do {
                let encoder = JSONEncoder()
                let data = try encoder.encode(newValue)
                set(data, forKey: Key.favoriteFoods.rawValue)
            } catch {
                assertionFailure("Unable to encode stored favorite foods")
            }
        }
    }

    var therapyProfiles: [TherapyProfile] {
        get {
            guard let data = object(forKey: Key.therapyProfiles.rawValue) as? Data else {
                return []
            }
            return (try? JSONDecoder().decode([TherapyProfile].self, from: data)) ?? []
        }
        set {
            do {
                let data = try JSONEncoder().encode(newValue)
                set(data, forKey: Key.therapyProfiles.rawValue)
                TherapyProfile.activeProfileSnapshot.value = nil
            } catch {
                assertionFailure("Unable to encode therapy profiles")
            }
        }
    }

    var activeTherapyProfileID: UUID? {
        get {
            string(forKey: Key.activeTherapyProfileID.rawValue).flatMap(UUID.init(uuidString:))
        }
        set {
            set(newValue?.uuidString, forKey: Key.activeTherapyProfileID.rawValue)
            TherapyProfile.activeProfileSnapshot.value = nil
        }
    }

    var insulinConcentrationChanges: [InsulinConcentrationChange] {
        get {
            guard let data = object(forKey: Key.insulinConcentrationChanges.rawValue) as? Data else {
                return []
            }
            return (try? JSONDecoder().decode([InsulinConcentrationChange].self, from: data)) ?? []
        }
        set {
            do {
                let data = try JSONEncoder().encode(newValue)
                set(data, forKey: Key.insulinConcentrationChanges.rawValue)
            } catch {
                assertionFailure("Unable to encode insulin concentration changes")
            }
        }
    }

    var insulinEffectMonitorSettings: InsulinEffectMonitorSettings {
        get {
            guard let data = object(forKey: Key.insulinEffectMonitorSettings.rawValue) as? Data else {
                return InsulinEffectMonitorSettings()
            }
            return (try? JSONDecoder().decode(InsulinEffectMonitorSettings.self, from: data)) ?? InsulinEffectMonitorSettings()
        }
        set {
            do {
                let data = try JSONEncoder().encode(newValue)
                set(data, forKey: Key.insulinEffectMonitorSettings.rawValue)
            } catch {
                assertionFailure("Unable to encode insulin effect monitor settings")
            }
        }
    }
}

/// Strength of the insulin in the pump. Loop's doses, rates and limits are in pump units of this insulin.
enum InsulinConcentration: Int, Codable {
    case u100 = 100
    case u200 = 200

    /// U100 units per pump unit.
    var unitsPerPumpUnit: Double {
        Double(rawValue) / 100
    }

    var label: String {
        "U\(rawValue)"
    }
}

struct InsulinConcentrationChange: Codable, Equatable {
    let start: Date
    let concentration: InsulinConcentration
}

/// When each insulin concentration came into use, so doses delivered before a change can be expressed in the
/// pump units of the insulin used now. The last entry is the concentration in use.
enum InsulinConcentrationHistory {
    /// Dose history Loop keeps locally (7 days) plus a day of margin.
    private static let retention: TimeInterval = 8 * 24 * 3600
    private static let changes = Locked(UserDefaults.standard.insulinConcentrationChanges)

    static var current: InsulinConcentration {
        changes.value.last?.concentration ?? .u100
    }

    /// Records the concentration in use from `date` on; the first call also records what was in use before.
    static func record(_ concentration: InsulinConcentration, previous: InsulinConcentration, at date: Date = Date()) {
        let updated = changes.mutate { history in
            history = recorded(concentration, previous: previous, at: date, in: history)
        }
        UserDefaults.standard.insulinConcentrationChanges = updated
    }

    /// A backdated `date` (e.g. pod start) replaces changes recorded after it.
    static func recorded(_ concentration: InsulinConcentration, previous: InsulinConcentration, at date: Date, in history: [InsulinConcentrationChange]) -> [InsulinConcentrationChange] {
        var history = history.filter { $0.start < date }
        if history.isEmpty {
            history = [InsulinConcentrationChange(start: .distantPast, concentration: previous)]
        }
        guard history.last?.concentration != concentration else { return history }
        history.append(InsulinConcentrationChange(start: date, concentration: concentration))
        if let oldestNeeded = history.lastIndex(where: { $0.start <= date.addingTimeInterval(-retention) }) {
            history.removeFirst(oldestNeeded)
        }
        return history
    }

    /// Starts the history with the concentration in use when nothing has been recorded yet.
    static func startIfNeeded(with concentration: InsulinConcentration) {
        guard changes.value.isEmpty else { return }
        record(concentration, previous: concentration)
    }

    /// Factor converting pump units delivered at `date` into current pump units, e.g. 0.5 for U100 doses while U200 is in use.
    static func pumpUnitScale(at date: Date) -> Double {
        pumpUnitScale(at: date, in: changes.value)
    }

    static func pumpUnitScale(at date: Date, in history: [InsulinConcentrationChange]) -> Double {
        guard let current = history.last?.concentration else { return 1 }
        let then = history.last { $0.start <= date }?.concentration ?? current
        return then.unitsPerPumpUnit / current.unitsPerPumpUnit
    }

    /// U100 (international) units per pump unit of the insulin in use at `date`.
    static func unitsPerPumpUnit(at date: Date) -> Double {
        unitsPerPumpUnit(at: date, in: changes.value)
    }

    static func unitsPerPumpUnit(at date: Date, in history: [InsulinConcentrationChange]) -> Double {
        (history.last { $0.start <= date } ?? history.last)?.concentration.unitsPerPumpUnit ?? 1
    }

    /// Pump units at `date` for insulin given in international units, e.g. a U100 pen injection.
    static func pumpUnits(fromInternationalUnits units: Double, at date: Date) -> Double {
        units / unitsPerPumpUnit(at: date)
    }
}

/// What the user must confirm before a profile with another insulin concentration is activated. Never blocks a switch.
enum ConcentrationSwitchConfirmation: Equatable {
    case notNeeded
    case normal
    /// The pump doses with the new values right away.
    case strict

    /// `podActive` is nil for pumps without a pod concept.
    static func required(from current: InsulinConcentration, to target: InsulinConcentration, podActive: Bool?) -> ConcentrationSwitchConfirmation {
        guard current != target else { return .notNeeded }
        return podActive == false ? .normal : .strict
    }

    /// Reads Loop's raw pump manager value: false without pump or pod, nil for pumps without a pod concept.
    static func podActive(rawPumpManager: [String: Any]?) -> Bool? {
        guard let rawPumpManager = rawPumpManager else { return false }
        // OmnipodKit's plugin identifier
        guard rawPumpManager["managerIdentifier"] as? String == "Omni" else { return nil }
        return (rawPumpManager["state"] as? [String: Any])?["podState"] != nil
    }

    /// Activation date of the running pod, if the raw pump manager value has one.
    static func podStart(rawPumpManager: [String: Any]?) -> Date? {
        guard podActive(rawPumpManager: rawPumpManager) == true else { return nil }
        let podState = (rawPumpManager?["state"] as? [String: Any])?["podState"] as? [String: Any]
        return podState?["activatedAt"] as? Date
    }
}

/// What Loop knows about the pod, read from the pump manager's raw state.
struct PodStatus: Equatable {
    /// nil for pumps without a pod concept or when the pump state is unknown.
    var isActive: Bool?
    var activatedAt: Date?
    /// OmnipodKit's pod wake-up tracking; nil for other pumps.
    var wakeUpCount: Int?
    var lastWakeUpDate: Date?

    static let unknown = PodStatus(isActive: nil, activatedAt: nil)

    init(isActive: Bool?, activatedAt: Date?, wakeUpCount: Int? = nil, lastWakeUpDate: Date? = nil) {
        self.isActive = isActive
        self.activatedAt = activatedAt
        self.wakeUpCount = wakeUpCount
        self.lastWakeUpDate = lastWakeUpDate
    }

    init(rawPumpManager: [String: Any]?) {
        let state = rawPumpManager?["state"] as? [String: Any]
        self.init(
            isActive: ConcentrationSwitchConfirmation.podActive(rawPumpManager: rawPumpManager),
            activatedAt: ConcentrationSwitchConfirmation.podStart(rawPumpManager: rawPumpManager),
            wakeUpCount: state?["podWakeUpCount"] as? Int,
            lastWakeUpDate: state?["lastPodWakeUpDate"] as? Date
        )
    }
}

/// A named set of basal rates, carb ratios, insulin sensitivities and delivery limits for one insulin concentration.
struct TherapyProfile: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var basalRateSchedule: BasalRateSchedule
    var carbRatioSchedule: CarbRatioSchedule
    var insulinSensitivitySchedule: InsulinSensitivitySchedule
    /// Optional so profiles saved before these fields existed still decode.
    var isStandard: Bool?
    var maximumBasalRatePerHour: Double?
    var maximumBolus: Double?
    /// Insulin the values are meant for; nil means U100.
    var insulinConcentration: InsulinConcentration?
    /// "Use for Corrections": while active, the glucose-dependent factor may change the correction share of doses.
    var usesGlucoseDependentSensitivity: Bool?

    /// Read on every dose calculation; the outer nil means not loaded since the profiles last changed.
    static let activeProfileSnapshot = Locked<TherapyProfile??>(nil)
}
