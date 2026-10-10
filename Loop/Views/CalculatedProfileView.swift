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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        List {
            Section(footer: Text(NSLocalizedString("Calculated from periods without carbs, overrides, lows or unannounced meals. All values are U100; data from times a U200 profile was active is converted automatically. The values are only displayed and never change dosing. Use them by creating a profile and activating it yourself.", comment: "Footer explaining the calculated therapy profile"))) {
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
                basalSection(state)
                sensitivitySection(state)
                sensitivityByGlucoseSection(state)
                carbRatioSection(state)
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
            Button(NSLocalizedString("Restart from Current Settings", comment: "Button that resets the therapy optimizer start values to the current settings")) {
                optimizer.restartFromCurrentSettings()
            }
            .disabled(optimizer.isProcessing)
        }
    }

    private func basalSection(_ state: TherapyOptimizerState) -> some View {
        Section(header: header(NSLocalizedString("Basal Rates (U/hr)", comment: "Header of the calculated basal rates table"))) {
            ForEach(0..<24, id: \.self) { hour in
                valuesRow(hourLabel(hour), start: state.basal.start[hour], calculated: state.basal.calculated[hour], dataDays: state.basal.dataDays[hour], format: "%.2f")
            }
            valuesRow(NSLocalizedString("Total U/day", comment: "Row label for the total daily basal insulin"), start: state.basal.start.reduce(0, +), calculated: state.basal.calculated.reduce(0, +), dataDays: nil, format: "%.2f")
        }
    }

    private func sensitivitySection(_ state: TherapyOptimizerState) -> some View {
        let unit = state.sensitivityUnit == .milligramsPerDeciliter ? "mg/dL" : "mmol/L"
        let format = state.sensitivityUnit == .milligramsPerDeciliter ? "%.0f" : "%.1f"
        return Section(header: header(String(format: NSLocalizedString("Insulin Sensitivities (%@/U)", comment: "Header of the calculated insulin sensitivities table (1: glucose unit)"), unit))) {
            valuesRow(allDayLabel, start: state.displaySensitivity(state.sensitivity.startAllDay), calculated: state.displaySensitivity(state.sensitivity.calculatedAllDay), dataDays: state.sensitivity.dataDaysAllDay, format: format)
            ForEach(0..<24, id: \.self) { hour in
                valuesRow(hourLabel(hour), start: state.displaySensitivity(state.sensitivity.start[hour]), calculated: state.displaySensitivity(state.sensitivity.calculated[hour]), dataDays: state.sensitivity.dataDays[hour], format: format)
            }
        }
    }

    private func carbRatioSection(_ state: TherapyOptimizerState) -> some View {
        Section(header: header(NSLocalizedString("Carb Ratios (g/U)", comment: "Header of the calculated carb ratios table"))) {
            valuesRow(allDayLabel, start: state.carbRatio.startAllDay, calculated: state.carbRatio.calculatedAllDay, dataDays: state.carbRatio.dataDaysAllDay, format: "%.1f")
            ForEach(0..<24, id: \.self) { hour in
                valuesRow(hourLabel(hour), start: state.carbRatio.start[hour], calculated: state.carbRatio.calculated[hour], dataDays: state.carbRatio.dataDays[hour], format: "%.1f")
            }
        }
    }

    private var allDayLabel: String {
        NSLocalizedString("All day", comment: "Row label for the all-day calculated value")
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
            footer: Text(NSLocalizedString("Change relative to your overall insulin sensitivity, e.g. −15 % means insulin works 15 % less in that range. The percentage can be applied to any 24-hour profile. Information only; Loop does not use it for dosing.", comment: "Footer of the insulin sensitivity by glucose range table"))
        ) {
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

    private func header(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(NSLocalizedString("Start · Calculated · Change · Days", comment: "Column legend of the calculated therapy tables"))
                .font(.caption2)
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    private func valueRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }

    private func valuesRow(_ title: String, start: Double, calculated: Double, dataDays: Int?, format: String) -> some View {
        let change = start != 0 ? (calculated / start - 1) * 100 : 0
        return HStack {
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
            Text(NSLocalizedString("All-day value", comment: "Use the single all-day calculated value")).tag(false)
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
