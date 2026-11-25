//
//  DynamicISFScenarioTests.swift
//  LoopTests
//

import XCTest
import HealthKit
import LoopKit
@testable import LoopCore
@testable import Loop

/// LoopDataManager with Dynamic ISF on the canned scenarios. The dose history is scheduled basal (net zero insulin),
/// so predictions are the same with and without Dynamic ISF and only the dosing insulin sensitivity differs.
final class DynamicISFScenarioTests: LoopDataManagerTests {
    private struct Setup {
        var scenario: DosingTestScenario
        var dynamicISF = true
        /// Weighted and average TDD in pump units; nil computes it from the dose history.
        var totalDailyDose: Double? = 40
        /// mg/dL per pump unit, all day.
        var sensitivity = 50.0
        /// Including an override, e.g. half of `sensitivity` for insulin needs 200 %.
        var overrideSensitivity: Double? = nil
        /// g per pump unit, all day.
        var carbRatio = 10.0
        /// Pump units per hour, all day; the dose history delivers it.
        var basalRate = 1.0
        var doseHistoryDuration = DynamicISFContext.doseHistoryDuration
        /// Pump units given `age` before the scenario's current date.
        var boluses: [(age: TimeInterval, units: Double)] = []
        /// Potential carb entries get an effect, using the insulin sensitivity at their start like CarbStore.
        var entrySensitivityCarbs = false
    }

    private let totalDailyDose40: (Date) -> DynamicISFTotalDailyDose? = { _ in
        DynamicISFTotalDailyDose(lastDay: 40, weighted: 40, average: 40)
    }

