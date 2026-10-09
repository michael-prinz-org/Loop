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
            if history.isEmpty {
                history = [InsulinConcentrationChange(start: .distantPast, concentration: previous)]
            }
            guard history.last?.concentration != concentration else { return }
            history.append(InsulinConcentrationChange(start: date, concentration: concentration))
            if let oldestNeeded = history.lastIndex(where: { $0.start <= date.addingTimeInterval(-retention) }) {
                history.removeFirst(oldestNeeded)
            }
        }
        UserDefaults.standard.insulinConcentrationChanges = updated
    }

    /// Starts the history with the concentration in use when nothing has been recorded yet.
    static func startIfNeeded(with concentration: InsulinConcentration) {
        guard changes.value.isEmpty else { return }
        record(concentration, previous: concentration)
    }

    /// Factor converting pump units delivered at `date` into current pump units, e.g. 0.5 for U100 doses while U200 is in use.
    static func pumpUnitScale(at date: Date) -> Double {
        let history = changes.value
        guard let current = history.last?.concentration else { return 1 }
        let then = history.last { $0.start <= date }?.concentration ?? current
        return then.unitsPerPumpUnit / current.unitsPerPumpUnit
    }
}

/// A named set of basal rates, carb ratios and insulin sensitivities the user can switch between.
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
}
