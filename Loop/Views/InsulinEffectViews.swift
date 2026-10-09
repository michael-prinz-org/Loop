//
//  InsulinEffectViews.swift
//  Loop
//
//  Detail and settings screens for the insulin effect monitor.
//

import SwiftUI
import HealthKit
import LoopCore
import LoopKit
import LoopKitUI

extension InsulinEffectLevel {
    func title(isEnabled: Bool) -> String {
        switch self {
        case .unknown:
            return isEnabled
                ? NSLocalizedString("Not available", comment: "Insulin effect status when there is not enough current data")
                : NSLocalizedString("Off", comment: "Insulin effect status when the monitor is turned off")
        case .normal:
            return NSLocalizedString("As expected", comment: "Insulin effect status when glucose behaves as expected")
        case .watch:
            return NSLocalizedString("Watch: rising faster than expected", comment: "Insulin effect status, first warning level")
        case .attention:
            return NSLocalizedString("Attention: insulin seems not to work", comment: "Insulin effect status, highest warning level")
        }
    }

    var color: UIColor {
        switch self {
        case .unknown: return .secondaryLabel
        case .normal: return .systemGreen
        case .watch: return .systemOrange
        case .attention: return .systemRed
        }
    }

    var symbolName: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .normal: return "checkmark.circle.fill"
        case .watch: return "exclamationmark.triangle.fill"
        case .attention: return "exclamationmark.octagon.fill"
        }
    }
}

struct InsulinEffectDetailView: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @Environment(\.dismissAction) private var dismiss

    let assessment: InsulinEffectAssessment

    var body: some View {
        NavigationView {
            List {
                Section(footer: Text(NSLocalizedString("Compares how glucose actually moves with what Loop expects from active insulin and carbs. It cannot tell missing insulin apart from more or faster carbs than entered. Display only; dosing is not changed.", comment: "Footer of the insulin effect detail screen"))) {
                    HStack(spacing: 12) {
                        Image(systemName: assessment.level.symbolName)
                            .font(.title2)
                            .foregroundColor(Color(assessment.level.color))
                        Text(assessment.level.title(isEnabled: UserDefaults.standard.insulinEffectMonitorSettings.isEnabled))
                            .font(.headline)
                    }
                    .padding(.vertical, 4)
                }

                if assessment.level.isWarning {
                    Section(header: Text(NSLocalizedString("What to check", comment: "Header of the insulin effect check list"))) {
                        Text(NSLocalizedString("Were the carbs entered correctly (amount and absorption time)?", comment: "Insulin effect check list item"))
                        Text(NSLocalizedString("Pod or site: wet, insulin smell, pain or redness?", comment: "Insulin effect check list item"))
                        Text(NSLocalizedString("Measure ketones if glucose stays high.", comment: "Insulin effect check list item"))
                        Text(NSLocalizedString("If in doubt, correct with a pen and replace the pod.", comment: "Insulin effect check list item"))
                    }
                }

                if assessment.level != .unknown {
                    Section(header: Text(NSLocalizedString("Measurements", comment: "Header of the insulin effect measurements"))) {
                        valueRow(NSLocalizedString("Glucose", comment: "Insulin effect measurement label"), glucose(assessment.glucose))
                        valueRow(NSLocalizedString("Sensor rise", comment: "Insulin effect measurement label"), rate(assessment.riseRate), signal: .fastRise)
                        valueRow(NSLocalizedString("Rise not explained by insulin", comment: "Insulin effect measurement label"), rate(assessment.counteractionRate), signal: .unexplainedRise)
                        valueRow(NSLocalizedString("Allowed for carbs", comment: "Insulin effect measurement label"), rate(assessment.carbAllowanceRate))
                        valueRow(NSLocalizedString("Above forecast (30 min)", comment: "Insulin effect measurement label"), glucose(assessment.discrepancy), signal: .aboveForecast)
                        valueRow(NSLocalizedString("Change in the last hour", comment: "Insulin effect measurement label"), glucose(assessment.hourChange), signal: .correctionNotWorking)
                        valueRow(NSLocalizedString("Active insulin", comment: "Insulin effect measurement label"), assessment.insulinOnBoard.map { String(format: "%.1f U", $0) } ?? "–")
                        valueRow(NSLocalizedString("Active carbs", comment: "Insulin effect measurement label"), assessment.carbsOnBoard.map { String(format: "%.0f g", $0) } ?? "–")
                    }
                }

                Section {
                    NavigationLink(destination: InsulinEffectMonitorSettingsView()) {
                        Text(NSLocalizedString("Settings", comment: "Link to the insulin effect monitor settings"))
                    }
                }
            }
            .insetGroupedListStyle()
            .navigationTitle(NSLocalizedString("Insulin Effect", comment: "Title of the insulin effect screens and status row"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(NSLocalizedString("Done", comment: "Button that closes the insulin effect screen"), action: dismiss)
                }
            }
        }
    }

    private func valueRow(_ title: String, _ value: String, signal: InsulinEffectAssessment.Signal? = nil) -> some View {
        let isActive = signal.map { assessment.signals.contains($0) } ?? false
        return HStack {
            Text(title)
            Spacer()
            if isActive {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(Color(assessment.level.color))
            }
            Text(value)
                .foregroundColor(isActive ? Color(assessment.level.color) : .secondary)
        }
    }

    private func glucose(_ milligramsPerDeciliter: Double?) -> String {
        guard let value = milligramsPerDeciliter else { return "–" }
        return displayGlucosePreference.format(HKQuantity(unit: .milligramsPerDeciliter, doubleValue: value))
    }

    private func rate(_ milligramsPerDeciliterPerMinute: Double?) -> String {
        guard let value = milligramsPerDeciliterPerMinute else { return "–" }
        return InsulinEffectMonitorSettingsView.rateLabel(value, unit: displayGlucosePreference.unit)
    }
}

