//
//  CLKComplicationTemplate.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 11/26/15.
//  Copyright © 2015 Nathan Racklyeft. All rights reserved.
//

import ClockKit
import HealthKit
import LoopKit
import Foundation
import LoopCore

extension CLKComplicationTemplate {

    static func templateForFamily(
        _ family: CLKComplicationFamily,
        from context: WatchContext,
        at date: Date,
        recencyInterval: TimeInterval,
        chartGenerator makeChart: () -> UIImage?
    ) -> CLKComplicationTemplate? {
        guard let glucose = context.glucose, let unit = context.displayGlucoseUnit else {
            return nil
        }
        
        return templateForFamily(family,
            glucose: glucose,
            unit: unit,
            glucoseDate: context.glucoseDate,
            trend: context.glucoseTrend,
            eventualGlucose: context.eventualGlucose,
            at: date,
            loopLastRunDate: context.loopLastRunDate,
            loopInterval: context.loopInterval ?? LoopCompletionFreshness.defaultLoopInterval,
            isClosedLoop: context.isClosedLoop,
            recencyInterval: recencyInterval,
            activeInsulin: context.activeInsulin,
            activeCarbohydrates: context.activeCarbohydrates,
            glucoseDisplayTier: context.glucoseDisplayTier,
            eventualGlucoseDisplayTier: context.eventualGlucoseDisplayTier,
            podWakeUpCount: context.podWakeUpCount,
            lastPodWakeUpDate: context.lastPodWakeUpDate,
            chartGenerator: makeChart)
    }

