//
//  LoopDataManagerDosingTests.swift
//  LoopTests
//
//  Created by Anna Quinlan on 10/19/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import XCTest
import HealthKit
import LoopKit
@testable import LoopCore
@testable import Loop

class MockDelegate: LoopDataManagerDelegate {
    let pumpManager = MockPumpManager()
    
    var bolusUnits: Double?
    func loopDataManager(_ manager: Loop.LoopDataManager, estimateBolusDuration units: Double) -> TimeInterval? {
        self.bolusUnits = units
        return pumpManager.estimatedDuration(toBolus: units)
    }
    
    var recommendation: AutomaticDoseRecommendation?
    var error: LoopError?
    func loopDataManager(_ manager: LoopDataManager, didRecommend automaticDose: (recommendation: AutomaticDoseRecommendation, date: Date), completion: @escaping (LoopError?) -> Void) {
        self.recommendation = automaticDose.recommendation
        completion(error)
    }
    func roundBasalRate(unitsPerHour: Double) -> Double { Double(Int(unitsPerHour / 0.05)) * 0.05 }
    func roundBolusVolume(units: Double) -> Double { Double(Int(units / 0.05)) * 0.05 }
    var pumpManagerStatus: PumpManagerStatus?
    var cgmManagerStatus: CGMManagerStatus?
    var pumpStatusHighlight: DeviceStatusHighlight?
}

class LoopDataManagerDosingTests: LoopDataManagerTests {
    // MARK: Functions to load fixtures
    func loadLocalDateGlucoseEffect(_ name: String) -> [GlucoseEffect] {
        let fixture: [JSONDictionary] = loadFixture(name)
        let localDateFormatter = ISO8601DateFormatter.localTimeDate()

        return fixture.map {
            return GlucoseEffect(startDate: localDateFormatter.date(from: $0["date"] as! String)!, quantity: HKQuantity(unit: HKUnit(from: $0["unit"] as! String), doubleValue:$0["amount"] as! Double))
        }
    }

