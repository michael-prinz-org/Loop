//
//  SettingsView.swift
//  LoopUI
//
//  Created by Rick Pasetto on 6/24/20.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import Combine
import LoopKit
import LoopKitUI
import LoopCore
import MockKit
import SwiftUI
import HealthKit

public struct SettingsView: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @Environment(\.dismissAction) private var dismiss
    @Environment(\.appName) private var appName
    @Environment(\.guidanceColors) private var guidanceColors
    @Environment(\.carbTintColor) private var carbTintColor
    @Environment(\.glucoseTintColor) private var glucoseTintColor
    @Environment(\.insulinTintColor) private var insulinTintColor

    @ObservedObject var viewModel: SettingsViewModel
    @ObservedObject var versionUpdateViewModel: VersionUpdateViewModel

    enum Destination {
        enum Alert: String, Identifiable {
            var id: String {
                rawValue
            }
            
            case deleteCGMData
            case deletePumpData
        }
        
        enum ActionSheet: String, Identifiable {
            var id: String {
                rawValue
            }
            
            case cgmPicker
            case pumpPicker
            case servicePicker
        }
        
        enum Sheet: String, Identifiable {
            var id: String {
                rawValue
            }
            
            case favoriteFoods
        }
    }
    
    @State private var actionSheet: Destination.ActionSheet?
    @State private var alert: Destination.Alert?
    @State private var sheet: Destination.Sheet?
    
    var localizedAppNameAndVersion: String

    public init(viewModel: SettingsViewModel, localizedAppNameAndVersion: String) {
        self.viewModel = viewModel
        self.versionUpdateViewModel = viewModel.versionUpdateViewModel
        self.localizedAppNameAndVersion = localizedAppNameAndVersion
    }
    
    public var body: some View {
        NavigationView {
            List {
                Group {
                    loopSection
                    if versionUpdateViewModel.softwareUpdateAvailable {
                        softwareUpdateSection
                    }
                    if FeatureFlags.automaticBolusEnabled {
                        dosingStrategySection
                    }
                    alertManagementSection
                    if viewModel.pumpManagerSettingsViewModel.isSetUp() {
                        configurationSection
                    }
                    deviceSettingsSection
                    if FeatureFlags.allowExperimentalFeatures {
                        favoriteFoodsSection
                    }
                    if (viewModel.pumpManagerSettingsViewModel.isTestingDevice || viewModel.cgmManagerSettingsViewModel.isTestingDevice) && viewModel.showDeleteTestData {
                        deleteDataSection
                    }
                }
                Group {
                    if viewModel.servicesViewModel.showServices {
                        servicesSection
                    }

                    ForEach(customSections) { customSectionName in
                        menuItemsForSection(name: customSectionName)
                    }

                    supportSection

                    if let profileExpiration = BuildDetails.default.profileExpiration, FeatureFlags.profileExpirationSettingsViewEnabled {
                        appExpirationSection(profileExpiration: profileExpiration)
                    }
                }
            }
            .insetGroupedListStyle()
            .navigationBarTitle(Text(NSLocalizedString("Settings", comment: "Settings screen title")))
            .navigationBarItems(trailing: dismissButton)
            .alert(item: $alert) { alert in
                switch alert {
                case .deleteCGMData:
                    return makeDeleteAlert(for: self.viewModel.cgmManagerSettingsViewModel)
                case .deletePumpData:
                    return makeDeleteAlert(for: self.viewModel.pumpManagerSettingsViewModel)
                }
            }
            .sheet(item: $sheet) { sheet in
                switch sheet {
                case .favoriteFoods:
                    FavoriteFoodsView()
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private func menuItemsForSection(name: String) -> some View {
        Section(header: SectionHeader(label: name)) {
            ForEach(pluginMenuItems.filter {$0.section.customLocalizedTitle == name}) { item in
                item.view
            }
        }
    }

    private var customSections: [String] {
        pluginMenuItems.compactMap { item in
            if case .custom(let name) = item.section {
                return name
            } else {
                return nil
            }
        }
    }
    
    private var closedLoopToggleState: Binding<Bool> {
        Binding(
            get: { self.viewModel.isClosedLoopAllowed && self.viewModel.closedLoopPreference },
            set: { self.viewModel.closedLoopPreference = $0 }
        )
    }
}

extension String: Identifiable {
    public typealias ID = Int
    public var id: Int {
        return hash
    }
}

struct PluginMenuItem<Content: View>: Identifiable {
    var id: String {
        return pluginIdentifier + String(describing: offset)
    }

    let section: SettingsMenuSection
    let view: Content
    let pluginIdentifier: String
    let offset: Int
}

extension SettingsView {
        
    private var dismissButton: some View {
        Button(action: dismiss) {
            Text("Done").bold()
        }
    }

    private var loopSection: some View {
        Section(header: SectionHeader(label: localizedAppNameAndVersion)) {
            Toggle(isOn: closedLoopToggleState) {
                VStack(alignment: .leading) {
                    Text("Closed Loop", comment: "The title text for the looping enabled switch cell")
                        .padding(.vertical, 3)
                    if !viewModel.isOnboardingComplete {
                        DescriptiveText(label: NSLocalizedString("Closed Loop requires Setup to be Complete", comment: "The description text for the looping enabled switch cell when onboarding is not complete"))
                    } else if let closedLoopDescriptiveText = viewModel.closedLoopDescriptiveText {
                        DescriptiveText(label: closedLoopDescriptiveText)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(!viewModel.isOnboardingComplete || !viewModel.isClosedLoopAllowed)

            customLoopIntervalControls
        }
    }

    @ViewBuilder
    private var customLoopIntervalControls: some View {
        describedToggle(
            isOn: $viewModel.customLoopIntervalEnabled,
            title: Text("Custom pod communication interval", comment: "The title text for the custom loop interval switch cell"),
            description: NSLocalizedString("Rate limit: caps how often Loop is allowed to contact the pod (dose syncs and background freshness syncs alike) to at most once per the interval below, in both foreground and background. It does not decide whether a sync happens, only how often — see Skip Background Pod Syncs below to also skip syncs that aren't needed for a dose. Off keeps the standard loop cadence.", comment: "The description text for the custom loop interval switch cell")
        )

        VStack(alignment: .leading, spacing: 4) {
            ExpandableWheelPicker(
                title: Text("Pod communication interval", comment: "The label for the pod communication interval picker"),
                selection: $viewModel.customLoopIntervalMinutes,
                options: (Int(viewModel.minimumCustomLoopIntervalMinutes)...Int(viewModel.maximumCustomLoopIntervalMinutes)).map { Double($0) },
                label: { String(format: NSLocalizedString("%d min", comment: "Custom loop interval value in minutes (1: number of minutes)"), Int($0.rounded())) }
            )

            if viewModel.customLoopIntervalExceedsRecencyLimit {
                DescriptiveText(label: NSLocalizedString("Above 13 minutes the pod is contacted less often than pump data stays fresh, so a status refresh is performed right before a dose and insulin adjustments can lag up to the communication interval.", comment: "Warning shown when the pod communication interval exceeds the pump data recency limit"))
                    .foregroundColor(guidanceColors.warning)
            }
        }
        .padding(.vertical, 3)
        .disabled(!viewModel.customLoopIntervalEnabled)

        describedToggle(
            isOn: $viewModel.suppressPodCommunicationInBackground,
            title: Text("Skip Background Pod Syncs", comment: "The title text for the disable pod communication switch cell"),
            description: NSLocalizedString("Need filter: while the app is in the background, skips the routine sync Loop otherwise makes just to keep pod data fresh, so the pod is only contacted when a dose actually needs to be delivered. A required dose is never skipped. The app in the foreground is unaffected — freshness syncs continue there so status shown on screen stays current. With Closed Loop off there are no freshness syncs to skip, so this setting has no effect.", comment: "The description text for the disable pod communication switch cell")
        )
    }

    @ViewBuilder
    private func describedToggle(isOn: Binding<Bool>, title: Text, description: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading) {
                title
                    .padding(.vertical, 3)
                DescriptiveText(label: description)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private var softwareUpdateSection: some View {
        Section(footer: Text(viewModel.versionUpdateViewModel.footer(appName: appName))) {
            NavigationLink(destination: viewModel.versionUpdateViewModel.softwareUpdateView) {
                Text(NSLocalizedString("Software Update", comment: "Software update button link text"))
                Spacer()
                viewModel.versionUpdateViewModel.icon
            }
        }
    }

    private var dosingStrategySection: some View {
        Section(header: SectionHeader(label: NSLocalizedString("Dosing Strategy", comment: "The title of the Dosing Strategy section in settings"))) {
            
            NavigationLink(destination: DosingStrategySelectionView(automaticDosingStrategy: $viewModel.automaticDosingStrategy))
            {
                HStack {
                    Text(viewModel.automaticDosingStrategy.title)
                }
            }
        }
    }
    
    @ViewBuilder
    private var alertWarning: some View {
        if viewModel.alertPermissionsChecker.showWarning || viewModel.alertPermissionsChecker.notificationCenterSettings.scheduledDeliveryEnabled {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.critical)
        } else if viewModel.alertMuter.configuration.shouldMute {
            Image(systemName: "speaker.slash.fill")
                .foregroundColor(.white)
                .padding(5)
                .background(guidanceColors.warning)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    private var alertManagementSection: some View {
        Section {
            NavigationLink(destination: AlertManagementView(checker: viewModel.alertPermissionsChecker, alertMuter: viewModel.alertMuter)) {
                LargeButton(
                    action: {},
                    includeArrow: false,
                    imageView: Image(systemName: "bell.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 30),
                    secondaryImageView: alertWarning,
                    label: NSLocalizedString("Alert Management", comment: "Alert Permissions button text"),
                    descriptiveText: NSLocalizedString("Alert Permissions and Mute Alerts", comment: "Alert Permissions descriptive text")
                )
            }
        }
    }

    private var therapySettingsView: some View {
        TherapySettingsScreen(glucoseDisplayRange: $viewModel.glucoseDisplayRange, makeBridge: {
            StandardTherapySettingsBridge(
                liveViewModel: TherapySettingsViewModel(
                    therapySettings: viewModel.therapySettings(),
                    sensitivityOverridesEnabled: FeatureFlags.sensitivityOverridesEnabled,
                    adultChildInsulinModelSelectionEnabled: FeatureFlags.adultChildInsulinModelSelectionEnabled,
                    delegate: viewModel.therapySettingsViewModelDelegate
                ),
                sensitivityOverridesEnabled: FeatureFlags.sensitivityOverridesEnabled,
                adultChildInsulinModelSelectionEnabled: FeatureFlags.adultChildInsulinModelSelectionEnabled
            )
        })
        .environmentObject(displayGlucosePreference)
        .environment(\.dismissAction, self.dismiss)
        .environment(\.appName, self.appName)
        .environment(\.chartColorPalette, .primary)
        .environment(\.carbTintColor, self.carbTintColor)
        .environment(\.glucoseTintColor, self.glucoseTintColor)
        .environment(\.guidanceColors, self.guidanceColors)
        .environment(\.insulinTintColor, self.insulinTintColor)
    }

    private var configurationSection: some View {
        Section(header: SectionHeader(label: NSLocalizedString("Configuration", comment: "The title of the Configuration section in settings"))) {
            NavigationLink(destination: therapySettingsView) {
                LargeButton(action: { },
                            includeArrow: false,
                            imageView: Image("Therapy Icon"),
                            label: NSLocalizedString("Therapy Settings", comment: "Title text for button to Therapy Settings"),
                            descriptiveText: NSLocalizedString("Diabetes Treatment", comment: "Descriptive text for Therapy Settings"))
            }

            NavigationLink(destination: InsulinEffectMonitorSettingsView().environmentObject(displayGlucosePreference)) {
                LargeButton(action: { },
                            includeArrow: false,
                            imageView: Image(systemName: "exclamationmark.triangle")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .foregroundColor(.orange)
                                .frame(width: 30),
                            label: NSLocalizedString("Insulin Effect", comment: "Title of the insulin effect screens and status row"),
                            descriptiveText: NSLocalizedString("Warns when insulin seems not to work", comment: "Descriptive text for the insulin effect monitor settings"))
            }

            ForEach(pluginMenuItems.filter {$0.section == .configuration}) { item in
                item.view
            }

            if FeatureFlags.allowAlgorithmExperiments {
                algorithmExperimentsSection
            }
        }
    }

    private var pluginMenuItems: [PluginMenuItem<some View>] {
        self.viewModel.availableSupports.flatMap { plugin in
            plugin.configurationMenuItems().enumerated().map { index, item in
                PluginMenuItem(section: item.section, view: item.view, pluginIdentifier: plugin.pluginIdentifier, offset: index)
            }
        }
    }

    private var deviceSettingsSection: some View {
        Section {
            pumpSection
            cgmSection
        }
    }
    
    @ViewBuilder
    private var pumpSection: some View {
        if viewModel.pumpManagerSettingsViewModel.isSetUp() {
            LargeButton(action: self.viewModel.pumpManagerSettingsViewModel.didTap,
                        includeArrow: true,
                        imageView: deviceImage(uiImage: viewModel.pumpManagerSettingsViewModel.image()),
                        label: viewModel.pumpManagerSettingsViewModel.name(),
                        descriptiveText: NSLocalizedString("Insulin Pump", comment: "Descriptive text for Insulin Pump"))
        } else if viewModel.isOnboardingComplete {
            LargeButton(action: { actionSheet = .pumpPicker },
                        includeArrow: false,
                        imageView: plusImage,
                        label: NSLocalizedString("Add Pump", comment: "Title text for button to add pump device"),
                        descriptiveText: NSLocalizedString("Tap here to set up a pump", comment: "Descriptive text for button to add pump device"))
            .background(
                PluginPopover(
                    isPresented: actionSheetBinding(for: .pumpPicker),
                    title: NSLocalizedString("Add Pump", comment: "The title of the pump chooser in settings"),
                    actions: pumpChoices
                )
            )
        }
    }

    private var pumpChoices: [PluginPopover.Action] {
        viewModel.pumpManagerSettingsViewModel.availableDevices.map { availableDevice in
            .init(title: availableDevice.localizedTitle) {
                self.viewModel.pumpManagerSettingsViewModel.didTapAdd(availableDevice)
            }
        }
    }
    
    @ViewBuilder
    private var cgmSection: some View {
        if viewModel.cgmManagerSettingsViewModel.isSetUp() {
            LargeButton(action: self.viewModel.cgmManagerSettingsViewModel.didTap,
                        includeArrow: true,
                        imageView: deviceImage(uiImage: viewModel.cgmManagerSettingsViewModel.image()),
                        label: viewModel.cgmManagerSettingsViewModel.name(),
                        descriptiveText: NSLocalizedString("Continuous Glucose Monitor", comment: "Descriptive text for Continuous Glucose Monitor"))
        } else {
            LargeButton(action: { actionSheet = .cgmPicker },
                        includeArrow: false,
                        imageView: plusImage,
                        label: NSLocalizedString("Add CGM", comment: "Title text for button to add CGM device"),
                        descriptiveText: NSLocalizedString("Tap here to set up a CGM", comment: "Descriptive text for button to add CGM device"))
            .background(
                PluginPopover(
                    isPresented: actionSheetBinding(for: .cgmPicker),
                    title: NSLocalizedString("Add CGM", comment: "The title of the CGM chooser in settings"),
                    actions: cgmChoices
                )
            )
        }
    }
    
    private var favoriteFoodsSection: some View {
        Section {
            LargeButton(action: { sheet = .favoriteFoods },
                        includeArrow: true,
                        imageView: Image("Favorite Foods Icon").renderingMode(.template).foregroundColor(carbTintColor),
                        label: NSLocalizedString("Favorite Foods", comment: "Label for Favorite Foods icon in Settings"),
                        descriptiveText: NSLocalizedString("Simplify Carb Entry", comment: "Subheading for Favorite Foods in Settings"))
        }
    }
    
    private var cgmChoices: [PluginPopover.Action] {
        viewModel.cgmManagerSettingsViewModel.availableDevices
            .sorted(by: {$0.localizedTitle < $1.localizedTitle})
            .map { availableDevice in
                .init(title: availableDevice.localizedTitle) {
                    self.viewModel.cgmManagerSettingsViewModel.didTapAdd(availableDevice)
                }
            }
    }
    
    private var servicesSection: some View {
        Section(header: SectionHeader(label: NSLocalizedString("Services", comment: "The title of the services section in settings"))) {
            ForEach(viewModel.servicesViewModel.activeServices().indices, id: \.self) { index in
                LargeButton(action: { self.viewModel.servicesViewModel.didTapService(index) },
                            includeArrow: true,
                            imageView: self.serviceImage(uiImage: (self.viewModel.servicesViewModel.activeServices()[index] as? ServiceUI)?.image),
                            label: self.viewModel.servicesViewModel.activeServices()[index].localizedTitle,
                            descriptiveText: "")
            }
            if viewModel.servicesViewModel.inactiveServices().count > 0 {
                LargeButton(action: { actionSheet = .servicePicker },
                            includeArrow: false,
                            imageView: plusImage,
                            label: NSLocalizedString("Add Service", comment: "The title of the add service button in settings"),
                            descriptiveText: NSLocalizedString("Tap here to set up a Service", comment: "The descriptive text of the add service button in settings"))
                .background(
                    PluginPopover(
                        isPresented: actionSheetBinding(for: .servicePicker),
                        title: NSLocalizedString("Add Service", comment: "The title of the add service action sheet in settings"),
                        actions: serviceChoices
                    )
                )
            }
        }
    }

    private var serviceChoices: [PluginPopover.Action] {
        viewModel.servicesViewModel.inactiveServices().map { availableService in
            .init(title: availableService.localizedTitle) {
                self.viewModel.servicesViewModel.didTapAddService(availableService)
            }
        }
    }
    
    private func actionSheetBinding(for destination: Destination.ActionSheet) -> Binding<Bool> {
        Binding(
            get: { actionSheet == destination },
            set: { isPresented in
                if !isPresented && actionSheet == destination {
                    actionSheet = nil
                }
            }
        )
    }

    private var deleteDataSection: some View {
        Section {
            if viewModel.pumpManagerSettingsViewModel.isTestingDevice {
                Button(action: { alert = .deletePumpData }) {
                    HStack {
                        Spacer()
                        Text("Delete Testing Pump Data").accentColor(.destructive)
                        Spacer()
                    }
                }
            }
            if viewModel.cgmManagerSettingsViewModel.isTestingDevice {
                Button(action: { alert = .deleteCGMData }) {
                    HStack {
                        Spacer()
                        Text("Delete Testing CGM Data").accentColor(.destructive)
                        Spacer()
                    }
                }
            }
        }
    }
    
    private func makeDeleteAlert<T>(for model: DeviceViewModel<T>) -> SwiftUI.Alert {
        return SwiftUI.Alert(title: Text("Delete Testing Data"),
                             message: Text("Are you sure you want to delete all your \(model.name()) Data?\n(This action is not reversible)", comment: "Confirmation before you delete all your Simulated Test Devices data"),
                             primaryButton: .cancel(),
                             secondaryButton: .destructive(Text("Delete"), action: model.deleteTestingDataFunc()))
    }
    
    private var supportSection: some View {
        Section(header: SectionHeader(label: NSLocalizedString("Support", comment: "The title of the support section in settings"))) {
            Button(action: {
                self.viewModel.didTapIssueReport()
            }) {
                Text("Issue Report", comment: "The title text for the issue report menu item")
            }

            ForEach(pluginMenuItems.filter( { $0.section == .support })) {
                $0.view
            }

            NavigationLink(destination: CriticalEventLogExportView(viewModel: viewModel.criticalEventLogExportViewModel)) {
                Text(NSLocalizedString("Export Critical Event Logs", comment: "The title of the export critical event logs in support"))
            }

            NavigationLink(destination: LogView()) {
                Text(NSLocalizedString("View Logs", comment: "The title of the view logs item in the support section"))
            }
        }
    }
    
    /*
     DIY loop specific component to show users the amount of time remaining on their build before a rebuild is necessary.
     */
    private func appExpirationSection(profileExpiration: Date) -> some View {
        let expirationDate = AppExpirationAlerter.calculateExpirationDate(profileExpiration: profileExpiration)
        let isTestFlight = AppExpirationAlerter.isTestFlightBuild()
        let nearExpiration = AppExpirationAlerter.isNearExpiration(expirationDate: expirationDate)
        let profileExpirationMsg = AppExpirationAlerter.createProfileExpirationSettingsMessage(expirationDate: expirationDate)
        let readableExpirationTime = Self.dateFormatter.string(from: expirationDate)
        
        if isTestFlight {
            return createAppExpirationSection(
                headerLabel: NSLocalizedString("TestFlight", comment: "Settings app TestFlight section"),
                footerLabel: NSLocalizedString("TestFlight expires ", comment: "Time that build expires") + readableExpirationTime,
                expirationLabel: NSLocalizedString("TestFlight Expiration", comment: "Settings TestFlight expiration view"),
                updateURL: "https://loopkit.github.io/loopdocs/gh-actions/gh-update/",
                nearExpiration: nearExpiration,
                expirationMessage: profileExpirationMsg
            )
        } else {
            return createAppExpirationSection(
                headerLabel: NSLocalizedString("App Profile", comment: "Settings app profile section"),
                footerLabel: NSLocalizedString("Profile expires ", comment: "Time that profile expires") + readableExpirationTime,
                expirationLabel: NSLocalizedString("Profile Expiration", comment: "Settings App Profile expiration view"),
                updateURL: "https://loopkit.github.io/loopdocs/build/updating/",
                nearExpiration: nearExpiration,
                expirationMessage: profileExpirationMsg
            )
        }
    }
    
    private func createAppExpirationSection(headerLabel: String, footerLabel: String, expirationLabel: String, updateURL: String, nearExpiration: Bool, expirationMessage: String) -> some View {
        return Section(
            header: SectionHeader(label: headerLabel),
            footer: Text(footerLabel)
        ) {
            if nearExpiration {
                Text(expirationMessage).foregroundColor(.red)
            } else {
                HStack {
                    Text(expirationLabel)
                    Spacer()
                    Text(expirationMessage).foregroundColor(Color.secondary)
                }
            }
            Button(action: {
                UIApplication.shared.open(URL(string: updateURL)!)
            }) {
                Text(NSLocalizedString("How to update (LoopDocs)", comment: "The title text for how to update"))
            }
        }
    }

    private static var dateFormatter: DateFormatter = {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        dateFormatter.timeStyle = .short
        return dateFormatter // formats date like "February 4, 2023 at 2:35 PM"
    }()

    private var plusImage: some View {
        Image(systemName: "plus.circle")
            .resizable()
            .scaledToFit()
            .accentColor(Color(.systemGray))
            .padding(EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
    }
    
    @ViewBuilder
    private func deviceImage(uiImage: UIImage?) -> some View {
        if let uiImage = uiImage {
            Image(uiImage: uiImage)
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
        } else {
            Spacer()
        }
    }
    
    @ViewBuilder
    private func serviceImage(uiImage: UIImage?) -> some View {
        deviceImage(uiImage: uiImage)
    }
}

fileprivate struct LargeButton<Content: View, SecondaryContent: View>: View {
    
    let action: () -> Void
    var includeArrow: Bool
    let imageView: Content
    let secondaryImageView: SecondaryContent
    let label: String
    let descriptiveText: String
    
    init(
        action: @escaping () -> Void,
        includeArrow: Bool = true,
        imageView: Content,
        secondaryImageView: SecondaryContent = EmptyView(),
        label: String,
        descriptiveText: String
    ) {
        self.action = action
        self.includeArrow = includeArrow
        self.imageView = imageView
        self.secondaryImageView = secondaryImageView
        self.label = label
        self.descriptiveText = descriptiveText
    }

    // TODO: The design doesn't show this, but do we need to consider different values here for different size classes?
    private let spacing: CGFloat = 15
    private let imageWidth: CGFloat = 60
    private let imageHeight: CGFloat = 60
    private let secondaryImageWidth: CGFloat = 30
    private let secondaryImageHeight: CGFloat = 30
    private let topBottomPadding: CGFloat = 10
    
    public var body: some View {
        Button(action: action) {
            HStack {
                HStack(spacing: spacing) {
                    imageView.frame(maxWidth: imageWidth, maxHeight: imageHeight)
                    VStack(alignment: .leading) {
                        Text(label)
                            .foregroundColor(.primary)
                        DescriptiveText(label: descriptiveText)
                    }
                }
                
                if !(secondaryImageView is EmptyView) || includeArrow {
                    Spacer()
                }
                
                if !(secondaryImageView is EmptyView) {
                    secondaryImageView.frame(width: secondaryImageWidth, height: secondaryImageHeight)
                }
                
                if includeArrow {
                    // TODO: Ick. I can't use a NavigationLink because we're not Navigating, but this seems worse somehow.
                    Image(systemName: "chevron.right").foregroundColor(.gray).font(.footnote)
                }
            }
            .padding(EdgeInsets(top: topBottomPadding, leading: 0, bottom: topBottomPadding, trailing: 0))
        }
    }
}

/// Shows a title and the current value; tapping the row opens an inline wheel to change it.
struct ExpandableWheelPicker<Value: Hashable>: View {
    let title: Text
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    @Environment(\.isEnabled) private var isEnabled
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation {
                    isExpanded.toggle()
                }
            } label: {
                HStack {
                    title
                        .foregroundColor(.primary)
                    Spacer()
                    Text(label(selection))
                        .foregroundColor(isExpanded ? .accentColor : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded && isEnabled {
                Picker("", selection: $selection) {
                    ForEach(options, id: \.self) { option in
                        Text(label(option)).tag(option)
                    }
                }
                .pickerStyle(.wheel)
                .labelsHidden()
            }
        }
        .onChange(of: isEnabled) { enabled in
            if !enabled {
                isExpanded = false
            }
        }
    }
}

/// Glucose display thresholds, shown as a card at the end of Therapy Settings.
struct GlucoseRangeCard: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference

    @Binding var range: GlucoseDisplayRange

    var body: some View {
        let bounds = LoopSettings.glucoseDisplayRangeBounds
        return VStack(alignment: .leading, spacing: 10) {
            Text(NSLocalizedString("Glucose Range", comment: "Title text for the glucose range editor"))
                .font(.headline)
            DescriptiveText(label: NSLocalizedString("These thresholds define the general glucose limits used by Loop to classify glucose values.", comment: "Descriptive text for general glucose range"))
            Divider()
            row(NSLocalizedString("Urgent Low", comment: "Glucose display range threshold label"), keyPath: \.urgentLow, from: bounds.lowerBound, through: range.low - step)
            Divider()
            row(NSLocalizedString("Low", comment: "Glucose display range threshold label"), keyPath: \.low, from: range.urgentLow + step, through: range.high - step)
            Divider()
            row(NSLocalizedString("High", comment: "Glucose display range threshold label"), keyPath: \.high, from: range.low + step, through: range.urgentHigh - step)
            Divider()
            row(NSLocalizedString("Urgent High", comment: "Glucose display range threshold label"), keyPath: \.urgentHigh, from: range.high + step, through: bounds.upperBound)
        }
    }

    /// One display step (1 mg/dL or 0.1 mmol/L) in mg/dL.
    private var step: Double {
        displayGlucosePreference.unit == .millimolesPerLiter
            ? HKQuantity(unit: .millimolesPerLiter, doubleValue: 0.1).doubleValue(for: .milligramsPerDeciliter)
            : 1
    }

    private func row(_ title: String, keyPath: WritableKeyPath<GlucoseDisplayRange, Double>, from lower: Double, through upper: Double) -> some View {
        let options = values(from: lower, through: upper, current: range[keyPath: keyPath])
        let selection = Binding<Double>(
            get: {
                let current = range[keyPath: keyPath]
                return options.min { abs($0 - current) < abs($1 - current) } ?? current
            },
            set: { newValue in
                var updated = range
                updated[keyPath: keyPath] = newValue
                range = GlucoseDisplayRange(urgentLow: updated.urgentLow,
                                            low: updated.low,
                                            high: updated.high,
                                            urgentHigh: updated.urgentHigh)
            }
        )
        return ExpandableWheelPicker(
            title: Text(title),
            selection: selection,
            options: options,
            label: { displayGlucosePreference.format(HKQuantity(unit: .milligramsPerDeciliter, doubleValue: $0)) }
        )
    }

    /// Values on the display unit's grid between `lower` and `upper`, in mg/dL.
    private func values(from lower: Double, through upper: Double, current: Double) -> [Double] {
        let unit = displayGlucosePreference.unit
        let stepsPerUnit = unit == .millimolesPerLiter ? 10.0 : 1.0
        let first = (HKQuantity(unit: .milligramsPerDeciliter, doubleValue: lower).doubleValue(for: unit) * stepsPerUnit).rounded(.up)
        let last = (HKQuantity(unit: .milligramsPerDeciliter, doubleValue: upper).doubleValue(for: unit) * stepsPerUnit).rounded(.down)
        guard first <= last else {
            return [current]
        }
        return stride(from: first, through: last, by: 1).map {
            HKQuantity(unit: unit, doubleValue: $0 / stepsPerUnit).doubleValue(for: .milligramsPerDeciliter)
        }
    }
}

struct PluginPopover: UIViewControllerRepresentable {
    struct Action {
        let title: String
        let handler: () -> Void
    }

    @Binding var isPresented: Bool
    let title: String
    let actions: [Action]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        let coordinator = context.coordinator

        if !isPresented {
            coordinator.didPresent = false
            return
        }

        guard !coordinator.didPresent else { return }
        guard uiViewController.presentedViewController == nil else { return }

        coordinator.didPresent = true
        coordinator.onDismiss = { self.isPresented = false }

        let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for action in actions {
            alert.addAction(UIAlertAction(title: action.title, style: .default) { _ in
                self.isPresented = false
                action.handler()
            })
        }

        alert.addAction(UIAlertAction(
            title: NSLocalizedString("Cancel", comment: "The title of the cancel action in an action sheet"),
            style: .destructive
        ) { _ in
            self.isPresented = false
        })

        if let popover = alert.popoverPresentationController {
            popover.sourceView = uiViewController.view
            popover.sourceRect = uiViewController.view.bounds
            popover.delegate = coordinator
        }

        uiViewController.present(alert, animated: true)
    }

    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var didPresent = false
        var onDismiss: (() -> Void)?

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            onDismiss?()
        }
    }
}

struct LogView: View {
    @ObservedObject private var store = InAppLogStore.shared

    @State private var searchText = ""
    @State private var displayLimit = 100
    @State private var minimumLevel: InAppLogLevel = .debug
    @State private var selectedCategory: String?

    private static let countOptions = [10, 25, 50, 100, 250, 500, 1000, 2000, 5000, 10000]

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            enableBar
            Divider()
            controlBar
            Divider()
            content
        }
        .navigationTitle(Text(NSLocalizedString("Logs", comment: "Title of the in-app log view")))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: Text(NSLocalizedString("Search messages", comment: "Search field prompt in the log view")))
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    store.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel(Text(NSLocalizedString("Clear", comment: "Clear logs button accessibility label")))
            }
        }
        // Keep the Settings sheet from swipe-dismissing while viewing logs; use the back button instead.
        .interactiveDismissDisabled()
    }

    private var enableBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { store.isCapturing },
                set: { store.setCapturing($0) }
            )) {
                Text(NSLocalizedString("Enable logging", comment: "Toggle label to enable in-app log capture"))
                    .font(.subheadline)
            }
            if !store.isCapturing {
                Text(NSLocalizedString("Logging is off. New messages are not captured.", comment: "Hint shown in the log view when in-app log capture is disabled"))
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            countMenu
            Spacer(minLength: 0)
            levelMenu
            Spacer(minLength: 0)
            categoryMenu
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var countMenu: some View {
        Menu {
            ForEach(Self.countOptions, id: \.self) { count in
                Button {
                    displayLimit = count
                } label: {
                    let title = String(format: NSLocalizedString("Last %d", comment: "Log entry count option (1: number of entries)"), count)
                    if displayLimit == count {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            menuLabel(systemImage: "number", text: String(format: NSLocalizedString("Last %d", comment: "Log entry count option (1: number of entries)"), displayLimit))
        }
    }

    private var levelMenu: some View {
        Menu {
            levelButton(NSLocalizedString("All levels", comment: "Log level filter option"), level: .debug)
            levelButton(NSLocalizedString("Info & up", comment: "Log level filter option"), level: .info)
            levelButton(NSLocalizedString("Default & up", comment: "Log level filter option"), level: .notice)
            levelButton(NSLocalizedString("Errors only", comment: "Log level filter option"), level: .error)
        } label: {
            menuLabel(systemImage: "line.3.horizontal.decrease.circle", text: minimumLevel == .debug ? NSLocalizedString("All levels", comment: "Log level filter option") : minimumLevel.title)
        }
    }

    private func levelButton(_ title: String, level: InAppLogLevel) -> some View {
        Button {
            minimumLevel = level
        } label: {
            if minimumLevel == level {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var categoryMenu: some View {
        Menu {
            Button {
                selectedCategory = nil
            } label: {
                let title = NSLocalizedString("All categories", comment: "Category filter option")
                if selectedCategory == nil {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
            ForEach(store.categories(), id: \.self) { category in
                Button {
                    selectedCategory = category
                } label: {
                    if selectedCategory == category {
                        Label(category, systemImage: "checkmark")
                    } else {
                        Text(category)
                    }
                }
            }
        } label: {
            menuLabel(systemImage: "tag", text: selectedCategory ?? NSLocalizedString("All categories", comment: "Category filter option"))
        }
    }

    private func menuLabel(systemImage: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .font(.footnote)
    }

    @ViewBuilder
    private var content: some View {
        let entries = filteredEntries
        if entries.isEmpty {
            VStack {
                Spacer()
                Text(NSLocalizedString("No log entries", comment: "Empty state for the log view"))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(entries) { entry in
                row(for: entry)
            }
            .listStyle(.plain)
        }
    }

    private var filteredEntries: [InAppLogEntry] {
        var entries = store.allEntries()
        if let selectedCategory {
            entries = entries.filter { $0.category == selectedCategory }
        }
        if minimumLevel != .debug {
            entries = entries.filter { $0.level >= minimumLevel }
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            entries = entries.filter {
                $0.message.localizedCaseInsensitiveContains(query) || $0.category.localizedCaseInsensitiveContains(query)
            }
        }
        // Show the most recent `displayLimit` entries, newest first.
        return Array(entries.suffix(displayLimit).reversed())
    }

    private func row(for entry: InAppLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: entry.level.systemImageName)
                    .font(.caption2)
                    .foregroundColor(color(for: entry.level))
                Text(entry.category)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Spacer()
                Text(Self.timeFormatter.string(from: entry.date))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
            Text(entry.message)
                .font(.system(.footnote, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func color(for level: InAppLogLevel) -> Color {
        switch level {
        case .debug: return .secondary
        case .info: return .accentColor
        case .notice: return .primary
        case .error: return .orange
        case .fault: return .red
        }
    }
}

// MARK: - Therapy profiles

/// Owns the Therapy Settings view models for one visit of the screen, so the profiles screen and the
/// Therapy Settings screen share (and stay in sync through) the same instances.
private struct TherapySettingsScreen: View {
    @EnvironmentObject private var displayGlucosePreference: DisplayGlucosePreference
    @StateObject private var bridge: StandardTherapySettingsBridge
    @Binding var glucoseDisplayRange: GlucoseDisplayRange

    init(glucoseDisplayRange: Binding<GlucoseDisplayRange>, makeBridge: @escaping () -> StandardTherapySettingsBridge) {
        _glucoseDisplayRange = glucoseDisplayRange
        _bridge = StateObject(wrappedValue: makeBridge())
    }

    var body: some View {
        TherapySettingsView(
            mode: .settings,
            viewModel: bridge.displayViewModel,
            headerContent: AnyView(activeProfileHeader),
            additionalContent: AnyView(GlucoseRangeCard(range: $glucoseDisplayRange).environmentObject(displayGlucosePreference))
        )
        .onAppear {
            bridge.reload()
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink(destination: TherapyProfilesView(liveViewModel: bridge.liveViewModel)
                                .environmentObject(displayGlucosePreference)) {
                    Text(NSLocalizedString("Profiles", comment: "Button in Therapy Settings that opens the therapy profiles list"))
                }
            }
        }
    }

    private var activeProfileHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(NSLocalizedString("Active Profile", comment: "Label of the active therapy profile in Therapy Settings"))
                    .font(.headline)
                Spacer()
                Text(bridge.activeProfileName ?? NSLocalizedString("Standard", comment: "Name of the protected standard therapy profile"))
                    .foregroundColor(bridge.isStandardActive ? .secondary : .orange)
            }
            if !bridge.isStandardActive {
                Text(NSLocalizedString("Loop uses the values of this profile. Basal rates, carb ratios, insulin sensitivities and delivery limits shown below belong to Standard; changes only affect Standard.", comment: "Notice in Therapy Settings while another therapy profile is active"))
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Shows the live therapy settings with basal rates, carb ratios, insulin sensitivities and delivery limits taken
/// from the Standard profile. Edits of those always update Standard and only reach Loop while Standard is active.
final class StandardTherapySettingsBridge: ObservableObject, TherapySettingsViewModelDelegate {
    let liveViewModel: TherapySettingsViewModel
    private let sensitivityOverridesEnabled: Bool
    private let adultChildInsulinModelSelectionEnabled: Bool
    private(set) lazy var displayViewModel: TherapySettingsViewModel = TherapySettingsViewModel(
        therapySettings: liveViewModel.therapySettings,
        sensitivityOverridesEnabled: sensitivityOverridesEnabled,
        adultChildInsulinModelSelectionEnabled: adultChildInsulinModelSelectionEnabled,
        delegate: self
    )
    @Published private(set) var isStandardActive = true
    @Published private(set) var activeProfileName: String?

    init(liveViewModel: TherapySettingsViewModel, sensitivityOverridesEnabled: Bool, adultChildInsulinModelSelectionEnabled: Bool) {
        self.liveViewModel = liveViewModel
        self.sensitivityOverridesEnabled = sensitivityOverridesEnabled
        self.adultChildInsulinModelSelectionEnabled = adultChildInsulinModelSelectionEnabled
        reload()
    }

    private var standard: TherapyProfile? {
        TherapyProfile.ensureStandard(from: liveViewModel.therapySettings)
    }

    func reload() {
        var display = liveViewModel.therapySettings
        if let standard = standard {
            standard.write(into: &display)
            let active = TherapyProfile.activeProfile()
            isStandardActive = active?.isStandardProfile != false
            activeProfileName = active?.displayName
        } else {
            isStandardActive = true
            activeProfileName = nil
        }
        displayViewModel.therapySettings = display
    }

    private var isStandardActiveNow: Bool {
        guard standard != nil else { return true }
        return TherapyProfile.activeProfile()?.isStandardProfile != false
    }

    func syncBasalRateSchedule(items: [RepeatingScheduleValue<Double>], completion: @escaping (Swift.Result<BasalRateSchedule, Error>) -> Void) {
        if isStandardActiveNow {
            liveViewModel.syncBasalRateSchedule(items: items, completion: completion)
        } else if let schedule = BasalRateSchedule(dailyItems: items, timeZone: liveViewModel.therapySettings.basalRateSchedule?.timeZone) {
            completion(.success(schedule))
        } else {
            completion(.failure(TherapyProfileError.invalidSchedule))
        }
    }

    func syncDeliveryLimits(deliveryLimits: DeliveryLimits, completion: @escaping (Swift.Result<DeliveryLimits, Error>) -> Void) {
        if isStandardActiveNow {
            liveViewModel.syncDeliveryLimits(deliveryLimits: deliveryLimits, completion: completion)
        } else {
            completion(.success(deliveryLimits))
        }
    }

    func saveCompletion(therapySettings: TherapySettings) {
        let live = liveViewModel.therapySettings
        var newLive = therapySettings
        let wasActive = isStandardActiveNow
        var profiles = UserDefaults.standard.therapyProfiles
        if let index = profiles.firstIndex(where: { $0.isStandardProfile }) {
            profiles[index].read(from: therapySettings)
            UserDefaults.standard.therapyProfiles = profiles
            if !wasActive {
                newLive.basalRateSchedule = live.basalRateSchedule
                newLive.carbRatioSchedule = live.carbRatioSchedule
                newLive.insulinSensitivitySchedule = live.insulinSensitivitySchedule
                newLive.maximumBasalRatePerHour = live.maximumBasalRatePerHour
                newLive.maximumBolus = live.maximumBolus
            }
        }

        liveViewModel.therapySettings = newLive
        if let basalRates = newLive.basalRateSchedule {
            liveViewModel.saveBasalRates(basalRates: basalRates)
        }
        // Called from inside the display view model's own save; refresh it afterwards.
        DispatchQueue.main.async {
            self.reload()
        }
    }

    func pumpSupportedIncrements() -> PumpSupportedIncrements? {
        liveViewModel.pumpSupportedIncrements()
    }
}

enum TherapyProfileError: LocalizedError {
    case basalRateAboveMaximum(Double)
    case invalidSchedule

    var errorDescription: String? {
        switch self {
        case .basalRateAboveMaximum(let maximum):
            return String(format: NSLocalizedString("This profile contains a basal rate above your maximum basal rate of %.2f U/hr. Edit the profile or raise the maximum basal rate first.", comment: "Error when activating a therapy profile whose basal rates exceed the maximum basal rate (1: maximum basal rate)"), maximum)
        case .invalidSchedule:
            return NSLocalizedString("The schedule is invalid.", comment: "Error when a therapy profile schedule cannot be created")
        }
    }
}

extension TherapyProfile {
    var isStandardProfile: Bool {
        isStandard == true
    }

    var concentration: InsulinConcentration {
        insulinConcentration ?? .u100
    }

    var isConcentrated: Bool {
        concentration != .u100
    }

    var displayName: String {
        isConcentrated ? "\(name) (\(concentration.label))" : name
    }

    init?(name: String, settings: TherapySettings, isStandard: Bool? = nil, insulinConcentration: InsulinConcentration? = nil) {
        guard let basalRates = settings.basalRateSchedule,
              let carbRatios = settings.carbRatioSchedule,
              let sensitivities = settings.insulinSensitivitySchedule else {
            return nil
        }
        self.init(
            name: name,
            basalRateSchedule: basalRates,
            carbRatioSchedule: carbRatios,
            insulinSensitivitySchedule: sensitivities,
            isStandard: isStandard,
            maximumBasalRatePerHour: settings.maximumBasalRatePerHour,
            maximumBolus: settings.maximumBolus,
            insulinConcentration: insulinConcentration
        )
    }

    /// Copies everything a profile holds into `settings`; missing delivery limits leave the current ones in place.
    func write(into settings: inout TherapySettings) {
        settings.basalRateSchedule = basalRateSchedule
        settings.carbRatioSchedule = carbRatioSchedule
        settings.insulinSensitivitySchedule = insulinSensitivitySchedule
        if let maximumBasalRatePerHour = maximumBasalRatePerHour {
            settings.maximumBasalRatePerHour = maximumBasalRatePerHour
        }
        if let maximumBolus = maximumBolus {
            settings.maximumBolus = maximumBolus
        }
    }

    mutating func read(from settings: TherapySettings) {
        if let basalRates = settings.basalRateSchedule {
            basalRateSchedule = basalRates
        }
        if let carbRatios = settings.carbRatioSchedule {
            carbRatioSchedule = carbRatios
        }
        if let sensitivities = settings.insulinSensitivitySchedule {
            insulinSensitivitySchedule = sensitivities
        }
        maximumBasalRatePerHour = settings.maximumBasalRatePerHour ?? maximumBasalRatePerHour
        maximumBolus = settings.maximumBolus ?? maximumBolus
    }

    /// Same insulin effect with another concentration: basal and limits scale with 1/factor (rounded to 0.05),
    /// carb ratios and insulin sensitivities with the factor (e.g. U100 → U200: halve / double).
    func converted(toConcentration target: InsulinConcentration, name: String) -> TherapyProfile? {
        let factor = target.unitsPerPumpUnit / concentration.unitsPerPumpUnit
        let pumpUnits: (Double) -> Double = { ($0 / factor * 20).rounded() / 20 }
        let limit: (Double) -> Double = { ($0 / factor * 20 + 1e-9).rounded(.down) / 20 }
        // Keep values on the editors' picker grids (0.1 g/U; 1 mg/dL or 0.1 mmol/L).
        let carbRatio: (Double) -> Double = { ($0 * factor * 10).rounded() / 10 }
        let sensitivityStepsPerUnit = insulinSensitivitySchedule.unit == .milligramsPerDeciliter ? 1.0 : 10.0
        let sensitivity: (Double) -> Double = { ($0 * factor * sensitivityStepsPerUnit).rounded() / sensitivityStepsPerUnit }
        guard let basalRates = BasalRateSchedule(
                dailyItems: basalRateSchedule.items.map { RepeatingScheduleValue(startTime: $0.startTime, value: pumpUnits($0.value)) },
                timeZone: basalRateSchedule.timeZone),
              let carbRatios = CarbRatioSchedule(
                unit: carbRatioSchedule.unit,
                dailyItems: carbRatioSchedule.items.map { RepeatingScheduleValue(startTime: $0.startTime, value: carbRatio($0.value)) },
                timeZone: carbRatioSchedule.timeZone),
              let sensitivities = InsulinSensitivitySchedule(
                unit: insulinSensitivitySchedule.unit,
                dailyItems: insulinSensitivitySchedule.items.map { RepeatingScheduleValue(startTime: $0.startTime, value: sensitivity($0.value)) },
                timeZone: insulinSensitivitySchedule.timeZone) else {
            return nil
        }
        return TherapyProfile(
            name: name,
            basalRateSchedule: basalRates,
            carbRatioSchedule: carbRatios,
            insulinSensitivitySchedule: sensitivities,
            maximumBasalRatePerHour: maximumBasalRatePerHour.map(limit),
            maximumBolus: maximumBolus.map(limit),
            insulinConcentration: target == .u100 ? nil : target
        )
    }

    /// Returns the stored Standard profile, creating it from `settings` the first time.
    @discardableResult
    static func ensureStandard(from settings: TherapySettings) -> TherapyProfile? {
        var profiles = UserDefaults.standard.therapyProfiles
        defer {
            migrateActiveProfileIfNeeded(liveSettings: settings)
        }
        if let index = profiles.firstIndex(where: { $0.isStandardProfile }) {
            // Standard profiles saved before delivery limits were part of profiles take the current ones once.
            if profiles[index].maximumBasalRatePerHour == nil || profiles[index].maximumBolus == nil {
                profiles[index].maximumBasalRatePerHour = profiles[index].maximumBasalRatePerHour ?? settings.maximumBasalRatePerHour
                profiles[index].maximumBolus = profiles[index].maximumBolus ?? settings.maximumBolus
                UserDefaults.standard.therapyProfiles = profiles
            }
            return profiles[index]
        }
        guard let standard = TherapyProfile(
            name: NSLocalizedString("Standard", comment: "Name of the protected standard therapy profile"),
            settings: settings,
            isStandard: true
        ) else {
            return nil
        }
        profiles.insert(standard, at: 0)
        UserDefaults.standard.therapyProfiles = profiles
        return standard
    }

    /// The single active profile; Standard when nothing else has been activated.
    static func activeProfile() -> TherapyProfile? {
        let profiles = UserDefaults.standard.therapyProfiles
        if let id = UserDefaults.standard.activeTherapyProfileID, let active = profiles.first(where: { $0.id == id }) {
            return active
        }
        return profiles.first { $0.isStandardProfile }
    }

    /// Before the active profile was stored, it was whichever profile equalled Loop's settings; carry that over once so
    /// Therapy Settings never treats Standard as active while Loop (and the pod) still run another profile.
    private static func migrateActiveProfileIfNeeded(liveSettings: TherapySettings) {
        guard UserDefaults.standard.activeTherapyProfileID == nil else { return }
        let profiles = UserDefaults.standard.therapyProfiles
        let isLive: (TherapyProfile) -> Bool = {
            $0.basalRateSchedule == liveSettings.basalRateSchedule
                && $0.carbRatioSchedule == liveSettings.carbRatioSchedule
                && $0.insulinSensitivitySchedule == liveSettings.insulinSensitivitySchedule
        }
        let active = profiles.first { $0.isStandardProfile && isLive($0) } ?? profiles.first(where: isLive) ?? profiles.first { $0.isStandardProfile }
        UserDefaults.standard.activeTherapyProfileID = active?.id
    }
}

final class TherapyProfilesModel: ObservableObject {
    @Published private(set) var profiles: [TherapyProfile]
    let liveViewModel: TherapySettingsViewModel
    private var liveSettingsCancellable: AnyCancellable?

    init(liveViewModel: TherapySettingsViewModel) {
        self.liveViewModel = liveViewModel
        TherapyProfile.ensureStandard(from: liveViewModel.therapySettings)
        self.profiles = UserDefaults.standard.therapyProfiles
        // The active marker depends on the live therapy settings.
        liveSettingsCancellable = liveViewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    func profile(withID id: UUID) -> TherapyProfile? {
        profiles.first { $0.id == id }
    }

    func isActive(_ profile: TherapyProfile) -> Bool {
        TherapyProfile.activeProfile()?.id == profile.id
    }

    var standardProfile: TherapyProfile? {
        profiles.first { $0.isStandardProfile }
    }

    func addProfileFromCurrentSettings() -> TherapyProfile? {
        guard let profile = TherapyProfile(
            name: String(format: NSLocalizedString("Profile %d", comment: "Default name of a new therapy profile (1: profile number)"), profiles.count + 1),
            settings: liveViewModel.therapySettings,
            insulinConcentration: TherapyProfile.activeProfile()?.insulinConcentration
        ) else {
            return nil
        }
        persist(profiles + [profile])
        return profile
    }

    func addProfile(name: String, basalRateSchedule: BasalRateSchedule, carbRatioSchedule: CarbRatioSchedule, insulinSensitivitySchedule: InsulinSensitivitySchedule, maximumBasalRatePerHour: Double?, maximumBolus: Double?) {
        persist(profiles + [TherapyProfile(
            name: name,
            basalRateSchedule: basalRateSchedule,
            carbRatioSchedule: carbRatioSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule,
            maximumBasalRatePerHour: maximumBasalRatePerHour,
            maximumBolus: maximumBolus
        )])
    }

    /// The active profile in U100 values, used as the base for profiles created from calculated (U100) values.
    var activeProfileInU100: TherapyProfile? {
        guard let active = TherapyProfile.activeProfile() else { return nil }
        return active.isConcentrated ? active.converted(toConcentration: .u100, name: active.name) : active
    }

    func addU200Copy(of profile: TherapyProfile) -> TherapyProfile? {
        guard let copy = profile.converted(toConcentration: .u200, name: String(format: NSLocalizedString("%@ U200", comment: "Name of a U200 copy of a therapy profile (1: original name)"), profile.name)) else {
            return nil
        }
        persist(profiles + [copy])
        return copy
    }

    func save(_ profile: TherapyProfile) {
        persist(profiles.map { $0.id == profile.id ? profile : $0 })
    }

    func delete(atOffsets offsets: IndexSet) {
        var updated = profiles
        let removable = IndexSet(offsets.filter { !profiles[$0].isStandardProfile && !isActive(profiles[$0]) })
        updated.remove(atOffsets: removable)
        persist(updated)
    }

    /// Transfers the whole profile: delivery limits and basal rates to the pump, then all values into Loop's settings.
    func activate(_ profile: TherapyProfile, completion: @escaping (Error?) -> Void) {
        let live = liveViewModel.therapySettings
        if let maximum = profile.maximumBasalRatePerHour ?? live.maximumBasalRatePerHour,
           profile.basalRateSchedule.items.contains(where: { $0.value > maximum + 1e-9 }) {
            completion(TherapyProfileError.basalRateAboveMaximum(maximum))
            return
        }
        let limits = DeliveryLimits(
            maximumBasalRate: (profile.maximumBasalRatePerHour ?? live.maximumBasalRatePerHour).map { HKQuantity(unit: DoseEntry.unitsPerHour, doubleValue: $0) },
            maximumBolus: (profile.maximumBolus ?? live.maximumBolus).map { HKQuantity(unit: .internationalUnit(), doubleValue: $0) }
        )
        let previousLimits = DeliveryLimits(
            maximumBasalRate: live.maximumBasalRatePerHour.map { HKQuantity(unit: DoseEntry.unitsPerHour, doubleValue: $0) },
            maximumBolus: live.maximumBolus.map { HKQuantity(unit: .internationalUnit(), doubleValue: $0) }
        )
        liveViewModel.syncDeliveryLimits(deliveryLimits: limits) { limitsResult in
            DispatchQueue.main.async {
                switch limitsResult {
                case .failure(let error):
                    completion(error)
                case .success(let syncedLimits):
                    self.syncBasalRatesAndApply(profile, syncedLimits: syncedLimits, previousLimits: previousLimits, completion: completion)
                }
            }
        }
    }

    private func syncBasalRatesAndApply(_ profile: TherapyProfile, syncedLimits: DeliveryLimits, previousLimits: DeliveryLimits, completion: @escaping (Error?) -> Void) {
        liveViewModel.syncBasalRateSchedule(items: profile.basalRateSchedule.items) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let syncedSchedule):
                    var activated = profile
                    activated.basalRateSchedule = syncedSchedule
                    let previousConcentration = TherapyProfile.activeProfile()?.concentration ?? .u100
                    self.save(activated)
                    UserDefaults.standard.activeTherapyProfileID = activated.id
                    // Before `apply`, so the effect caches it invalidates are rebuilt with rescaled dose history.
                    InsulinConcentrationHistory.record(activated.concentration, previous: previousConcentration)
                    self.apply(activated)
                    completion(nil)
                case .failure(let error):
                    self.restoreDeliveryLimits(previousLimits, pumpLimits: syncedLimits) {
                        completion(error)
                    }
                }
            }
        }
    }

    /// Puts the pump's limits back; if the pump refuses, Loop takes over the pump's limits so both always agree.
    private func restoreDeliveryLimits(_ previousLimits: DeliveryLimits, pumpLimits: DeliveryLimits, completion: @escaping () -> Void) {
        liveViewModel.syncDeliveryLimits(deliveryLimits: previousLimits) { result in
            DispatchQueue.main.async {
                if case .failure = result {
                    self.liveViewModel.saveDeliveryLimits(limits: pumpLimits)
                    if var active = TherapyProfile.activeProfile() {
                        active.maximumBasalRatePerHour = pumpLimits.maximumBasalRate?.doubleValue(for: DoseEntry.unitsPerHour)
                        active.maximumBolus = pumpLimits.maximumBolus?.doubleValue(for: .internationalUnit())
                        self.save(active)
                    }
                }
                completion()
            }
        }
    }

    /// Writes the profile into the live therapy settings without talking to the pump.
    func apply(_ profile: TherapyProfile) {
        var settings = liveViewModel.therapySettings
        profile.write(into: &settings)
        liveViewModel.therapySettings = settings
        liveViewModel.saveBasalRates(basalRates: profile.basalRateSchedule)
    }

    private func persist(_ updated: [TherapyProfile]) {
        profiles = updated
        UserDefaults.standard.therapyProfiles = updated
    }
}

/// Backs the stock LoopKitUI schedule editors with a profile instead of the live therapy settings.
/// Edits to the active profile are also applied live (basal rates are synced to the pump first).
final class TherapyProfileEditorModel: ObservableObject, TherapySettingsViewModelDelegate {
    let profileID: UUID
    private let profiles: TherapyProfilesModel
    private(set) lazy var viewModel: TherapySettingsViewModel = TherapySettingsViewModel(therapySettings: profiles.liveViewModel.therapySettings, delegate: self)

    init(profileID: UUID, profiles: TherapyProfilesModel) {
        self.profileID = profileID
        self.profiles = profiles
        reload()
    }

    func reload() {
        guard let profile = profiles.profile(withID: profileID) else { return }
        var settings = profiles.liveViewModel.therapySettings
        profile.write(into: &settings)
        viewModel.therapySettings = settings
    }

    private var isProfileActive: Bool {
        profiles.profile(withID: profileID).map { profiles.isActive($0) } ?? false
    }

    func syncBasalRateSchedule(items: [RepeatingScheduleValue<Double>], completion: @escaping (Swift.Result<BasalRateSchedule, Error>) -> Void) {
        if isProfileActive {
            profiles.liveViewModel.syncBasalRateSchedule(items: items, completion: completion)
        } else if let schedule = BasalRateSchedule(dailyItems: items, timeZone: viewModel.therapySettings.basalRateSchedule?.timeZone) {
            completion(.success(schedule))
        } else {
            completion(.failure(TherapyProfileError.invalidSchedule))
        }
    }

    func syncDeliveryLimits(deliveryLimits: DeliveryLimits, completion: @escaping (Swift.Result<DeliveryLimits, Error>) -> Void) {
        if isProfileActive {
            profiles.liveViewModel.syncDeliveryLimits(deliveryLimits: deliveryLimits, completion: completion)
        } else {
            completion(.success(deliveryLimits))
        }
    }

    func saveCompletion(therapySettings: TherapySettings) {
        guard var profile = profiles.profile(withID: profileID) else {
            return
        }
        let wasActive = profiles.isActive(profile)
        profile.read(from: therapySettings)
        profiles.save(profile)
        if wasActive {
            profiles.apply(profile)
        }
    }

    func pumpSupportedIncrements() -> PumpSupportedIncrements? {
        profiles.liveViewModel.pumpSupportedIncrements()
    }
}

struct TherapyProfilesView: View {
    @StateObject private var model: TherapyProfilesModel
    @State private var selectedProfileID: UUID?

    init(liveViewModel: TherapySettingsViewModel) {
        _model = StateObject(wrappedValue: TherapyProfilesModel(liveViewModel: liveViewModel))
    }

    var body: some View {
        List {
            Section(footer: Text(NSLocalizedString("A profile is a set of basal rates, carb ratios and insulin sensitivities. Activating a profile sends its basal rates to the pump and makes it your current therapy settings.", comment: "Footer of the therapy profiles list"))) {
                ForEach(model.profiles) { profile in
                    NavigationLink(destination: TherapyProfileDetailView(profileID: profile.id, profiles: model),
                                   tag: profile.id,
                                   selection: $selectedProfileID) {
                        HStack {
                            Text(profile.name)
                            if profile.isStandardProfile {
                                Image(systemName: "lock.fill")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            if profile.isConcentrated {
                                Text(profile.concentration.label)
                                    .font(.caption.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.orange))
                            }
                            Spacer()
                            if model.isActive(profile) {
                                Text(NSLocalizedString("Active", comment: "Marker for the therapy profile matching the current therapy settings"))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .deleteDisabled(profile.isStandardProfile || model.isActive(profile))
                }
                .onDelete(perform: model.delete(atOffsets:))
            }

            Section {
                Button(NSLocalizedString("New Profile from Current Settings", comment: "Button that creates a therapy profile from the current therapy settings")) {
                    selectedProfileID = model.addProfileFromCurrentSettings()?.id
                }
            }

            Section(header: Text(NSLocalizedString("Calculated", comment: "Header of the calculated therapy profile section"))) {
                NavigationLink(destination: CalculatedProfileView(profiles: model)) {
                    Text(NSLocalizedString("Calculated Profile", comment: "Row that opens the calculated therapy profile"))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(NSLocalizedString("Profiles", comment: "Title of the therapy profiles list")))
    }
}

struct TherapyProfileDetailView: View {
    private enum Editor: Hashable {
        case basalRates
        case carbRatios
        case insulinSensitivities
        case deliveryLimits
    }

    @ObservedObject var profiles: TherapyProfilesModel
    @StateObject private var editor: TherapyProfileEditorModel
    @State private var name: String
    @State private var activeEditor: Editor?
    @State private var activationTarget: TherapyProfile?
    @State private var isActivating = false
    @State private var activationErrorMessage: String?

    init(profileID: UUID, profiles: TherapyProfilesModel) {
        self.profiles = profiles
        _editor = StateObject(wrappedValue: TherapyProfileEditorModel(profileID: profileID, profiles: profiles))
        _name = State(initialValue: profiles.profile(withID: profileID)?.name ?? "")
    }

    private var profile: TherapyProfile? {
        profiles.profile(withID: editor.profileID)
    }

    var body: some View {
        List {
            Section(header: Text(NSLocalizedString("Name", comment: "Header of the therapy profile name field"))) {
                TextField(NSLocalizedString("Name", comment: "Placeholder of the therapy profile name field"), text: $name)
                    .disabled(profile?.isStandardProfile == true)
            }

            Section {
                NavigationLink(destination: BasalRateScheduleEditor(mode: .settings, therapySettingsViewModel: editor.viewModel, didSave: closeEditor),
                               tag: Editor.basalRates,
                               selection: $activeEditor) {
                    Text(NSLocalizedString("Basal Rates", comment: "Therapy profile basal rates row"))
                }
                NavigationLink(destination: CarbRatioScheduleEditor(mode: .settings, therapySettingsViewModel: editor.viewModel, didSave: closeEditor),
                               tag: Editor.carbRatios,
                               selection: $activeEditor) {
                    Text(NSLocalizedString("Carb Ratios", comment: "Therapy profile carb ratios row"))
                }
                NavigationLink(destination: InsulinSensitivityScheduleEditor(mode: .settings, therapySettingsViewModel: editor.viewModel, didSave: closeEditor),
                               tag: Editor.insulinSensitivities,
                               selection: $activeEditor) {
                    Text(NSLocalizedString("Insulin Sensitivities", comment: "Therapy profile insulin sensitivities row"))
                }
                if editor.viewModel.pumpSupportedIncrements() != nil {
                    NavigationLink(destination: DeliveryLimitsEditor(mode: .settings, therapySettingsViewModel: editor.viewModel, didSave: closeEditor),
                                   tag: Editor.deliveryLimits,
                                   selection: $activeEditor) {
                        Text(NSLocalizedString("Delivery Limits", comment: "Therapy profile delivery limits row"))
                    }
                }
            }

            if let profile = profile {
                Section(footer: Text(NSLocalizedString("A U200 copy halves basal rates, maximum basal rate and maximum bolus and doubles carb ratios and insulin sensitivities, so the same insulin effect results with insulin of double concentration. All amounts in Loop are then pump units. When a profile with another concentration is activated, insulin delivered before is converted to the new pump units, so active insulin stays correct.", comment: "Footer explaining the U200 profile copy"))) {
                    HStack {
                        Text(NSLocalizedString("Insulin", comment: "Label of the insulin concentration of a therapy profile"))
                        Spacer()
                        Text(profile.concentration.label)
                            .foregroundColor(profile.isConcentrated ? .orange : .secondary)
                    }
                    if !profile.isConcentrated {
                        Button(NSLocalizedString("Create U200 Profile", comment: "Button that creates a U200 copy of a therapy profile")) {
                            _ = profiles.addU200Copy(of: profile)
                        }
                    }
                }
            }

            Section(footer: Text(NSLocalizedString("Only one profile is active at a time. Changes to the active profile are applied immediately; basal rate changes are sent to the pump. Deactivating a profile returns to Standard.", comment: "Footer of the therapy profile activation section"))) {
                if let profile = profile, profiles.isActive(profile) {
                    Label(NSLocalizedString("Active Profile", comment: "Shown when the therapy profile matches the current therapy settings"), systemImage: "checkmark.circle.fill")
                    if !profile.isStandardProfile, let standard = profiles.standardProfile {
                        activationButton(
                            title: NSLocalizedString("Deactivate (Back to Standard)", comment: "Button that deactivates a therapy profile and activates Standard"),
                            confirmationTitle: NSLocalizedString("Back to Standard?", comment: "Title of the confirmation to deactivate a therapy profile"),
                            target: standard
                        )
                    }
                } else if let profile = profile {
                    activationButton(
                        title: NSLocalizedString("Activate Profile", comment: "Button that activates a therapy profile"),
                        confirmationTitle: NSLocalizedString("Activate Profile?", comment: "Title of the therapy profile activation confirmation"),
                        target: profile
                    )
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(name))
        .onChange(of: name) { newName in
            guard var profile = profile else { return }
            profile.name = newName
            profiles.save(profile)
        }
        .alert(NSLocalizedString("Activation Failed", comment: "Title of the therapy profile activation error"), isPresented: Binding(
            get: { activationErrorMessage != nil },
            set: { if !$0 { activationErrorMessage = nil } }
        )) {
            Button(NSLocalizedString("OK", comment: "Dismiss the therapy profile activation error"), role: .cancel) {}
        } message: {
            Text(activationErrorMessage ?? "")
        }
    }

    private func closeEditor() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            activeEditor = nil
        }
    }

    private func activationButton(title: String, confirmationTitle: String, target: TherapyProfile) -> some View {
        Button {
            activationTarget = target
        } label: {
            HStack {
                Text(title)
                if isActivating {
                    Spacer()
                    ProgressView()
                }
            }
        }
        .disabled(isActivating)
        .alert(confirmationTitle, isPresented: Binding(
            get: { activationTarget?.id == target.id },
            set: { if !$0 { activationTarget = nil } }
        )) {
            Button(NSLocalizedString("Activate", comment: "Confirm therapy profile activation")) {
                activate(target)
            }
            Button(NSLocalizedString("Cancel", comment: "Cancel therapy profile activation"), role: .cancel) {}
        } message: {
            Text(String(format: NSLocalizedString("The basal rates of “%@” are sent to the pump now. Carb ratios and insulin sensitivities take effect immediately.", comment: "Message of the therapy profile activation confirmation (1: profile name)"), target.name))
        }
    }

    private func activate(_ target: TherapyProfile) {
        isActivating = true
        profiles.activate(target) { error in
            editor.reload()
            isActivating = false
            activationErrorMessage = error?.localizedDescription
        }
    }
}

public struct SettingsView_Previews: PreviewProvider {
        
    public static var previews: some View {
        let displayGlucosePreference = DisplayGlucosePreference(displayGlucoseUnit: .milligramsPerDeciliter)
        let viewModel = SettingsViewModel.preview
        return Group {
            SettingsView(viewModel: viewModel, localizedAppNameAndVersion: "Loop Demo V1")
                .colorScheme(.light)
                .previewDevice(PreviewDevice(rawValue: "iPhone SE 2"))
                .previewDisplayName("SE light")
                .environmentObject(displayGlucosePreference)
            
            SettingsView(viewModel: viewModel, localizedAppNameAndVersion: "Loop Demo V1")
                .colorScheme(.dark)
                .previewDevice(PreviewDevice(rawValue: "iPhone 11 Pro Max"))
                .previewDisplayName("11 Pro dark")
                .environmentObject(displayGlucosePreference)
        }
    }
}
