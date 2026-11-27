//
//  ExtensionDataManager.swift
//  Loop
//
//  Created by Bharat Mediratta on 11/25/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import HealthKit
import UIKit
import LoopKit


final class ExtensionDataManager {
    unowned let deviceManager: DeviceDataManager
    private let automaticDosingStatus: AutomaticDosingStatus

    init(deviceDataManager: DeviceDataManager,
         automaticDosingStatus: AutomaticDosingStatus)
    {
        self.deviceManager = deviceDataManager
        self.automaticDosingStatus = automaticDosingStatus

        NotificationCenter.default.addObserver(self, selector: #selector(notificationReceived(_:)), name: .LoopDataUpdated, object: deviceDataManager.loopManager)
        NotificationCenter.default.addObserver(self, selector: #selector(notificationReceived(_:)), name: .PumpManagerChanged, object: nil)
       
        // Wait until LoopDataManager has had a chance to initialize itself
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.update()
        }
    }

    fileprivate static var defaults: UserDefaults? {
        return UserDefaults.appGroup
    }

    static var context: StatusExtensionContext? {
        get {
            return defaults?.statusExtensionContext
        }
        set {
            defaults?.statusExtensionContext = newValue
        }
    }

    static var intentExtensionInfo: IntentExtensionInfo? {
        get {
            return defaults?.intentExtensionInfo
        }
        set {
            defaults?.intentExtensionInfo = newValue
        }
    }

    static var lastLoopCompleted: Date? {
        context?.lastLoopCompleted
    }

    @objc private func notificationReceived(_ notification: Notification) {
        update()
    }

    /// One loop cycle posts several updates (glucose, doses, loop finished); publish once they settle.
    private static let publishQuietPeriod: TimeInterval = 5
    private static let publishMaximumDelay: TimeInterval = 60

    // Main queue only
    private var pendingContext: (context: StatusExtensionContext, displayedValues: NSDictionary)?
    private var pendingSince: Date?
    private var publishWorkItem: DispatchWorkItem?
    private var publishedDisplayedValues: NSDictionary?

    private func update() {
        createStatusContext(glucoseUnit:  deviceManager.preferredGlucoseUnit) { (context, displayedValues) in
            if let context = context {
                DispatchQueue.main.async {
                    self.schedulePublish(context, displayedValues: displayedValues)
                }
            }
        }
        
        createIntentsContext { (info) in
            if let info = info, ExtensionDataManager.intentExtensionInfo?.overridePresetNames != info.overridePresetNames {
                ExtensionDataManager.intentExtensionInfo = info
            }
        }
    }
    
    private func schedulePublish(_ context: StatusExtensionContext, displayedValues: NSDictionary) {
        let now = Date()
        let since = pendingSince ?? now
        pendingContext = (context, displayedValues)
        pendingSince = since

        publishWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.publishPendingContext()
        }
        publishWorkItem = workItem
        let remaining = since.addingTimeInterval(Self.publishMaximumDelay).timeIntervalSince(now)
        DispatchQueue.main.asyncAfter(deadline: .now() + min(Self.publishQuietPeriod, max(0, remaining)), execute: workItem)
    }

    /// Widgets and the Live Activity are refreshed only when something they display has changed.
    private func publishPendingContext() {
        guard let pending = pendingContext else { return }
        pendingContext = nil
        pendingSince = nil
        publishWorkItem = nil

        guard pending.displayedValues != publishedDisplayedValues else { return }
        publishedDisplayedValues = pending.displayedValues
        ExtensionDataManager.context = pending.context
        deviceManager.loopManager.extensionContextDidChange()
    }

    private func createIntentsContext(_ completion: @escaping (_ context: IntentExtensionInfo?) -> Void) {
        let presets = deviceManager.loopManager.settings.overridePresets
        let info = IntentExtensionInfo(overridePresetNames: presets.map { $0.name })
        completion(info)
    }