    func loadPredictedGlucoseFixture(_ name: String) -> [PredictedGlucoseValue] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let url = bundle.url(forResource: name, withExtension: "json")!
        return try! decoder.decode([PredictedGlucoseValue].self, from: try! Data(contentsOf: url))
    }

    // MARK: Tests
    func testForecastFromLiveCaptureInputData() {

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let url = bundle.url(forResource: "live_capture_input", withExtension: "json")!
        let predictionInput = try! decoder.decode(LoopPredictionInput.self, from: try! Data(contentsOf: url))

        // Therapy settings in the "live capture" input only have one value, so we can fake some schedules
        // from the first entry of each therapy setting's history.
        let basalRateSchedule = BasalRateSchedule(dailyItems: [
            RepeatingScheduleValue(startTime: 0, value: predictionInput.settings.basal.first!.value)
        ])
        let insulinSensitivitySchedule = InsulinSensitivitySchedule(
            unit: .milligramsPerDeciliter,
            dailyItems: [
                RepeatingScheduleValue(startTime: 0, value: predictionInput.settings.sensitivity.first!.value.doubleValue(for: .milligramsPerDeciliter))
            ],
            timeZone: .utcTimeZone
        )!
        let carbRatioSchedule = CarbRatioSchedule(
            unit: .gram(),
            dailyItems: [
                RepeatingScheduleValue(startTime: 0.0, value: predictionInput.settings.carbRatio.first!.value)
            ],
            timeZone: .utcTimeZone
        )!

        let settings = LoopSettings(
            dosingEnabled: false,
            glucoseTargetRangeSchedule: glucoseTargetRangeSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule,
            basalRateSchedule: basalRateSchedule,
            carbRatioSchedule: carbRatioSchedule,
            maximumBasalRatePerHour: 10,
            maximumBolus: 5,
            suspendThreshold: predictionInput.settings.suspendThreshold,
            automaticDosingStrategy: .automaticBolus
        )

        let glucoseStore = MockGlucoseStore()
        glucoseStore.storedGlucose = predictionInput.glucoseHistory

        let currentDate = glucoseStore.latestGlucose!.startDate
        now = currentDate

        let doseStore = MockDoseStore()
        doseStore.basalProfile = basalRateSchedule
        doseStore.basalProfileApplyingOverrideHistory = doseStore.basalProfile
        doseStore.sensitivitySchedule = insulinSensitivitySchedule
        doseStore.doseHistory = predictionInput.doses
        doseStore.lastAddedPumpData = predictionInput.doses.last!.startDate
        let carbStore = MockCarbStore()
        carbStore.insulinSensitivityScheduleApplyingOverrideHistory = insulinSensitivitySchedule
        carbStore.carbRatioSchedule = carbRatioSchedule
        carbStore.carbRatioScheduleApplyingOverrideHistory = carbRatioSchedule
        carbStore.carbHistory = predictionInput.carbEntries


        dosingDecisionStore = MockDosingDecisionStore()
        automaticDosingStatus = AutomaticDosingStatus(automaticDosingEnabled: true, isAutomaticDosingAllowed: true)
        loopDataManager = LoopDataManager(
            lastLoopCompleted: currentDate,
            basalDeliveryState: .active(currentDate),
            settings: settings,
            overrideHistory: TemporaryScheduleOverrideHistory(),
            analyticsServicesManager: AnalyticsServicesManager(),
            localCacheDuration: .days(1),
            doseStore: doseStore,
            glucoseStore: glucoseStore,
            carbStore: carbStore,
            dosingDecisionStore: dosingDecisionStore,
            latestStoredSettingsProvider: MockLatestStoredSettingsProvider(),
            now: { currentDate },
            pumpInsulinType: .novolog,
            automaticDosingStatus: automaticDosingStatus,
            trustedTimeOffset: { 0 }
        )

        let expectedPredictedGlucose = loadPredictedGlucoseFixture("live_capture_predicted_glucose")

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var predictedGlucose: [PredictedGlucoseValue]?
        var recommendedBasal: TempBasalRecommendation?
        self.loopDataManager.getLoopState { _, state in
            predictedGlucose = state.predictedGlucoseIncludingPendingInsulin
            recommendedBasal = state.recommendedAutomaticDose?.recommendation.basalAdjustment
            updateGroup.leave()
        }
        // We need to wait until the task completes to get outputs
        updateGroup.wait()

        XCTAssertNotNil(predictedGlucose)

        XCTAssertEqual(expectedPredictedGlucose.count, predictedGlucose!.count)

        for (expected, calculated) in zip(expectedPredictedGlucose, predictedGlucose!) {
            XCTAssertEqual(expected.startDate, calculated.startDate)
            XCTAssertEqual(expected.quantity.doubleValue(for: .milligramsPerDeciliter), calculated.quantity.doubleValue(for: .milligramsPerDeciliter), accuracy: defaultAccuracy)
        }
    }


    func testFlatAndStable() {
        setUp(for: .flatAndStable)
        let predictedGlucoseOutput = loadLocalDateGlucoseEffect("flat_and_stable_predicted_glucose")

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var predictedGlucose: [PredictedGlucoseValue]?
        var recommendedDose: AutomaticDoseRecommendation?
        self.loopDataManager.getLoopState { _, state in
            predictedGlucose = state.predictedGlucose
            recommendedDose = state.recommendedAutomaticDose?.recommendation
            updateGroup.leave()
        }
        // We need to wait until the task completes to get outputs
        updateGroup.wait()

        XCTAssertNotNil(predictedGlucose)
        XCTAssertEqual(predictedGlucoseOutput.count, predictedGlucose!.count)
        
        for (expected, calculated) in zip(predictedGlucoseOutput, predictedGlucose!) {
            XCTAssertEqual(expected.startDate, calculated.startDate)
            XCTAssertEqual(expected.quantity.doubleValue(for: .milligramsPerDeciliter), calculated.quantity.doubleValue(for: .milligramsPerDeciliter), accuracy: defaultAccuracy)
        }
        
        let recommendedTempBasal = recommendedDose?.basalAdjustment

        XCTAssertEqual(1.40, recommendedTempBasal!.unitsPerHour, accuracy: defaultAccuracy)
    }
    
    func testHighAndStable() {
        setUp(for: .highAndStable)
        let predictedGlucoseOutput = loadLocalDateGlucoseEffect("high_and_stable_predicted_glucose")

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var predictedGlucose: [PredictedGlucoseValue]?
        var recommendedBasal: TempBasalRecommendation?
        self.loopDataManager.getLoopState { _, state in
            predictedGlucose = state.predictedGlucose
            recommendedBasal = state.recommendedAutomaticDose?.recommendation.basalAdjustment
            updateGroup.leave()
        }
        // We need to wait until the task completes to get outputs
        updateGroup.wait()

        XCTAssertNotNil(predictedGlucose)
        XCTAssertEqual(predictedGlucoseOutput.count, predictedGlucose!.count)
        
        for (expected, calculated) in zip(predictedGlucoseOutput, predictedGlucose!) {
            XCTAssertEqual(expected.startDate, calculated.startDate)
            XCTAssertEqual(expected.quantity.doubleValue(for: .milligramsPerDeciliter), calculated.quantity.doubleValue(for: .milligramsPerDeciliter), accuracy: defaultAccuracy)
        }

        XCTAssertEqual(4.63, recommendedBasal!.unitsPerHour, accuracy: defaultAccuracy)
    }
    
    func testHighAndFalling() {
        setUp(for: .highAndFalling)
        let predictedGlucoseOutput = loadLocalDateGlucoseEffect("high_and_falling_predicted_glucose")

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var predictedGlucose: [PredictedGlucoseValue]?
        var recommendedTempBasal: TempBasalRecommendation?
        self.loopDataManager.getLoopState { _, state in
            predictedGlucose = state.predictedGlucose
            recommendedTempBasal = state.recommendedAutomaticDose?.recommendation.basalAdjustment
            updateGroup.leave()
        }
        // We need to wait until the task completes to get outputs
        updateGroup.wait()

        XCTAssertNotNil(predictedGlucose)
        XCTAssertEqual(predictedGlucoseOutput.count, predictedGlucose!.count)
        
        for (expected, calculated) in zip(predictedGlucoseOutput, predictedGlucose!) {
            XCTAssertEqual(expected.startDate, calculated.startDate)
            XCTAssertEqual(expected.quantity.doubleValue(for: .milligramsPerDeciliter), calculated.quantity.doubleValue(for: .milligramsPerDeciliter), accuracy: defaultAccuracy)
        }

        XCTAssertEqual(0, recommendedTempBasal!.unitsPerHour, accuracy: defaultAccuracy)
    }
    
    func testHighAndRisingWithCOB() {
        setUp(for: .highAndRisingWithCOB)
        let predictedGlucoseOutput = loadLocalDateGlucoseEffect("high_and_rising_with_cob_predicted_glucose")

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var predictedGlucose: [PredictedGlucoseValue]?
        var recommendedBolus: ManualBolusRecommendation?
        self.loopDataManager.getLoopState { _, state in
            predictedGlucose = state.predictedGlucose
            recommendedBolus = try? state.recommendBolus(consideringPotentialCarbEntry: nil, replacingCarbEntry: nil, considerPositiveVelocityAndRC: true)
            updateGroup.leave()
        }
        // We need to wait until the task completes to get outputs
        updateGroup.wait()

        XCTAssertNotNil(predictedGlucose)
        XCTAssertEqual(predictedGlucoseOutput.count, predictedGlucose!.count)
        
        for (expected, calculated) in zip(predictedGlucoseOutput, predictedGlucose!) {
            XCTAssertEqual(expected.startDate, calculated.startDate)
            XCTAssertEqual(expected.quantity.doubleValue(for: .milligramsPerDeciliter), calculated.quantity.doubleValue(for: .milligramsPerDeciliter), accuracy: defaultAccuracy)
        }

        XCTAssertEqual(1.6, recommendedBolus!.amount, accuracy: defaultAccuracy)
    }
    
    func testLowAndFallingWithCOB() {
        setUp(for: .lowAndFallingWithCOB)
        let predictedGlucoseOutput = loadLocalDateGlucoseEffect("low_and_falling_predicted_glucose")

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var predictedGlucose: [PredictedGlucoseValue]?
        var recommendedTempBasal: TempBasalRecommendation?
        self.loopDataManager.getLoopState { _, state in
            predictedGlucose = state.predictedGlucose
            recommendedTempBasal = state.recommendedAutomaticDose?.recommendation.basalAdjustment
            updateGroup.leave()
        }
        // We need to wait until the task completes to get outputs
        updateGroup.wait()

        XCTAssertNotNil(predictedGlucose)
        XCTAssertEqual(predictedGlucoseOutput.count, predictedGlucose!.count)
        
        for (expected, calculated) in zip(predictedGlucoseOutput, predictedGlucose!) {
            XCTAssertEqual(expected.startDate, calculated.startDate)
            XCTAssertEqual(expected.quantity.doubleValue(for: .milligramsPerDeciliter), calculated.quantity.doubleValue(for: .milligramsPerDeciliter), accuracy: defaultAccuracy)
        }

        XCTAssertEqual(0, recommendedTempBasal!.unitsPerHour, accuracy: defaultAccuracy)
    }
    
    func testLowWithLowTreatment() {
        setUp(for: .lowWithLowTreatment)
        let predictedGlucoseOutput = loadLocalDateGlucoseEffect("low_with_low_treatment_predicted_glucose")

        let updateGroup = DispatchGroup()
        updateGroup.enter()
        var predictedGlucose: [PredictedGlucoseValue]?
        var recommendedTempBasal: TempBasalRecommendation?
        self.loopDataManager.getLoopState { _, state in
            predictedGlucose = state.predictedGlucose
            recommendedTempBasal = state.recommendedAutomaticDose?.recommendation.basalAdjustment
            updateGroup.leave()
        }
        // We need to wait until the task completes to get outputs
        updateGroup.wait()

        XCTAssertNotNil(predictedGlucose)
        XCTAssertEqual(predictedGlucoseOutput.count, predictedGlucose!.count)
        
        for (expected, calculated) in zip(predictedGlucoseOutput, predictedGlucose!) {
            XCTAssertEqual(expected.startDate, calculated.startDate)
            XCTAssertEqual(expected.quantity.doubleValue(for: .milligramsPerDeciliter), calculated.quantity.doubleValue(for: .milligramsPerDeciliter), accuracy: defaultAccuracy)
        }

        XCTAssertEqual(0, recommendedTempBasal!.unitsPerHour, accuracy: defaultAccuracy)
    }

    func waitOnDataQueue(timeout: TimeInterval = 10.0) {
        let e = expectation(description: "dataQueue")
        loopDataManager.getLoopState { _, _ in
            e.fulfill()
        }
        wait(for: [e], timeout: timeout)
    }
    
    func testValidateMaxTempBasalDoesntCancelTempBasalIfHigher() {
        let dose = DoseEntry(type: .tempBasal, startDate: Date(), endDate: nil, value: 3.0, unit: .unitsPerHour, deliveredUnits: nil, description: nil, syncIdentifier: nil, scheduledBasalRate: nil)
        setUp(for: .highAndStable, basalDeliveryState: .tempBasal(dose))
        // This wait is working around the issue presented by LoopDataManager.init().  It cancels the temp basal if
        // `isClosedLoop` is false (which it is from `setUp` above). When that happens, it races with
        // `maxTempBasalSavePreflight` below.  This ensures only one happens at a time.
        waitOnDataQueue()
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate
        var error: Error?
        let exp = expectation(description: #function)
        XCTAssertNil(delegate.recommendation)
        loopDataManager.maxTempBasalSavePreflight(unitsPerHour: 5.0) {
            error = $0
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)
        XCTAssertNil(error)
        XCTAssertNil(delegate.recommendation)
        XCTAssertTrue(dosingDecisionStore.dosingDecisions.isEmpty)
    }
    
    func testValidateMaxTempBasalCancelsTempBasalIfLower() {
        let dose = DoseEntry(type: .tempBasal, startDate: Date(), endDate: nil, value: 5.0, unit: .unitsPerHour, deliveredUnits: nil, description: nil, syncIdentifier: nil, scheduledBasalRate: nil)
        setUp(for: .highAndStable, basalDeliveryState: .tempBasal(dose))
        // This wait is working around the issue presented by LoopDataManager.init().  It cancels the temp basal if
        // `isClosedLoop` is false (which it is from `setUp` above). When that happens, it races with
        // `maxTempBasalSavePreflight` below.  This ensures only one happens at a time.
        waitOnDataQueue()
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate
        var error: Error?
        let exp = expectation(description: #function)
        XCTAssertNil(delegate.recommendation)
        loopDataManager.maxTempBasalSavePreflight(unitsPerHour: 3.0) {
            error = $0
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)
        XCTAssertNil(error)
        XCTAssertEqual(delegate.recommendation, AutomaticDoseRecommendation(basalAdjustment: .cancel))
        XCTAssertEqual(dosingDecisionStore.dosingDecisions.count, 1)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].reason, "maximumBasalRateChanged")
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].automaticDoseRecommendation, AutomaticDoseRecommendation(basalAdjustment: .cancel))
    }
    
    func testChangingMaxBasalUpdatesLoopData() {
        setUp(for: .highAndStable)
        waitOnDataQueue()
        var loopDataUpdated = false
        let exp = expectation(description: #function)
        let observer = NotificationCenter.default.addObserver(forName: .LoopDataUpdated, object: nil, queue: nil) { _ in
            loopDataUpdated = true
            exp.fulfill()
        }
        XCTAssertFalse(loopDataUpdated)
        loopDataManager.mutateSettings { $0.maximumBasalRatePerHour = 2.0 }
        wait(for: [exp], timeout: 10.0)
        XCTAssertTrue(loopDataUpdated)
        NotificationCenter.default.removeObserver(observer)
    }

    func testOpenLoopCancelsTempBasal() {
        let dose = DoseEntry(type: .tempBasal, startDate: Date(), value: 1.0, unit: .unitsPerHour)
        setUp(for: .highAndStable, basalDeliveryState: .tempBasal(dose))
        waitOnDataQueue()
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate
        let exp = expectation(description: #function)
        let observer = NotificationCenter.default.addObserver(forName: .LoopDataUpdated, object: nil, queue: nil) { _ in
            exp.fulfill()
        }
        automaticDosingStatus.automaticDosingEnabled = false
        wait(for: [exp], timeout: 10.0)
        let expectedAutomaticDoseRecommendation = AutomaticDoseRecommendation(basalAdjustment: .cancel)
        XCTAssertEqual(delegate.recommendation, expectedAutomaticDoseRecommendation)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions.count, 1)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].reason, "automaticDosingDisabled")
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].automaticDoseRecommendation, expectedAutomaticDoseRecommendation)
        NotificationCenter.default.removeObserver(observer)
    }

    func testReceivedUnreliableCGMReadingCancelsTempBasal() {
        let dose = DoseEntry(type: .tempBasal, startDate: Date(), value: 5.0, unit: .unitsPerHour)
        setUp(for: .highAndStable, basalDeliveryState: .tempBasal(dose))
        waitOnDataQueue()
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate
        let exp = expectation(description: #function)
        let observer = NotificationCenter.default.addObserver(forName: .LoopDataUpdated, object: nil, queue: nil) { _ in
            exp.fulfill()
        }
        loopDataManager.receivedUnreliableCGMReading()
        wait(for: [exp], timeout: 10.0)
        let expectedAutomaticDoseRecommendation = AutomaticDoseRecommendation(basalAdjustment: .cancel)
        XCTAssertEqual(delegate.recommendation, expectedAutomaticDoseRecommendation)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions.count, 1)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].reason, "unreliableCGMData")
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].automaticDoseRecommendation, expectedAutomaticDoseRecommendation)
        NotificationCenter.default.removeObserver(observer)
    }

    func testLoopEnactsTempBasalWithoutManualBolusRecommendation() {
        setUp(for: .highAndStable)
        waitOnDataQueue()
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate
        let exp = expectation(description: #function)
        let observer = NotificationCenter.default.addObserver(forName: .LoopCompleted, object: nil, queue: nil) { _ in
            exp.fulfill()
        }
        loopDataManager.loop()
        wait(for: [exp], timeout: 10.0)
        let expectedAutomaticDoseRecommendation = AutomaticDoseRecommendation(basalAdjustment: TempBasalRecommendation(unitsPerHour: 4.55, duration: .minutes(30)))
        XCTAssertEqual(delegate.recommendation, expectedAutomaticDoseRecommendation)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions.count, 1)
        if dosingDecisionStore.dosingDecisions.count == 1 {
            XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].reason, "loop")
            XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].automaticDoseRecommendation, expectedAutomaticDoseRecommendation)
            XCTAssertNil(dosingDecisionStore.dosingDecisions[0].manualBolusRecommendation)
            XCTAssertNil(dosingDecisionStore.dosingDecisions[0].manualBolusRequested)
        }
        NotificationCenter.default.removeObserver(observer)
    }

    func testLoopRecommendsTempBasalWithoutEnactingIfOpenLoop() {
        setUp(for: .highAndStable)
        automaticDosingStatus.automaticDosingEnabled = false
        waitOnDataQueue()
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate
        let exp = expectation(description: #function)
        let observer = NotificationCenter.default.addObserver(forName: .LoopCompleted, object: nil, queue: nil) { _ in
            exp.fulfill()
        }
        loopDataManager.loop()
        wait(for: [exp], timeout: 10.0)
        let expectedAutomaticDoseRecommendation = AutomaticDoseRecommendation(basalAdjustment: TempBasalRecommendation(unitsPerHour: 4.55, duration: .minutes(30)))
        XCTAssertNil(delegate.recommendation)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions.count, 1)
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].reason, "loop")
        XCTAssertEqual(dosingDecisionStore.dosingDecisions[0].automaticDoseRecommendation, expectedAutomaticDoseRecommendation)
        XCTAssertNil(dosingDecisionStore.dosingDecisions[0].manualBolusRecommendation)
        XCTAssertNil(dosingDecisionStore.dosingDecisions[0].manualBolusRequested)
        NotificationCenter.default.removeObserver(observer)
    }

    func testLoopGetStateRecommendsManualBolus() {
        setUp(for: .highAndStable)
        let exp = expectation(description: #function)
        var recommendedBolus: ManualBolusRecommendation?
        loopDataManager.getLoopState { (_, loopState) in
            recommendedBolus = try? loopState.recommendBolus(consideringPotentialCarbEntry: nil, replacingCarbEntry: nil, considerPositiveVelocityAndRC: true)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 100000.0)
        XCTAssertEqual(recommendedBolus!.amount, 1.82, accuracy: 0.01)
    }

    func testLoopGetStateRecommendsManualBolusWithMomentum() {
        setUp(for: .highAndRisingWithCOB)
        let exp = expectation(description: #function)
        var recommendedBolus: ManualBolusRecommendation?
        loopDataManager.getLoopState { (_, loopState) in
            recommendedBolus = try? loopState.recommendBolus(consideringPotentialCarbEntry: nil, replacingCarbEntry: nil, considerPositiveVelocityAndRC: true)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)
        XCTAssertEqual(recommendedBolus!.amount, 1.62, accuracy: 0.01)
    }

    func testLoopGetStateRecommendsManualBolusWithoutMomentum() {
        setUp(for: .highAndRisingWithCOB)
        let exp = expectation(description: #function)
        var recommendedBolus: ManualBolusRecommendation?
        loopDataManager.getLoopState { (_, loopState) in
            recommendedBolus = try? loopState.recommendBolus(consideringPotentialCarbEntry: nil, replacingCarbEntry: nil, considerPositiveVelocityAndRC: false)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)
        XCTAssertEqual(recommendedBolus!.amount, 1.52, accuracy: 0.01)
    }

    func testIsClosedLoopAvoidsTriggeringTempBasalCancelOnCreation() {
        let settings = LoopSettings(
            dosingEnabled: false,
            glucoseTargetRangeSchedule: glucoseTargetRangeSchedule,
            maximumBasalRatePerHour: 5,
            maximumBolus: 10,
            suspendThreshold: suspendThreshold
        )

        let doseStore = MockDoseStore()
        let glucoseStore = MockGlucoseStore(for: .flatAndStable)
        let carbStore = MockCarbStore()

        let currentDate = Date()

        dosingDecisionStore = MockDosingDecisionStore()
        automaticDosingStatus = AutomaticDosingStatus(automaticDosingEnabled: false, isAutomaticDosingAllowed: true)
        let existingTempBasal = DoseEntry(
            type: .tempBasal,
            startDate: currentDate.addingTimeInterval(-.minutes(2)),
            endDate: currentDate.addingTimeInterval(.minutes(28)),
            value: 1.0,
            unit: .unitsPerHour,
            deliveredUnits: nil,
            description: "Mock Temp Basal",
            syncIdentifier: "asdf",
            scheduledBasalRate: nil,
            insulinType: .novolog,
            automatic: true,
            manuallyEntered: false,
            isMutable: true)
        loopDataManager = LoopDataManager(
            lastLoopCompleted: currentDate.addingTimeInterval(-.minutes(5)),
            basalDeliveryState: .tempBasal(existingTempBasal),
            settings: settings,
            overrideHistory: TemporaryScheduleOverrideHistory(),
            analyticsServicesManager: AnalyticsServicesManager(),
            localCacheDuration: .days(1),
            doseStore: doseStore,
            glucoseStore: glucoseStore,
            carbStore: carbStore,
            dosingDecisionStore: dosingDecisionStore,
            latestStoredSettingsProvider: MockLatestStoredSettingsProvider(),
            now: { currentDate },
            pumpInsulinType: .novolog,
            automaticDosingStatus: automaticDosingStatus,
            trustedTimeOffset: { 0 }
        )
        let mockDelegate = MockDelegate()
        loopDataManager.delegate = mockDelegate

        // Dose enacting happens asynchronously, as does receiving isClosedLoop signals
        waitOnMain(timeout: 5)
        XCTAssertNil(mockDelegate.recommendation)
    }

    func testAutoBolusMaxIOBClamping() {
        /// `maxBolus` is set to clamp the automatic dose
        /// Autobolus without clamping: 0.65 U. Clamped recommendation: 0.2 U.
        setUp(for: .highAndRisingWithCOB, maxBolus: 5, dosingStrategy: .automaticBolus)

        // This sets up dose rounding
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate

        let updateGroup = DispatchGroup()
        updateGroup.enter()

        var insulinOnBoard: InsulinValue?
        var recommendedBolus: Double?
        self.loopDataManager.getLoopState { _, state in
            insulinOnBoard = state.insulinOnBoard
            recommendedBolus = state.recommendedAutomaticDose?.recommendation.bolusUnits
            updateGroup.leave()
        }
        updateGroup.wait()

        XCTAssertEqual(recommendedBolus!, 0.5, accuracy: 0.01)
        XCTAssertEqual(insulinOnBoard?.value, 9.5)

        /// Set the `maximumBolus` to 10U so there's no clamping
        updateGroup.enter()
        self.loopDataManager.mutateSettings { settings in settings.maximumBolus = 10 }
        self.loopDataManager.getLoopState { _, state in
            insulinOnBoard = state.insulinOnBoard
            recommendedBolus = state.recommendedAutomaticDose?.recommendation.bolusUnits
            updateGroup.leave()
        }
        updateGroup.wait()

        XCTAssertEqual(recommendedBolus!, 0.65, accuracy: 0.01)
        XCTAssertEqual(insulinOnBoard?.value, 9.5)
    }

    func testTempBasalMaxIOBClamping() {
        /// `maximumBolus` is set to 5U to clamp max IOB at 10U
        /// Without clamping: 4.25 U/hr. Clamped recommendation: 2.0 U/hr.
        setUp(for: .highAndRisingWithCOB, maxBolus: 5)

        // This sets up dose rounding
        let delegate = MockDelegate()
        loopDataManager.delegate = delegate

        let updateGroup = DispatchGroup()
        updateGroup.enter()

        var insulinOnBoard: InsulinValue?
        var recommendedBasal: TempBasalRecommendation?
        self.loopDataManager.getLoopState { _, state in
            insulinOnBoard = state.insulinOnBoard
            recommendedBasal = state.recommendedAutomaticDose?.recommendation.basalAdjustment
            updateGroup.leave()
        }
        updateGroup.wait()

        XCTAssertEqual(recommendedBasal!.unitsPerHour, 2.0, accuracy: 0.01)
        XCTAssertEqual(insulinOnBoard?.value, 9.5)

        /// Set the `maximumBolus` to 10U so there's no clamping
        updateGroup.enter()
        self.loopDataManager.mutateSettings { settings in settings.maximumBolus = 10 }
        self.loopDataManager.getLoopState { _, state in
            insulinOnBoard = state.insulinOnBoard
            recommendedBasal = state.recommendedAutomaticDose?.recommendation.basalAdjustment
            updateGroup.leave()
        }
        updateGroup.wait()

        XCTAssertEqual(recommendedBasal!.unitsPerHour, 4.25, accuracy: 0.01)
        XCTAssertEqual(insulinOnBoard?.value, 9.5)
    }

    // MARK: - Use for Corrections (glucose-dependent sensitivity, Variant B)

    private func recommendations(for scenario: DosingTestScenario, strategy: AutomaticDosingStrategy = .tempBasalOnly, factor: Double?) -> (automatic: AutomaticDoseRecommendation?, manualBolus: Double?) {
        setUp(for: scenario, dosingStrategy: strategy, glucoseDependentSensitivityFactor: { _, _ in factor })
        return currentRecommendations()
    }

    private func currentRecommendations() -> (automatic: AutomaticDoseRecommendation?, manualBolus: Double?) {
        let exp = expectation(description: #function)
        var automatic: AutomaticDoseRecommendation?
        var manualBolus: Double?
        loopDataManager.getLoopState { _, state in
            automatic = state.recommendedAutomaticDose?.recommendation
            manualBolus = (try? state.recommendBolus(consideringPotentialCarbEntry: nil, replacingCarbEntry: nil, considerPositiveVelocityAndRC: true))?.amount
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10.0)
        return (automatic, manualBolus)
    }

    /// Cap for the high-and-rising-with-COB fixture: glucose 129.93, correction range 90–100, ISF 55.
    private func risingWithCarbsCap(factor: Double) -> Double {
        GlucoseDependentSensitivity.cap(glucose: 129.93174411197853, correctionRangeMidpoint: 95, sensitivity: 55, factor: factor)
    }

    func testUseForCorrectionsOffKeepsRecommendations() {
        let savedProfiles = UserDefaults.standard.therapyProfiles
        let savedActiveID = UserDefaults.standard.activeTherapyProfileID
        defer {
            UserDefaults.standard.therapyProfiles = savedProfiles
            UserDefaults.standard.activeTherapyProfileID = savedActiveID
        }
        let profile = TherapyProfile(
            name: "Test",
            basalRateSchedule: loadBasalRateScheduleFixture("basal_profile"),
            carbRatioSchedule: CarbRatioSchedule(unit: .gram(), dailyItems: [RepeatingScheduleValue(startTime: 0, value: 10)], timeZone: .utcTimeZone)!,
            insulinSensitivitySchedule: InsulinSensitivitySchedule(unit: .milligramsPerDeciliter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: 45)], timeZone: .utcTimeZone)!
        )
        UserDefaults.standard.therapyProfiles = [profile]
        UserDefaults.standard.activeTherapyProfileID = profile.id
        XCTAssertNil(GlucoseDependentSensitivity.activeFactor(forGlucose: 200, at: Date()))

        // Default wiring: the active profile's switch decides.
        setUp(for: .highAndStable)
        let off = currentRecommendations()
        XCTAssertEqual(off.automatic?.basalAdjustment?.unitsPerHour ?? -1, 4.63, accuracy: defaultAccuracy)
        XCTAssertEqual(off.manualBolus ?? -1, 1.82, accuracy: 0.01)
    }

    func testUseForCorrectionsManualBolusWithCarbsChangesOnlyCorrectionShare() {
        let off = recommendations(for: .highAndRisingWithCOB, factor: nil)
        let on = recommendations(for: .highAndRisingWithCOB, factor: 0.8)
        let cap = risingWithCarbsCap(factor: 0.8)
        XCTAssertGreaterThan(cap, 0)
        // Scaling the whole dose would add about 0.4 U; only the correction share may be added.
        XCTAssertEqual(on.manualBolus! - off.manualBolus!, cap, accuracy: 1e-9)
    }

    func testUseForCorrectionsFactorAboveOneReducesOnlyCorrectionShare() {
        let off = recommendations(for: .highAndRisingWithCOB, factor: nil)
        let on = recommendations(for: .highAndRisingWithCOB, factor: 1.25)
        XCTAssertEqual(off.manualBolus! - on.manualBolus!, risingWithCarbsCap(factor: 1.25), accuracy: 1e-9)
    }

    func testUseForCorrectionsTempBasalCappedInUnits() {
        let off = recommendations(for: .highAndRisingWithCOB, factor: nil)
        let on = recommendations(for: .highAndRisingWithCOB, factor: 0.8)
        let standardRate = off.automatic!.basalAdjustment!.unitsPerHour
        let rate = on.automatic!.basalAdjustment!.unitsPerHour
        XCTAssertEqual(standardRate, 4.25, accuracy: 0.05)
        XCTAssertEqual((rate - standardRate) * 0.5, risingWithCarbsCap(factor: 0.8), accuracy: 1e-9)
        XCTAssertLessThanOrEqual(rate, 5.0)
    }

    func testUseForCorrectionsAutomaticBolusCapped() {
        let off = recommendations(for: .highAndRisingWithCOB, strategy: .automaticBolus, factor: nil)
        let on = recommendations(for: .highAndRisingWithCOB, strategy: .automaticBolus, factor: 0.8)
        let deviation = on.automatic!.bolusUnits! - off.automatic!.bolusUnits!
        XCTAssertGreaterThan(deviation, 0)
        XCTAssertLessThanOrEqual(deviation, risingWithCarbsCap(factor: 0.8) + 1e-9)
    }

    func testUseForCorrectionsBelowMidpointKeepsStandard() {
        for strategy in [AutomaticDosingStrategy.tempBasalOnly, .automaticBolus] {
            let off = recommendations(for: .lowWithLowTreatment, strategy: strategy, factor: nil)
            let on = recommendations(for: .lowWithLowTreatment, strategy: strategy, factor: 0.8)
            XCTAssertEqual(on.automatic, off.automatic)
            XCTAssertEqual(on.manualBolus, off.manualBolus)
        }
        XCTAssertEqual(GlucoseDependentSensitivity.cap(glucose: 105, correctionRangeMidpoint: 105, sensitivity: 45, factor: 0.8), 0)
        XCTAssertEqual(GlucoseDependentSensitivity.cap(glucose: 90, correctionRangeMidpoint: 105, sensitivity: 45, factor: 1.2), 0)
    }

    func testUseForCorrectionsCap() {
        XCTAssertEqual(GlucoseDependentSensitivity.cap(glucose: 200, correctionRangeMidpoint: 100, sensitivity: 50, factor: 0.8), 0.5, accuracy: 1e-9)
        XCTAssertEqual(GlucoseDependentSensitivity.cap(glucose: 200, correctionRangeMidpoint: 100, sensitivity: 50, factor: 1.25), 0.4, accuracy: 1e-9)
    }

    func testUseForCorrectionsMealBolusScalesOnlyCorrectionShare() {
        // 4 U for carbs plus 2 U correcting 200 to 100 mg/dL at ISF 50; factor 0.8 scales the whole dose to 7.5 U.
        let bolus = GlucoseDependentSensitivity.limitedBolus(standard: 6, scaled: 7.5, cap: 0.5, volumeRounder: nil)
        XCTAssertEqual(bolus, 6.5, accuracy: 1e-9)
        let reduced = GlucoseDependentSensitivity.limitedBolus(standard: 6, scaled: 4.8, cap: 0.4, volumeRounder: nil)
        XCTAssertEqual(reduced, 5.6, accuracy: 1e-9)
        XCTAssertEqual(GlucoseDependentSensitivity.limitedBolus(standard: 2, scaled: 2.3, cap: 0.5, volumeRounder: nil), 2.3)
    }

    func testUseForCorrectionsTempBasalDeviationInUnits() {
        let now = Date()
        let standard = TempBasalRecommendation(unitsPerHour: 2.0, duration: .minutes(30))
        let scaled = TempBasalRecommendation(unitsPerHour: 4.0, duration: .minutes(30))
        // 2 U/h more for 30 minutes is 1 U; the cap of 0.5 U allows 1 U/h more.
        let limited = GlucoseDependentSensitivity.limitedTempBasal(standard: standard, scaled: scaled, cap: 0.5, scheduledBasalRate: 1.0, lastTempBasal: nil, at: now, rateRounder: nil)
        XCTAssertEqual(limited, TempBasalRecommendation(unitsPerHour: 3.0, duration: .minutes(30)))

        // No new temp keeps the running 2 U/h; 2.6 U/h is 0.3 U more, within the cap.
        let small = TempBasalRecommendation(unitsPerHour: 2.6, duration: .minutes(30))
        XCTAssertEqual(GlucoseDependentSensitivity.limitedTempBasal(standard: nil, scaled: small, cap: 0.5, scheduledBasalRate: 1.0, lastTempBasal: runningTemp(2.0, at: now), at: now, rateRounder: nil), small)

        // Cancel returns to scheduled basal: 1 U/h less than 3 U/h is 0.5 U, capped to 0.2 U.
        let reduced = GlucoseDependentSensitivity.limitedTempBasal(standard: TempBasalRecommendation(unitsPerHour: 3.0, duration: .minutes(30)), scaled: .cancel, cap: 0.2, scheduledBasalRate: 2.0, lastTempBasal: nil, at: now, rateRounder: nil)
        XCTAssertEqual(reduced!.unitsPerHour, 2.6, accuracy: 1e-9)
    }

    func testUseForCorrectionsAutomaticDoseSharesCap() {
        let now = Date()
        let standard = AutomaticDoseRecommendation(basalAdjustment: nil, bolusUnits: 1.0)
        let scaled = AutomaticDoseRecommendation(basalAdjustment: nil, bolusUnits: 2.0)
        let limited = GlucoseDependentSensitivity.limitedAutomaticDose(standard: standard, scaled: scaled, cap: 0.5, scheduledBasalRate: 1.0, lastTempBasal: nil, at: now, volumeRounder: nil, rateRounder: nil)
        XCTAssertEqual(limited?.bolusUnits ?? 0, 1.5, accuracy: 1e-9)
        XCTAssertNil(limited?.basalAdjustment)
        XCTAssertEqual(GlucoseDependentSensitivity.limitedAutomaticDose(standard: standard, scaled: standard, cap: 0.5, scheduledBasalRate: 1.0, lastTempBasal: nil, at: now, volumeRounder: nil, rateRounder: nil), standard)
    }

    // MARK: - Automatic dose urgency

    private func runningTemp(_ unitsPerHour: Double, at now: Date) -> DoseEntry {
        DoseEntry(type: .tempBasal, startDate: now.addingTimeInterval(.minutes(-10)), endDate: now.addingTimeInterval(.minutes(20)), value: unitsPerHour, unit: .unitsPerHour)
    }

    private func urgency(_ recommendation: AutomaticDoseRecommendation?, runningTemp: DoseEntry?, at now: Date) -> AutomaticDoseUrgency {
        AutomaticDoseUrgency(recommendation: recommendation, runningTempBasal: runningTemp, scheduledBasalRate: 1.0, at: now)
    }

    func testUrgencySuspendIsUrgent() {
        let now = Date()
        let suspend = AutomaticDoseRecommendation(basalAdjustment: TempBasalRecommendation(unitsPerHour: 0, duration: .minutes(30)))
        XCTAssertEqual(urgency(suspend, runningTemp: nil, at: now), .urgent)
        XCTAssertEqual(urgency(suspend, runningTemp: runningTemp(0.6, at: now), at: now), .urgent)
    }

    func testUrgencyStoppingHighTempIsUrgent() {
        let now = Date()
        let cancel = AutomaticDoseRecommendation(basalAdjustment: .cancel)
        XCTAssertEqual(urgency(cancel, runningTemp: runningTemp(2.5, at: now), at: now), .urgent)
        let lower = AutomaticDoseRecommendation(basalAdjustment: TempBasalRecommendation(unitsPerHour: 1.5, duration: .minutes(30)))
        XCTAssertEqual(urgency(lower, runningTemp: runningTemp(2.5, at: now), at: now), .urgent)
    }

    func testUrgencyModerateReductionCanWait() {
        let now = Date()
        let reduction = AutomaticDoseRecommendation(basalAdjustment: TempBasalRecommendation(unitsPerHour: 0.4, duration: .minutes(30)))
        XCTAssertEqual(urgency(reduction, runningTemp: nil, at: now), .canWait)
        XCTAssertEqual(urgency(reduction, runningTemp: runningTemp(0.8, at: now), at: now), .canWait)
    }

    func testUrgencyIncreaseCanWait() {
        let now = Date()
        let increase = AutomaticDoseRecommendation(basalAdjustment: TempBasalRecommendation(unitsPerHour: 2.0, duration: .minutes(30)))
        XCTAssertEqual(urgency(increase, runningTemp: nil, at: now), .canWait)
        XCTAssertEqual(urgency(increase, runningTemp: runningTemp(0, at: now), at: now), .canWait)
        // Ending a zero temp returns to scheduled basal, which is an increase.
        XCTAssertEqual(urgency(AutomaticDoseRecommendation(basalAdjustment: .cancel), runningTemp: runningTemp(0, at: now), at: now), .canWait)
    }

    func testUrgencyBolusCanWait() {
        let now = Date()
        XCTAssertEqual(urgency(AutomaticDoseRecommendation(basalAdjustment: nil, bolusUnits: 0.5), runningTemp: nil, at: now), .canWait)
    }

    func testUrgencyNoRecommendation() {
        let now = Date()
        XCTAssertEqual(urgency(nil, runningTemp: nil, at: now), .noDose)
        XCTAssertEqual(urgency(AutomaticDoseRecommendation(basalAdjustment: nil, bolusUnits: 0), runningTemp: nil, at: now), .noDose)
    }

    func testUrgencyIgnoresExpiredTemp() {
        let now = Date()
        let expired = DoseEntry(type: .tempBasal, startDate: now.addingTimeInterval(.minutes(-40)), endDate: now.addingTimeInterval(.minutes(-10)), value: 2.5, unit: .unitsPerHour)
        let lower = AutomaticDoseRecommendation(basalAdjustment: TempBasalRecommendation(unitsPerHour: 0.5, duration: .minutes(30)))
        XCTAssertEqual(urgency(lower, runningTemp: expired, at: now), .canWait)
    }

}
