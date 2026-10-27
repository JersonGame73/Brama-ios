//
//  ControllerManager.swift
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

import SwiftUI
import GameController
import Combine

final class ControllerManager: ObservableObject {
    static let shared = ControllerManager()
    
    @Published var isPhysicalControllerConnected: Bool = false
    @Published var controllerName: String = "Sin mando físico"
    @Published var controllerBatteryLevel: Float = 1.0
    @Published var showVirtualTouchControls: Bool = false
    
    // Quick controller actions
    @Published var lastButtonPressed: String = ""
    
    init() {
        setupControllerObservers()
        checkExistingControllers()
    }
    
    private func setupControllerObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleControllerDidConnect(notification:)),
            name: .GCControllerDidConnect,
            object: nil
        )
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleControllerDidDisconnect(notification:)),
            name: .GCControllerDidDisconnect,
            object: nil
        )
    }
    
    private func checkExistingControllers() {
        if let controller = GCController.controllers().first {
            configure(controller: controller)
        }
    }
    
    @objc private func handleControllerDidConnect(notification: Notification) {
        guard let controller = notification.object as? GCController else { return }
        DispatchQueue.main.async {
            self.configure(controller: controller)
        }
    }
    
    @objc private func handleControllerDidDisconnect(notification: Notification) {
        DispatchQueue.main.async {
            self.isPhysicalControllerConnected = false
            self.controllerName = "Sin mando físico"
        }
    }
    
    private func configure(controller: GCController) {
        self.isPhysicalControllerConnected = true
        self.controllerName = controller.vendorName ?? "Mando Inalámbrico"
        if let battery = controller.battery {
            self.controllerBatteryLevel = battery.batteryLevel
        }
        
        // Listen to button presses
        if let extendedGamepad = controller.extendedGamepad {
            extendedGamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    DispatchQueue.main.async { self?.lastButtonPressed = "A" }
                }
            }
            extendedGamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    DispatchQueue.main.async { self?.lastButtonPressed = "B" }
                }
            }
            extendedGamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    DispatchQueue.main.async { self?.lastButtonPressed = "X" }
                }
            }
            extendedGamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    DispatchQueue.main.async { self?.lastButtonPressed = "Y" }
                }
            }
        }
    }
}
