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

    private var activeButtonsMask: UInt16 = 0
    private var leftTriggerVal: UInt8 = 0
    private var rightTriggerVal: UInt8 = 0
    private var leftStickX: Int16 = 0
    private var leftStickY: Int16 = 0
    private var rightStickX: Int16 = 0
    private var rightStickY: Int16 = 0
    private var releaseWorkItem: DispatchWorkItem?
    
    init() {
        setupControllerObservers()
        checkExistingControllers()
        // Publish slot 0 connected at rest so XInput games detect a controller at startup
        syncGamepadStateToEngine()
    }

    private func syncGamepadStateToEngine() {
        BramaCore.shared().updateGamepadState(
            at: 0,
            buttons: activeButtonsMask,
            leftTrigger: leftTriggerVal,
            rightTrigger: rightTriggerVal,
            leftX: leftStickX,
            leftY: leftStickY,
            rightX: rightStickX,
            rightY: rightStickY,
            connected: true
        )
    }

    private static func scaleAxis(_ value: Float) -> Int16 {
        guard value.isFinite else { return 0 }
        let clamped = max(-1.0, min(1.0, value))
        return Int16((clamped * (clamped < 0 ? 32768.0 : 32767.0)).rounded())
    }

    private static func scaleTrigger(_ value: Float) -> UInt8 {
        guard value.isFinite else { return 0 }
        return UInt8((max(0.0, min(1.0, value)) * 255.0).rounded())
    }
    
    func sendVirtualInput(_ label: String, dx: CGFloat = 0, dy: CGFloat = 0) {
        lastButtonPressed = label
        if dx != 0 || dy != 0 {
            moveVector = CGSize(width: dx, height: dy)
        }
        actionPulseID &+= 1

        releaseWorkItem?.cancel()

        var transientMask: UInt16 = 0
        var transientVK: Int32 = 0
        var lt: UInt8 = 0
        var rt: UInt8 = 0
        let lx = Self.scaleAxis(Float(dx))
        let ly = Self.scaleAxis(Float(-dy))

        switch label {
        case "A":
            transientMask = 0x1000 // XINPUT_GAMEPAD_A
            transientVK = 0x5A     // 'Z' (Jump / Confirm in Hollow Knight)
        case "B":
            transientMask = 0x2000 // XINPUT_GAMEPAD_B
            transientVK = 0x58     // 'X' (Attack / Cancel)
        case "X":
            transientMask = 0x4000 // XINPUT_GAMEPAD_X
            transientVK = 0x43     // 'C' (Dash)
        case "Y":
            transientMask = 0x8000 // XINPUT_GAMEPAD_Y
            transientVK = 0x41     // 'A' (Focus / Cast)
        case "L1":
            transientMask = 0x0100 // XINPUT_GAMEPAD_LEFT_SHOULDER
            transientVK = 0x09     // VK_TAB (Map)
        case "R1":
            transientMask = 0x0200 // XINPUT_GAMEPAD_RIGHT_SHOULDER
            transientVK = 0x46     // 'F' (Quick Cast)
        case "L2":
            lt = 255
            transientVK = 0x53     // 'S' (Super Dash)
        case "R2":
            rt = 255
            transientVK = 0x44     // 'D' (Dream Nail)
        case "START", "MENU":
            transientMask = 0x0010 // XINPUT_GAMEPAD_START
            transientVK = 0x1B     // VK_ESCAPE
        case "SELECT", "OPTIONS":
            transientMask = 0x0020 // XINPUT_GAMEPAD_BACK
            transientVK = 0x49     // 'I' (Inventory)
        case "ARRIBA":
            transientMask = 0x0001 // XINPUT_GAMEPAD_DPAD_UP
            transientVK = 0x26     // VK_UP
        case "ABAJO":
            transientMask = 0x0002 // XINPUT_GAMEPAD_DPAD_DOWN
            transientVK = 0x28     // VK_DOWN
        case "IZQUIERDA":
            transientMask = 0x0004 // XINPUT_GAMEPAD_DPAD_LEFT
            transientVK = 0x25     // VK_LEFT
        case "DERECHA":
            transientMask = 0x0008 // XINPUT_GAMEPAD_DPAD_RIGHT
            transientVK = 0x27     // VK_RIGHT
        default:
            break
        }

        activeButtonsMask = transientMask
        leftTriggerVal = lt
        rightTriggerVal = rt
        leftStickX = lx
        leftStickY = ly
        syncGamepadStateToEngine()

        if transientVK != 0 {
            BramaCore.shared().postKeyVirtualCode(transientVK, isDown: true)
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.activeButtonsMask = 0
            self.leftTriggerVal = 0
            self.rightTriggerVal = 0
            self.leftStickX = 0
            self.leftStickY = 0
            self.syncGamepadStateToEngine()
            if transientVK != 0 {
                BramaCore.shared().postKeyVirtualCode(transientVK, isDown: false)
            }
        }
        releaseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
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
            self.activeButtonsMask = 0
            self.leftTriggerVal = 0
            self.rightTriggerVal = 0
            self.leftStickX = 0
            self.leftStickY = 0
            self.rightStickX = 0
            self.rightStickY = 0
            self.syncGamepadStateToEngine()
        }
    }
    
    private func configure(controller: GCController) {
        self.isPhysicalControllerConnected = true
        self.controllerName = controller.vendorName ?? "Mando Inalámbrico"
        if let battery = controller.battery {
            self.controllerBatteryLevel = battery.batteryLevel
        }
        
        if let extendedGamepad = controller.extendedGamepad {
            extendedGamepad.valueChangedHandler = { [weak self] pad, _ in
                guard let self = self else { return }
                var mask: UInt16 = 0
                if pad.dpad.up.isPressed    { mask |= 0x0001 }
                if pad.dpad.down.isPressed  { mask |= 0x0002 }
                if pad.dpad.left.isPressed  { mask |= 0x0004 }
                if pad.dpad.right.isPressed { mask |= 0x0008 }
                if pad.buttonMenu.isPressed { mask |= 0x0010 }
                if pad.buttonOptions?.isPressed == true { mask |= 0x0020 }
                if pad.leftThumbstickButton?.isPressed == true  { mask |= 0x0040 }
                if pad.rightThumbstickButton?.isPressed == true { mask |= 0x0080 }
                if pad.leftShoulder.isPressed  { mask |= 0x0100 }
                if pad.rightShoulder.isPressed { mask |= 0x0200 }
                if pad.buttonHome?.isPressed == true { mask |= 0x0400 }
                if pad.buttonA.isPressed { mask |= 0x1000 }
                if pad.buttonB.isPressed { mask |= 0x2000 }
                if pad.buttonX.isPressed { mask |= 0x4000 }
                if pad.buttonY.isPressed { mask |= 0x8000 }

                self.activeButtonsMask = mask
                self.leftTriggerVal = Self.scaleTrigger(pad.leftTrigger.value)
                self.rightTriggerVal = Self.scaleTrigger(pad.rightTrigger.value)
                self.leftStickX = Self.scaleAxis(pad.leftThumbstick.xAxis.value)
                self.leftStickY = Self.scaleAxis(pad.leftThumbstick.yAxis.value)
                self.rightStickX = Self.scaleAxis(pad.rightThumbstick.xAxis.value)
                self.rightStickY = Self.scaleAxis(pad.rightThumbstick.yAxis.value)
                self.syncGamepadStateToEngine()
            }
        }
    }
}
