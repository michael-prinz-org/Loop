//
//  ComplicationChartManager.swift
//  WatchApp Extension
//
//  Created by Michael Pangburn on 10/17/18.
//  Copyright © 2018 LoopKit Authors. All rights reserved.
//

import Foundation
import UIKit
import HealthKit
import WatchKit
import LoopKit
import LoopCore

private let textInsets = UIEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)

extension CGSize {
    fileprivate static let glucosePoint = CGSize(width: 2, height: 2)
}

extension NSAttributedString {
    fileprivate class func forGlucoseLabel(string: String) -> NSAttributedString {
        return NSAttributedString(string: string, attributes: [
            .font: UIFont(name: "HelveticaNeue", size: 10)!,
            .foregroundColor: UIColor.chartLabel
        ])
    }
}

extension CGFloat {
    fileprivate static let predictionDashPhase: CGFloat = 11
}

private let predictionDashLengths: [CGFloat] = [5, 3]


final class ComplicationChartManager {
    private enum GlucoseLabelPosition {
        case high
        case low
    }

    var data: GlucoseChartData?
    private var lastRenderDate: Date?
    private var renderedChartImage: UIImage?
    private var visibleInterval: TimeInterval = .hours(4)

    private var unit: HKUnit {
        return data?.unit ?? .milligramsPerDeciliter
    }

    func renderChartImage(size: CGSize, scale: CGFloat) -> UIImage? {
        guard let data = data else {
            renderedChartImage = nil
            return nil
        }

        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        defer { UIGraphicsEndImageContext() }

        guard let context = UIGraphicsGetCurrentContext() else {
            return nil
        }

        drawChart(in: context, data: data, size: size)

        guard let cgImage = context.makeImage() else {
            renderedChartImage = nil
            return nil
        }

        let image = UIImage(cgImage: cgImage, scale: scale, orientation: .up)
        renderedChartImage = image
        return image
    }

    private func drawChart(in context: CGContext, data: GlucoseChartData, size: CGSize) {
        let now = Date()
        lastRenderDate = now
        let spannedInterval = DateInterval(start: now - visibleInterval / 2, duration: visibleInterval)
        let glucoseRange = data.chartableGlucoseRange(from: spannedInterval)
        let scaler = GlucoseChartScaler(size: size, dateInterval: spannedInterval, glucoseRange: glucoseRange, unit: unit)

        let drawingSteps = [drawTargetRange, drawOverridesIfNeeded, drawHistoricalGlucose, drawPredictedGlucose, drawGlucoseLabels, drawEventualGlucoseLabel]
        drawingSteps.forEach { drawIn in drawIn(context, scaler) }
    }

    private func drawGlucoseLabels(in context: CGContext, using scaler: GlucoseChartScaler) {
        let formatter = NumberFormatter.glucoseFormatter(for: unit)
        drawGlucoseLabelText(formatter.string(from: scaler.glucoseMax)!, position: .high, scaler: scaler)
        drawGlucoseLabelText(formatter.string(from: scaler.glucoseMin)!, position: .low, scaler: scaler)
    }

