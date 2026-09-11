//
//  LoopSettingsTests.swift
//  LoopTests
//
//  Created by Michael Pangburn on 3/1/20.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import XCTest
import HealthKit
import LoopCore
import LoopKit


class LoopSettingsTests: XCTestCase {
    private let preMealRange = DoubleRange(minValue: 80, maxValue: 80).quantityRange(for: .milligramsPerDeciliter)
    private let targetRange = DoubleRange(minValue: 95, maxValue: 105)
    
    private lazy var settings: LoopSettings = {
        var settings = LoopSettings()
        settings.preMealTargetRange = preMealRange
        settings.glucoseTargetRangeSchedule = GlucoseRangeSchedule(
            unit: .milligramsPerDeciliter,
            dailyItems: [.init(startTime: 0, value: targetRange)]
        )
        return settings
    }()
    
    func testPreMealOverride() {
        var settings = self.settings
        let preMealStart = Date()
        settings.enablePreMealOverride(at: preMealStart, for: 1 /* hour */ * 60 * 60)
        let actualPreMealRange = settings.effectiveGlucoseTargetRangeSchedule()?.quantityRange(at: preMealStart.addingTimeInterval(30 /* minutes */ * 60))
        XCTAssertEqual(preMealRange, actualPreMealRange)
    }
    
    func testPreMealOverrideWithPotentialCarbEntry() {
        var settings = self.settings
        let preMealStart = Date()
        settings.enablePreMealOverride(at: preMealStart, for: 1 /* hour */ * 60 * 60)
        let actualRange = settings.effectiveGlucoseTargetRangeSchedule(presumingMealEntry: true)?.value(at: preMealStart.addingTimeInterval(30 /* minutes */ * 60))
        XCTAssertEqual(targetRange, actualRange)
    }

    func testScheduleOverride() {
        var settings = self.settings
        let overrideStart = Date()
        let overrideTargetRange = DoubleRange(minValue: 130, maxValue: 150)
        let override = TemporaryScheduleOverride(
            context: .custom,
            settings: TemporaryScheduleOverrideSettings(
                unit: .milligramsPerDeciliter,
                targetRange: overrideTargetRange
            ),
            startDate: overrideStart,
            duration: .finite(3 /* hours */ * 60 * 60),
            enactTrigger: .local,
            syncIdentifier: UUID()
        )
        settings.scheduleOverride = override
        let actualOverrideRange = settings.effectiveGlucoseTargetRangeSchedule()?.value(at: overrideStart.addingTimeInterval(30 /* minutes */ * 60))
        XCTAssertEqual(actualOverrideRange, overrideTargetRange)
    }

    func testBothPreMealAndScheduleOverride() {
        var settings = self.settings
        let preMealStart = Date()
        settings.enablePreMealOverride(at: preMealStart, for: 1 /* hour */ * 60 * 60)

        let overrideStart = Date()
        let overrideTargetRange = DoubleRange(minValue: 130, maxValue: 150)
        let override = TemporaryScheduleOverride(
            context: .custom,
            settings: TemporaryScheduleOverrideSettings(
                unit: .milligramsPerDeciliter,
                targetRange: overrideTargetRange
            ),
            startDate: overrideStart,
            duration: .finite(3 /* hours */ * 60 * 60),
            enactTrigger: .local,
            syncIdentifier: UUID()
        )
        settings.scheduleOverride = override

        let actualPreMealRange = settings.effectiveGlucoseTargetRangeSchedule()?.quantityRange(at: preMealStart.addingTimeInterval(30 /* minutes */ * 60))
        XCTAssertEqual(actualPreMealRange, preMealRange)

        // The pre-meal range should be projected into the future, despite the simultaneous schedule override
        let preMealRangeDuringOverride = settings.effectiveGlucoseTargetRangeSchedule()?.quantityRange(at: preMealStart.addingTimeInterval(2 /* hours */ * 60 * 60))
        XCTAssertEqual(preMealRangeDuringOverride, preMealRange)
    }

    func testScheduleOverrideWithExpiredPreMealOverride() {
        var settings = self.settings
        settings.preMealOverride = TemporaryScheduleOverride(
            context: .preMeal,
            settings: TemporaryScheduleOverrideSettings(targetRange: preMealRange),
            startDate: Date(timeIntervalSinceNow: -2 /* hours */ * 60 * 60),
            duration: .finite(1 /* hours */ * 60 * 60),
            enactTrigger: .local,
            syncIdentifier: UUID()
        )

        let overrideStart = Date()
        let overrideTargetRange = DoubleRange(minValue: 130, maxValue: 150)
        let override = TemporaryScheduleOverride(
            context: .custom,
            settings: TemporaryScheduleOverrideSettings(
                unit: .milligramsPerDeciliter,
                targetRange: overrideTargetRange
            ),
            startDate: overrideStart,
            duration: .finite(3 /* hours */ * 60 * 60),
            enactTrigger: .local,
            syncIdentifier: UUID()
        )
        settings.scheduleOverride = override

        let actualOverrideRange = settings.effectiveGlucoseTargetRangeSchedule()?.value(at: overrideStart.addingTimeInterval(2 /* hours */ * 60 * 60))
        XCTAssertEqual(actualOverrideRange, overrideTargetRange)
    }

