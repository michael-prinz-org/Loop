//
//  SettingsView.swift
//  LoopUI
//
//  Created by Rick Pasetto on 6/24/20.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

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
            description: NSLocalizedString("Rate limit: caps how often Loop is allowed to contact the pod (dose syncs and background freshness syncs alike) to at most once per the interval below, in both foreground and background. It does not decide whether a sync happens, only how often — see Disable Pod Communication below to also skip syncs that aren't needed for a dose. Off keeps the standard loop cadence.", comment: "The description text for the custom loop interval switch cell")
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Pod communication interval", comment: "The label for the pod communication interval picker")
                Spacer()
                Text(String(format: NSLocalizedString("%d min", comment: "Custom loop interval value in minutes (1: number of minutes)"), Int(viewModel.customLoopIntervalMinutes.rounded())))
                    .foregroundColor(.secondary)
            }
            Picker("", selection: $viewModel.customLoopIntervalMinutes) {
                ForEach(Int(viewModel.minimumCustomLoopIntervalMinutes)...Int(viewModel.maximumCustomLoopIntervalMinutes), id: \.self) { minute in
                    Text(String(format: NSLocalizedString("%d min", comment: "Custom loop interval value in minutes (1: number of minutes)"), minute))
                        .tag(Double(minute))
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()

            if viewModel.customLoopIntervalExceedsRecencyLimit {
                DescriptiveText(label: NSLocalizedString("Above 13 minutes the pod is contacted less often than pump data stays fresh, so a status refresh is performed right before a dose and insulin adjustments can lag up to the communication interval.", comment: "Warning shown when the pod communication interval exceeds the pump data recency limit"))
                    .foregroundColor(guidanceColors.warning)
            }
        }
        .padding(.vertical, 3)
        .disabled(!viewModel.customLoopIntervalEnabled)

        describedToggle(
            isOn: $viewModel.suppressPodCommunicationInBackground,
            title: Text("Disable Pod Communication", comment: "The title text for the disable pod communication switch cell"),
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
        TherapySettingsView(
            mode: .settings,
            viewModel: TherapySettingsViewModel(
                therapySettings: viewModel.therapySettings(),
                sensitivityOverridesEnabled: FeatureFlags.sensitivityOverridesEnabled,
                adultChildInsulinModelSelectionEnabled: FeatureFlags.adultChildInsulinModelSelectionEnabled,
                delegate: viewModel.therapySettingsViewModelDelegate
            )
        )
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
                        label: "Favorite Foods",
                        descriptiveText: "Simplify Carb Entry")
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
