//
//  CalculatedProfileView.swift
//  Loop
//
//  Read-only view of the TherapyOptimizer results.
//

import SwiftUI
import HealthKit
import LoopKit
import LoopKitUI

struct CalculatedProfileView: View {
    @ObservedObject private var optimizer = TherapyOptimizer.shared
    @ObservedObject var profiles: TherapyProfilesModel
    @State private var showCreateSheet = false
    @State private var showDeleteConfirmation = false
    @State private var pendingChange: CalculatedProfileChange?
    @State private var message: String?
    @AppStorage(UserDefaults.glucoseDependentSensitivityEnabledKey) private var glucoseDependentSensitivity = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        List {
            Section(footer: Text(NSLocalizedString("Calculated from periods without carbs, overrides, lows or unannounced meals and compared with the active profile, which is followed automatically when it changes. All values are U100; data from times a U200 profile was active is converted automatically. The values never change dosing by themselves (except glucose-dependent sensitivity when \u{201C}Use for Corrections\u{201D} is on): tap a value to apply it to the active profile.", comment: "Footer explaining the calculated therapy profile"))) {
                Toggle(NSLocalizedString("Calculate Profile", comment: "Toggle that enables the therapy optimizer"), isOn: Binding(
                    get: { optimizer.state != nil },
                    set: { enabled in
                        if enabled {
                            optimizer.enable()
                        } else {
                            optimizer.disable()
                        }
                    }
                ))
                if optimizer.isProcessing {
                    HStack {
                        Text(NSLocalizedString("Calculating…", comment: "Shown while the therapy optimizer processes data"))
                        Spacer()
                        ProgressView()
                    }
                }
                if let error = optimizer.lastError {
                    Text(error).foregroundColor(.red)
                }
            }

            if let state = optimizer.state {
                statusSection(state)
                if let profile = TherapyProfile.activeProfile() {
                    CalculatedValuesSections(state: state, profile: profile, pendingChange: $pendingChange, message: $message)
                }
                sensitivityByGlucoseSection(state)
            }

            Section(footer: Text(NSLocalizedString("Collected data is kept when the calculation is turned off. Up to 90 days are stored, including Loop's original glucose, insulin and carb records, so values can be calculated again later.", comment: "Footer explaining that therapy optimizer data is kept"))) {
                Button(NSLocalizedString("Delete Collected Data", comment: "Button that deletes all therapy optimizer data"), role: .destructive) {
                    showDeleteConfirmation = true
                }
                .disabled(optimizer.storedDays == 0 && optimizer.state == nil)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(NSLocalizedString("Calculated Profile", comment: "Title of the calculated therapy profile view")))
        .alert(NSLocalizedString("Delete Collected Data?", comment: "Title of the confirmation to delete therapy optimizer data"), isPresented: $showDeleteConfirmation) {
            Button(NSLocalizedString("Delete", comment: "Confirm deleting therapy optimizer data"), role: .destructive) {
                optimizer.deleteCollectedData()
            }
            Button(NSLocalizedString("Cancel", comment: "Cancel deleting therapy optimizer data"), role: .cancel) {}
        } message: {
            Text(NSLocalizedString("All stored days and calculated values are deleted. Only the last days still in Loop can be collected again.", comment: "Message of the confirmation to delete therapy optimizer data"))
        }
        .sheet(isPresented: $showCreateSheet) {
            if let state = optimizer.state {
                CreateCalculatedProfileSheet(state: state, profiles: profiles)
            }
        }
        .calculatedProfileChangeDialogs($pendingChange, message: $message, profiles: profiles)
    }

    private func statusSection(_ state: TherapyOptimizerState) -> some View {
        Section {
            Picker(NSLocalizedString("Window", comment: "Picker for the therapy optimizer window length"), selection: Binding(
                get: { state.windowDays },
                set: { optimizer.setWindowDays($0) }
            )) {
                ForEach(TherapyOptimizerState.windowOptions, id: \.self) { days in
                    Text(String(format: NSLocalizedString("%d days", comment: "Therapy optimizer window option (1: number of days)"), days)).tag(days)
                }
            }
            valueRow(NSLocalizedString("Days of data", comment: "Number of days with collected therapy optimizer data"), "\(state.summaries.count)")
            valueRow(NSLocalizedString("Days stored for recalculation", comment: "Number of days of stored input the therapy optimizer can replay"), "\(optimizer.storedDays)")
            valueRow(NSLocalizedString("Last update", comment: "Date of the last therapy optimizer daily update"), state.lastDailyUpdate.map { Self.dateFormatter.string(from: $0) } ?? "–")
            valueRow(NSLocalizedString("Processed until", comment: "Date up to which data was processed by the therapy optimizer"), Self.dateFormatter.string(from: state.lastProcessedDate))

            Button(NSLocalizedString("Create Profile from Calculated", comment: "Button that opens the sheet to create a therapy profile from calculated values")) {
                showCreateSheet = true
            }
            Button(NSLocalizedString("Recalculate", comment: "Button that recalculates the therapy optimizer from history")) {
                optimizer.recalculate()
            }
            .disabled(optimizer.isProcessing)
        }
    }