struct InsulinEffectMonitorSettingsView: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @State private var settings = UserDefaults.standard.insulinEffectMonitorSettings

    var body: some View {
        List {
            Section(footer: Text(NSLocalizedString("Shows on the main screen and on the watch (\"!\") when glucose rises although insulin should lower it, e.g. because of a leaking pod. Display only; dosing is not changed.", comment: "Footer of the insulin effect monitor switch"))) {
                Toggle(NSLocalizedString("Insulin Effect Monitor", comment: "Switch that turns the insulin effect monitor on"), isOn: $settings.isEnabled)
            }

            Section(footer: Text(NSLocalizedString("Lower values warn earlier but more often. \"Watch\" appears when one check is exceeded, \"Attention\" when they confirm each other or a correction does not lower glucose within an hour.", comment: "Footer of the insulin effect monitor thresholds"))) {
                picker(NSLocalizedString("Sensor rise beyond carbs", comment: "Insulin effect threshold label"), \.riseRateThreshold, options: stride(from: 0.5, through: 5, by: 0.25).map { $0 }) {
                    Self.rateLabel($0, unit: displayGlucosePreference.unit)
                }
                picker(NSLocalizedString("Unexplained rise", comment: "Insulin effect threshold label"), \.unexplainedRateThreshold, options: stride(from: 0.5, through: 5, by: 0.25).map { $0 }) {
                    Self.rateLabel($0, unit: displayGlucosePreference.unit)
                }
                picker(NSLocalizedString("Above forecast", comment: "Insulin effect threshold label"), \.discrepancyThreshold, options: stride(from: 10, through: 100, by: 5).map { $0 }) {
                    displayGlucosePreference.format(HKQuantity(unit: .milligramsPerDeciliter, doubleValue: $0))
                }
                picker(NSLocalizedString("Minimum active insulin", comment: "Insulin effect threshold label"), \.minimumInsulinOnBoard, options: stride(from: 0.5, through: 5, by: 0.5).map { $0 }) {
                    String(format: "%.1f U", $0)
                }
                picker(NSLocalizedString("Carbs absorbed within", comment: "Insulin effect threshold label"), \.carbAllowanceMinutes, options: stride(from: 60, through: 360, by: 30).map { $0 }) {
                    String(format: NSLocalizedString("%d min", comment: "Custom loop interval value in minutes (1: number of minutes)"), Int($0))
                }
                Button(NSLocalizedString("Reset to Defaults", comment: "Button that resets the insulin effect thresholds")) {
                    settings = InsulinEffectMonitorSettings(isEnabled: settings.isEnabled)
                }
            }
            .disabled(!settings.isEnabled)
        }
        .insetGroupedListStyle()
        .navigationTitle(NSLocalizedString("Insulin Effect", comment: "Title of the insulin effect screens and status row"))
        .onChange(of: settings) { newValue in
            UserDefaults.standard.insulinEffectMonitorSettings = newValue
        }
    }

    private func picker(_ title: String, _ keyPath: WritableKeyPath<InsulinEffectMonitorSettings, Double>, options: [Double], label: @escaping (Double) -> String) -> some View {
        let selection = Binding<Double>(
            get: {
                let current = settings[keyPath: keyPath]
                return options.min { abs($0 - current) < abs($1 - current) } ?? current
            },
            set: { settings[keyPath: keyPath] = $0 }
        )
        return ExpandableWheelPicker(title: Text(title), selection: selection, options: options, label: label)
    }

    static func rateLabel(_ milligramsPerDeciliterPerMinute: Double, unit: HKUnit) -> String {
        if unit == .millimolesPerLiter {
            let value = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: milligramsPerDeciliterPerMinute).doubleValue(for: .millimolesPerLiter)
            return String(format: NSLocalizedString("%.2f mmol/L/min", comment: "Glucose rate in mmol/L per minute (1: value)"), value)
        }
        return String(format: NSLocalizedString("%.1f mg/dL/min", comment: "Glucose rate in mg/dL per minute (1: value)"), milligramsPerDeciliterPerMinute)
    }
}