    private func makeManager(_ setup: Setup) -> LoopDataManager {
        let glucoseStore = MockGlucoseStore(for: setup.scenario)
        let currentDate = glucoseStore.latestGlucose!.startDate

        let sensitivitySchedule = { (value: Double) in
            InsulinSensitivitySchedule(unit: .milligramsPerDeciliter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: value)], timeZone: .utcTimeZone)!
        }
        let sensitivity = sensitivitySchedule(setup.sensitivity)
        let sensitivityApplyingOverride = setup.overrideSensitivity.map(sensitivitySchedule) ?? sensitivity
        let basalRateSchedule = BasalRateSchedule(dailyItems: [RepeatingScheduleValue(startTime: 0, value: setup.basalRate)], timeZone: .utcTimeZone)!
        let carbRatioSchedule = CarbRatioSchedule(unit: .gram(), dailyItems: [RepeatingScheduleValue(startTime: 0, value: setup.carbRatio)], timeZone: .utcTimeZone)!

        let settings = LoopSettings(
            dosingEnabled: false,
            glucoseTargetRangeSchedule: glucoseTargetRangeSchedule,
            insulinSensitivitySchedule: sensitivity,
            basalRateSchedule: basalRateSchedule,
            carbRatioSchedule: carbRatioSchedule,
            maximumBasalRatePerHour: 10,
            maximumBolus: 10,
            suspendThreshold: suspendThreshold,
            automaticDosingStrategy: .tempBasalOnly
        )

        let historyStart = currentDate.addingTimeInterval(-setup.doseHistoryDuration)
        let basalDoses = (0..<Int(setup.doseHistoryDuration.hours)).map { hour -> DoseEntry in
            let start = historyStart.addingTimeInterval(.hours(Double(hour)))
            return DoseEntry(type: .basal, startDate: start, endDate: start.addingTimeInterval(.hours(1)), value: setup.basalRate, unit: .unitsPerHour)
        }
        let bolusDoses = setup.boluses.map { bolus -> DoseEntry in
            let date = currentDate.addingTimeInterval(-bolus.age)
            return DoseEntry(type: .bolus, startDate: date, endDate: date, value: bolus.units, unit: .units)
        }

        let doseStore = MockDoseStore(for: setup.scenario)
        doseStore.basalProfile = basalRateSchedule
        doseStore.basalProfileApplyingOverrideHistory = basalRateSchedule
        doseStore.sensitivitySchedule = sensitivityApplyingOverride
        doseStore.doseHistory = (basalDoses + bolusDoses).sorted { $0.startDate < $1.startDate }

        let carbStore: MockCarbStore = setup.entrySensitivityCarbs ? EntrySensitivityCarbStore(for: setup.scenario) : MockCarbStore(for: setup.scenario)
        carbStore.insulinSensitivitySchedule = sensitivity
        carbStore.insulinSensitivityScheduleApplyingOverrideHistory = sensitivityApplyingOverride
        carbStore.carbRatioSchedule = carbRatioSchedule
        carbStore.carbRatioScheduleApplyingOverrideHistory = carbRatioSchedule

        var dynamicISFSettings = DynamicISFSettings()
        dynamicISFSettings.isEnabled = setup.dynamicISF
        var totalDailyDose: ((Date) -> DynamicISFTotalDailyDose?)?
        if let tdd = setup.totalDailyDose {
            totalDailyDose = { _ in DynamicISFTotalDailyDose(lastDay: tdd, weighted: tdd, average: tdd) }
        }

        return LoopDataManager(
            lastLoopCompleted: currentDate,
            basalDeliveryState: .active(currentDate),
            settings: settings,
            overrideHistory: TemporaryScheduleOverrideHistory(),
            analyticsServicesManager: AnalyticsServicesManager(),
            localCacheDuration: .days(1),
            doseStore: doseStore,
            glucoseStore: glucoseStore,
            carbStore: carbStore,
            dosingDecisionStore: MockDosingDecisionStore(),
            latestStoredSettingsProvider: MockLatestStoredSettingsProvider(),
            now: { currentDate },
            pumpInsulinType: .novolog,
            automaticDosingStatus: AutomaticDosingStatus(automaticDosingEnabled: true, isAutomaticDosingAllowed: true),
            trustedTimeOffset: { 0 },
            dynamicISFSettings: { dynamicISFSettings },
            dynamicISFDailyTotals: DynamicISFDailyTotalsStore(defaults: nil),
            dynamicISFTotalDailyDose: totalDailyDose
        )
    }

    private func withLoopState<T>(_ manager: LoopDataManager, _ body: @escaping (LoopState) -> T) -> T {
        var result: T?
        let done = expectation(description: "loop state")
        manager.getLoopState { _, state in
            result = body(state)
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        return result!
    }

    private func recommendedBolus(_ state: LoopState, carbs: Double? = nil, at date: Date) -> Double {
        let entry = carbs.map { NewCarbEntry(quantity: HKQuantity(unit: .gram(), doubleValue: $0), startDate: date, foodType: nil, absorptionTime: .hours(3)) }
        return (try? state.recommendBolus(consideringPotentialCarbEntry: entry, replacingCarbEntry: nil, considerPositiveVelocityAndRC: true))?.amount ?? 0
    }

    /// Manual bolus in pump units.
    private func bolus(_ setup: Setup, carbs: Double? = nil) -> Double {
        let manager = makeManager(setup)
        return withLoopState(manager) { self.recommendedBolus($0, carbs: carbs, at: setup.scenario.currentDate) }
    }

    private func tempBasalRate(_ setup: Setup) -> Double? {
        let manager = makeManager(setup)
        return withLoopState(manager) { $0.recommendedAutomaticDose?.recommendation.basalAdjustment?.unitsPerHour }
    }

    /// Glucose at the end of the prediction from insulin alone, mg/dL.
    private func eventualGlucoseFromInsulin(_ setup: Setup) -> Double {
        let manager = makeManager(setup)
        return withLoopState(manager) { state in
            (try? state.predictGlucose(using: .insulin))?.last?.quantity.doubleValue(for: .milligramsPerDeciliter) ?? .nan
        }
    }

    // MARK: Off

    func testOffKeepsFixtureRecommendations() {
        setUp(for: .highAndStable, dynamicISFTotalDailyDose: totalDailyDose40)

        let (tempBasal, manualBolus) = withLoopState(loopDataManager) { state in
            (state.recommendedAutomaticDose?.recommendation.basalAdjustment?.unitsPerHour, self.recommendedBolus(state, at: self.now))
        }

        // Same as LoopDataManagerDosingTests.testHighAndStable and testLoopGetStateRecommendsManualBolus.
        XCTAssertEqual(tempBasal ?? 0, 4.63, accuracy: defaultAccuracy)
        XCTAssertEqual(manualBolus, 1.82, accuracy: 0.01)
    }

    func testOnWithoutDoseHistoryKeepsFixtureRecommendations() {
        var settings = DynamicISFSettings()
        settings.isEnabled = true
        setUp(for: .highAndStable, dynamicISFSettings: settings, dynamicISFTotalDailyDose: totalDailyDose40)

        let (tempBasal, manualBolus) = withLoopState(loopDataManager) { state in
            (state.recommendedAutomaticDose?.recommendation.basalAdjustment?.unitsPerHour, self.recommendedBolus(state, at: self.now))
        }

        XCTAssertEqual(tempBasal ?? 0, 4.63, accuracy: defaultAccuracy)
        XCTAssertEqual(manualBolus, 1.82, accuracy: 0.01)
    }

    // MARK: Corrections

    func testHighGlucoseCorrectsMoreUpToMaximumRatio() {
        // BG 200: 50 × 0.8 × 40 × ln(200 / 55 + 1) / 1800 = 1.36, limited to 1.2.
        let dynamic = Setup(scenario: .highAndStable)
        var profile = dynamic
        profile.dynamicISF = false
        var doubleTDD = dynamic
        doubleTDD.totalDailyDose = 80

        let profileBolus = bolus(profile)
        let dynamicBolus = bolus(dynamic)

        XCTAssertGreaterThan(profileBolus, 0.5)
        XCTAssertEqual(dynamicBolus, 1.2 * profileBolus, accuracy: 0.01)
        XCTAssertEqual(bolus(doubleTDD), dynamicBolus, accuracy: 1e-9)
    }

    func testBelowTargetNeverDosesMoreThanProfile() {
        // BG 75, target 95: TDD 20 gives ratio 0.38, the hypo guard raises it to 1; TDD 60 gives 1.15.
        for tdd in [20.0, 60.0] {
            var dynamic = Setup(scenario: .lowAndFallingWithCOB)
            dynamic.totalDailyDose = tdd
            var profile = dynamic
            profile.dynamicISF = false

            XCTAssertLessThanOrEqual(bolus(dynamic), bolus(profile) + 1e-9, "TDD \(tdd)")
            XCTAssertLessThanOrEqual(tempBasalRate(dynamic) ?? 1, (tempBasalRate(profile) ?? 1) + 1e-9, "TDD \(tdd)")
        }

        var guarded = Setup(scenario: .lowAndFallingWithCOB)
        guarded.totalDailyDose = 20
        var profile = guarded
        profile.dynamicISF = false
        XCTAssertEqual(tempBasalRate(guarded), tempBasalRate(profile))
        XCTAssertEqual(bolus(guarded), bolus(profile))
    }

    // MARK: Meals

    func testMealBolusCoversCarbsLikeProfile() {
        // BG 123, target 95: 50 × 0.8 × 40 × ln(123.4 / 55 + 1) / 1800 = 1.05. The carb effect uses the same dynamic ISF,
        // so the meal part stays carbs / CR; with the profile's ISF in the carb effect it would be 5 % larger.
        var dynamic = Setup(scenario: .flatAndStable)
        dynamic.entrySensitivityCarbs = true
        var profile = dynamic
        profile.dynamicISF = false

        let dynamicMeal = bolus(dynamic, carbs: 50) - bolus(dynamic)
        let profileMeal = bolus(profile, carbs: 50) - bolus(profile)

        XCTAssertGreaterThan(profileMeal, 1)
        XCTAssertEqual(dynamicMeal, profileMeal, accuracy: 0.1)
    }

    // MARK: Overrides

    func testOverrideScalesDynamicSensitivity() {
        // Insulin needs 200 %: the ratio still comes from the scheduled 50 (1.36, limited to 1.2) and divides the override's 25.
        let dynamic = Setup(scenario: .highAndStable)
        var override = dynamic
        override.overrideSensitivity = 25
        var profileOverride = override
        profileOverride.dynamicISF = false

        let overrideBolus = bolus(override)

        XCTAssertEqual(overrideBolus, 2 * bolus(dynamic), accuracy: 0.01)
        XCTAssertEqual(overrideBolus, 1.2 * bolus(profileOverride), accuracy: 0.01)
    }

    // MARK: Missing inputs

    func testDoseWithoutRecentGlucoseUsesProfileSensitivity() {
        // The scenario's only glucose value is at its current date: a dose 30 minutes earlier has no glucose ≤ 15 minutes old.
        var earlier = Setup(scenario: .highAndStable)
        earlier.boluses = [(age: .minutes(30), units: 2)]
        var earlierProfile = earlier
        earlierProfile.dynamicISF = false

        XCTAssertEqual(eventualGlucoseFromInsulin(earlier), eventualGlucoseFromInsulin(earlierProfile), accuracy: 1e-6)

        // A dose now uses BG 200 (ratio 1.2): 2 U lower glucose by 2 × 50 / 1.2 instead of 2 × 50 mg/dL.
        var current = Setup(scenario: .highAndStable)
        current.boluses = [(age: 0, units: 2)]
        var currentProfile = current
        currentProfile.dynamicISF = false

        XCTAssertEqual(eventualGlucoseFromInsulin(current) - eventualGlucoseFromInsulin(currentProfile), 100 - 100 / 1.2, accuracy: 1)
    }

    func testMissingTotalDailyDoseUsesProfileSensitivity() {
        // Six hours of doses: no TDD of the last 24 hours.
        var short = Setup(scenario: .highAndStable)
        short.totalDailyDose = nil
        short.doseHistoryDuration = .hours(6)
        var shortProfile = short
        shortProfile.dynamicISF = false

        XCTAssertEqual(bolus(short), bolus(shortProfile), accuracy: 1e-9)

        // The full history delivers 24 U per day: 50 × 0.8 × 24 × ln(200 / 55 + 1) / 1800 = 0.818.
        var full = Setup(scenario: .highAndStable)
        full.totalDailyDose = nil
        var fullProfile = full
        fullProfile.dynamicISF = false

        XCTAssertEqual(bolus(full), 0.818 * bolus(fullProfile), accuracy: 0.01)
    }

    // MARK: Insulin concentration

    func testU200GivesSameInternationalUnitsAsU100() {
        // U200 profile: ISF and CR per pump unit doubled, basal and therefore the TDD in pump units halved.
        var u100 = Setup(scenario: .highAndStable)
        u100.totalDailyDose = nil
        var u200 = u100
        u200.sensitivity = 100
        u200.carbRatio = 20
        u200.basalRate = 0.5

        XCTAssertEqual(2 * bolus(u200), bolus(u100), accuracy: 1e-6)
    }
}

