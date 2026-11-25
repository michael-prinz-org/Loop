//
//  DynamicISFTests.swift
//  LoopTests
//

import XCTest
import HealthKit
import LoopKit
@testable import Loop

final class DynamicISFTests: XCTestCase {
    /// 2023-11-14 00:00:00 UTC
    private let t0 = Date(timeIntervalSince1970: 1_699_920_000)
    private let hour: TimeInterval = 3600
    private let day: TimeInterval = 24 * 3600
    private let accuracy = 1e-9
    private let suiteName = "DynamicISFTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private var utc: Calendar {
        calendar("UTC")
    }

    private func basal(from start: Date, to end: Date, rate: Double, deliveredUnits: Double? = nil) -> DoseEntry {
        DoseEntry(type: .tempBasal, startDate: start, endDate: end, value: rate, unit: .unitsPerHour, deliveredUnits: deliveredUnits)
    }

    private func bolus(at date: Date, units: Double, duration: TimeInterval = 0) -> DoseEntry {
        DoseEntry(type: .bolus, startDate: date, endDate: date.addingTimeInterval(duration), value: units, unit: .units)
    }

    private func total(_ dayOffset: Int, _ internationalUnits: Double) -> DynamicISFDailyTotal {
        DynamicISFDailyTotal(day: t0.addingTimeInterval(Double(dayOffset) * day), internationalUnits: internationalUnits)
    }

    private func assertTotals(_ totals: [DynamicISFDailyTotal], _ expected: [(day: Date, internationalUnits: Double)], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(totals.map { $0.day }, expected.map { $0.day }, file: file, line: line)
        for (actual, wanted) in zip(totals, expected) {
            XCTAssertEqual(actual.internationalUnits, wanted.internationalUnits, accuracy: accuracy, file: file, line: line)
        }
    }

    private var sigmoid: DynamicISFSettings {
        var settings = DynamicISFSettings()
        settings.formula = .sigmoid
        return settings
    }

    /// Correction target 100 mg/dL, scheduled sensitivity 50 mg/dL/U.
    private func value(glucose: Double, weightedTDD: Double = 40, averageTDD: Double = 40, sensitivity: Double = 50, divisor: Double = 55, settings: DynamicISFSettings = DynamicISFSettings()) -> DynamicISFValue? {
        DynamicISFCalculator.value(
            glucose: glucose,
            correctionTarget: 100,
            sensitivity: sensitivity,
            scheduledSensitivity: 50,
            totalDailyDose: DynamicISFTotalDailyDose(lastDay: weightedTDD, weighted: weightedTDD, average: averageTDD),
            divisor: divisor,
            settings: settings
        )
    }

    private func assertValue(_ value: DynamicISFValue?, ratio: Double, unlimitedRatio: Double, sensitivity: Double, profileSensitivity: Double = 50, file: StaticString = #filePath, line: UInt = #line) {
        guard let value else {
            XCTFail("Expected a value", file: file, line: line)
            return
        }
        XCTAssertEqual(value.ratio, ratio, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(value.unlimitedRatio, unlimitedRatio, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(value.sensitivity, sensitivity, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(value.profileSensitivity, profileSensitivity, accuracy: accuracy, file: file, line: line)
    }

    // MARK: Settings

    func testSettingsDefaults() {
        let settings = defaults.dynamicISFSettings
        XCTAssertEqual(settings, DynamicISFSettings())
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.formula, .logarithmic)
        XCTAssertEqual(settings.adjustmentFactor, 0.8)
        XCTAssertEqual(settings.adjustmentFactorSigmoid, 0.5)
        XCTAssertEqual(settings.minimumRatio, 0.7)
        XCTAssertEqual(settings.maximumRatio, 1.2)
        XCTAssertEqual(settings.tddWeight, 0.65)
    }

    func testSettingsReadStoredValues() {
        defaults.set(true, forKey: UserDefaults.DynamicISFKey.enabled.rawValue)
        defaults.set(DynamicISFFormula.sigmoid.rawValue, forKey: UserDefaults.DynamicISFKey.formula.rawValue)
        defaults.set(0.9, forKey: UserDefaults.DynamicISFKey.adjustmentFactor.rawValue)
        defaults.set(0.4, forKey: UserDefaults.DynamicISFKey.adjustmentFactorSigmoid.rawValue)
        defaults.set(0.8, forKey: UserDefaults.DynamicISFKey.minimumRatio.rawValue)
        defaults.set(1.5, forKey: UserDefaults.DynamicISFKey.maximumRatio.rawValue)
        defaults.set(0.5, forKey: UserDefaults.DynamicISFKey.tddWeight.rawValue)

        XCTAssertEqual(defaults.dynamicISFSettings, DynamicISFSettings(isEnabled: true, formula: .sigmoid, adjustmentFactor: 0.9, adjustmentFactorSigmoid: 0.4, minimumRatio: 0.8, maximumRatio: 1.5, tddWeight: 0.5))
    }

    // MARK: Configuration

    private func configuration(irc: Bool = false, insulinType: InsulinType? = .novolog, _ change: (inout DynamicISFSettings) -> Void = { _ in }) -> DynamicISFConfiguration {
        var settings = DynamicISFSettings()
        settings.isEnabled = true
        change(&settings)
        return DynamicISFConfiguration(settings: settings, integralRetrospectiveCorrectionEnabled: irc, insulinType: insulinType)
    }

    func testInactiveReasons() {
        XCTAssertEqual(configuration { $0.isEnabled = false }.inactiveReason, .disabled)
        XCTAssertEqual(configuration(irc: true).inactiveReason, .integralRetrospectiveCorrection)
        XCTAssertEqual(configuration(insulinType: .afrezza).inactiveReason, .unsupportedInsulin)
        XCTAssertEqual(configuration { $0.minimumRatio = 1.2 }.inactiveReason, .invalidRatioLimits)
        XCTAssertEqual(configuration { $0.minimumRatio = 1.3; $0.maximumRatio = 0.7 }.inactiveReason, .invalidRatioLimits)
    }

    func testActiveConfigurations() {
        XCTAssertNil(configuration().inactiveReason)
        XCTAssertNil(configuration(insulinType: .fiasp).inactiveReason)
        XCTAssertNil(configuration(insulinType: nil).inactiveReason)
    }

    // MARK: Divisor

    func testDivisorPerInsulinType() {
        XCTAssertEqual(DynamicISFCalculator.insulinDivisor(for: .novolog), 55)
        XCTAssertEqual(DynamicISFCalculator.insulinDivisor(for: .humalog), 55)
        XCTAssertEqual(DynamicISFCalculator.insulinDivisor(for: .apidra), 55)
        XCTAssertEqual(DynamicISFCalculator.insulinDivisor(for: nil), 55)
        XCTAssertEqual(DynamicISFCalculator.insulinDivisor(for: .fiasp), 70)
        XCTAssertEqual(DynamicISFCalculator.insulinDivisor(for: .lyumjev), 70)
        XCTAssertNil(DynamicISFCalculator.insulinDivisor(for: .afrezza))
    }

    // MARK: Logarithmic

    func testLogarithmicMatchesHandCalculation() {
        // 50 × 0.8 × 40 × ln(110 / 55 + 1) / 1800 = 1600 × ln 3 / 1800
        assertValue(value(glucose: 110), ratio: 0.976544256593875, unlimitedRatio: 0.976544256593875, sensitivity: 51.2009564977596)
    }

    func testLogarithmicUsesUltraRapidDivisor() {
        // 1600 × ln(110 / 70 + 1) / 1800
        assertValue(value(glucose: 110, divisor: 70), ratio: 0.839521430080757, unlimitedRatio: 0.839521430080757, sensitivity: 50 / 0.839521430080757)
    }

    func testLogarithmicIgnoresAverageTDD() {
        XCTAssertEqual(value(glucose: 110, averageTDD: 10), value(glucose: 110))
    }

    func testLogarithmicClampsToMaximumRatio() {
        // 1600 × ln(300 / 55 + 1) / 1800
        assertValue(value(glucose: 300), ratio: 1.2, unlimitedRatio: 1.65758631488262, sensitivity: 50 / 1.2)
    }

    func testLogarithmicClampsToMinimumRatio() {
        // 50 × 0.8 × 20 × ln(150 / 55 + 1) / 1800
        assertValue(value(glucose: 150, weightedTDD: 20), ratio: 0.7, unlimitedRatio: 0.584745241735972, sensitivity: 50 / 0.7)
    }

    func testCustomRatioLimits() {
        var settings = DynamicISFSettings()
        settings.minimumRatio = 0.9
        settings.maximumRatio = 1.1
        XCTAssertEqual(value(glucose: 300, settings: settings)?.ratio ?? 0, 1.1, accuracy: accuracy)
        XCTAssertEqual(value(glucose: 150, weightedTDD: 20, settings: settings)?.ratio ?? 0, 0.9, accuracy: accuracy)
    }

    // MARK: Sigmoid

    func testSigmoidRatioIsOneAtTarget() {
        assertValue(value(glucose: 100, settings: sigmoid), ratio: 1, unlimitedRatio: 1, sensitivity: 50)
        assertValue(value(glucose: 100, weightedTDD: 60, averageTDD: 40, settings: sigmoid), ratio: 1, unlimitedRatio: 1, sensitivity: 50)
    }

    func testSigmoidMatchesHandCalculation() {
        // offset = ln((1 − 0.7) / (1.2 − 1)) = ln 1.5; exponent = (200 − 100) × 0.0555 × 0.5 + ln 1.5; ratio = 0.5 / (1 + e^−exponent) + 0.7
        assertValue(value(glucose: 200, settings: sigmoid), ratio: 1.18004624521596, unlimitedRatio: 1.18004624521596, sensitivity: 50 / 1.18004624521596)
        // exponent = 20 × 0.0555 × 0.5 + ln 1.5
        assertValue(value(glucose: 120, settings: sigmoid), ratio: 1.06160745892593, unlimitedRatio: 1.06160745892593, sensitivity: 50 / 1.06160745892593)
    }

    func testSigmoidScalesWithTDDFactor() {
        // tddFactor = 60 / 40; exponent = 100 × 0.0555 × 0.5 × 1.5 + ln 1.5
        assertValue(value(glucose: 200, weightedTDD: 60, averageTDD: 40, settings: sigmoid), ratio: 1.19486377987643, unlimitedRatio: 1.19486377987643, sensitivity: 50 / 1.19486377987643)
    }

    func testSigmoidWithoutAverageTDDUsesFactorOne() {
        XCTAssertEqual(value(glucose: 200, weightedTDD: 60, averageTDD: 0, settings: sigmoid)?.ratio ?? 0, 1.18004624521596, accuracy: accuracy)
    }

    func testSigmoidIgnoresProfileSensitivity() {
        XCTAssertEqual(value(glucose: 200, sensitivity: 25, settings: sigmoid)?.ratio ?? 0, 1.18004624521596, accuracy: accuracy)
    }

    func testSigmoidWithMaximumRatioOneStaysFinite() {
        var settings = sigmoid
        settings.maximumRatio = 1
        // max − 1 is replaced by 0.01: offset = ln(0.3 / 0.01); ratio = 0.3 / (1 + e^−offset) + 0.7
        assertValue(value(glucose: 100, settings: settings), ratio: 0.990322580645161, unlimitedRatio: 0.990322580645161, sensitivity: 50 / 0.990322580645161)
        XCTAssertEqual(value(glucose: 400, settings: settings)?.ratio ?? 0, 1, accuracy: 1e-4)
    }

    // MARK: Hypo guard

    func testHypoGuardRaisesRatioToOneBelowTarget() {
        // 1600 × ln(80 / 55 + 1) / 1800
        assertValue(value(glucose: 80), ratio: 1, unlimitedRatio: 0.798170305071963, sensitivity: 50)
        // ln 1.5 − 30 × 0.0555 × 0.5
        assertValue(value(glucose: 70, settings: sigmoid), ratio: 1, unlimitedRatio: 0.897417296914646, sensitivity: 50)
    }

    func testHypoGuardKeepsHigherRatio() {
        // 50 × 0.8 × 60 × ln(80 / 55 + 1) / 1800
        assertValue(value(glucose: 80, weightedTDD: 60), ratio: 1.19725545760794, unlimitedRatio: 1.19725545760794, sensitivity: 50 / 1.19725545760794)
    }

    // MARK: Overrides and guards

    func testOverrideScalesDynamicSensitivity() {
        // The ratio comes from the scheduled 50 mg/dL/U; the override's 25 mg/dL/U is divided by it.
        assertValue(value(glucose: 110, sensitivity: 25), ratio: 0.976544256593875, unlimitedRatio: 0.976544256593875, sensitivity: 25.6004782488798, profileSensitivity: 25)
    }

    func testInvalidInputsHaveNoValue() {
        XCTAssertNil(value(glucose: 0))
        XCTAssertNil(value(glucose: -10))
        XCTAssertNil(value(glucose: 110, weightedTDD: 0))
        XCTAssertNil(value(glucose: 110, weightedTDD: 0, settings: sigmoid))
    }

    // MARK: Insulin history

    func testDeliveredSumsBolusesAndProRataBasal() {
        let history = DynamicISFInsulinHistory(doses: [
            basal(from: t0, to: t0 + day, rate: 1),
            bolus(at: t0 + 6 * hour, units: 2),
            bolus(at: t0 + day, units: 3)
        ], fetchStart: t0)

        XCTAssertEqual(history.delivered(from: t0, to: t0 + day) ?? 0, 26, accuracy: accuracy)
        XCTAssertEqual(history.delivered(from: t0 + 12 * hour, to: t0 + 18 * hour) ?? 0, 6, accuracy: accuracy)
        XCTAssertEqual(history.delivered(from: t0 + 5 * hour, to: t0 + 7 * hour) ?? 0, 4, accuracy: accuracy)
        // A bolus counts from its start date on.
        XCTAssertEqual(history.delivered(from: t0 + 6 * hour, to: t0 + 6 * hour + 1) ?? 0, 2, accuracy: 1e-3)
        XCTAssertEqual(history.delivered(from: t0 + day, to: t0 + day + 1) ?? 0, 3, accuracy: accuracy)
    }

    func testDeliveredCountsOverlappingDosesProRata() {
        let history = DynamicISFInsulinHistory(doses: [
            basal(from: t0, to: t0 + day, rate: 1),
            bolus(at: t0 + 10 * hour, units: 2, duration: hour)
        ], fetchStart: t0)

        XCTAssertEqual(history.delivered(from: t0 + 10 * hour, to: t0 + 10.5 * hour) ?? 0, 1.5, accuracy: accuracy)
        XCTAssertEqual(history.delivered(from: t0 + 10.5 * hour, to: t0 + 12 * hour) ?? 0, 2.5, accuracy: accuracy)
    }

    func testDeliveredMatchesTrimmedDoses() {
        var doses: [DoseEntry] = []
        for index in 0..<(36 * 12) {
            let start = t0 + Double(index) * 5 * 60
            let rate = Double(index % 7) * 0.35
            doses.append(basal(from: start, to: start + 5 * 60, rate: rate, deliveredUnits: rate / 12))
            if index % 29 == 0 {
                doses.append(bolus(at: start + 90, units: Double(index % 5) + 0.5, duration: 120))
            }
        }
        // Delivered units keep `trimmed` from rounding to pump increments, which the pro rata totals don't do.
        doses.append(basal(from: t0 + 3 * hour, to: t0 + 15 * hour, rate: 0.6, deliveredUnits: 7.2))
        let history = DynamicISFInsulinHistory(doses: doses.shuffled(), fetchStart: t0)

        for (start, end) in [(t0, t0 + 36 * hour), (t0 + 3 * hour + 17 * 60, t0 + 20 * hour + 43 * 60), (t0 + 7, t0 + 5 * 60 + 13), (t0 + 30 * hour, t0 + 40 * hour)] {
            let expected = doses.reduce(0.0) { total, dose in
                guard dose.startDate < end, dose.endDate > start || (dose.endDate == dose.startDate && dose.startDate >= start) else {
                    return total
                }
                return total + dose.trimmed(from: start, to: end).unitsInDeliverableIncrements
            }
            XCTAssertEqual(history.delivered(from: start, to: end) ?? -1, expected, accuracy: 1e-9)
        }
    }

    func testDeliveredIgnoresSuspendAndResume() {
        let history = DynamicISFInsulinHistory(doses: [
            DoseEntry(suspendDate: t0),
            DoseEntry(resumeDate: t0 + hour),
            basal(from: t0 + hour, to: t0 + day, rate: 1)
        ], fetchStart: t0)

        XCTAssertEqual(history.doses.count, 1)
        XCTAssertEqual(history.delivered(from: t0, to: t0 + day) ?? 0, 23, accuracy: accuracy)
    }

    func testDeliveredNeedsDataCoveringStart() {
        let history = DynamicISFInsulinHistory(doses: [basal(from: t0 + 2 * hour, to: t0 + day, rate: 1)], fetchStart: t0)

        XCTAssertNil(history.delivered(from: t0, to: t0 + day))
        XCTAssertEqual(history.delivered(from: t0 + 1.5 * hour, to: t0 + 4 * hour) ?? 0, 2, accuracy: accuracy)
    }

    func testDataStartingWithinToleranceIsComplete() {
        let history = DynamicISFInsulinHistory(doses: [basal(from: t0 + hour, to: t0 + day, rate: 1)], fetchStart: t0)

        XCTAssertEqual(history.delivered(from: t0, to: t0 + day) ?? 0, 23, accuracy: accuracy)
    }

    func testDataBeforeFetchStartDoesNotCount() {
        let history = DynamicISFInsulinHistory(doses: [basal(from: t0 - day, to: t0 + day, rate: 1)], fetchStart: t0)

        XCTAssertEqual(history.dataStart, t0)
        XCTAssertNil(history.delivered(from: t0 - 2 * hour, to: t0))
    }

    func testEmptyHistoryHasNoData() {
        let history = DynamicISFInsulinHistory(doses: [], fetchStart: t0)

        XCTAssertNil(history.delivered(from: t0, to: t0 + hour))
        XCTAssertEqual(history.dailyTotals(before: t0 + 2 * day, unitsPerPumpUnit: 1, calendar: utc), [])
    }

    // MARK: Daily totals

    func testBackfillSkipsIncompleteFirstDayAndToday() {
        let fetchStart = t0 - 7 * day + 10 * hour
        let now = t0 + 15 * hour
        let history = DynamicISFInsulinHistory(doses: [basal(from: fetchStart, to: now, rate: 1)], fetchStart: fetchStart)

        assertTotals(history.dailyTotals(before: now, unitsPerPumpUnit: 1, calendar: utc), (1...6).reversed().map { (day: t0 - Double($0) * day, internationalUnits: 24.0) })
    }

    func testDailyTotalsAreInternationalUnits() {
        let history = DynamicISFInsulinHistory(doses: [basal(from: t0 - 2 * day, to: t0, rate: 0.5)], fetchStart: t0 - 2 * day)

        assertTotals(history.dailyTotals(before: t0 + hour, unitsPerPumpUnit: 2, calendar: utc), [(t0 - 2 * day, 24), (t0 - day, 24)])
    }

    func testDailyTotalsFollowDaylightSavingTime() {
        let berlin = calendar("Europe/Berlin")
        let date = { (month: Int, day: Int, hour: Int) in berlin.date(from: DateComponents(year: 2023, month: month, day: day, hour: hour))! }

        let autumn = DynamicISFInsulinHistory(doses: [basal(from: date(10, 27, 0), to: date(10, 31, 0), rate: 1)], fetchStart: date(10, 27, 0))
        assertTotals(autumn.dailyTotals(before: date(10, 31, 12), unitsPerPumpUnit: 1, calendar: berlin), [
            (date(10, 27, 0), 24), (date(10, 28, 0), 24), (date(10, 29, 0), 25), (date(10, 30, 0), 24)
        ])

        let spring = DynamicISFInsulinHistory(doses: [basal(from: date(3, 25, 0), to: date(3, 28, 0), rate: 1)], fetchStart: date(3, 25, 0))
        assertTotals(spring.dailyTotals(before: date(3, 28, 12), unitsPerPumpUnit: 1, calendar: berlin), [
            (date(3, 25, 0), 24), (date(3, 26, 0), 23), (date(3, 27, 0), 24)
        ])
    }

    // MARK: TDD

    private func totalDailyDose(at date: Date, history: DynamicISFInsulinHistory, dailyTotals: [DynamicISFDailyTotal] = [], unitsPerPumpUnit: Double = 1, weight: Double = 0.65, calendar: Calendar? = nil) -> DynamicISFTotalDailyDose? {
        DynamicISFDailyTotalsStore.totalDailyDose(at: date, history: history, dailyTotals: dailyTotals, unitsPerPumpUnit: unitsPerPumpUnit, weight: weight, calendar: calendar ?? utc)
    }

    private func assertTDD(_ tdd: DynamicISFTotalDailyDose?, lastDay: Double, weighted: Double, average: Double, file: StaticString = #filePath, line: UInt = #line) {
        guard let tdd else {
            XCTFail("Expected a TDD", file: file, line: line)
            return
        }
        XCTAssertEqual(tdd.lastDay, lastDay, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(tdd.weighted, weighted, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(tdd.average, average, accuracy: accuracy, file: file, line: line)
    }

    func testTDDNeedsComplete24Hours() {
        let date = t0 + 12 * hour
        let history = DynamicISFInsulinHistory(doses: [basal(from: date - 20 * hour, to: date, rate: 1)], fetchStart: date - 20 * hour)

        XCTAssertNil(totalDailyDose(at: date, history: history, dailyTotals: [total(-1, 30)]))
    }

    func testTDDWithoutDeliveryIsNil() {
        let date = t0 + 12 * hour
        let history = DynamicISFInsulinHistory(doses: [basal(from: date - day, to: date, rate: 0)], fetchStart: date - day)

        XCTAssertNil(totalDailyDose(at: date, history: history, dailyTotals: [total(-1, 30)]))
    }

    func testWeightedTDD() {
        let date = t0 + 12 * hour
        let history = DynamicISFInsulinHistory(doses: [basal(from: date - day, to: date, rate: 1)], fetchStart: date - day)

        // 0.65 × 24 + 0.35 × (30 + 20) / 2
        assertTDD(totalDailyDose(at: date, history: history, dailyTotals: [total(-2, 20), total(-1, 30)]), lastDay: 24, weighted: 24.35, average: 25)
        assertTDD(totalDailyDose(at: date, history: history, dailyTotals: [total(-2, 20), total(-1, 30)], weight: 1), lastDay: 24, weighted: 24, average: 25)
        assertTDD(totalDailyDose(at: date, history: history, dailyTotals: [total(-2, 20), total(-1, 30)], weight: 0), lastDay: 24, weighted: 25, average: 25)
    }

    func testTDDWithoutEarlierDaysUsesLastDay() {
        let date = t0 + 12 * hour
        let history = DynamicISFInsulinHistory(doses: [basal(from: date - day, to: date, rate: 1)], fetchStart: date - day)

        assertTDD(totalDailyDose(at: date, history: history), lastDay: 24, weighted: 24, average: 24)
    }

    func testTDDAveragesTenAndFourteenFullDays() {
        let date = t0 + 12 * hour
        let history = DynamicISFInsulinHistory(doses: [basal(from: date - day, to: date, rate: 1)], fetchStart: date - day)
        // k IU k days back; today's and the 15th day's totals are outside both windows.
        let dailyTotals = (1...15).map { total(-$0, Double($0)) } + [total(0, 100)]

        // 0.65 × 24 + 0.35 × mean(1...10); average = mean(1...14)
        assertTDD(totalDailyDose(at: date, history: history, dailyTotals: dailyTotals), lastDay: 24, weighted: 17.525, average: 7.5)
    }

    func testTDDDayBoundary() {
        let history = DynamicISFInsulinHistory(doses: [basal(from: t0 - 2 * day, to: t0 + hour, rate: 1)], fetchStart: t0 - 2 * day)
        let dailyTotals = [total(-2, 10), total(-1, 30)]

        // At midnight yesterday is a full earlier day ...
        assertTDD(totalDailyDose(at: t0, history: history, dailyTotals: dailyTotals), lastDay: 24, weighted: 0.65 * 24 + 0.35 * 20, average: 20)
        // ... a second before it is still today.
        assertTDD(totalDailyDose(at: t0 - 1, history: history, dailyTotals: dailyTotals), lastDay: 24, weighted: 0.65 * 24 + 0.35 * 10, average: 10)
    }

    func testTDDConvertsStoredInternationalUnitsToCurrentPumpUnits() {
        let date = t0 + 12 * hour
        // U200: 0.5 pump units/h for 24 h; the earlier days were stored as 40 IU each (e.g. while U100 was in use).
        let history = DynamicISFInsulinHistory(doses: [basal(from: date - day, to: date, rate: 0.5)], fetchStart: date - day)

        assertTDD(totalDailyDose(at: date, history: history, dailyTotals: [total(-2, 40), total(-1, 40)], unitsPerPumpUnit: 2), lastDay: 12, weighted: 0.65 * 12 + 0.35 * 20, average: 20)
    }

    func testTDDAcrossDaylightSavingTimeUses24Hours() {
        let berlin = calendar("Europe/Berlin")
        let date = berlin.date(from: DateComponents(year: 2023, month: 10, day: 29, hour: 12))!
        let history = DynamicISFInsulinHistory(doses: [basal(from: date - 2 * day, to: date, rate: 1)], fetchStart: date - 2 * day)
        let yesterday = berlin.date(from: DateComponents(year: 2023, month: 10, day: 28))!

        assertTDD(totalDailyDose(at: date, history: history, dailyTotals: [DynamicISFDailyTotal(day: yesterday, internationalUnits: 30)], calendar: berlin), lastDay: 24, weighted: 0.65 * 24 + 0.35 * 30, average: 30)
    }

    // MARK: Store

    func testStoreKeepsFourteenDaysSorted() {
        let store = DynamicISFDailyTotalsStore(defaults: nil)
        let now = t0 + 12 * hour

        store.store((1...20).map { total(-$0, Double($0)) }, now: now, calendar: utc)

        XCTAssertEqual(store.totals, (1...14).reversed().map { total(-$0, Double($0)) })
    }

    func testStoreReplacesStoredDays() {
        let store = DynamicISFDailyTotalsStore(defaults: nil)
        let now = t0 + 12 * hour

        store.store([total(-2, 20), total(-1, 30)], now: now, calendar: utc)
        store.store([total(-1, 32)], now: now, calendar: utc)

        XCTAssertEqual(store.totals, [total(-2, 20), total(-1, 32)])
    }

    func testNeedsUpdateUntilYesterdayIsStored() {
        let store = DynamicISFDailyTotalsStore(defaults: nil)
        let now = t0 + 12 * hour

        XCTAssertTrue(store.needsUpdate(now: now, calendar: utc))
        store.store([total(-2, 20)], now: now, calendar: utc)
        XCTAssertTrue(store.needsUpdate(now: now, calendar: utc))
        store.store([total(-1, 30)], now: now, calendar: utc)
        XCTAssertFalse(store.needsUpdate(now: now, calendar: utc))
        XCTAssertTrue(store.needsUpdate(now: now + day, calendar: utc))
    }

    func testBackfillFillsStore() {
        let store = DynamicISFDailyTotalsStore(defaults: nil)
        let now = t0 + 15 * hour
        let fetchStart = now - 14 * day
        // Local dose history only covers 7 days.
        let history = DynamicISFInsulinHistory(doses: [basal(from: now - 7 * day, to: now, rate: 1)], fetchStart: fetchStart)

        store.store(history.dailyTotals(before: now, unitsPerPumpUnit: 1, calendar: utc), now: now, calendar: utc)

        XCTAssertEqual(store.totals.map { $0.day }, (1...6).reversed().map { t0 - Double($0) * day })
        XCTAssertFalse(store.needsUpdate(now: now, calendar: utc))
    }

    func testStorePersistsInUserDefaults() {
        let now = t0 + 12 * hour
        DynamicISFDailyTotalsStore(defaults: defaults).store([total(-2, 20), total(-1, 30.5)], now: now, calendar: utc)

        XCTAssertEqual(DynamicISFDailyTotalsStore(defaults: defaults).totals, [total(-2, 20), total(-1, 30.5)])
    }

    func testStoreWithoutDefaultsKeepsTotalsInMemory() {
        let now = t0 + 12 * hour
        let store = DynamicISFDailyTotalsStore(defaults: nil)
        store.store([total(-1, 30)], now: now, calendar: utc)

        XCTAssertEqual(store.totals, [total(-1, 30)])
        XCTAssertEqual(DynamicISFDailyTotalsStore(defaults: nil).totals, [])
    }

    // MARK: Context

    /// Profile 50 mg/dL/U, target 100 mg/dL, weighted TDD 40 U, logarithmic with divisor 55.
    private func makeContext(glucose: [(date: Date, value: Double)], doses: [DoseEntry] = [], referenceDate: Date) -> DynamicISFContext {
        let sensitivity = InsulinSensitivitySchedule(unit: .milligramsPerDeciliter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: 50)], timeZone: .utcTimeZone)!
        return DynamicISFContext(
            referenceDate: referenceDate,
            settings: DynamicISFSettings(),
            divisor: 55,
            history: DynamicISFInsulinHistory(doses: doses, fetchStart: referenceDate - 2 * day),
            glucose: glucose,
            sensitivitySchedule: sensitivity,
            scheduledSensitivitySchedule: sensitivity,
            correctionRange: GlucoseRangeSchedule(unit: .milligramsPerDeciliter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: DoubleRange(minValue: 100, maxValue: 100))], timeZone: .utcTimeZone)!,
            totalDailyDose: { _ in DynamicISFTotalDailyDose(lastDay: 40, weighted: 40, average: 40) }
        )
    }

    func testContextUsesGlucoseAtMostFifteenMinutesOld() {
        let context = makeContext(glucose: [(t0, 110)], referenceDate: t0 + hour)

        XCTAssertNil(context.latestGlucose(at: t0 - 1))
        XCTAssertEqual(context.latestGlucose(at: t0 + 15 * 60), 110)
        XCTAssertNil(context.latestGlucose(at: t0 + 15 * 60 + 1))
        XCTAssertEqual(context.sensitivity(at: t0 + 5 * 60), 51.2009564977596, accuracy: 1e-6)
        XCTAssertEqual(context.sensitivity(at: t0 + 20 * 60), 50)
    }

    func testContextUsesReferenceDateForLaterDates() {
        let context = makeContext(glucose: [(t0, 110)], referenceDate: t0 + 5 * 60)

        XCTAssertEqual(context.carbEntrySensitivity(at: t0 + hour)?.doubleValue(for: .milligramsPerDeciliter) ?? 0, 51.2009564977596, accuracy: 1e-6)
    }

    func testContextUsesManualGlucose() {
        let context = makeContext(glucose: [(t0, 110)], referenceDate: t0)

        XCTAssertEqual(context.value(at: t0, glucose: 300)?.ratio ?? 0, 1.2, accuracy: accuracy)
    }

    func testContextInsulinEffectsUseEachDoseSensitivity() {
        let doses = [bolus(at: t0, units: 1), bolus(at: t0 + hour, units: 1)]
        let context = makeContext(glucose: [(t0 - 5 * 60, 110), (t0 + 55 * 60, 300)], doses: doses, referenceDate: t0 + 2 * hour)
        let model = ExponentialInsulinModelPreset.rapidActingAdult

        let effects = context.insulinEffects(start: t0, basalDosingEnd: nil, insulinModelProvider: StaticInsulinModelProvider(model), longestEffectDuration: model.effectDuration)

        // Fully absorbed: 1 U × 51.20 (BG 110) + 1 U × 50 / 1.2 (BG 300, maximum ratio)
        XCTAssertEqual(effects.last?.quantity.doubleValue(for: .milligramsPerDeciliter) ?? 0, -(51.2009564977596 + 50 / 1.2), accuracy: 1e-6)
    }

    func testDosingScheduleIsConstantInProfileUnit() {
        let context = makeContext(glucose: [(t0, 110)], referenceDate: t0)
        let profile = InsulinSensitivitySchedule(unit: .millimolesPerLiter, dailyItems: [RepeatingScheduleValue(startTime: 0, value: 2.8), RepeatingScheduleValue(startTime: 12 * hour, value: 3.5)], timeZone: .utcTimeZone)!

        let dosing = context.dosingSchedule(profile, at: t0, glucose: nil)

        let expected = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 51.2009564977596).doubleValue(for: .millimolesPerLiter)
        XCTAssertEqual(dosing?.schedule.unit, .millimolesPerLiter)
        XCTAssertEqual(dosing?.schedule.items.count, 1)
        XCTAssertEqual(dosing?.schedule.value(at: t0 + 13 * hour) ?? 0, expected, accuracy: 1e-6)
    }
}
