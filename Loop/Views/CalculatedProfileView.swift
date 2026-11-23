//
//  CalculatedProfileView.swift
//  Loop
//
//  TherapyOptimizer results, applying them to profiles and the "Use for Corrections" switch.
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

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        List {
            Section(footer: Text(NSLocalizedString("Calculated from periods without carbs, overrides (and 4 hours after), lows or unannounced meals and compared with the active profile, which is followed automatically when it changes. Values are shown in the active profile's pump units; the calculation runs in U100 and data from times a U200 profile was active is converted automatically. The values change dosing only through \u{201C}Use for Corrections\u{201D} or when you tap a value with at least 3 days of data to apply it to the active profile.", comment: "Footer explaining the calculated therapy profile"))) {
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
                    CalculatedValuesSections(state: state, profile: profile, profiles: profiles, pendingChange: $pendingChange, message: $message)
                }
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

/// Basal, insulin sensitivity and carb ratio tables comparing the calculated (U100) values with `profile`, shown in the profile's pump units.
/// Tapping a row proposes the calculated value for that profile.
struct CalculatedValuesSections: View {
    let state: TherapyOptimizerState
    let profile: TherapyProfile
    @ObservedObject var profiles: TherapyProfilesModel
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
        sensitivityByGlucoseSection(profileSensitivity: perUnitInPumpUnits(Self.mean(sensitivity)))
        carbRatioSection(carbRatio)
    }

    private func basalInPumpUnits(_ u100: Double) -> Double {
        u100 / profile.concentration.unitsPerPumpUnit
    }

    /// Carb ratios and insulin sensitivities grow with the concentration.
    private func perUnitInPumpUnits(_ u100: Double) -> Double {
        u100 * profile.concentration.unitsPerPumpUnit
    }

    @ViewBuilder
    private var unitsFooter: some View {
        if profile.isConcentrated {
            Text(String(format: NSLocalizedString("Values in %@ pump units; calculated in U100.", comment: "Footer of the calculated therapy tables for a concentrated profile (1: insulin concentration, e.g. U200)"), profile.concentration.label))
        }
    }

    /// The calculated factor per glucose range, shown on this profile's sensitivity (in its pump units).
    private func sensitivityByGlucoseSection(profileSensitivity: Double) -> some View {
        let format = state.sensitivityUnit == .milligramsPerDeciliter ? "%.0f" : "%.1f"
        let bounds = TherapyOptimizerEngine.glucoseRangeUpperBounds.map { String(format: format, locale: .current, state.displaySensitivity($0)) }
        let ranges = state.sensitivityByGlucose ?? []
        let limits = TherapyOptimizerEngine.dosingSensitivityFactorRange
        return Section(
            header: VStack(alignment: .leading, spacing: 2) {
                Text(NSLocalizedString("Insulin Sensitivity by Glucose", comment: "Header of the insulin sensitivity by glucose range table"))
                Text(NSLocalizedString("Glucose · Change · Sensitivity · Days", comment: "Column legend of the insulin sensitivity by glucose range table"))
                    .font(.caption2)
            },
            footer: VStack(alignment: .leading, spacing: 4) {
                Text(NSLocalizedString("Change observed in each glucose range relative to your overall insulin sensitivity, e.g. −15 % means insulin works 15 % less there; it updates with the calculation. Sensitivity shows this profile's all-day value with the change. With \u{201C}Use for Corrections\u{201D} on and this profile active, bolus and automatic dose recommendations use the change at the current glucose (blended between ranges, limited to ±20 %, needs at least 3 days of data and a calculation from the last 3 days). It changes a recommendation by at most its part of correcting current glucose to the middle of the correction range: carbs are dosed as usual, at or below the middle nothing changes, and maximum bolus and maximum basal rate still apply. Forecasts and the profile's values are not changed.", comment: "Footer of the insulin sensitivity by glucose range table"))
                unitsFooter
            }
        ) {
            Toggle(NSLocalizedString("Use for Corrections", comment: "Switch that applies the glucose-dependent insulin sensitivity to correction dosing"), isOn: Binding(
                get: { profile.usesGlucoseDependentSensitivity == true },
                set: { enabled in
                    guard var latest = profiles.profile(withID: profile.id) else { return }
                    latest.usesGlucoseDependentSensitivity = enabled ? true : nil
                    profiles.save(latest)
                }
            ))
            glucoseRangeRow(NSLocalizedString("Profile", comment: "Row with the profile's all-day insulin sensitivity the glucose ranges are applied to"), change: nil, sensitivity: profileSensitivity, dataDays: state.sensitivityByGlucoseReference?.dataDays ?? 0, format: format)
            ForEach(1..<TherapyOptimizerEngine.glucoseRangeCount, id: \.self) { index in
                let range = index < ranges.count ? ranges[index] : nil
                glucoseRangeRow(
                    glucoseRangeLabel(index, bounds: bounds),
                    change: range?.factor,
                    sensitivity: range?.factor.map { profileSensitivity * min(max($0, limits.lowerBound), limits.upperBound) },
                    dataDays: range?.dataDays ?? 0,
                    format: format
                )
            }
        }
    }

    private func glucoseRangeLabel(_ range: Int, bounds: [String]) -> String {
        if range == bounds.count {
            return "> \(bounds[bounds.count - 1])"
        }
        return "\(bounds[range - 1])–\(bounds[range])"
    }

    private func glucoseRangeRow(_ title: String, change: Double?, sensitivity: Double?, dataDays: Int, format: String) -> some View {
        HStack {
            Text(title)
                .frame(width: 80, alignment: .leading)
            Spacer()
            Text(change.map { String(format: "%+.0f %%", ($0 - 1) * 100) } ?? "")
                .bold()
                .frame(minWidth: 56, alignment: .trailing)
            Text(sensitivity.map { String(format: format, locale: .current, state.displaySensitivity($0)) } ?? "–")
                .foregroundColor(.secondary)
                .frame(minWidth: 48, alignment: .trailing)
            Text("\(dataDays)")
                .foregroundColor(.secondary)
                .frame(minWidth: 24, alignment: .trailing)
        }
        .font(.footnote.monospacedDigit())
        .opacity(dataDays >= TherapyOptimizerEngine.reliableHourDataDays ? 1 : 0.5)
    }

    private func basalSection(_ reference: [Double]) -> some View {
        Section(header: header(NSLocalizedString("Basal Rates (U/hr)", comment: "Header of the calculated basal rates table")), footer: unitsFooter) {
            ForEach(0..<24, id: \.self) { hour in
                valuesRow(hourLabel(hour), start: basalInPumpUnits(reference[hour]), calculated: basalInPumpUnits(state.basal.calculated[hour]), dataDays: state.basal.dataDays[hour], format: "%.2f") {
                    offerApply(.basal, hour: hour, calculated: state.basal.calculated[hour], dataDays: state.basal.dataDays[hour])
                }
            }
            valuesRow(NSLocalizedString("Total U/day", comment: "Row label for the total daily basal insulin"), start: basalInPumpUnits(reference.reduce(0, +)), calculated: basalInPumpUnits(state.basal.calculated.reduce(0, +)), dataDays: nil, format: "%.2f")
        }
    }

    private func sensitivitySection(_ reference: [Double]) -> some View {
        let unit = state.sensitivityUnit.localizedShortUnitString
        let format = state.sensitivityUnit == .milligramsPerDeciliter ? "%.0f" : "%.1f"
        let referenceAllDay = Self.mean(reference)
        return Section(header: header(String(format: NSLocalizedString("Insulin Sensitivities (%@/U)", comment: "Header of the calculated insulin sensitivities table (1: glucose unit)"), unit)), footer: unitsFooter) {
            valuesRow(allDayLabel, start: state.displaySensitivity(perUnitInPumpUnits(referenceAllDay)), calculated: state.displaySensitivity(perUnitInPumpUnits(state.sensitivity.calculatedAllDay)), dataDays: state.sensitivity.dataDaysAllDay, format: format) {
                offerScale(.sensitivity, calculatedAllDay: state.sensitivity.calculatedAllDay, referenceAllDay: referenceAllDay, dataDays: state.sensitivity.dataDaysAllDay)
            }
            ForEach(0..<24, id: \.self) { hour in
                valuesRow(hourLabel(hour), start: state.displaySensitivity(perUnitInPumpUnits(reference[hour])), calculated: state.displaySensitivity(perUnitInPumpUnits(state.sensitivity.calculated[hour])), dataDays: state.sensitivity.dataDays[hour], format: format) {
                    offerApply(.sensitivity, hour: hour, calculated: state.sensitivity.calculated[hour], dataDays: state.sensitivity.dataDays[hour])
                }
            }
        }
    }

    private func carbRatioSection(_ reference: [Double]) -> some View {
        let referenceAllDay = Self.mean(reference)
        return Section(header: header(NSLocalizedString("Carb Ratios (g/U)", comment: "Header of the calculated carb ratios table")), footer: unitsFooter) {
            valuesRow(allDayLabel, start: perUnitInPumpUnits(referenceAllDay), calculated: perUnitInPumpUnits(state.carbRatio.calculatedAllDay), dataDays: state.carbRatio.dataDaysAllDay, format: "%.1f") {
                offerScale(.carbRatio, calculatedAllDay: state.carbRatio.calculatedAllDay, referenceAllDay: referenceAllDay, dataDays: state.carbRatio.dataDaysAllDay)
            }
            ForEach(0..<24, id: \.self) { hour in
                valuesRow(hourLabel(hour), start: perUnitInPumpUnits(reference[hour]), calculated: perUnitInPumpUnits(state.carbRatio.calculated[hour]), dataDays: state.carbRatio.dataDays[hour], format: "%.1f") {
                    offerApply(.carbRatio, hour: hour, calculated: state.carbRatio.calculated[hour], dataDays: state.carbRatio.dataDays[hour])
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
            Text(String(format: format, locale: .current, start))
                .foregroundColor(.secondary)
            Text(String(format: format, locale: .current, calculated))
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
    private func offerApply(_ kind: TherapyProfilesModel.ScheduleKind, hour: Int, calculated: Double, dataDays: Int) {
        guard hasEnoughData(dataDays) else { return }
        let factor = profile.concentration.unitsPerPumpUnit
        let concentration = profile.isConcentrated ? " \(profile.concentration.label)" : ""
        let value: Double
        let items: [RepeatingScheduleValue<Double>]
        let valueText: String
        switch kind {
        case .basal:
            value = TherapyOptimizerMath.roundedToGrid(calculated / factor, stepsPerUnit: TherapyOptimizerMath.basalStepsPerUnit)
            items = profile.basalRateSchedule.items
            valueText = String(format: "%.2f U/hr", locale: .current, value) + concentration
        case .sensitivity:
            let unit = profile.insulinSensitivitySchedule.unit
            value = TherapyOptimizerMath.roundedToGrid(HKQuantity(unit: .milligramsPerDeciliter, doubleValue: calculated).doubleValue(for: unit) * factor, stepsPerUnit: TherapyOptimizerMath.sensitivityStepsPerUnit(unit))
            items = profile.insulinSensitivitySchedule.items
            valueText = String(format: unit == .milligramsPerDeciliter ? "%.0f %@/U" : "%.1f %@/U", locale: .current, value, unit.localizedShortUnitString) + concentration
        case .carbRatio:
            value = TherapyOptimizerMath.roundedToGrid(calculated * factor, stepsPerUnit: TherapyOptimizerMath.carbRatioStepsPerUnit)
            items = profile.carbRatioSchedule.items
            valueText = String(format: "%.1f g/U", locale: .current, value) + concentration
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
    private func offerScale(_ kind: TherapyProfilesModel.ScheduleKind, calculatedAllDay: Double, referenceAllDay: Double, dataDays: Int) {
        guard referenceAllDay > 0, hasEnoughData(dataDays) else { return }
        let factor = calculatedAllDay / referenceAllDay
        let percent = (factor - 1) * 100
        guard abs(percent) >= 0.5 else {
            message = String(format: NSLocalizedString("“%@” already matches the calculated values.", comment: "Message when the all-day change is below 1 % (1: profile name)"), profile.name)
            return
        }
        let summary = String(format: NSLocalizedString("All entries of “%@” %+.0f %%; the hourly pattern is kept.", comment: "Summary of an all-day change to apply (1: profile name, 2: percent)"), profile.name, percent)
        pendingChange = CalculatedProfileChange(profileID: profile.id, kind: kind, change: .scale(factor), summary: summary)
    }

    private func hasEnoughData(_ dataDays: Int) -> Bool {
        let required = TherapyOptimizerEngine.reliableHourDataDays
        guard dataDays < required else { return true }
        message = String(format: NSLocalizedString("This value is based on %1$d days of data; at least %2$d are needed to apply it.", comment: "Message when a calculated value has too little data to be applied (1: days of data, 2: required days)"), dataDays, required)
        return false
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
                Section(footer: Text(NSLocalizedString("Parts that are not taken are copied from the active profile. Parts and hours with fewer than 3 days of data keep the profile's values.", comment: "Footer of the create-from-calculated sheet"))) {
                    includeToggle(NSLocalizedString("Basal Rates", comment: "Therapy profile basal rates row"), isOn: $includeBasal, hasData: hasEnoughData(state.basal))
                    includeToggle(NSLocalizedString("Insulin Sensitivities", comment: "Therapy profile insulin sensitivities row"), isOn: $includeSensitivity, hasData: hasEnoughData(state.sensitivity))
                    if includeSensitivity && hasEnoughData(state.sensitivity) {
                        modePicker(selection: $hourlySensitivity)
                    }
                    includeToggle(NSLocalizedString("Carb Ratios", comment: "Therapy profile carb ratios row"), isOn: $includeCarbRatio, hasData: hasEnoughData(state.carbRatio))
                    if includeCarbRatio && hasEnoughData(state.carbRatio) {
                        modePicker(selection: $hourlyCarbRatio)
                    }
                }
                Section(footer: Text(NSLocalizedString("Calculated values are U100. With U200 on, basal rates and limits are halved and carb ratios and insulin sensitivities doubled.", comment: "Footer of the U200 switch when creating a profile from calculated values"))) {
                    Toggle(NSLocalizedString("U200 Insulin", comment: "Switch that creates the therapy profile for U200 insulin"), isOn: $isU200)
                }
                if isU200, let draft = draft {
                    BasalConversionPreview(source: draft, target: .u200)
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

    private func includeToggle(_ title: String, isOn: Binding<Bool>, hasData: Bool) -> some View {
        Toggle(title, isOn: Binding(get: { isOn.wrappedValue && hasData }, set: { isOn.wrappedValue = $0 }))
            .disabled(!hasData)
    }

    private func hasEnoughData(_ values: TherapyOptimizerValues) -> Bool {
        let required = TherapyOptimizerEngine.reliableHourDataDays
        return values.dataDaysAllDay >= required || values.dataDays.contains { $0 >= required }
    }

    /// The new profile in U100: calculated parts plus the active profile's other parts, converted to U100 if needed.
    private var draft: TherapyProfile? {
        let base = profiles.activeProfileInU100
        let live = profiles.liveViewModel.therapySettings
        let maximumBasalRate = base?.maximumBasalRatePerHour ?? live.maximumBasalRatePerHour
        let basal = includeBasal && hasEnoughData(state.basal)
            ? state.calculatedBasalSchedule(maximumBasalRate: maximumBasalRate, maximumEntryCount: profiles.liveViewModel.maximumBasalScheduleEntryCount)
            : base?.basalRateSchedule
        let sensitivity = includeSensitivity && hasEnoughData(state.sensitivity) ? state.calculatedSensitivitySchedule(hourly: hourlySensitivity) : base?.insulinSensitivitySchedule
        let carbRatio = includeCarbRatio && hasEnoughData(state.carbRatio) ? state.calculatedCarbRatioSchedule(hourly: hourlyCarbRatio) : base?.carbRatioSchedule

        guard let basal = basal, let sensitivity = sensitivity, let carbRatio = carbRatio else {
            return nil
        }
        return TherapyProfile(
            name: name.trimmingCharacters(in: .whitespaces),
            basalRateSchedule: basal,
            carbRatioSchedule: carbRatio,
            insulinSensitivitySchedule: sensitivity,
            maximumBasalRatePerHour: maximumBasalRate,
            maximumBolus: base?.maximumBolus ?? live.maximumBolus
        )
    }

    private func create() {
        guard let draft = draft else {
            errorMessage = NSLocalizedString("The profile could not be created.", comment: "Error when a profile cannot be created from calculated values")
            return
        }
        do {
            profiles.add(try draft.copy(named: draft.name, concentration: isU200 ? .u200 : .u100))
            presentationMode.wrappedValue.dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
