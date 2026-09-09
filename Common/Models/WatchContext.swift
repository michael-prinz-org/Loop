//
//  WatchContext.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 11/25/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit
import LoopCore


final class WatchContext: RawRepresentable {
    typealias RawValue = [String: Any]

    private let version = 5

    var creationDate = Date()

    var displayGlucoseUnit: HKUnit?

    var glucose: HKQuantity?
    var glucoseCondition: GlucoseCondition?
    var glucoseTrend: GlucoseTrend?
    var glucoseTrendRate: HKQuantity?
    var glucoseDate: Date?
    var glucoseIsDisplayOnly: Bool?
    var glucoseWasUserEntered: Bool?
    var glucoseSyncIdentifier: String?

    var predictedGlucose: WatchPredictedGlucose?
    var eventualGlucose: HKQuantity? {
        return predictedGlucose?.values.last?.quantity
    }

    /// Precomputed on the phone so the watch never evaluates thresholds or the correction range itself.
    var glucoseDisplayTier: GlucoseDisplayTier?
    var eventualGlucoseDisplayTier: GlucoseDisplayTier?

    var loopLastRunDate: Date?
    var loopInterval: TimeInterval?
    var podWakeUpCount: Int?
    var lastPodWakeUpDate: Date?
    var lastNetTempBasalDose: Double?
    var lastNetTempBasalDate: Date?
    var recommendedBolusDose: Double?

    var potentialCarbEntry: NewCarbEntry?

    var cob: Double?
    var iob: Double?
    var reservoir: Double?
    var reservoirPercentage: Double?
    var batteryPercentage: Double?

    var cgmManagerState: CGMManager.RawStateValue?

    var isClosedLoop: Bool?
    
    init() {}

    required init?(rawValue: RawValue) {
        guard rawValue["v"] as? Int == version, let creationDate = rawValue["cd"] as? Date else {
            return nil
        }

        self.creationDate = creationDate
        isClosedLoop = rawValue["cl"] as? Bool

        if let unitString = rawValue["gu"] as? String {
            displayGlucoseUnit = HKUnit(from: unitString)
        }
        let unit = displayGlucoseUnit ?? .milligramsPerDeciliter
        if let glucoseValue = rawValue["gv"] as? Double {
            glucose = HKQuantity(unit: unit, doubleValue: glucoseValue)
        }

        if let rawGlucoseCondition = rawValue["gc"] as? GlucoseCondition.RawValue {
            glucoseCondition = GlucoseCondition(rawValue: rawGlucoseCondition)
        }
        if let rawGlucoseTrend = rawValue["gt"] as? GlucoseTrend.RawValue {
            glucoseTrend = GlucoseTrend(rawValue: rawGlucoseTrend)
        }
        if let glucoseTrendRateValue = rawValue["gtrv"] as? Double {
            glucoseTrendRate = HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: glucoseTrendRateValue)
        }
        glucoseDate = rawValue["gd"] as? Date
        glucoseIsDisplayOnly = rawValue["gdo"] as? Bool
        glucoseWasUserEntered = rawValue["gue"] as? Bool
        glucoseSyncIdentifier = rawValue["gs"] as? String
        iob = rawValue["iob"] as? Double
        reservoir = rawValue["r"] as? Double
        reservoirPercentage = rawValue["rp"] as? Double
        batteryPercentage = rawValue["bp"] as? Double

        loopLastRunDate = rawValue["ld"] as? Date
        loopInterval = rawValue["li"] as? TimeInterval
        podWakeUpCount = rawValue["pwc"] as? Int
        lastPodWakeUpDate = rawValue["pwd"] as? Date
        lastNetTempBasalDose = rawValue["ba"] as? Double
        lastNetTempBasalDate = rawValue["bad"] as? Date
        recommendedBolusDose = rawValue["rbo"] as? Double
        if let rawPotentialCarbEntry = rawValue["pce"] as? NewCarbEntry.RawValue {
            potentialCarbEntry = NewCarbEntry(rawValue: rawPotentialCarbEntry)
        }
        cob = rawValue["cob"] as? Double

        cgmManagerState = rawValue["cgmManagerState"] as? CGMManager.RawStateValue

        if let rawValue = rawValue["pg"] as? WatchPredictedGlucose.RawValue {
            predictedGlucose = WatchPredictedGlucose(rawValue: rawValue)
        }

        if let rawTier = rawValue["gdt"] as? GlucoseDisplayTier.RawValue {
            glucoseDisplayTier = GlucoseDisplayTier(rawValue: rawTier)
        }
        if let rawTier = rawValue["egdt"] as? GlucoseDisplayTier.RawValue {
            eventualGlucoseDisplayTier = GlucoseDisplayTier(rawValue: rawTier)
        }
    }

    var rawValue: RawValue {
        var raw: [String: Any] = [
            "v": version,
            "cd": creationDate
        ]

        raw["ba"] = lastNetTempBasalDose
        raw["bad"] = lastNetTempBasalDate
        raw["bp"] = batteryPercentage
        raw["cl"] = isClosedLoop

        raw["cgmManagerState"] = cgmManagerState

        raw["cob"] = cob

        let unit = displayGlucoseUnit ?? .milligramsPerDeciliter
        raw["gu"] = displayGlucoseUnit?.unitString
        raw["gv"] = glucose?.doubleValue(for: unit)

        raw["gc"] = glucoseCondition?.rawValue
        raw["gt"] = glucoseTrend?.rawValue
        if let glucoseTrendRate = glucoseTrendRate {
            let unitPerMinute = unit.unitDivided(by: .minute())
            raw["gtru"] = unitPerMinute.unitString
            raw["gtrv"] = glucoseTrendRate.doubleValue(for: unitPerMinute)
        }
        raw["gd"] = glucoseDate
        raw["gdo"] = glucoseIsDisplayOnly
        raw["gue"] = glucoseWasUserEntered
        raw["gs"] = glucoseSyncIdentifier
        raw["gdt"] = glucoseDisplayTier?.rawValue
        raw["egdt"] = eventualGlucoseDisplayTier?.rawValue
        raw["iob"] = iob
        raw["ld"] = loopLastRunDate
        raw["li"] = loopInterval
        raw["pwc"] = podWakeUpCount
        raw["pwd"] = lastPodWakeUpDate
        raw["r"] = reservoir
        raw["rbo"] = recommendedBolusDose
        raw["pce"] = potentialCarbEntry?.rawValue
        raw["rp"] = reservoirPercentage
        raw["pg"] = predictedGlucose?.rawValue

        return raw
    }
}


extension WatchContext {
    func shouldReplace(_ other: WatchContext) -> Bool {
        if let date = self.glucoseDate, let otherDate = other.glucoseDate {
            return date >= otherDate
        } else {
            return true
        }
    }
}

extension WatchContext {
    var newGlucoseSample: NewGlucoseSample? {
        if let quantity = glucose, let date = glucoseDate, let syncIdentifier = glucoseSyncIdentifier {
            return NewGlucoseSample(date: date,
                                    quantity: quantity,
                                    condition: glucoseCondition,
                                    trend: glucoseTrend,
                                    trendRate: glucoseTrendRate,
                                    isDisplayOnly: glucoseIsDisplayOnly ?? false,
                                    wasUserEntered: glucoseWasUserEntered ?? false,
                                    syncIdentifier: syncIdentifier, syncVersion: 0)
        }
        return nil
    }
}
