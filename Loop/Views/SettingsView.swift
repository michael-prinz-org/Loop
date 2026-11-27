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
    @EnvironmentObject var displayGlucosePreference: DisplayGlucosePreference
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

            podCommunicationIntervalControls
        }
    }

    @ViewBuilder
    private var podCommunicationIntervalControls: some View {
        describedToggle(
            isOn: $viewModel.podCommunicationIntervalEnabled,
            title: Text("Custom pod communication interval", comment: "The title text for the pod communication interval switch cell"),
            description: NSLocalizedString("Limits how often Loop contacts the pod to once per the interval below, in foreground and background. Increases, automatic boluses and moderate reductions wait until the interval has passed; a suspend and stopping a temp basal above scheduled basal are sent right away. Automatic Bolus applies its partial dose once per interval, so it responds more slowly. Off keeps the standard loop cadence.", comment: "The description text for the pod communication interval switch cell")
        )

        ExpandableWheelPicker(
            title: Text("Pod communication interval", comment: "The label for the pod communication interval picker"),
            selection: $viewModel.podCommunicationIntervalMinutes,
            options: (Int(viewModel.minimumPodCommunicationIntervalMinutes)...Int(viewModel.maximumPodCommunicationIntervalMinutes)).map { Double($0) },
            label: { String(format: NSLocalizedString("%d min", comment: "Pod communication interval value in minutes (1: number of minutes)"), Int($0.rounded())) }
        )
        .padding(.vertical, 3)
        .disabled(!viewModel.podCommunicationIntervalEnabled)

        describedToggle(
            isOn: $viewModel.suppressPodCommunicationInBackground,
            title: Text("Skip Background Pod Syncs", comment: "The title text for the disable pod communication switch cell"),
            description: NSLocalizedString("While the app is in the background, skips the routine sync Loop otherwise makes just to keep pod data fresh. Dose changes are never skipped: a suspend or stopping extra insulin is sent right away, other dose changes after the interval. In the foreground freshness syncs continue so the status on screen stays current. With Closed Loop off there are no freshness syncs to skip, so this setting has no effect.", comment: "The description text for the disable pod communication switch cell")
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
        TherapySettingsScreen(glucoseDisplayRange: $viewModel.glucoseDisplayRange, podStatus: { [weak deviceManager = viewModel.therapySettingsViewModelDelegate as? DeviceDataManager] in
            guard let deviceManager = deviceManager else { return .unknown }
            return PodStatus(rawPumpManager: deviceManager.pumpManager?.rawValue)
        }, makeBridge: {
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
            ForEach(pluginMenuItems.filter( { $0.section == .support })) {
                $0.view
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
            DescriptiveText(label: NSLocalizedString("These thresholds colour glucose values on the Apple Watch complication and chart. They do not change dosing.", comment: "Descriptive text for general glucose range"))
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
            ResourceUsageBar()
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
            levelButton(level: .debug)
            levelButton(level: .info)
            levelButton(level: .notice)
            levelButton(level: .error)
        } label: {
            menuLabel(systemImage: "line.3.horizontal.decrease.circle", text: levelFilterTitle(minimumLevel))
        }
    }

    private func levelFilterTitle(_ level: InAppLogLevel) -> String {
        switch level {
        case .debug: return NSLocalizedString("All levels", comment: "Log level filter option")
        case .info: return NSLocalizedString("Info & up", comment: "Log level filter option")
        case .notice: return NSLocalizedString("Default & up", comment: "Log level filter option")
        case .error, .fault: return NSLocalizedString("Errors only", comment: "Log level filter option")
        }
    }

    private func levelButton(level: InAppLogLevel) -> some View {
        let title = levelFilterTitle(level)
        return Button {
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

/// Separate view so its periodic refresh does not re-filter the log list.
private struct ResourceUsageBar: View {
    @State private var usage = ResourceUsage.current()
    @State private var storage: ResourceUsage.Storage?

    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(usage.memoryDescription)
            Text(usage.cpuDescription)
            Text(storage.map(ResourceUsage.storageDescription) ?? "Storage …")
        }
        .font(.caption2.monospacedDigit())
        .foregroundColor(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 6)
        .onReceive(refreshTimer) { _ in
            usage = ResourceUsage.current()
        }
        .task {
            storage = await Task.detached(priority: .utility) { ResourceUsage.storage() }.value
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
    let podStatus: () -> PodStatus

    init(glucoseDisplayRange: Binding<GlucoseDisplayRange>, podStatus: @escaping () -> PodStatus, makeBridge: @escaping () -> StandardTherapySettingsBridge) {
        _glucoseDisplayRange = glucoseDisplayRange
        self.podStatus = podStatus
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
                NavigationLink(destination: TherapyProfilesView(liveViewModel: bridge.liveViewModel, podStatus: podStatus)
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
    case concentrationChangeNeedsConfirmation
    /// Start of the day's segment, in seconds after midnight
    case convertedBasalRateIsZero(startTime: TimeInterval)
    case convertedCarbRatioOutsideGuardrail
    case convertedInsulinSensitivityOutsideGuardrail

    var errorDescription: String? {
        switch self {
        case .basalRateAboveMaximum(let maximum):
            return String(format: NSLocalizedString("This profile contains a basal rate above your maximum basal rate of %.2f U/hr. Edit the profile or raise the maximum basal rate first.", comment: "Error when activating a therapy profile whose basal rates exceed the maximum basal rate (1: maximum basal rate)"), maximum)
        case .invalidSchedule:
            return NSLocalizedString("The schedule is invalid.", comment: "Error when a therapy profile schedule cannot be created")
        case .concentrationChangeNeedsConfirmation:
            return NSLocalizedString("This profile uses another insulin concentration. Activate it from the profile screen and confirm the change.", comment: "Error when a therapy profile with another insulin concentration is activated without confirmation")
        case .convertedBasalRateIsZero(let startTime):
            return String(format: NSLocalizedString("The basal rate from %@ would become 0 U/hr in the other concentration. Raise it first; the profile was not converted.", comment: "Error when converting a therapy profile would round a basal rate down to zero (1: segment start time)"), Self.scheduleTimeString(startTime))
        case .convertedCarbRatioOutsideGuardrail:
            return NSLocalizedString("A converted carb ratio would be outside the allowed range. The profile was not converted.", comment: "Error when converting a therapy profile would put a carb ratio outside the guardrails")
        case .convertedInsulinSensitivityOutsideGuardrail:
            return NSLocalizedString("A converted insulin sensitivity would be outside the allowed range. The profile was not converted.", comment: "Error when converting a therapy profile would put an insulin sensitivity outside the guardrails")
        }
    }

    /// "HH:mm" for a schedule start time in seconds after midnight.
    static func scheduleTimeString(_ startTime: TimeInterval) -> String {
        let minutes = Int(startTime / 60)
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
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

    /// Same insulin effect in another concentration; basal and limits round down so no rate grows in IU.
    func converted(toConcentration target: InsulinConcentration, name: String) throws -> TherapyProfile {
        let factor = target.unitsPerPumpUnit / concentration.unitsPerPumpUnit
        let pumpUnits: (Double) -> Double = { TherapyOptimizerMath.roundedToGrid($0 / factor, stepsPerUnit: TherapyOptimizerMath.basalStepsPerUnit, rule: .down) }
        let carbRatio: (Double) -> Double = { TherapyOptimizerMath.roundedToGrid($0 * factor, stepsPerUnit: TherapyOptimizerMath.carbRatioStepsPerUnit) }
        let sensitivityStepsPerUnit = TherapyOptimizerMath.sensitivityStepsPerUnit(insulinSensitivitySchedule.unit)
        let sensitivity: (Double) -> Double = { TherapyOptimizerMath.roundedToGrid($0 * factor, stepsPerUnit: sensitivityStepsPerUnit) }

        let basalItems = basalRateSchedule.items.map { RepeatingScheduleValue(startTime: $0.startTime, value: pumpUnits($0.value)) }
        if let zeroed = zip(basalRateSchedule.items, basalItems).first(where: { $0.0.value > 0 && $0.1.value <= 0 }) {
            throw TherapyProfileError.convertedBasalRateIsZero(startTime: zeroed.0.startTime)
        }
        let carbRatioItems = carbRatioSchedule.items.map { RepeatingScheduleValue(startTime: $0.startTime, value: carbRatio($0.value)) }
        let carbRatioUnit = carbRatioSchedule.unit.unitDivided(by: .internationalUnit())
        guard carbRatioItems.allSatisfy({ Guardrail.carbRatio.absoluteBounds.contains(HKQuantity(unit: carbRatioUnit, doubleValue: $0.value)) }) else {
            throw TherapyProfileError.convertedCarbRatioOutsideGuardrail
        }
        let sensitivityItems = insulinSensitivitySchedule.items.map { RepeatingScheduleValue(startTime: $0.startTime, value: sensitivity($0.value)) }
        let sensitivityUnit = insulinSensitivitySchedule.unit.unitDivided(by: .internationalUnit())
        guard sensitivityItems.allSatisfy({ Guardrail.insulinSensitivity.absoluteBounds.contains(HKQuantity(unit: sensitivityUnit, doubleValue: $0.value)) }) else {
            throw TherapyProfileError.convertedInsulinSensitivityOutsideGuardrail
        }
        guard let basalRates = BasalRateSchedule(dailyItems: basalItems, timeZone: basalRateSchedule.timeZone),
              let carbRatios = CarbRatioSchedule(unit: carbRatioSchedule.unit, dailyItems: carbRatioItems, timeZone: carbRatioSchedule.timeZone),
              let sensitivities = InsulinSensitivitySchedule(unit: insulinSensitivitySchedule.unit, dailyItems: sensitivityItems, timeZone: insulinSensitivitySchedule.timeZone) else {
            throw TherapyProfileError.invalidSchedule
        }
        return TherapyProfile(
            name: name,
            basalRateSchedule: basalRates,
            carbRatioSchedule: carbRatios,
            insulinSensitivitySchedule: sensitivities,
            maximumBasalRatePerHour: maximumBasalRatePerHour.map(pumpUnits),
            maximumBolus: maximumBolus.map(pumpUnits),
            insulinConcentration: target == .u100 ? nil : target
        )
    }

    /// Basal rates in international units per hour, comparable across concentrations.
    var basalRatesInInternationalUnits: [RepeatingScheduleValue<Double>] {
        basalRateSchedule.items.map { RepeatingScheduleValue(startTime: $0.startTime, value: $0.value * concentration.unitsPerPumpUnit) }
    }

    var dailyBasalInInternationalUnits: Double {
        basalRateSchedule.total() * concentration.unitsPerPumpUnit
    }

    /// A new, unsaved profile with these values for the given insulin, converted if the concentration differs.
    func copy(named name: String, concentration target: InsulinConcentration) throws -> TherapyProfile {
        guard target == concentration else {
            return try converted(toConcentration: target, name: name)
        }
        return TherapyProfile(
            name: name,
            basalRateSchedule: basalRateSchedule,
            carbRatioSchedule: carbRatioSchedule,
            insulinSensitivitySchedule: insulinSensitivitySchedule,
            maximumBasalRatePerHour: maximumBasalRatePerHour,
            maximumBolus: maximumBolus,
            insulinConcentration: insulinConcentration
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
        activeProfileSnapshot.mutate { snapshot in
            guard snapshot == nil else { return }
            snapshot = .some(loadActiveProfile())
        } ?? nil
    }

    private static func loadActiveProfile() -> TherapyProfile? {
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
    private let podStatus: () -> PodStatus
    private var liveSettingsCancellable: AnyCancellable?

    init(liveViewModel: TherapySettingsViewModel, podStatus: @escaping () -> PodStatus) {
        self.liveViewModel = liveViewModel
        self.podStatus = podStatus
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

    func concentrationSwitchConfirmation(for profile: TherapyProfile) -> ConcentrationSwitchConfirmation {
        ConcentrationSwitchConfirmation.required(
            from: TherapyProfile.activeProfile()?.concentration ?? .u100,
            to: profile.concentration,
            podActive: podStatus().isActive
        )
    }

    /// Start of the running pod, offered as the date the new concentration applies from.
    var podStartForConcentrationSwitch: Date? {
        let status = podStatus()
        guard status.isActive == true, let start = status.activatedAt, start < Date() else { return nil }
        return start
    }

    var standardProfile: TherapyProfile? {
        profiles.first { $0.isStandardProfile }
    }

    func profileFromCurrentSettings() -> TherapyProfile? {
        TherapyProfile(
            name: String(format: NSLocalizedString("Profile %d", comment: "Default name of a new therapy profile (1: profile number)"), profiles.count + 1),
            settings: liveViewModel.therapySettings,
            insulinConcentration: TherapyProfile.activeProfile()?.insulinConcentration
        )
    }

    func add(_ profile: TherapyProfile) {
        persist(profiles + [profile])
    }

    /// The active profile in U100 values, used as the base for profiles created from calculated (U100) values.
    var activeProfileInU100: TherapyProfile? {
        guard let active = TherapyProfile.activeProfile() else { return nil }
        guard active.isConcentrated else { return active }
        return try? active.converted(toConcentration: .u100, name: active.name)
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
    /// `concentrationStart` backdates a concentration change (e.g. to pod start); nil means now.
    func activate(_ profile: TherapyProfile, concentrationChangeConfirmed: Bool, concentrationStart: Date? = nil, completion: @escaping (Error?) -> Void) {
        let currentConcentration = TherapyProfile.activeProfile()?.concentration ?? .u100
        guard concentrationChangeConfirmed || profile.concentration == currentConcentration else {
            completion(TherapyProfileError.concentrationChangeNeedsConfirmation)
            return
        }
        let switchStart = profile.concentration == currentConcentration ? nil : concentrationStart
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
                    self.syncBasalRatesAndApply(profile, concentrationStart: switchStart, syncedLimits: syncedLimits, previousLimits: previousLimits, completion: completion)
                }
            }
        }
    }

    private func syncBasalRatesAndApply(_ profile: TherapyProfile, concentrationStart: Date?, syncedLimits: DeliveryLimits, previousLimits: DeliveryLimits, completion: @escaping (Error?) -> Void) {
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
                    InsulinConcentrationHistory.record(activated.concentration, previous: previousConcentration, at: min(concentrationStart ?? Date(), Date()))
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

    enum ScheduleKind {
        case basal, sensitivity, carbRatio
    }

    enum ScheduleChange {
        /// From the hour to the next full hour, in the profile's own units and concentration
        case value(Double, hour: Int)
        /// Every entry multiplied, keeping the profile's shape
        case scale(Double)
    }

    /// Changes a profile; for the active profile the change takes effect immediately and basal rates go to the pump first.
    func changeProfile(withID id: UUID, _ kind: ScheduleKind, _ change: ScheduleChange, completion: @escaping (Error?) -> Void) {
        guard var profile = self.profile(withID: id) else {
            completion(TherapyProfileError.invalidSchedule)
            return
        }
        let stepsPerUnit: Double
        switch kind {
        case .basal: stepsPerUnit = TherapyOptimizerMath.basalStepsPerUnit
        case .sensitivity: stepsPerUnit = TherapyOptimizerMath.sensitivityStepsPerUnit(profile.insulinSensitivitySchedule.unit)
        case .carbRatio: stepsPerUnit = TherapyOptimizerMath.carbRatioStepsPerUnit
        }
        let changed = { (items: [RepeatingScheduleValue<Double>]) -> [RepeatingScheduleValue<Double>] in
            switch change {
            case .value(let value, let hour):
                return TherapyOptimizerMath.settingValue(value, forHour: hour, in: items)
            case .scale(let factor):
                return items.map { RepeatingScheduleValue(startTime: $0.startTime, value: TherapyOptimizerMath.roundedToGrid($0.value * factor, stepsPerUnit: stepsPerUnit)) }
            }
        }
        switch kind {
        case .basal:
            let schedule = profile.basalRateSchedule
            guard let updated = BasalRateSchedule(dailyItems: changed(schedule.items), timeZone: schedule.timeZone) else {
                completion(TherapyProfileError.invalidSchedule)
                return
            }
            profile.basalRateSchedule = updated
        case .sensitivity:
            let schedule = profile.insulinSensitivitySchedule
            guard let updated = InsulinSensitivitySchedule(unit: schedule.unit, dailyItems: changed(schedule.items), timeZone: schedule.timeZone) else {
                completion(TherapyProfileError.invalidSchedule)
                return
            }
            profile.insulinSensitivitySchedule = updated
        case .carbRatio:
            let schedule = profile.carbRatioSchedule
            guard let updated = CarbRatioSchedule(unit: schedule.unit, dailyItems: changed(schedule.items), timeZone: schedule.timeZone) else {
                completion(TherapyProfileError.invalidSchedule)
                return
            }
            profile.carbRatioSchedule = updated
        }
        let profileIsActive = isActive(profile)
        if profileIsActive, kind == .basal {
            activate(profile, concentrationChangeConfirmed: false, completion: completion)
            return
        }
        save(profile)
        if profileIsActive {
            apply(profile)
        }
        completion(nil)
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
    @State private var newProfileSource: TherapyProfile?
    @State private var createdProfileID: UUID?

    init(liveViewModel: TherapySettingsViewModel, podStatus: @escaping () -> PodStatus) {
        _model = StateObject(wrappedValue: TherapyProfilesModel(liveViewModel: liveViewModel, podStatus: podStatus))
    }

    var body: some View {
        List {
            Section(footer: Text(NSLocalizedString("A profile is a set of basal rates, carb ratios, insulin sensitivities and delivery limits for one insulin concentration (U100 or U200); its values are pump units of that insulin. Activating a profile sends its basal rates and limits to the pump and makes it your current therapy settings.", comment: "Footer of the therapy profiles list"))) {
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
                            InsulinConcentrationBadge(concentration: profile.concentration)
                            Spacer()
                            if model.isActive(profile) {
                                Text(NSLocalizedString("Active", comment: "Marker for the active therapy profile"))
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
                    newProfileSource = model.profileFromCurrentSettings()
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
        .sheet(item: $newProfileSource, onDismiss: {
            selectedProfileID = createdProfileID
            createdProfileID = nil
        }) { source in
            NewTherapyProfileSheet(source: source, defaultName: source.name) { profile in
                model.add(profile)
                createdProfileID = profile.id
            }
        }
    }
}

/// Confirms name and insulin concentration before a profile is created.
struct NewTherapyProfileSheet: View {
    let source: TherapyProfile
    let onCreate: (TherapyProfile) -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var name: String
    @State private var isU200: Bool
    @State private var errorMessage: String?

    init(source: TherapyProfile, defaultName: String, onCreate: @escaping (TherapyProfile) -> Void) {
        self.source = source
        self.onCreate = onCreate
        _name = State(initialValue: defaultName)
        _isU200 = State(initialValue: Self.startsAsU200(source: source))
    }

    /// The switch starts at the source's concentration, so a copy is only converted when the user asks for it.
    static func startsAsU200(source: TherapyProfile) -> Bool {
        source.concentration == .u200
    }

    private var targetConcentration: InsulinConcentration {
        isU200 ? .u200 : .u100
    }

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text(NSLocalizedString("Name", comment: "Header of the therapy profile name field"))) {
                    TextField(NSLocalizedString("Name", comment: "Placeholder of the therapy profile name field"), text: $name)
                }
                Section(footer: Text(NSLocalizedString("U200 halves basal rates, maximum basal rate and maximum bolus and doubles carb ratios and insulin sensitivities, so the same insulin effect results with insulin of double concentration. All amounts in Loop are then pump units.", comment: "Footer of the U200 switch when creating a therapy profile"))) {
                    Toggle(NSLocalizedString("U200 Insulin", comment: "Switch that creates the therapy profile for U200 insulin"), isOn: $isU200)
                }
                if targetConcentration != source.concentration {
                    BasalConversionPreview(source: source, target: targetConcentration)
                }
                if let errorMessage = errorMessage {
                    Section {
                        Text(errorMessage).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle(Text(NSLocalizedString("New Profile", comment: "Title of the sheet that creates a therapy profile")))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NSLocalizedString("Cancel", comment: "Cancel creating a therapy profile")) {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(NSLocalizedString("Create", comment: "Create the therapy profile"), action: create)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func create() {
        do {
            onCreate(try source.copy(named: name.trimmingCharacters(in: .whitespaces), concentration: targetConcentration))
            presentationMode.wrappedValue.dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Old and new basal rates, delivery limits, carb ratios and insulin sensitivities in pump units, with the daily basal total in IU, shown before a converted profile is saved.
struct BasalConversionPreview: View {
    let source: TherapyProfile
    let target: InsulinConcentration

    private static let formatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    private func number(_ value: Double) -> String {
        Self.formatter.string(from: NSNumber(value: value)) ?? ""
    }

    private func number(_ value: Double, fractionDigits: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = fractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? ""
    }

    private var factor: Double {
        target.unitsPerPumpUnit / source.concentration.unitsPerPumpUnit
    }

    private var sensitivityFractionDigits: Int {
        source.insulinSensitivitySchedule.unit == .milligramsPerDeciliter ? 0 : 1
    }

    var body: some View {
        switch Swift.Result<TherapyProfile, Error>(catching: { try source.converted(toConcentration: target, name: source.name) }) {
        case .success(let converted):
            Section(header: Text(String(format: NSLocalizedString("Pump Units %1$@ → %2$@", comment: "Header of the basal conversion preview (1: source concentration, 2: target concentration)"), source.concentration.label, target.label)),
                    footer: Text(String(format: NSLocalizedString("Daily basal total: %1$@ IU → %2$@ IU. Converted rates and limits are rounded down to the pump's 0.05 steps, so no rate increases in IU.", comment: "Footer of the basal conversion preview (1: old daily basal in IU, 2: new daily basal in IU)"), number(source.dailyBasalInInternationalUnits), number(converted.dailyBasalInInternationalUnits)))) {
                ForEach(Array(zip(source.basalRateSchedule.items, converted.basalRateSchedule.items).enumerated()), id: \.offset) { item in
                    HStack {
                        Text(TherapyProfileError.scheduleTimeString(item.element.0.startTime))
                        Spacer()
                        Text("\(number(item.element.0.value)) → \(number(item.element.1.value)) U/hr")
                    }
                }
                if let oldMaximum = source.maximumBasalRatePerHour, let newMaximum = converted.maximumBasalRatePerHour {
                    HStack {
                        Text(NSLocalizedString("Maximum Basal Rate", comment: "Maximum basal rate row of the basal conversion preview"))
                        Spacer()
                        Text("\(number(oldMaximum)) → \(number(newMaximum)) U/hr")
                    }
                }
                if let oldMaximum = source.maximumBolus, let newMaximum = converted.maximumBolus {
                    HStack {
                        Text(NSLocalizedString("Maximum Bolus", comment: "Maximum bolus row of the basal conversion preview"))
                        Spacer()
                        Text("\(number(oldMaximum)) → \(number(newMaximum)) U")
                    }
                }
            }
            Section(header: Text(NSLocalizedString("Carb Ratios", comment: "Header of the carb ratio rows of the conversion preview"))) {
                ForEach(Array(zip(source.carbRatioSchedule.items, converted.carbRatioSchedule.items).enumerated()), id: \.offset) { item in
                    HStack {
                        Text(TherapyProfileError.scheduleTimeString(item.element.0.startTime))
                        Spacer()
                        Text("\(number(item.element.0.value, fractionDigits: 1)) → \(number(item.element.1.value, fractionDigits: 1)) g/U")
                    }
                }
            }
            Section(header: Text(NSLocalizedString("Insulin Sensitivities", comment: "Header of the insulin sensitivity rows of the conversion preview")),
                    footer: Text(String(format: NSLocalizedString("Carb ratios and insulin sensitivities are multiplied by %@ because one pump unit now holds that much more or less insulin.", comment: "Footer of the carb ratio and insulin sensitivity conversion preview (1: conversion factor, e.g. 2 or 0.5)"), number(factor, fractionDigits: 1)))) {
                ForEach(Array(zip(source.insulinSensitivitySchedule.items, converted.insulinSensitivitySchedule.items).enumerated()), id: \.offset) { item in
                    HStack {
                        Text(TherapyProfileError.scheduleTimeString(item.element.0.startTime))
                        Spacer()
                        Text("\(number(item.element.0.value, fractionDigits: sensitivityFractionDigits)) → \(number(item.element.1.value, fractionDigits: sensitivityFractionDigits)) \(source.insulinSensitivitySchedule.unit.localizedShortUnitString)/U")
                    }
                }
            }
        case .failure(let error):
            Section {
                Text(error.localizedDescription).foregroundColor(.red)
            }
        }
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
    @State private var activationConfirmation = ConcentrationSwitchConfirmation.notNeeded
    @State private var activationPodStart: Date?
    @State private var isActivating = false
    @State private var activationErrorMessage: String?
    @State private var copySource: TherapyProfile?
    @ObservedObject private var optimizer = TherapyOptimizer.shared
    @State private var showCalculatedProfile: Bool
    @State private var pendingCalculatedChange: CalculatedProfileChange?
    @State private var calculatedMessage: String?

    init(profileID: UUID, profiles: TherapyProfilesModel) {
        self.profiles = profiles
        _editor = StateObject(wrappedValue: TherapyProfileEditorModel(profileID: profileID, profiles: profiles))
        _name = State(initialValue: profiles.profile(withID: profileID)?.name ?? "")
        _showCalculatedProfile = State(initialValue: UserDefaults.standard.profilesShowingCalculatedValues.contains(profileID))
    }

    /// Remembered per profile.
    private var showCalculatedProfileBinding: Binding<Bool> {
        Binding(get: { showCalculatedProfile }, set: { show in
            showCalculatedProfile = show
            var ids = UserDefaults.standard.profilesShowingCalculatedValues
            if show {
                ids.insert(editor.profileID)
            } else {
                ids.remove(editor.profileID)
            }
            UserDefaults.standard.profilesShowingCalculatedValues = ids
        })
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
                Section(footer: Text(String(format: NSLocalizedString("Basal rates, limits, carb ratios and insulin sensitivities of this profile are in %@ pump units. When a profile with another concentration is activated, insulin delivered before the chosen start (now or pod start) is converted to the new pump units, so active insulin stays correct. Apple Health receives international units (IU); Nightscout receives pump units.", comment: "Footer of the insulin concentration of a therapy profile (1: insulin concentration, e.g. U200)"), profile.concentration.label))) {
                    HStack {
                        Text(NSLocalizedString("Insulin", comment: "Label of the insulin concentration of a therapy profile"))
                        Spacer()
                        Text(profile.concentration.label)
                            .foregroundColor(profile.isConcentrated ? .orange : .secondary)
                    }
                    Button(NSLocalizedString("Create Copy…", comment: "Button that opens the sheet to create a copy of a therapy profile, optionally for U200")) {
                        copySource = profile
                    }
                }
            }

            Section(footer: Text(NSLocalizedString("Only one profile is active at a time. Changes to the active profile are applied immediately; basal rate changes are sent to the pump. Deactivating a profile returns to Standard.", comment: "Footer of the therapy profile activation section"))) {
                if let profile = profile, profiles.isActive(profile) {
                    Label(NSLocalizedString("Active Profile", comment: "Shown when the therapy profile is the active one"), systemImage: "checkmark.circle.fill")
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

            if let state = optimizer.state, let profile = profile {
                Section(footer: Text(NSLocalizedString("Compares this profile with the calculated values, converted to this profile's insulin. Tap a value to apply it to this profile.", comment: "Footer of the switch that shows the calculated profile in a therapy profile"))) {
                    Toggle(NSLocalizedString("Show Calculated Profile", comment: "Switch that shows the calculated values in a therapy profile"), isOn: showCalculatedProfileBinding)
                }
                if showCalculatedProfile {
                    CalculatedValuesSections(state: state, profile: profile, profiles: profiles, pendingChange: $pendingCalculatedChange, message: $calculatedMessage)
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(name))
        .calculatedProfileChangeDialogs($pendingCalculatedChange, message: $calculatedMessage, profiles: profiles, onChanged: editor.reload)
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
        .sheet(item: $copySource) { source in
            NewTherapyProfileSheet(
                source: source,
                defaultName: String(format: NSLocalizedString("%@ Copy", comment: "Default name of a copy of a therapy profile (1: original name)"), source.name),
                onCreate: profiles.add
            )
        }
    }

    private func closeEditor() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            activeEditor = nil
        }
    }

    private func activationButton(title: String, confirmationTitle: String, target: TherapyProfile) -> some View {
        Button {
            activationConfirmation = profiles.concentrationSwitchConfirmation(for: target)
            activationPodStart = activationConfirmation == .strict ? profiles.podStartForConcentrationSwitch : nil
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
            if activationConfirmation == .strict, let podStart = activationPodStart {
                Button(NSLocalizedString("Activate – Insulin Since Now", comment: "Confirm a concentration switch that applies from now on"), role: .destructive) {
                    activate(target)
                }
                Button(NSLocalizedString("Activate – Insulin Since Pod Start", comment: "Confirm a concentration switch that applies since the running pod was started"), role: .destructive) {
                    activate(target, concentrationStart: podStart)
                }
            } else if activationConfirmation == .strict {
                Button(NSLocalizedString("Activate", comment: "Confirm therapy profile activation"), role: .destructive) {
                    activate(target)
                }
            } else {
                Button(NSLocalizedString("Activate", comment: "Confirm therapy profile activation")) {
                    activate(target)
                }
            }
            Button(NSLocalizedString("Cancel", comment: "Cancel therapy profile activation"), role: .cancel) {}
        } message: {
            Text(activationMessage(for: target))
        }
    }

    private func activationMessage(for target: TherapyProfile) -> String {
        var paragraphs = [String(format: NSLocalizedString("The basal rates of “%1$@” (%2$@ pump units) are sent to the pump now. Carb ratios and insulin sensitivities take effect immediately.", comment: "Message of the therapy profile activation confirmation (1: profile name, 2: insulin concentration, e.g. U200)"), target.name, target.concentration.label)]
        guard activationConfirmation != .notNeeded else {
            return paragraphs[0]
        }
        let live = profiles.liveViewModel.therapySettings
        let currentConcentration = TherapyProfile.activeProfile()?.concentration ?? .u100
        let newConcentration = target.concentration
        paragraphs.append([
            String(format: NSLocalizedString("Insulin: %1$@ → %2$@", comment: "Concentration change in the therapy profile activation confirmation (1: current, 2: new)"), currentConcentration.label, newConcentration.label),
            String(format: NSLocalizedString("Daily basal: %1$@ → %2$@", comment: "Daily basal change in the therapy profile activation confirmation (1: current, 2: new)"),
                   internationalUnits(live.basalRateSchedule.map { $0.total() * currentConcentration.unitsPerPumpUnit }),
                   internationalUnits(target.basalRateSchedule.total() * newConcentration.unitsPerPumpUnit)),
            String(format: NSLocalizedString("Maximum bolus: %1$@ → %2$@", comment: "Maximum bolus change in the therapy profile activation confirmation (1: current, 2: new)"),
                   internationalUnits(live.maximumBolus.map { $0 * currentConcentration.unitsPerPumpUnit }),
                   internationalUnits((target.maximumBolus ?? live.maximumBolus).map { $0 * newConcentration.unitsPerPumpUnit }))
        ].joined(separator: "\n"))
        paragraphs.append(String(format: NSLocalizedString("The profile must match the insulin in the pod now (%@).", comment: "Reminder in the therapy profile activation confirmation (1: new concentration)"), newConcentration.label))
        if activationConfirmation == .strict {
            paragraphs.append(NSLocalizedString("The running pod doses with this profile immediately. If the pod holds other insulin, every dose is doubled or halved.", comment: "Warning in the therapy profile activation confirmation while a pod is running"))
        }
        if let podStart = activationPodStart {
            paragraphs.append(String(format: NSLocalizedString("Since when does the pod hold %1$@ insulin? “Since Pod Start” (%2$@) also counts the insulin this pod delivered so far as %1$@, so active insulin is correct if the pod was filled with it.", comment: "Question in the therapy profile activation confirmation while a pod is running (1: new concentration, 2: pod start date and time)"), newConcentration.label, DateFormatter.localizedString(from: podStart, dateStyle: .short, timeStyle: .short)))
        }
        return paragraphs.joined(separator: "\n\n")
    }

    private static let internationalUnitsFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private func internationalUnits(_ value: Double?) -> String {
        value.flatMap { Self.internationalUnitsFormatter.string(from: $0, unit: NSLocalizedString("IU", comment: "Unit of international insulin units")) } ?? "–"
    }

    private func activate(_ target: TherapyProfile, concentrationStart: Date? = nil) {
        isActivating = true
        profiles.activate(target, concentrationChangeConfirmed: activationConfirmation != .notNeeded, concentrationStart: concentrationStart) { error in
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