    private func sensitivityByGlucoseSection(_ state: TherapyOptimizerState) -> some View {
        let format = state.sensitivityUnit == .milligramsPerDeciliter ? "%.0f" : "%.1f"
        let bounds = TherapyOptimizerEngine.glucoseRangeUpperBounds.map { String(format: format, state.displaySensitivity($0)) }
        let ranges = state.sensitivityByGlucose ?? []
        return Section(
            header: VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("Insulin Sensitivity by Glucose", comment: "Header of the insulin sensitivity by glucose range table"))
                Text(NSLocalizedString("Glucose · Change · Sensitivity · Days", comment: "Column legend of the insulin sensitivity by glucose range table"))
                    .font(.caption2)
            },
            footer: Text(NSLocalizedString("Change relative to the reference row, your overall observed insulin sensitivity: e.g. −15 % means insulin works 15 % less in that range. With “Use for Corrections” on, corrections and bolus recommendations use the active profile's insulin sensitivity times this change (limited to ±20 %), only for ranges with at least 3 days of data and never below 70 mg/dL. Forecasts are not changed.", comment: "Footer of the insulin sensitivity by glucose range table"))
        ) {
            Toggle(NSLocalizedString("Use for Corrections", comment: "Switch that applies the glucose-dependent insulin sensitivity to correction dosing"), isOn: $glucoseDependentSensitivity)
            glucoseRangeRow(NSLocalizedString("Reference", comment: "Row with the overall sensitivity the glucose ranges are compared with"), range: state.sensitivityByGlucoseReference, state: state, format: format)
            ForEach(0..<TherapyOptimizerEngine.glucoseRangeCount, id: \.self) { range in
                glucoseRangeRow(glucoseRangeLabel(range, bounds: bounds), range: range < ranges.count ? ranges[range] : nil, state: state, format: format)
            }
        }
    }

    private func glucoseRangeLabel(_ range: Int, bounds: [String]) -> String {
        if range == 0 {
            return "< \(bounds[0])"
        }
        if range == bounds.count {
            return "> \(bounds[bounds.count - 1])"
        }
        return "\(bounds[range - 1])–\(bounds[range])"
    }

    private func glucoseRangeRow(_ title: String, range: TherapyOptimizerGlucoseRangeSensitivity?, state: TherapyOptimizerState, format: String) -> some View {
        let dataDays = range?.dataDays ?? 0
        return HStack {
            Text(title)
                .frame(width: 80, alignment: .leading)
            Spacer()
            Text(range?.factor.map { String(format: "%+.0f %%", ($0 - 1) * 100) } ?? "–")
                .bold()
                .frame(minWidth: 56, alignment: .trailing)
            Text(range?.sensitivity.map { String(format: format, state.displaySensitivity($0)) } ?? "–")
                .foregroundColor(.secondary)
                .frame(minWidth: 48, alignment: .trailing)
            Text("\(dataDays)")
                .foregroundColor(.secondary)
                .frame(minWidth: 24, alignment: .trailing)
        }
        .font(.footnote.monospacedDigit())
        .opacity(dataDays >= TherapyOptimizerEngine.reliableHourDataDays ? 1 : 0.5)
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}

/// A calculated value the user tapped, waiting for confirmation.
struct CalculatedProfileChange {
    let profileID: UUID
    let kind: TherapyProfilesModel.ScheduleKind
    let change: TherapyProfilesModel.ScheduleChange
    let summary: String
}

/// Basal, insulin sensitivity and carb ratio tables comparing the calculated (U100) values with `profile`.
/// Tapping a row proposes the calculated value for that profile.
struct CalculatedValuesSections: View {
    let state: TherapyOptimizerState
    let profile: TherapyProfile
    @Binding var pendingChange: CalculatedProfileChange?
    @Binding var message: String?

