//
//  SettingsView+algorithmExperimentsSection.swift
//  Loop
//
//  Created by Jonas Björkert on 2023-06-03.
//  Copyright © 2023 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import SwiftUI
import LoopKit
import LoopKitUI

extension SettingsView {
    internal var algorithmExperimentsSection: some View {
        NavigationLink(NSLocalizedString("Algorithm Experiments", comment: "The title of the Algorithm Experiments section in settings")) {
            ExperimentsSettingsView(automaticDosingStrategy: viewModel.automaticDosingStrategy)
                .environmentObject(displayGlucosePreference)
        }
    }
}

public struct ExperimentRow: View {
    var name: String
    var enabled: Bool
    var hint: String? = nil

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                    .foregroundColor(.primary)
                Spacer()
                Text(enabled ? "On" : "Off")
                    .foregroundColor(enabled ? .red : .secondary)
            }
            if let hint {
                Text(hint)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .foregroundColor(.accentColor)
        .cornerRadius(10)
    }
}

public struct ExperimentsSettingsView: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @ObservedObject private var dynamicISFState = DynamicISFState.shared
    @AppStorage(UserDefaults.Key.GlucoseBasedApplicationFactorEnabled.rawValue) private var isGlucoseBasedApplicationFactorEnabled = false
    @AppStorage(UserDefaults.Key.IntegralRetrospectiveCorrectionEnabled.rawValue) private var isIntegralRetrospectiveCorrectionEnabled = false
    @AppStorage(UserDefaults.DynamicISFKey.enabled.rawValue) private var isDynamicISFEnabled = false
    var automaticDosingStrategy: AutomaticDosingStrategy

    public var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 12) {
                Text(NSLocalizedString("Algorithm Experiments", comment: "Navigation title for algorithms experiments screen"))
                    .font(.headline)
                VStack {
                    Text("⚠️").font(.largeTitle)
                    Text("Caution")
                }
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(NSLocalizedString("Algorithm Experiments are optional modifications to the Loop Algorithm. These modifications are less tested than the standard Loop Algorithm, so please use carefully.", comment: "Algorithm Experiments description."))
                    Text(NSLocalizedString("In future versions of Loop these experiments may change, end up as standard parts of the Loop Algorithm, or be removed from Loop entirely. Please follow along in the Loop Zulip chat to stay informed of possible changes to these features.", comment: "Algorithm Experiments description second paragraph."))
                }
                .foregroundColor(.secondary)

                Divider()
                NavigationLink(destination: GlucoseBasedApplicationFactorSelectionView(isGlucoseBasedApplicationFactorEnabled: $isGlucoseBasedApplicationFactorEnabled, automaticDosingStrategy: automaticDosingStrategy)) {
                    ExperimentRow(
                        name: NSLocalizedString("Glucose Based Partial Application", comment: "Title of glucose based partial application experiment"),
                        enabled: isGlucoseBasedApplicationFactorEnabled && automaticDosingStrategy == .automaticBolus)
                }
                NavigationLink(destination: IntegralRetrospectiveCorrectionSelectionView(isIntegralRetrospectiveCorrectionEnabled: $isIntegralRetrospectiveCorrectionEnabled, isDynamicISFEnabled: $isDynamicISFEnabled)) {
                    ExperimentRow(
                        name: NSLocalizedString("Integral Retrospective Correction", comment: "Title of integral retrospective correction experiment"),
                        enabled: isIntegralRetrospectiveCorrectionEnabled,
                        hint: isDynamicISFEnabled ? ExperimentName.exclusionHint(other: ExperimentName.dynamicISF) : nil)
                }
                NavigationLink(destination: DynamicISFSettingsView(isDynamicISFEnabled: $isDynamicISFEnabled, isIntegralRetrospectiveCorrectionEnabled: $isIntegralRetrospectiveCorrectionEnabled)
                    .environmentObject(displayGlucosePreference)) {
                    ExperimentRow(
                        name: ExperimentName.dynamicISF,
                        enabled: isDynamicISFEnabled && !dynamicISFState.isUnavailable,
                        hint: dynamicISFHint)
                }
                Spacer()
            }
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    private var dynamicISFHint: String? {
        if dynamicISFState.isUnavailable {
            return DynamicISFSettingsView.unavailableHint
        }
        if isIntegralRetrospectiveCorrectionEnabled {
            return ExperimentName.exclusionHint(other: ExperimentName.integralRetrospectiveCorrection)
        }
        return nil
    }
}

enum ExperimentName {
    static let dynamicISF = NSLocalizedString("Dynamic ISF", comment: "Title of the dynamic insulin sensitivity experiment")
    static let integralRetrospectiveCorrection = NSLocalizedString("Integral Retrospective Correction", comment: "Title of integral retrospective correction experiment")

