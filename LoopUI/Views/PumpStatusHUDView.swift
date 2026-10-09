//
//  PumpStatusHUDView.swift
//  LoopUI
//
//  Created by Nathaniel Hamming on 2020-06-09.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import UIKit
import HealthKit
import LoopKit
import LoopKitUI

public final class PumpStatusHUDView: DeviceStatusHUDView, NibLoadable {
    
    @IBOutlet public weak var basalRateHUD: BasalRateHUDView!
    
    @IBOutlet public weak var pumpManagerProvidedHUD: BaseHUDView!

    /// Short marker over the pump image, e.g. "U200" while concentrated insulin is in use; nil hides it.
    public var insulinConcentrationText: String? {
        didSet {
            if insulinConcentrationText != oldValue {
                updateInsulinConcentrationLabel()
            }
        }
    }

    private lazy var insulinConcentrationLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 10, weight: .bold)
        label.textColor = .white
        label.backgroundColor = .systemOrange
        label.layer.cornerRadius = 4
        label.clipsToBounds = true
        label.isHidden = true
        return label
    }()

    private var insulinConcentrationConstraints: [NSLayoutConstraint] = []

    private func updateInsulinConcentrationLabel() {
        let label = insulinConcentrationLabel
        NSLayoutConstraint.deactivate(insulinConcentrationConstraints)
        insulinConcentrationConstraints = []
        guard let text = insulinConcentrationText, statusHighlightView?.isHidden != false else {
            label.isHidden = true
            return
        }
        if label.superview == nil {
            addSubview(label)
        }
        label.text = " \(text) "
        let anchorView: UIView = pumpManagerProvidedHUD.flatMap { $0.superview != nil ? $0 : nil } ?? self
        let preferredTop = label.topAnchor.constraint(equalTo: anchorView.topAnchor)
        preferredTop.priority = .defaultHigh
        insulinConcentrationConstraints = [
            label.centerXAnchor.constraint(equalTo: anchorView.centerXAnchor),
            preferredTop,
            // Pump HUDs center a ~34 pt reservoir image whose volume text sits inside it; stay above the image.
            label.bottomAnchor.constraint(lessThanOrEqualTo: anchorView.centerYAnchor, constant: -18)
        ]
        NSLayoutConstraint.activate(insulinConcentrationConstraints)
        label.isHidden = false
        bringSubviewToFront(label)
    }
        
    override public var orderPriority: HUDViewOrderPriority {
        return 3
    }
    
    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    
    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        setup()
    }
    
    override func setup() {
        super.setup()
        statusHighlightView.setIconPosition(.left)
    }
    
    public override func tintColorDidChange() {
        super.tintColorDidChange()
        
        basalRateHUD.tintColor = tintColor
    }

    override public func presentStatusHighlight() {
        guard !statusStackView.arrangedSubviews.contains(statusHighlightView) else {
            return
        }
        
        // need to also hide these view, since they will be added back to the stack at some point
        basalRateHUD.isHidden = true
        statusStackView.removeArrangedSubview(basalRateHUD)
        
        if let pumpManagerProvidedHUD = pumpManagerProvidedHUD {
            pumpManagerProvidedHUD.isHidden = true
            statusStackView.removeArrangedSubview(pumpManagerProvidedHUD)
        }

        super.presentStatusHighlight()
        updateInsulinConcentrationLabel()
    }
    
    override public func dismissStatusHighlight() {
        guard statusStackView.arrangedSubviews.contains(statusHighlightView) else {
            return
        }
        
        super.dismissStatusHighlight()
        
        statusStackView.addArrangedSubview(basalRateHUD)
        basalRateHUD.isHidden = false
        
        if let pumpManagerProvidedHUD = pumpManagerProvidedHUD {
            statusStackView.addArrangedSubview(pumpManagerProvidedHUD)
            pumpManagerProvidedHUD.isHidden = false
        }
        updateInsulinConcentrationLabel()
    }
    
    public func removePumpManagerProvidedHUD() {
        guard let pumpManagerProvidedHUD = pumpManagerProvidedHUD else {
            return
        }
        
        statusStackView.removeArrangedSubview(pumpManagerProvidedHUD)
        pumpManagerProvidedHUD.removeFromSuperview()
        updateInsulinConcentrationLabel()
    }
    
    public func addPumpManagerProvidedHUDView(_ pumpManagerProvidedHUD: BaseHUDView) {
        self.pumpManagerProvidedHUD = pumpManagerProvidedHUD
        statusStackView.addArrangedSubview(self.pumpManagerProvidedHUD)
        updateInsulinConcentrationLabel()
    }
    
}
