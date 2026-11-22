//
//  GlucoseRangeCategory.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-07-28.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import LoopKit
import LoopCore

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
}

extension GlucoseTrend {
    public var loopTrendColor: UIColor {
        switch displayTier {
        case .inRange:
            return .freshColor
        case .outOfRange:
            return .systemOrange
        case .urgent:
            return .critical
        }
    }
}