    static func exclusionHint(other: String) -> String {
        String(format: NSLocalizedString("Off while %@ is on; they can't be used together.", comment: "Why an algorithm experiment is off (1: the other experiment)"), other)
    }
}

/// For experiments that exclude each other: turning one on while the other is on asks to turn the other off; cancel changes nothing.
struct ExclusiveExperimentToggle: View {
    let title: String
    @Binding var isOn: Bool
    let otherName: String
    @Binding var otherIsOn: Bool

    @State private var isConfirming = false

    var body: some View {
        Toggle(title, isOn: Binding(
            get: { isOn },
            set: { newValue in
                if newValue && otherIsOn {
                    isConfirming = true
                } else {
                    isOn = newValue
                }
            }
        ))
        .confirmationDialog(
            String(format: NSLocalizedString("%@ will be turned off.", comment: "Confirmation title when turning on an algorithm experiment turns the other one off (1: the other experiment)"), otherName),
            isPresented: $isConfirming,
            titleVisibility: .visible
        ) {
            Button(String(format: NSLocalizedString("Turn Off %@", comment: "Button that turns the other algorithm experiment off (1: the other experiment)"), otherName), role: .destructive) {
                otherIsOn = false
                isOn = true
            }
            Button(NSLocalizedString("Cancel", comment: "Cancel button"), role: .cancel) { }
        }
    }
}

extension DynamicISFState {
    /// Dynamic ISF has no divisor for the pump's insulin (Afrezza); unknown until the first loop update.
    var isUnavailable: Bool {
        status.map { DynamicISFCalculator.insulinDivisor(for: $0.insulinType) == nil } ?? false
    }
}

struct DynamicISFSettingsView: View {
    static let unavailableHint = NSLocalizedString("Not available with Afrezza.", comment: "Why dynamic ISF can't be turned on")

    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @ObservedObject private var state = DynamicISFState.shared

    @Binding var isDynamicISFEnabled: Bool
    @Binding var isIntegralRetrospectiveCorrectionEnabled: Bool

    @AppStorage(UserDefaults.DynamicISFKey.formula.rawValue) private var formula = DynamicISFSettings().formula
    @AppStorage(UserDefaults.DynamicISFKey.adjustmentFactor.rawValue) private var adjustmentFactor = DynamicISFSettings().adjustmentFactor
    @AppStorage(UserDefaults.DynamicISFKey.adjustmentFactorSigmoid.rawValue) private var adjustmentFactorSigmoid = DynamicISFSettings().adjustmentFactorSigmoid
    @AppStorage(UserDefaults.DynamicISFKey.minimumRatio.rawValue) private var minimumRatio = DynamicISFSettings().minimumRatio
    @AppStorage(UserDefaults.DynamicISFKey.maximumRatio.rawValue) private var maximumRatio = DynamicISFSettings().maximumRatio
    @AppStorage(UserDefaults.DynamicISFKey.tddWeight.rawValue) private var tddWeight = DynamicISFSettings().tddWeight

    // Steps of 0.05; minimum below 1 and maximum above 1 keep min < 1 < max.
    private static let adjustmentFactorOptions = (6...40).map { Double($0) / 20 }
    private static let adjustmentFactorSigmoidOptions = (2...30).map { Double($0) / 20 }
    private static let minimumRatioOptions = (10...19).map { Double($0) / 20 }
    private static let maximumRatioOptions = (21...40).map { Double($0) / 20 }
    private static let tddWeightOptions = (0...20).map { Double($0) / 20 }