/// Carb effects of potential entries like CarbStore, with the insulin sensitivity at the entry's start.
private final class EntrySensitivityCarbStore: MockCarbStore {
    override func glucoseEffects<Sample>(of samples: [Sample], startingAt start: Date, endingAt end: Date?, effectVelocities: [LoopKit.GlucoseEffectVelocity]) throws -> [LoopKit.GlucoseEffect] where Sample : LoopKit.CarbEntry {
        guard let carbRatioSchedule = carbRatioScheduleApplyingOverrideHistory,
              let sensitivitySchedule = insulinSensitivityScheduleApplyingOverrideHistory,
              let first = samples.map({ $0.startDate }).min(),
              let last = samples.map({ $0.startDate }).max() else {
            return []
        }
        let sensitivity = insulinSensitivityAtEntryStart?(first) ?? sensitivitySchedule.quantity(at: first)
        let insulinSensitivity = [AbsoluteScheduleValue(startDate: first, endDate: last, value: sensitivity)]
        let carbRatio = carbRatioSchedule.between(start: first, end: last)
        return samples.map(
            to: effectVelocities,
            carbRatio: carbRatio,
            insulinSensitivity: insulinSensitivity
        ).dynamicGlucoseEffects(
            from: start,
            to: end,
            carbRatios: carbRatio,
            insulinSensitivities: insulinSensitivity
        )
    }
}
