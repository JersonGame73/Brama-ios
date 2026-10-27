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
    @Published var showVirtualTouchControls: Bool = true
    
    // Real-time input state for in-game session
    @Published var lastButtonPressed: String = "LISTO"
    @Published var moveVector: CGSize = .zero
    @Published var actionPulseID: Int = 0
    
    init() {
        setupControllerObservers()
        checkExistingControllers()
    }
    
    func sendVirtualInput(_ label: String, dx: CGFloat = 0, dy: CGFloat = 0) {
        lastButtonPressed = label
        if dx != 0 || dy != 0 {
            moveVector = CGSize(width: dx, height: dy)
        }
        actionPulseID &+= 1
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
            self.showVirtualTouchControls = true
        }
    }
    
    private func configure(controller: GCController) {
        self.isPhysicalControllerConnected = true
        self.controllerName = controller.vendorName ?? "Mando Inalámbrico"
        if let battery = controller.battery {
            self.controllerBatteryLevel = battery.batteryLevel
        }
        
        if let extendedGamepad = controller.extendedGamepad {
            extendedGamepad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    DispatchQueue.main.async { self?.sendVirtualInput("A") }
                }
            }
            extendedGamepad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    DispatchQueue.main.async { self?.sendVirtualInput("B") }
                }
            }
            extendedGamepad.buttonX.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    DispatchQueue.main.async { self?.sendVirtualInput("X") }
                }
            }
            extendedGamepad.buttonY.pressedChangedHandler = { [weak self] _, _, pressed in
                if pressed {
                    DispatchQueue.main.async { self?.sendVirtualInput("Y") }
                }
            }
            extendedGamepad.dpad.valueChangedHandler = { [weak self] _, xValue, yValue in
                DispatchQueue.main.async {
                    if abs(xValue) > 0.2 || abs(yValue) > 0.2 {
                        self?.sendVirtualInput("DPAD", dx: CGFloat(xValue), dy: CGFloat(-yValue))
                    }
                }
            }
            extendedGamepad.leftThumbstick.valueChangedHandler = { [weak self] _, xValue, yValue in
                DispatchQueue.main.async {
                    if abs(xValue) > 0.2 || abs(yValue) > 0.2 {
                        self?.sendVirtualInput("STICK", dx: CGFloat(xValue), dy: CGFloat(-yValue))
                    }
                }
            }
        }
    }
}
