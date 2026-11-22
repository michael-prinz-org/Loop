//
//  TherapyProfileTests.swift
//  LoopTests
//

import XCTest
import HealthKit
import LoopKit
import LoopKitUI
@testable import Loop

final class TherapyProfileTests: XCTestCase {
    /// 2023-11-14 00:00:00 UTC
    private let t0 = Date(timeIntervalSince1970: 1_699_920_000)
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 24 * 3600

    private func recorded(_ concentration: InsulinConcentration, previous: InsulinConcentration, at date: Date, in history: [InsulinConcentrationChange]) -> [InsulinConcentrationChange] {
        InsulinConcentrationHistory.recorded(concentration, previous: previous, at: date, in: history)
    }

    private func scale(at date: Date, in history: [InsulinConcentrationChange]) -> Double {
        InsulinConcentrationHistory.pumpUnitScale(at: date, in: history)
    }

    private func unitsPerPumpUnit(at date: Date, in history: [InsulinConcentrationChange]) -> Double {
        InsulinConcentrationHistory.unitsPerPumpUnit(at: date, in: history)
    }

    private func profile(_ concentration: InsulinConcentration?, isStandard: Bool? = nil) -> TherapyProfile {
        profile(concentration, basalRates: [0.5], carbRatio: 10, sensitivity: 50, isStandard: isStandard)
    }