    func testCustomLoopIntervalRawValueRoundTrip() {
        var settings = LoopSettings()
        settings.customLoopIntervalEnabled = true
        settings.customLoopInterval = .minutes(30)

        let restored = LoopSettings(rawValue: settings.rawValue)
        XCTAssertEqual(restored?.customLoopIntervalEnabled, true)
        XCTAssertEqual(restored?.customLoopInterval, .minutes(30))
    }

    func testCustomLoopIntervalDefaults() {
        let settings = LoopSettings()
        XCTAssertFalse(settings.customLoopIntervalEnabled)
        XCTAssertEqual(settings.customLoopInterval, LoopSettings.defaultCustomLoopInterval)
    }

    func testCustomLoopIntervalClampedOnDecode() {
        var raw = LoopSettings().rawValue
        raw["customLoopInterval"] = TimeInterval.minutes(120)
        XCTAssertEqual(LoopSettings(rawValue: raw)?.customLoopInterval, LoopSettings.maximumCustomLoopInterval)

        raw["customLoopInterval"] = TimeInterval.minutes(1)
        XCTAssertEqual(LoopSettings(rawValue: raw)?.customLoopInterval, LoopSettings.minimumCustomLoopInterval)
    }

    func testSuppressPodCommunicationInBackgroundRawValueRoundTrip() {
        var settings = LoopSettings()
        settings.suppressPodCommunicationInBackground = true

        let restored = LoopSettings(rawValue: settings.rawValue)
        XCTAssertEqual(restored?.suppressPodCommunicationInBackground, true)
    }

    func testSuppressPodCommunicationInBackgroundDefaults() {
        let settings = LoopSettings()
        XCTAssertFalse(settings.suppressPodCommunicationInBackground)
    }

    // MARK: - Glucose display range

    private func mgdL(_ value: Double) -> HKQuantity {
        HKQuantity(unit: .milligramsPerDeciliter, doubleValue: value)
    }

    func testGlucoseDisplayRangeDefaults() {
        let settings = LoopSettings()
        XCTAssertEqual(settings.glucoseUrgentLow, 54)
        XCTAssertEqual(settings.glucoseLow, 70)
        XCTAssertEqual(settings.glucoseHigh, 180)
        XCTAssertEqual(settings.glucoseUrgentHigh, 250)
    }

    func testGlucoseDisplayRangeRawValueRoundTrip() {
        var settings = LoopSettings()
        settings.glucoseDisplayRange = GlucoseDisplayRange(urgentLow: 60, low: 80, high: 160, urgentHigh: 300)

        let restored = LoopSettings(rawValue: settings.rawValue)
        XCTAssertEqual(restored?.glucoseDisplayRange, GlucoseDisplayRange(urgentLow: 60, low: 80, high: 160, urgentHigh: 300))
    }

    func testGlucoseDisplayRangeEnforcesOrdering() {
        let range = GlucoseDisplayRange(urgentLow: 100, low: 70, high: 60, urgentHigh: 50)
        XCTAssertEqual(range.urgentLow, 100)
        XCTAssertEqual(range.low, 101)
        XCTAssertEqual(range.high, 102)
        XCTAssertEqual(range.urgentHigh, 103)
    }

    func testGlucoseDisplayTierBoundaries() {
        let settings = LoopSettings()

        XCTAssertEqual(settings.glucoseDisplayTier(for: mgdL(53)), .urgent)
        XCTAssertEqual(settings.glucoseDisplayTier(for: mgdL(54)), .outOfRange)
        XCTAssertEqual(settings.glucoseDisplayTier(for: mgdL(69)), .outOfRange)
        XCTAssertEqual(settings.glucoseDisplayTier(for: mgdL(70)), .inRange)
        XCTAssertEqual(settings.glucoseDisplayTier(for: mgdL(179)), .inRange)
        XCTAssertEqual(settings.glucoseDisplayTier(for: mgdL(180)), .inRange)
        XCTAssertEqual(settings.glucoseDisplayTier(for: mgdL(181)), .outOfRange)
        XCTAssertEqual(settings.glucoseDisplayTier(for: mgdL(250)), .outOfRange)
        XCTAssertEqual(settings.glucoseDisplayTier(for: mgdL(251)), .urgent)
    }

    func testPredictedGlucoseTierUsesCorrectionRange() {
        var settings = LoopSettings()
        settings.glucoseTargetRangeSchedule = GlucoseRangeSchedule(
            unit: .milligramsPerDeciliter,
            dailyItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 120))]
        )

        let date = Date()
        XCTAssertEqual(settings.glucoseDisplayTier(forPredicted: mgdL(110), at: date), .inRange)
        // Comfortably safe, but outside target: Loop does not expect to land in range.
        XCTAssertEqual(settings.glucoseDisplayTier(forPredicted: mgdL(98), at: date), .outOfRange)
        XCTAssertEqual(settings.glucoseDisplayTier(forPredicted: mgdL(53), at: date), .urgent)
        XCTAssertEqual(settings.glucoseDisplayTier(forPredicted: mgdL(260), at: date), .urgent)
    }
}