    static func templateForFamily(
        _ family: CLKComplicationFamily,
        glucose: HKQuantity,
        unit: HKUnit,
        glucoseDate: Date?,
        trend: GlucoseTrend?,
        eventualGlucose: HKQuantity?,
        at date: Date,
        loopLastRunDate: Date?,
        loopInterval: TimeInterval = LoopCompletionFreshness.defaultLoopInterval,
        isClosedLoop: Bool? = nil,
        recencyInterval: TimeInterval,
        activeInsulin: HKQuantity? = nil,
        activeCarbohydrates: HKQuantity? = nil,
        glucoseDisplayTier: GlucoseDisplayTier? = nil,
        eventualGlucoseDisplayTier: GlucoseDisplayTier? = nil,
        podWakeUpCount: Int? = nil,
        lastPodWakeUpDate: Date? = nil,
        chartGenerator makeChart: () -> UIImage?
    ) -> CLKComplicationTemplate? {

        let formatter = NumberFormatter.glucoseFormatter(for: unit)
        
        guard let glucoseDate = glucoseDate else {
            return nil
        }
        
        let glucoseString: String
        let trendString: String
        
        let isGlucoseStale = date.timeIntervalSince(glucoseDate) > recencyInterval

        if isGlucoseStale {
            glucoseString = NSLocalizedString("---", comment: "No glucose value representation (3 dashes for mg/dL; no spaces as this will get truncated in the watch complication)")
            trendString = ""
        } else {
            guard let formattedGlucose = formatter.string(from: glucose.doubleValue(for: unit)) else {
                return nil
            }
            glucoseString = formattedGlucose
            trendString = trend?.symbol ?? " "
        }
        
        let loopCompletionFreshness = LoopCompletionFreshness(lastCompletion: loopLastRunDate, at: date, loopInterval: loopInterval)
        
        let tintColor: UIColor
        
        switch loopCompletionFreshness {
        case .fresh:
            tintColor = .tintColor
        case .aging:
            tintColor = .agingColor
        case .stale:
            tintColor = .staleColor
        }

        let glucoseAndTrend = "\(glucoseString)\(trendString)"
        var accessibilityStrings = [glucoseString]

        if let trend = trend {
            accessibilityStrings.append(trend.localizedDescription)
        }

        let glucoseAndTrendText = CLKSimpleTextProvider(text: glucoseAndTrend, shortText: glucoseString, accessibilityLabel: accessibilityStrings.joined(separator: ", "))
        
        let timeText: CLKTextProvider
        
        if let loopLastRunDate = loopLastRunDate {
            timeText = CLKRelativeDateTextProvider(date: loopLastRunDate, style: .natural, units: [.minute, .hour, .day])
        } else {
            timeText = CLKTextProvider(format: "")
        }
        timeText.tintColor = tintColor

        let timeFormatter = DateFormatter()
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short

        switch family {
        case .modularSmall:
            let template = CLKComplicationTemplateModularSmallStackText(line1TextProvider: glucoseAndTrendText, line2TextProvider: timeText)
            template.highlightLine2 = true
            return template
        case .modularLarge:
            return CLKComplicationTemplateModularLargeTallBody(headerTextProvider: timeText, bodyTextProvider: glucoseAndTrendText)
        case .circularSmall:
            return CLKComplicationTemplateCircularSmallSimpleText(textProvider: CLKSimpleTextProvider(text: glucoseString))
        case .extraLarge:
            return CLKComplicationTemplateExtraLargeStackText(line1TextProvider: glucoseAndTrendText, line2TextProvider: timeText)
        case .utilitarianSmall, .utilitarianSmallFlat:
            return CLKComplicationTemplateUtilitarianSmallFlat(textProvider: CLKSimpleTextProvider(text: glucoseString))
        case .utilitarianLarge:
            var eventualGlucoseText = ""
            if  let eventualGlucose = eventualGlucose,
                let eventualGlucoseString = formatter.string(from: eventualGlucose.doubleValue(for: unit))
            {
                eventualGlucoseText = eventualGlucoseString
            }

            let format = NSLocalizedString("UtilitarianLargeFlat", tableName: "ckcomplication", comment: "Utilitarian large flat format string (1: Glucose & Trend symbol) (2: Eventual Glucose) (3: Time)")

            return CLKComplicationTemplateUtilitarianLargeFlat(
                textProvider: CLKSimpleTextProvider(text: String(format: format, arguments: [
                    glucoseAndTrend,
                    eventualGlucoseText,
                    timeFormatter.string(from: glucoseDate)
                ]
            )))
        case .graphicCorner:
            if #available(watchOSApplicationExtension 5.0, *) {
                return CLKComplicationTemplateGraphicCornerStackText(innerTextProvider: timeText, outerTextProvider: glucoseAndTrendText)
            } else {
                return nil
            }
        case .graphicCircular:
            if #available(watchOSApplicationExtension 5.0, *) {
                return CLKComplicationTemplateGraphicCircularOpenGaugeSimpleText(
                    gaugeProvider: CLKSimpleGaugeProvider(style: .fill, gaugeColor: tintColor, fillFraction: 1),
                    bottomTextProvider: CLKSimpleTextProvider(text: trendString),
                    centerTextProvider: CLKSimpleTextProvider(text: glucoseString)
                )
            } else {
                return nil
            }
        case .graphicBezel:
            if #available(watchOSApplicationExtension 5.0, *) {
                guard
                    let circularTemplate = templateForFamily(.graphicCircular,
                                                             glucose: glucose,
                                                             unit: unit,
                                                             glucoseDate: glucoseDate,
                                                             trend: trend,
                                                             eventualGlucose: eventualGlucose,
                                                             at: date,
                                                             loopLastRunDate: loopLastRunDate,
                                                             loopInterval: loopInterval,
                                                             recencyInterval: recencyInterval,
                                                             activeInsulin: activeInsulin,
                                                             activeCarbohydrates: activeCarbohydrates,
                                                             glucoseDisplayTier: glucoseDisplayTier,
                                                             eventualGlucoseDisplayTier: eventualGlucoseDisplayTier,
                                                             chartGenerator: makeChart
                        ) as? CLKComplicationTemplateGraphicCircular
                else {
                    fatalError("\(#function) invoked with .graphicCircular must return a subclass of CLKComplicationTemplateGraphicCircular")
                }
                return CLKComplicationTemplateGraphicBezelCircularText(circularTemplate: circularTemplate, textProvider: timeText)
            } else {
                return nil
            }
        case .graphicRectangular:
            if #available(watchOSApplicationExtension 5.0, *) {
                return CLKComplicationTemplateGraphicRectangularLargeImage(
                    textProvider: rectangularTextProvider(glucoseAndTrend: glucoseAndTrend,
                                                          glucoseString: glucoseString,
                                                          accessibilityLabel: accessibilityStrings.joined(separator: ", "),
                                                          glucoseDisplayTier: glucoseDisplayTier,
                                                          trend: trend,
                                                          isClosedLoop: isClosedLoop,
                                                          loopStatusColor: tintColor,
                                                          activeInsulin: activeInsulin,
                                                          freshnessColor: tintColor,
                                                          fallbackTimeText: timeText,
                                                          podWakeUpCount: podWakeUpCount,
                                                          lastPodWakeUpDate: lastPodWakeUpDate),
                    imageProvider: CLKFullColorImageProvider(fullColorImage: makeChart() ?? UIImage())
                )
            } else {
                return nil
            }
        case .graphicExtraLarge:
            if #available(watchOSApplicationExtension 5.0, *) {
                return CLKComplicationTemplateGraphicExtraLargeCircularOpenGaugeSimpleText(
                    gaugeProvider: CLKSimpleGaugeProvider(style: .fill, gaugeColor: tintColor, fillFraction: 1),
                    bottomTextProvider: CLKSimpleTextProvider(text: trendString),
                    centerTextProvider: CLKSimpleTextProvider(text: glucoseString)
                )
            } else {
                return nil
            }
        @unknown default:
            return nil
        }
    }

    private static var complicationInsulinFormatter: QuantityFormatter = {
        let formatter = QuantityFormatter(for: .internationalUnit())
        formatter.numberFormatter.minimumFractionDigits = 1
        formatter.numberFormatter.maximumFractionDigits = 1
        return formatter
    }()

    /// Per-segment tint colors survive on `.graphicRectangular` because `ComplicationController` deliberately
    /// does not set a template-wide tint for that family.
    private static func rectangularTextProvider(
        glucoseAndTrend: String,
        glucoseString: String,
        accessibilityLabel: String,
        glucoseDisplayTier: GlucoseDisplayTier?,
        trend: GlucoseTrend?,
        isClosedLoop: Bool?,
        loopStatusColor: UIColor,
        activeInsulin: HKQuantity?,
        freshnessColor: UIColor,
        fallbackTimeText: CLKTextProvider,
        podWakeUpCount: Int?,
        lastPodWakeUpDate: Date?
    ) -> CLKTextProvider {
        var providers: [CLKTextProvider] = []

        if let isClosedLoop {
            let loopStatusText = CLKSimpleTextProvider(text: isClosedLoop ? "●" : "○")
            loopStatusText.tintColor = loopStatusColor
            providers.append(loopStatusText)
        }

        let glucoseText = CLKSimpleTextProvider(text: glucoseString, shortText: glucoseString, accessibilityLabel: glucoseString)
        glucoseText.tintColor = glucoseDisplayTier?.complicationColor ?? freshnessColor
        providers.append(glucoseText)

        if let trend {
            let trendText = CLKSimpleTextProvider(text: trend.arrows, shortText: trend.arrows, accessibilityLabel: trend.localizedDescription)
            trendText.tintColor = trend.complicationColor
            providers.append(trendText)
        }

        if let activeInsulin, let insulinString = compactString(from: activeInsulin, formatter: complicationInsulinFormatter, unit: "AI") {
            let insulinText = CLKSimpleTextProvider(text: insulinString, shortText: insulinString, accessibilityLabel: insulinString)
            insulinText.tintColor = .cyan
            providers.append(insulinText)
        }

        if let podWakeUpCount {
            let wakeUpCountText = CLKSimpleTextProvider(text: "\(podWakeUpCount)x", shortText: "\(podWakeUpCount)x", accessibilityLabel: "\(podWakeUpCount)x")
            wakeUpCountText.tintColor = .purple
            providers.append(wakeUpCountText)

            if let lastPodWakeUpDate {
                let timeString = DateFormatter.localizedString(from: lastPodWakeUpDate, dateStyle: .none, timeStyle: .short)
                let wakeUpTimeText = CLKSimpleTextProvider(text: timeString)
                wakeUpTimeText.tintColor = .white
                providers.append(wakeUpTimeText)
            }
        }

        return CLKTextProvider(byJoining: providers, separator: "  ")
    }

    /// Value and unit without the usual separating space, to save room on the complication. Pass `unit` to
    /// override the localized unit label (e.g. "AI" for active insulin instead of "IE").
    private static func compactString(from quantity: HKQuantity, formatter: QuantityFormatter, unit: String? = nil) -> String? {
        guard let value = formatter.string(from: quantity, includeUnit: false) else {
            return nil
        }
        let unitString = unit ?? formatter.localizedUnitStringWithPlurality(forQuantity: quantity, avoidLineBreaking: false)
        return value + unitString
    }

}

extension GlucoseDisplayTier {
    var complicationColor: UIColor {
        switch self {
        case .inRange:
            return UIColor(red: 76 / 255, green: 217 / 255, blue: 100 / 255, alpha: 1)
        case .outOfRange:
            return UIColor(red: 1, green: 149 / 255, blue: 0, alpha: 1)
        case .urgent:
            return .staleColor
        }
    }
}

private extension GlucoseTrend {
    var complicationColor: UIColor {
        switch self {
        case .flat:
            return UIColor(red: 76 / 255, green: 217 / 255, blue: 100 / 255, alpha: 1)
        case .up, .down:
            return UIColor(red: 1, green: 149 / 255, blue: 0, alpha: 1)
        case .upUp, .downDown, .upUpUp, .downDownDown:
            return UIColor(red: 1, green: 59 / 255, blue: 48 / 255, alpha: 1)
        }
    }
}