    /// Basal segments start every 3 hours.
    private func profile(_ concentration: InsulinConcentration?, basalRates: [Double], carbRatio: Double, sensitivity: Double, isStandard: Bool? = nil, maximumBasalRatePerHour: Double? = nil, maximumBolus: Double? = nil) -> TherapyProfile {
        TherapyProfile(
            name: "Test",
            basalRateSchedule: BasalRateSchedule(dailyItems: basalRates.enumerated().map { RepeatingScheduleValue(startTime: Double($0.offset) * 3 * hour, value: $0.element) }, timeZone: .utcTimeZone)!,
            carbRatioSchedule: CarbRatioSchedule(unit: .gram(), dailyItems: [RepeatingScheduleValue(startTime: 0, value: carbRatio)], timeZone: .utcTimeZone)!,
            insulinSensitivitySchedule: InsulinSensitivitySchedule(unit: .milligramsPerDeciliter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: sensitivity)], timeZone: .utcTimeZone)!,
            isStandard: isStandard,
            maximumBasalRatePerHour: maximumBasalRatePerHour,
            maximumBolus: maximumBolus,
            insulinConcentration: concentration
        )
    }

    private func basalRates(_ profile: TherapyProfile) -> [Double] {
        profile.basalRateSchedule.items.map { $0.value }
    }

    private func assertConversionFails(_ profile: TherapyProfile, to target: InsulinConcentration, file: StaticString = #filePath, line: UInt = #line, matching: (TherapyProfileError) -> Bool) {
        do {
            let converted = try profile.converted(toConcentration: target, name: "Converted")
            XCTFail("Expected an error, got \(converted)", file: file, line: line)
        } catch let error as TherapyProfileError {
            XCTAssertTrue(matching(error), "Unexpected error \(error)", file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    // MARK: Concentration history

    func testEmptyHistoryScalesNothing() {
        XCTAssertEqual(scale(at: t0, in: []), 1)
        XCTAssertEqual(unitsPerPumpUnit(at: t0, in: []), 1)
    }

    func testFirstRecordKeepsPreviousConcentration() {
        XCTAssertEqual(recorded(.u200, previous: .u100, at: t0, in: []), [
            InsulinConcentrationChange(start: .distantPast, concentration: .u100),
            InsulinConcentrationChange(start: t0, concentration: .u200)
        ])
    }

    func testRecordingTheSameConcentrationAddsNoChange() {
        let history = recorded(.u100, previous: .u100, at: t0, in: [])
        XCTAssertEqual(history, [InsulinConcentrationChange(start: .distantPast, concentration: .u100)])
        XCTAssertEqual(recorded(.u100, previous: .u100, at: t0 + day, in: history), history)
    }

    func testU100ToU200ToU100() {
        let u200 = recorded(.u200, previous: .u100, at: t0, in: [])
        // With U200 in use, a U100 pump unit is half a current pump unit.
        XCTAssertEqual(scale(at: t0 - hour, in: u200), 0.5)
        XCTAssertEqual(scale(at: t0 + hour, in: u200), 1)
        XCTAssertEqual(unitsPerPumpUnit(at: t0 - hour, in: u200), 1)
        XCTAssertEqual(unitsPerPumpUnit(at: t0 + hour, in: u200), 2)

        let back = recorded(.u100, previous: .u200, at: t0 + day, in: u200)
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(scale(at: t0 - hour, in: back), 1)
        XCTAssertEqual(scale(at: t0 + hour, in: back), 2)
        XCTAssertEqual(scale(at: t0 + day + hour, in: back), 1)
        XCTAssertEqual(unitsPerPumpUnit(at: t0 + hour, in: back), 2)
        XCTAssertEqual(unitsPerPumpUnit(at: t0 + day + hour, in: back), 1)
    }

    func testTrimsChangesNoLongerNeededForDoseHistory() {
        let u200 = recorded(.u200, previous: .u100, at: t0, in: [])
        let back = recorded(.u100, previous: .u200, at: t0 + 9 * day, in: u200)
        // U200 still covers the start of the retained 8 days, so only the entry before it goes.
        XCTAssertEqual(back, [
            InsulinConcentrationChange(start: t0, concentration: .u200),
            InsulinConcentrationChange(start: t0 + 9 * day, concentration: .u100)
        ])
        XCTAssertEqual(scale(at: t0 + 2 * day, in: back), 2)
    }

    func testBackdatedRecordCoversDosesSincePodStart() {
        let podStart = t0
        let history = recorded(.u200, previous: .u100, at: podStart, in: [InsulinConcentrationChange(start: .distantPast, concentration: .u100)])
        XCTAssertEqual(history, [
            InsulinConcentrationChange(start: .distantPast, concentration: .u100),
            InsulinConcentrationChange(start: podStart, concentration: .u200)
        ])
        // Doses this pod delivered before the switch are U200 already.
        XCTAssertEqual(scale(at: podStart + hour, in: history), 1)
        XCTAssertEqual(scale(at: podStart - hour, in: history), 0.5)
    }

    func testBackdatedRecordReplacesLaterChanges() {
        let podStart = t0
        let switchedTooLate = recorded(.u200, previous: .u100, at: podStart + hour, in: [])
        let back = recorded(.u100, previous: .u200, at: podStart, in: switchedTooLate)
        XCTAssertEqual(back, [InsulinConcentrationChange(start: .distantPast, concentration: .u100)])
        XCTAssertEqual(scale(at: podStart + 2 * hour, in: back), 1)
    }

    // MARK: Concentration switch confirmation

    func testNoConfirmationWithoutConcentrationChange() {
        XCTAssertEqual(ConcentrationSwitchConfirmation.required(from: .u100, to: .u100, podActive: true), .notNeeded)
        XCTAssertEqual(ConcentrationSwitchConfirmation.required(from: .u200, to: .u200, podActive: nil), .notNeeded)
    }

    func testNormalConfirmationForSwitchWithoutPod() {
        XCTAssertEqual(ConcentrationSwitchConfirmation.required(from: .u100, to: .u200, podActive: false), .normal)
        XCTAssertEqual(ConcentrationSwitchConfirmation.required(from: .u200, to: .u100, podActive: false), .normal)
    }

    func testStrictConfirmationForSwitchWithPod() {
        XCTAssertEqual(ConcentrationSwitchConfirmation.required(from: .u100, to: .u200, podActive: true), .strict)
        XCTAssertEqual(ConcentrationSwitchConfirmation.required(from: .u200, to: .u100, podActive: true), .strict)
    }

    func testStrictConfirmationForPumpWithoutPodConcept() {
        XCTAssertEqual(ConcentrationSwitchConfirmation.required(from: .u100, to: .u200, podActive: nil), .strict)
    }

    func testPodActiveReadFromRawPumpManager() {
        XCTAssertEqual(ConcentrationSwitchConfirmation.podActive(rawPumpManager: nil), false)
        XCTAssertEqual(ConcentrationSwitchConfirmation.podActive(rawPumpManager: ["managerIdentifier": "Omni", "state": ["podState": ["address": 1]]]), true)
        XCTAssertEqual(ConcentrationSwitchConfirmation.podActive(rawPumpManager: ["managerIdentifier": "Omni", "state": [String: Any]()]), false)
        XCTAssertNil(ConcentrationSwitchConfirmation.podActive(rawPumpManager: ["managerIdentifier": "Minimed500", "state": [String: Any]()]))
    }

    func testPodStartReadFromRawPumpManager() {
        let omnipod: [String: Any] = ["managerIdentifier": "Omni", "state": ["podState": ["activatedAt": t0]]]
        XCTAssertEqual(PodStatus(rawPumpManager: omnipod), PodStatus(isActive: true, activatedAt: t0))
        XCTAssertEqual(PodStatus(rawPumpManager: ["managerIdentifier": "Omni", "state": ["podState": ["address": 1]]]), PodStatus(isActive: true, activatedAt: nil))
        XCTAssertEqual(PodStatus(rawPumpManager: ["managerIdentifier": "Omni", "state": [String: Any]()]), PodStatus(isActive: false, activatedAt: nil))
        XCTAssertEqual(PodStatus(rawPumpManager: ["managerIdentifier": "Minimed500", "state": [String: Any]()]), .unknown)
    }

    func testPodWakeUpsReadFromRawPumpManager() {
        let omnipod: [String: Any] = ["managerIdentifier": "Omni", "state": ["podWakeUpCount": 12, "lastPodWakeUpDate": t0]]
        let status = PodStatus(rawPumpManager: omnipod)
        XCTAssertEqual(status.wakeUpCount, 12)
        XCTAssertEqual(status.lastWakeUpDate, t0)
        XCTAssertNil(PodStatus(rawPumpManager: nil).wakeUpCount)
    }

    // MARK: Concentration conversion

    func testU100ToU200HalvesBasalAndLimitsAndDoublesRatios() throws {
        let source = profile(nil, basalRates: [0.5, 1.0], carbRatio: 10, sensitivity: 50, maximumBasalRatePerHour: 3, maximumBolus: 10)
        let converted = try source.converted(toConcentration: .u200, name: "U200")
        XCTAssertEqual(converted.concentration, .u200)
        XCTAssertEqual(basalRates(converted), [0.25, 0.5])
        XCTAssertEqual(converted.carbRatioSchedule.items.map { $0.value }, [20])
        XCTAssertEqual(converted.insulinSensitivitySchedule.items.map { $0.value }, [100])
        XCTAssertEqual(converted.maximumBasalRatePerHour, 1.5)
        XCTAssertEqual(converted.maximumBolus, 5)
        XCTAssertEqual(converted.dailyBasalInInternationalUnits, source.dailyBasalInInternationalUnits, accuracy: 1e-9)
    }

    func testU200ToU100DoublesBasal() throws {
        let converted = try profile(.u200, basalRates: [0.05, 0.35], carbRatio: 20, sensitivity: 100).converted(toConcentration: .u100, name: "U100")
        XCTAssertNil(converted.insulinConcentration)
        XCTAssertEqual(basalRates(converted), [0.1, 0.7])
        XCTAssertEqual(converted.carbRatioSchedule.items.map { $0.value }, [10])
        XCTAssertEqual(converted.insulinSensitivitySchedule.items.map { $0.value }, [50])
    }

    func testConversionRoundsBasalDownSoNoRateIncreasesInInternationalUnits() throws {
        let source = profile(nil, basalRates: [0.15, 0.25, 0.35, 1.05], carbRatio: 10, sensitivity: 50)
        let converted = try source.converted(toConcentration: .u200, name: "U200")
        XCTAssertEqual(basalRates(converted), [0.05, 0.1, 0.15, 0.5])
        for (old, new) in zip(source.basalRatesInInternationalUnits, converted.basalRatesInInternationalUnits) {
            XCTAssertLessThanOrEqual(new.value, old.value + 1e-9)
        }
    }

    func testRoundTripKeepsValuesOnTheTenthGridAndNeverIncreasesBasal() throws {
        let source = profile(nil, basalRates: [0.1, 0.5, 1.2, 0.15], carbRatio: 10.5, sensitivity: 45)
        let back = try source.converted(toConcentration: .u200, name: "U200").converted(toConcentration: .u100, name: "U100")
        XCTAssertEqual(basalRates(back), [0.1, 0.5, 1.2, 0.1])
        XCTAssertEqual(back.carbRatioSchedule.items.map { $0.value }, [10.5])
        XCTAssertEqual(back.insulinSensitivitySchedule.items.map { $0.value }, [45])
    }

    func testConversionRejectsNonZeroBasalBecomingZero() {
        let threeHours = 3 * hour
        assertConversionFails(profile(nil, basalRates: [0.5, 0.05], carbRatio: 10, sensitivity: 50), to: .u200) {
            if case .convertedBasalRateIsZero(let startTime) = $0 { return startTime == threeHours }
            return false
        }
    }

    func testConversionKeepsZeroBasalSegments() throws {
        let converted = try profile(nil, basalRates: [0, 0.5], carbRatio: 10, sensitivity: 50).converted(toConcentration: .u200, name: "U200")
        XCTAssertEqual(basalRates(converted), [0, 0.25])
    }

    func testConversionRejectsValuesOutsideGuardrails() {
        assertConversionFails(profile(nil, basalRates: [0.5], carbRatio: 10, sensitivity: 300), to: .u200) {
            if case .convertedInsulinSensitivityOutsideGuardrail = $0 { return true }
            return false
        }
        assertConversionFails(profile(nil, basalRates: [0.5], carbRatio: 80, sensitivity: 50), to: .u200) {
            if case .convertedCarbRatioOutsideGuardrail = $0 { return true }
            return false
        }
        assertConversionFails(profile(.u200, basalRates: [0.5], carbRatio: 3, sensitivity: 50), to: .u100) {
            if case .convertedCarbRatioOutsideGuardrail = $0 { return true }
            return false
        }
    }

    // MARK: New profile

    func testNewProfileStartsAtSourceConcentration() {
        XCTAssertTrue(NewTherapyProfileSheet.startsAsU200(source: profile(.u200)))
        XCTAssertFalse(NewTherapyProfileSheet.startsAsU200(source: profile(nil)))
        XCTAssertFalse(NewTherapyProfileSheet.startsAsU200(source: profile(.u100)))
    }

    func testCopyKeepsConcentrationWithoutConverting() throws {
        let source = profile(.u200, basalRates: [0.05], carbRatio: 20, sensitivity: 100)
        let copy = try source.copy(named: "Copy", concentration: .u200)
        XCTAssertEqual(copy.concentration, .u200)
        XCTAssertEqual(basalRates(copy), [0.05])
        XCTAssertNotEqual(copy.id, source.id)
    }

    func testActivatingAnotherConcentrationWithoutConfirmationFails() {
        let savedProfiles = UserDefaults.standard.therapyProfiles
        let savedActiveID = UserDefaults.standard.activeTherapyProfileID
        defer {
            UserDefaults.standard.therapyProfiles = savedProfiles
            UserDefaults.standard.activeTherapyProfileID = savedActiveID
        }
        let standard = profile(nil, isStandard: true)
        let u200 = profile(.u200)
        UserDefaults.standard.therapyProfiles = [standard, u200]
        UserDefaults.standard.activeTherapyProfileID = standard.id
        let model = TherapyProfilesModel(liveViewModel: TherapySettingsViewModel(therapySettings: TherapySettings()), podStatus: { PodStatus(isActive: true, activatedAt: nil) })

        var result: Error?
        model.activate(u200, concentrationChangeConfirmed: false) { result = $0 }

        guard case .concentrationChangeNeedsConfirmation? = result as? TherapyProfileError else {
            return XCTFail("Expected concentrationChangeNeedsConfirmation, got \(String(describing: result))")
        }
        XCTAssertEqual(UserDefaults.standard.activeTherapyProfileID, standard.id)
    }
}
