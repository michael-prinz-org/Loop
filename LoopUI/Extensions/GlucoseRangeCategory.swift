//
//  GlucoseRangeCategory.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-07-28.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import LoopKit

extension GlucoseRangeCategory {
    public var glucoseColor: UIColor {
        switch self {
        case .high, .low, .aboveRange:
            return .systemOrange
        case .normal:
            return .freshColor
        case .urgentLow, .belowRange:
            return .critical
        }
    }
    
    public var trendColor: UIColor {
        switch self {
        case .normal:
            return .glucose
        case .urgentLow, .belowRange:
            return .critical
        case .low, .high, .aboveRange:
            return .warning
        }
    }
}

extension GlucoseTrend {
    public var loopTrendColor: UIColor {
        switch self {
        case .flat:
            return .freshColor
        case .up, .down:
            return .systemOrange
        case .upUp, .downDown, .upUpUp, .downDownDown:
            return .critical
        }
    }
}