    private func drawEventualGlucoseLabel(in context: CGContext, using scaler: GlucoseChartScaler) {
        guard let eventualGlucose = data?.eventualGlucose,
              let text = NumberFormatter.glucoseFormatter(for: unit).string(from: eventualGlucose.doubleValue(for: unit))
        else {
            return
        }

        let attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont(name: "HelveticaNeue-Bold", size: 10)!,
            .foregroundColor: data?.eventualGlucoseDisplayTier?.complicationColor ?? UIColor.chartLabel
        ])
        let size = attributedText.size()
        let x = scaler.xCoordinate(for: scaler.dates.end) - size.width - textInsets.right
        let y = scaler.yCoordinate(for: (scaler.glucoseMin + scaler.glucoseMax) / 2) - size.height / 2
        let rect = CGRect(origin: CGPoint(x: x, y: y), size: size).alignedToScreenScale(WKInterfaceDevice.current().screenScale)
        attributedText.draw(with: rect, options: NSStringDrawingOptions.usesLineFragmentOrigin, context: nil)
    }

    private func drawGlucoseLabelText(_ text: String, position: GlucoseLabelPosition, scaler: GlucoseChartScaler) {
        let attributedText = NSAttributedString.forGlucoseLabel(string: text)
        let size = attributedText.size()
        let x = scaler.xCoordinate(for: scaler.dates.end) - size.width - textInsets.right
        let y: CGFloat = {
            switch position {
            case .high:
                return scaler.yCoordinate(for: scaler.glucoseMax) + textInsets.top
            case .low:
                return scaler.yCoordinate(for: scaler.glucoseMin) - size.height - textInsets.bottom
            }
        }()
        let rect = CGRect(origin: CGPoint(x: x, y: y), size: size).alignedToScreenScale(WKInterfaceDevice.current().screenScale)
        attributedText.draw(with: rect, options: NSStringDrawingOptions.usesLineFragmentOrigin, context: nil)
    }

    private func drawTargetRange(in context: CGContext, using scaler: GlucoseChartScaler) {
        let activeOverride = data?.activeScheduleOverride
        let targetRangeAlpha: CGFloat = activeOverride != nil ? 0.2 : 0.3
        context.setFillColor(UIColor.glucose.withAlphaComponent(targetRangeAlpha).cgColor)
        data?.correctionRange?.quantityBetween(start: scaler.dates.start, end: scaler.dates.end).forEach { range in
            let rangeRect = scaler.rect(for: range, unit: unit)
            context.fill(rangeRect)
        }
    }

    private func drawOverridesIfNeeded(in context: CGContext, using scaler: GlucoseChartScaler) {
        let overrideColor = UIColor.glucose.withAlphaComponent(0.4).cgColor
        let extendedOverrideColor = UIColor.glucose.withAlphaComponent(0.25).cgColor
        let spannedInterval = scaler.dates

        func drawOverride(
            _ override: TemporaryScheduleOverride,
            pushingStartTo startDate: Date? = nil,
            extendingToChartEnd shouldExtendToChartEnd: Bool
        ) {
            var override = override
            if let startDate = startDate {
                guard startDate < override.scheduledEndDate else {
                    return
                }

                override.scheduledInterval = DateInterval(start: startDate, end: override.scheduledEndDate)
            }

            guard let overrideHashable = TemporaryScheduleOverrideHashable(override) else {
                return
            }

            context.setFillColor(overrideColor)
            let overrideRect = scaler.rect(for: overrideHashable, unit: unit)
            context.fill(overrideRect)

            if spannedInterval.end > override.scheduledEndDate, shouldExtendToChartEnd {
                var extendedOverride = override
                extendedOverride.duration = .finite(spannedInterval.end.timeIntervalSince(override.startDate))
                // Target range already known to be non-nil
                let extendedOverrideHashable = TemporaryScheduleOverrideHashable(extendedOverride)!
                let extendedOverrideRect = scaler.rect(for: extendedOverrideHashable, unit: unit)
                context.setFillColor(extendedOverrideColor)
                context.fill(extendedOverrideRect)
            }
        }

        if let preMealOverride = data?.activePreMealOverride {
            drawOverride(preMealOverride, extendingToChartEnd: true)
        }

        if let override = data?.activeScheduleOverride {
            drawOverride(override, pushingStartTo: data?.activePreMealOverride?.scheduledEndDate, extendingToChartEnd: data?.activePreMealOverride == nil)
        }
    }

    private func drawHistoricalGlucose(in context: CGContext, using scaler: GlucoseChartScaler) {
        let historicalGlucose = data?.historicalGlucose?.filter {
            scaler.dates.contains($0.startDate)
        } ?? []

        guard !historicalGlucose.isEmpty else {
            return
        }

        if historicalGlucose.count > 1 {
            context.setLineWidth(1)
            for index in 1..<historicalGlucose.count {
                let previous = historicalGlucose[index - 1]
                let current = historicalGlucose[index]
                let trendPath = CGMutablePath()
                trendPath.move(to: scaler.point(for: previous, unit: unit))
                trendPath.addLine(to: scaler.point(for: current, unit: unit))
                context.setStrokeColor(chartColor(for: data?.glucoseSettings.glucoseDisplayTier(for: current.quantity) ?? .inRange).cgColor)
                context.addPath(trendPath)
                context.strokePath()
            }
        }

        historicalGlucose.forEach { glucose in
            let origin = scaler.point(for: glucose, unit: unit)
            let glucoseRect = CGRect(origin: origin, size: .glucosePoint).alignedToScreenScale(WKInterfaceDevice.current().screenScale)
            context.setFillColor(chartColor(for: data?.glucoseSettings.glucoseDisplayTier(for: glucose.quantity) ?? .inRange).cgColor)
            context.fill(glucoseRect)
        }
    }

    private func drawPredictedGlucose(in context: CGContext, using scaler: GlucoseChartScaler) {
        guard let predictedGlucose = data?.predictedGlucose, predictedGlucose.count > 2 else {
            return
        }
        context.setLineWidth(2)
        for index in 1..<predictedGlucose.count {
            let previous = predictedGlucose[index - 1]
            let current = predictedGlucose[index]
            let predictedPath = CGMutablePath()
            predictedPath.move(to: scaler.point(for: previous, unit: unit))
            predictedPath.addLine(to: scaler.point(for: current, unit: unit))
            let dashedPath = predictedPath.copy(dashingWithPhase: .predictionDashPhase, lengths: predictionDashLengths)
            context.setStrokeColor(chartColor(for: data?.glucoseSettings.glucoseDisplayTier(forPredicted: current.quantity, at: current.startDate) ?? .inRange).cgColor)
            context.addPath(dashedPath)
            context.strokePath()
        }
    }

    private static func chartColor(for tier: GlucoseDisplayTier) -> UIColor {
        switch tier {
        case .inRange:
            return UIColor(red: 76 / 255, green: 217 / 255, blue: 100 / 255, alpha: 0.82)
        case .outOfRange:
            return UIColor(red: 1, green: 149 / 255, blue: 0, alpha: 0.72)
        case .urgent:
            return UIColor(red: 1, green: 59 / 255, blue: 48 / 255, alpha: 0.78)
        }
    }
}