    var body: some View {
        List {
            Section(footer: Text(switchFooter)) {
                ExclusiveExperimentToggle(
                    title: NSLocalizedString("Enable Dynamic ISF", comment: "Title of the dynamic insulin sensitivity switch"),
                    isOn: $isDynamicISFEnabled,
                    otherName: ExperimentName.integralRetrospectiveCorrection,
                    otherIsOn: $isIntegralRetrospectiveCorrectionEnabled
                )
                .disabled(state.isUnavailable && !isDynamicISFEnabled)
            }

            Section(header: Text(NSLocalizedString("Formula", comment: "Header of the dynamic insulin sensitivity formula section")),
                    footer: Text(formulaFooter)) {
                Picker(NSLocalizedString("Formula", comment: "Title of the dynamic insulin sensitivity formula picker"), selection: $formula) {
                    ForEach(DynamicISFFormula.allCases, id: \.self) { formula in
                        Text(Self.name(of: formula)).tag(formula)
                    }
                }
                .pickerStyle(.segmented)
                switch formula {
                case .logarithmic:
                    picker(NSLocalizedString("Adjustment Factor", comment: "Title of the dynamic insulin sensitivity adjustment factor"), $adjustmentFactor, options: Self.adjustmentFactorOptions)
                case .sigmoid:
                    picker(NSLocalizedString("Adjustment Factor", comment: "Title of the dynamic insulin sensitivity adjustment factor"), $adjustmentFactorSigmoid, options: Self.adjustmentFactorSigmoidOptions)
                }
            }

            Section(header: Text(NSLocalizedString("Limits", comment: "Header of the dynamic insulin sensitivity limits section")),
                    footer: Text(NSLocalizedString("The ratio profile ISF / dynamic ISF stays between the minimum and the maximum; a higher ratio means more insulin. Weighted TDD = weight × last 24 hours + (1 − weight) × average of up to 10 days before.", comment: "Footer of the dynamic insulin sensitivity limits section"))) {
                picker(NSLocalizedString("Minimum Ratio", comment: "Title of the dynamic insulin sensitivity minimum ratio"), $minimumRatio, options: Self.minimumRatioOptions)
                picker(NSLocalizedString("Maximum Ratio", comment: "Title of the dynamic insulin sensitivity maximum ratio"), $maximumRatio, options: Self.maximumRatioOptions)
                picker(NSLocalizedString("TDD Weight", comment: "Title of the weight of the last 24 hours in the weighted total daily dose"), $tddWeight, options: Self.tddWeightOptions)
            }

            Section(header: Text(NSLocalizedString("Current", comment: "Header of the current dynamic insulin sensitivity values"))) {
                row(NSLocalizedString("Status", comment: "Title of the dynamic insulin sensitivity status row"), statusText)
                if let status = liveStatus {
                    if let value = status.value {
                        row(NSLocalizedString("ISF", comment: "Title of the current dynamic insulin sensitivity row"), sensitivityText(value))
                        row(NSLocalizedString("Ratio", comment: "Title of the current dynamic ratio row"),
                            String(format: NSLocalizedString("%1$.2f (unlimited %2$.2f)", comment: "Dynamic ratio with the value before the limits (1: ratio, 2: unlimited ratio)"), locale: .current, value.ratio, value.unlimitedRatio))
                    }
                    if let glucose = status.glucose {
                        row(NSLocalizedString("Glucose", comment: "Title of the glucose row of dynamic insulin sensitivity"), displayGlucosePreference.format(HKQuantity(unit: .milligramsPerDeciliter, doubleValue: glucose)))
                    }
                    if let totalDailyDose = status.totalDailyDose {
                        row(NSLocalizedString("TDD 24 h", comment: "Title of the insulin delivered in the last 24 hours"), Self.unitsText(totalDailyDose.lastDay))
                        row(NSLocalizedString("Weighted TDD", comment: "Title of the weighted total daily dose"), Self.unitsText(totalDailyDose.weighted))
                        row(NSLocalizedString("Average TDD", comment: "Title of the average total daily dose"), Self.unitsText(totalDailyDose.average))
                    }
                    row(NSLocalizedString("Updated", comment: "Title of the time of the last dynamic insulin sensitivity update"), status.date.formatted(date: .omitted, time: .shortened))
                }
            }
        }
        .insetGroupedListStyle()
        .navigationTitle(ExperimentName.dynamicISF)
    }

    private var switchFooter: String {
        var text = NSLocalizedString("Dynamic ISF (from Trio) adjusts the insulin sensitivity to the current glucose and the total daily dose (TDD): the higher both are, the lower the sensitivity and the more insulin Loop gives. Below the correction target it never gives more than with the profile's sensitivity. Every past dose and carb entry uses the dynamic ISF of its start time, so the forecast uses it too. Needs complete insulin data for the last 24 hours.", comment: "Description of the dynamic insulin sensitivity experiment")
        if state.isUnavailable {
            text += "\n\n" + Self.unavailableHint
        } else if isIntegralRetrospectiveCorrectionEnabled {
            text += "\n\n" + ExperimentName.exclusionHint(other: ExperimentName.integralRetrospectiveCorrection)
        }
        return text
    }

    private var formulaFooter: String {
        switch formula {
        case .logarithmic:
            return NSLocalizedString("ISF = 1800 / (AF × weighted TDD × ln(glucose / d + 1)), d = 55 for rapid-acting and 70 for ultra-rapid insulin. Default AF 0.8.", comment: "Footer of the logarithmic dynamic insulin sensitivity formula")
        case .sigmoid:
            return NSLocalizedString("Ratio 1 at the correction target, rising with glucose and with weighted TDD above the average TDD; AF sets the slope. Default AF 0.5.", comment: "Footer of the sigmoid dynamic insulin sensitivity formula")
        }
    }