    private func createStatusContext(glucoseUnit: HKUnit, _ completionHandler: @escaping (_ context: StatusExtensionContext?, _ displayedValues: NSDictionary) -> Void) {

        let basalDeliveryState = deviceManager.pumpManager?.status.basalDeliveryState

        deviceManager.loopManager.getLoopState { (manager, state) in
            let dataManager = self.deviceManager
            var context = StatusExtensionContext()

            context.createdAt = Date()
        
            #if IOS_SIMULATOR
                // If we're in the simulator, there's a higher likelihood that we don't have
                // a fully configured app. Inject some baseline debug data to let us test the
                // experience. This data will be overwritten by actual data below, if available.
                context.batteryPercentage = 0.25
                context.netBasal = NetBasalContext(
                    rate: 2.1,
                    percentage: 0.6,
                    start:
                    Date(timeIntervalSinceNow: -250),
                    end: Date(timeIntervalSinceNow: .minutes(30))
                )
                context.predictedGlucose = PredictedGlucoseContext(
                    values: (1...36).map { 89.123 + Double($0 * 5) }, // 3 hours of linear data
                    unit: HKUnit.milligramsPerDeciliter,
                    startDate: Date(),
                    interval: TimeInterval(minutes: 5))

                let lastLoopCompleted = Date(timeIntervalSinceNow: -TimeInterval(minutes: 0))
            #else
                let lastLoopCompleted = manager.lastLoopCompleted
            #endif

            context.lastLoopCompleted = lastLoopCompleted
            
            context.isClosedLoop = self.automaticDosingStatus.automaticDosingEnabled
            
            context.preMealPresetAllowed = self.automaticDosingStatus.automaticDosingEnabled && manager.settings.preMealTargetRange != nil
            context.preMealPresetActive = manager.settings.preMealTargetEnabled()
            context.customPresetActive = manager.settings.nonPreMealOverrideEnabled()

            // Drop the first element in predictedGlucose because it is the currentGlucose
            // and will have a different interval to the next element
            if let predictedGlucose = state.predictedGlucoseIncludingPendingInsulin?.dropFirst(),
                predictedGlucose.count > 1 {
                let first = predictedGlucose[predictedGlucose.startIndex]
                let second = predictedGlucose[predictedGlucose.startIndex.advanced(by: 1)]
                context.predictedGlucose = PredictedGlucoseContext(
                    values: predictedGlucose.map { $0.quantity.doubleValue(for: glucoseUnit) },
                    unit: glucoseUnit,
                    startDate: first.startDate,
                    interval: second.startDate.timeIntervalSince(first.startDate))
            }

            if let basalDeliveryState = basalDeliveryState,
                let basalSchedule = manager.basalRateScheduleApplyingOverrideHistory,
                let netBasal = basalDeliveryState.getNetBasal(basalSchedule: basalSchedule, settings: manager.settings)
            {
                context.netBasal = NetBasalContext(rate: netBasal.rate, percentage: netBasal.percent, start: netBasal.start, end: netBasal.end)
            }

            context.batteryPercentage = dataManager.pumpManager?.status.pumpBatteryChargeRemaining
            context.reservoirCapacity = dataManager.pumpManager?.pumpReservoirCapacity

            if let glucoseDisplay = dataManager.glucoseDisplay(for: dataManager.glucoseStore.latestGlucose) {
                context.glucoseDisplay = GlucoseDisplayableContext(
                    isStateValid: glucoseDisplay.isStateValid,
                    stateDescription: glucoseDisplay.stateDescription,
                    trendType: glucoseDisplay.trendType,
                    trendRate: glucoseDisplay.trendRate,
                    isLocal: glucoseDisplay.isLocal,
                    glucoseRangeCategory: glucoseDisplay.glucoseRangeCategory
                )
            }
            
            if let pumpManagerHUDProvider = dataManager.pumpManagerHUDProvider {
                context.pumpManagerHUDViewContext = PumpManagerHUDViewContext(pumpManagerHUDViewRawValue: PumpManagerHUDViewRawValueFromHUDProvider(pumpManagerHUDProvider))
            }
            
            context.pumpStatusHighlightContext = DeviceStatusHighlightContext(from: dataManager.pumpStatusHighlight)
            context.pumpLifecycleProgressContext = DeviceLifecycleProgressContext(from: dataManager.pumpLifecycleProgress)

            context.cgmStatusHighlightContext = DeviceStatusHighlightContext(from: dataManager.cgmStatusHighlight)
            context.cgmLifecycleProgressContext = DeviceLifecycleProgressContext(from: dataManager.cgmLifecycleProgress)

            context.carbsOnBoard = state.carbsOnBoard?.quantity.doubleValue(for: .gram())

            // The widgets read glucose and the Live Activity IOB from the stores, not from the context.
            var displayedValues = context.rawValue
            displayedValues["createdAt"] = nil
            displayedValues["latestGlucose"] = dataManager.glucoseStore.latestGlucose.map { [$0.startDate, $0.quantity.doubleValue(for: .milligramsPerDeciliter)] as [Any] }
            displayedValues["insulinOnBoard"] = state.insulinOnBoard.map { ($0.value * 10).rounded() / 10 }

            completionHandler(context, NSDictionary(dictionary: displayedValues))
        }
    }
}


extension ExtensionDataManager: CustomDebugStringConvertible {
    var debugDescription: String {
        return [
            "## StatusExtensionDataManager",
            "appGroupName: \(Bundle.main.appGroupSuiteName)",
            "statusExtensionContext: \(String(reflecting: ExtensionDataManager.context))",
            ""
        ].joined(separator: "\n")
    }
}