    var body: some View {
        // The profile in U100, like the calculated values.
        let factor = profile.concentration.unitsPerPumpUnit
        let sensitivityUnit = profile.insulinSensitivitySchedule.unit
        let basal = TherapyOptimizerMath.hourlyValues(profile.basalRateSchedule.items).map { $0 * factor }
        let sensitivity = TherapyOptimizerMath.hourlyValues(profile.insulinSensitivitySchedule.items).map {
            HKQuantity(unit: sensitivityUnit, doubleValue: $0).doubleValue(for: .milligramsPerDeciliter) / factor
        }
        let carbRatio = TherapyOptimizerMath.hourlyValues(profile.carbRatioSchedule.items).map { $0 / factor }
        basalSection(basal)
        sensitivitySection(sensitivity)
        carbRatioSection(carbRatio)
    }

    private func basalSection(_ reference: [Double]) -> some View {
        Section(header: header(NSLocalizedString("Basal Rates (U/hr)", comment: "Header of the calculated basal rates table"))) {
            ForEach(0..<24, id: \.self) { hour in
                valuesRow(hourLabel(hour), start: reference[hour], calculated: state.basal.calculated[hour], dataDays: state.basal.dataDays[hour], format: "%.2f") {
                    offerApply(.basal, hour: hour, calculated: state.basal.calculated[hour])
                }
            }
            valuesRow(NSLocalizedString("Total U/day", comment: "Row label for the total daily basal insulin"), start: reference.reduce(0, +), calculated: state.basal.calculated.reduce(0, +), dataDays: nil, format: "%.2f")
        }
    }

    private func sensitivitySection(_ reference: [Double]) -> some View {
        let unit = state.sensitivityUnit == .milligramsPerDeciliter ? "mg/dL" : "mmol/L"
        let format = state.sensitivityUnit == .milligramsPerDeciliter ? "%.0f" : "%.1f"
        let referenceAllDay = Self.mean(reference)
        return Section(header: header(String(format: NSLocalizedString("Insulin Sensitivities (%@/U)", comment: "Header of the calculated insulin sensitivities table (1: glucose unit)"), unit))) {
            valuesRow(allDayLabel, start: state.displaySensitivity(referenceAllDay), calculated: state.displaySensitivity(state.sensitivity.calculatedAllDay), dataDays: state.sensitivity.dataDaysAllDay, format: format) {
                offerScale(.sensitivity, calculatedAllDay: state.sensitivity.calculatedAllDay, referenceAllDay: referenceAllDay)
            }
            ForEach(0..<24, id: \.self) { hour in
                valuesRow(hourLabel(hour), start: state.displaySensitivity(reference[hour]), calculated: state.displaySensitivity(state.sensitivity.calculated[hour]), dataDays: state.sensitivity.dataDays[hour], format: format) {
                    offerApply(.sensitivity, hour: hour, calculated: state.sensitivity.calculated[hour])
                }
            }
        }
    }