    /// The last loop update's status, unless it predates the current switch positions.
    private var liveStatus: DynamicISFStatus? {
        guard isDynamicISFEnabled,
              let status = state.status,
              status.inactiveReason != .disabled,
              status.inactiveReason != .integralRetrospectiveCorrection || isIntegralRetrospectiveCorrectionEnabled else {
            return nil
        }
        return status
    }

    private var statusText: String {
        guard isDynamicISFEnabled else {
            return NSLocalizedString("Off", comment: "Dynamic insulin sensitivity status when switched off")
        }
        guard let status = liveStatus else {
            return NSLocalizedString("Applies with the next loop update", comment: "Dynamic insulin sensitivity status right after switching on")
        }
        switch status.inactiveReason {
        case nil:
            return NSLocalizedString("Active", comment: "Dynamic insulin sensitivity status when applied")
        case .disabled?:
            return NSLocalizedString("Off", comment: "Dynamic insulin sensitivity status when switched off")
        case .integralRetrospectiveCorrection?:
            return ExperimentName.exclusionHint(other: ExperimentName.integralRetrospectiveCorrection)
        case .unsupportedInsulin?:
            return Self.unavailableHint
        case .invalidRatioLimits?:
            return NSLocalizedString("Minimum ratio must be below the maximum", comment: "Dynamic insulin sensitivity status with invalid limits")
        case .missingTherapySettings?:
            return NSLocalizedString("Insulin sensitivity or correction range missing", comment: "Dynamic insulin sensitivity status without therapy settings")
        case .missingTotalDailyDose?:
            return NSLocalizedString("No complete insulin data for the last 24 hours; using the profile", comment: "Dynamic insulin sensitivity status without total daily dose")
        case .missingGlucose?:
            return NSLocalizedString("No glucose in the last 15 minutes; using the profile", comment: "Dynamic insulin sensitivity status without recent glucose")
        }
    }

    private func sensitivityText(_ value: DynamicISFValue) -> String {
        let formatter = QuantityFormatter(for: displayGlucosePreference.unit)
        let format = { (sensitivity: Double) in
            formatter.string(from: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: sensitivity), includeUnit: false) ?? ""
        }
        let unit = QuantityFormatter(for: displayGlucosePreference.unit.unitDivided(by: .internationalUnit())).localizedUnitStringWithPlurality()
        return String(format: NSLocalizedString("%1$@ (profile %2$@) %3$@", comment: "Dynamic insulin sensitivity with the profile's value and the unit (1: dynamic, 2: profile, 3: unit)"),
                      format(value.sensitivity), format(value.profileSensitivity), unit)
    }

    /// Pump units (per U200 unit with U200, like the profile).
    private static func unitsText(_ units: Double) -> String {
        String(format: NSLocalizedString("%.1f U", comment: "Total daily dose in pump units (1: units)"), locale: .current, units)
    }

    private static func name(of formula: DynamicISFFormula) -> String {
        switch formula {
        case .logarithmic:
            return NSLocalizedString("Logarithmic", comment: "Name of the logarithmic dynamic insulin sensitivity formula")
        case .sigmoid:
            return NSLocalizedString("Sigmoid", comment: "Name of the sigmoid dynamic insulin sensitivity formula")
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func picker(_ title: String, _ value: Binding<Double>, options: [Double]) -> some View {
        let selection = Binding<Double>(
            get: { options.min { abs($0 - value.wrappedValue) < abs($1 - value.wrappedValue) } ?? value.wrappedValue },
            set: { value.wrappedValue = $0 }
        )
        return ExpandableWheelPicker(title: Text(title), selection: selection, options: options) {
            String(format: "%.2f", locale: .current, $0)
        }
    }
}


extension UserDefaults {
    fileprivate enum Key: String {
        case GlucoseBasedApplicationFactorEnabled = "com.loopkit.algorithmExperiments.glucoseBasedApplicationFactorEnabled"
        case IntegralRetrospectiveCorrectionEnabled = "com.loopkit.algorithmExperiments.integralRetrospectiveCorrectionEnabled"
    }

    var glucoseBasedApplicationFactorEnabled: Bool {
        get {
            bool(forKey: Key.GlucoseBasedApplicationFactorEnabled.rawValue) as Bool
        }
        set {
            set(newValue, forKey: Key.GlucoseBasedApplicationFactorEnabled.rawValue)
        }
    }

    var integralRetrospectiveCorrectionEnabled: Bool {
        get {
            bool(forKey: Key.IntegralRetrospectiveCorrectionEnabled.rawValue) as Bool
        }
        set {
            set(newValue, forKey: Key.IntegralRetrospectiveCorrectionEnabled.rawValue)
        }
    }

}