    private func carbRatioSection(_ reference: [Double]) -> some View {
        let referenceAllDay = Self.mean(reference)
        return Section(header: header(NSLocalizedString("Carb Ratios (g/U)", comment: "Header of the calculated carb ratios table"))) {
            valuesRow(allDayLabel, start: referenceAllDay, calculated: state.carbRatio.calculatedAllDay, dataDays: state.carbRatio.dataDaysAllDay, format: "%.1f") {
                offerScale(.carbRatio, calculatedAllDay: state.carbRatio.calculatedAllDay, referenceAllDay: referenceAllDay)
            }
            ForEach(0..<24, id: \.self) { hour in
                valuesRow(hourLabel(hour), start: reference[hour], calculated: state.carbRatio.calculated[hour], dataDays: state.carbRatio.dataDays[hour], format: "%.1f") {
                    offerApply(.carbRatio, hour: hour, calculated: state.carbRatio.calculated[hour])
                }
            }
        }
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private var allDayLabel: String {
        NSLocalizedString("All day", comment: "Row label for the all-day calculated value")
    }

    private func header(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(NSLocalizedString("Profile · Calculated · Change · Days", comment: "Column legend of the calculated therapy tables"))
                .font(.caption2)
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    private func valuesRow(_ title: String, start: Double, calculated: Double, dataDays: Int?, format: String, onTap: (() -> Void)? = nil) -> some View {
        let change = start != 0 ? (calculated / start - 1) * 100 : 0
        let row = HStack {
            Text(title)
                .frame(width: 64, alignment: .leading)
            Spacer()
            Text(String(format: format, start))
                .foregroundColor(.secondary)
            Text(String(format: format, calculated))
                .bold()
                .frame(minWidth: 48, alignment: .trailing)
            Text(String(format: "%+.0f%%", change))
                .foregroundColor(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
            Text(dataDays.map { "\($0)" } ?? "")
                .foregroundColor(.secondary)
                .frame(minWidth: 24, alignment: .trailing)
        }
        .font(.footnote.monospacedDigit())
        .opacity((dataDays ?? TherapyOptimizerEngine.reliableHourDataDays) >= TherapyOptimizerEngine.reliableHourDataDays ? 1 : 0.5)
        .contentShape(Rectangle())
        return row.onTapGesture { onTap?() }
    }

    /// Asks before writing the calculated value, converted to the profile's units and concentration.
    private func offerApply(_ kind: TherapyProfilesModel.ScheduleKind, hour: Int, calculated: Double) {
        let factor = profile.concentration.unitsPerPumpUnit
        let concentration = profile.isConcentrated ? " \(profile.concentration.label)" : ""
        let value: Double
        let items: [RepeatingScheduleValue<Double>]
        let valueText: String
        switch kind {
        case .basal:
            value = (calculated / factor * 20).rounded() / 20
            items = profile.basalRateSchedule.items
            valueText = String(format: "%.2f U/hr", value) + concentration
        case .sensitivity:
            let unit = profile.insulinSensitivitySchedule.unit
            let stepsPerUnit = unit == .milligramsPerDeciliter ? 1.0 : 10.0
            value = (HKQuantity(unit: .milligramsPerDeciliter, doubleValue: calculated).doubleValue(for: unit) * factor * stepsPerUnit).rounded() / stepsPerUnit
            items = profile.insulinSensitivitySchedule.items
            valueText = String(format: unit == .milligramsPerDeciliter ? "%.0f %@/U" : "%.1f %@/U", value, unit == .milligramsPerDeciliter ? "mg/dL" : "mmol/L") + concentration
        case .carbRatio:
            value = (calculated * factor * 10).rounded() / 10
            items = profile.carbRatioSchedule.items
            valueText = String(format: "%.1f g/U", value) + concentration
        }
        guard abs(TherapyOptimizerMath.hourlyValues(items)[hour] - value) >= 1e-9 else {
            message = String(format: NSLocalizedString("“%@” already uses %@.", comment: "Message when the calculated value already is in the profile (1: profile name, 2: value)"), profile.name, valueText)
            return
        }
        let period = String(format: "%02d:00–%02d:00", hour, (hour + 1) % 24)
        var summary = String(format: NSLocalizedString("%@ in “%@”: %@", comment: "Summary of a value to apply (1: time period, 2: profile name, 3: value)"), period, profile.name, valueText)
        if kind == .basal, TherapyProfile.activeProfile()?.id == profile.id {
            summary += "\n" + NSLocalizedString("Basal rates are sent to the pump.", comment: "Note that applying a basal rate communicates with the pump")
        }
        pendingChange = CalculatedProfileChange(profileID: profile.id, kind: kind, change: .value(value, hour: hour), summary: summary)
    }

    /// The all-day change applied to every entry, so an hourly profile keeps its shape.
    private func offerScale(_ kind: TherapyProfilesModel.ScheduleKind, calculatedAllDay: Double, referenceAllDay: Double) {
        guard referenceAllDay > 0 else { return }
        let factor = calculatedAllDay / referenceAllDay
        let percent = (factor - 1) * 100
        guard abs(percent) >= 0.5 else {
            message = String(format: NSLocalizedString("“%@” already matches the calculated values.", comment: "Message when the all-day change is below 1 % (1: profile name)"), profile.name)
            return
        }
        let summary = String(format: NSLocalizedString("All entries of “%@” %+.0f %%; the hourly pattern is kept.", comment: "Summary of an all-day change to apply (1: profile name, 2: percent)"), profile.name, percent)
        pendingChange = CalculatedProfileChange(profileID: profile.id, kind: kind, change: .scale(factor), summary: summary)
    }
}

extension View {
    /// Confirmation and result messages for `CalculatedValuesSections`.
    func calculatedProfileChangeDialogs(_ pendingChange: Binding<CalculatedProfileChange?>, message: Binding<String?>, profiles: TherapyProfilesModel, onChanged: @escaping () -> Void = {}) -> some View {
        confirmationDialog(
            NSLocalizedString("Apply Calculated Value?", comment: "Title of the confirmation to apply a calculated value to a profile"),
            isPresented: Binding(get: { pendingChange.wrappedValue != nil }, set: { if !$0 { pendingChange.wrappedValue = nil } }),
            titleVisibility: .visible,
            presenting: pendingChange.wrappedValue
        ) { change in
            Button(NSLocalizedString("Apply", comment: "Button that applies a calculated value to a profile")) {
                profiles.changeProfile(withID: change.profileID, change.kind, change.change) { error in
                    DispatchQueue.main.async {
                        message.wrappedValue = error?.localizedDescription
                        onChanged()
                    }
                }
            }
        } message: { change in
            Text(change.summary)
        }
        .alert(NSLocalizedString("Calculated Profile", comment: "Title of the calculated therapy profile view"), isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button(NSLocalizedString("OK", comment: "Dismiss a calculated profile message"), role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}

private struct CreateCalculatedProfileSheet: View {
    let state: TherapyOptimizerState
    @ObservedObject var profiles: TherapyProfilesModel
    @Environment(\.presentationMode) private var presentationMode

    @State private var name = String(format: NSLocalizedString("Calculated %@", comment: "Default name of a profile created from calculated values (1: date)"), DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none))
    @State private var includeBasal = true
    @State private var includeSensitivity = true
    @State private var includeCarbRatio = true
    @State private var hourlySensitivity = false
    @State private var hourlyCarbRatio = false
    @State private var isU200 = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(NSLocalizedString("Name", comment: "Header of the therapy profile name field"))) {
                    TextField(NSLocalizedString("Name", comment: "Placeholder of the therapy profile name field"), text: $name)
                }
                Section(footer: Text(NSLocalizedString("Parts that are not taken are copied from the active profile.", comment: "Footer of the create-from-calculated sheet"))) {
                    Toggle(NSLocalizedString("Basal Rates", comment: "Therapy profile basal rates row"), isOn: $includeBasal)
                    Toggle(NSLocalizedString("Insulin Sensitivities", comment: "Therapy profile insulin sensitivities row"), isOn: $includeSensitivity)
                    if includeSensitivity {
                        modePicker(selection: $hourlySensitivity)
                    }
                    Toggle(NSLocalizedString("Carb Ratios", comment: "Therapy profile carb ratios row"), isOn: $includeCarbRatio)
                    if includeCarbRatio {
                        modePicker(selection: $hourlyCarbRatio)
                    }
                }
                Section(footer: Text(NSLocalizedString("Calculated values are U100. With U200 on, basal rates and limits are halved and carb ratios and insulin sensitivities doubled.", comment: "Footer of the U200 switch when creating a profile from calculated values"))) {
                    Toggle(NSLocalizedString("U200 Insulin", comment: "Switch that creates the therapy profile for U200 insulin"), isOn: $isU200)
                }
                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(Text(NSLocalizedString("New Profile", comment: "Title of the create-from-calculated sheet")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Cancel", comment: "Cancel creating a profile from calculated values")) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("Create", comment: "Create a profile from calculated values"), action: create)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func modePicker(selection: Binding<Bool>) -> some View {
        Picker("", selection: selection) {
            Text(NSLocalizedString("Overall change", comment: "Apply the all-day change to the active profile's hourly values")).tag(false)
            Text(NSLocalizedString("Hourly", comment: "Use the hourly calculated values")).tag(true)
        }
        .pickerStyle(.segmented)
    }

    private func create() {
        // Calculated values are U100; parts not taken come from the active profile, converted to U100 if needed.
        let base = profiles.activeProfileInU100
        let live = profiles.liveViewModel.therapySettings
        let maximumBasalRate = base?.maximumBasalRatePerHour ?? live.maximumBasalRatePerHour
        let basal = includeBasal
            ? state.calculatedBasalSchedule(maximumBasalRate: maximumBasalRate, maximumEntryCount: profiles.liveViewModel.maximumBasalScheduleEntryCount)
            : base?.basalRateSchedule
        let sensitivity = includeSensitivity ? state.calculatedSensitivitySchedule(hourly: hourlySensitivity) : base?.insulinSensitivitySchedule
        let carbRatio = includeCarbRatio ? state.calculatedCarbRatioSchedule(hourly: hourlyCarbRatio) : base?.carbRatioSchedule

        guard let basal = basal, let sensitivity = sensitivity, let carbRatio = carbRatio,
              let profile = TherapyProfile(
                name: name.trimmingCharacters(in: .whitespaces),
                basalRateSchedule: basal,
                carbRatioSchedule: carbRatio,
                insulinSensitivitySchedule: sensitivity,
                maximumBasalRatePerHour: maximumBasalRate,
                maximumBolus: base?.maximumBolus ?? live.maximumBolus
              ).copy(named: name.trimmingCharacters(in: .whitespaces), concentration: isU200 ? .u200 : .u100) else {
            errorMessage = NSLocalizedString("The profile could not be created.", comment: "Error when a profile cannot be created from calculated values")
            return
        }
        profiles.add(profile)
        presentationMode.wrappedValue.dismiss()
    }
}
