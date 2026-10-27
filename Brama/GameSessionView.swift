//
//  GameSessionView.swift
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

import SwiftUI
import Combine

struct GameSessionView: View {
    let game: GameTitle
    @Environment(\.dismiss) private var dismiss
    
    @ObservedObject var perfManager = PerformanceManager.shared
    @ObservedObject var controllerManager = ControllerManager.shared
    
    @State private var bootLogs: [String] = []
    @State private var isBootSequenceFinished: Bool = false
    @State private var showInGameMenu: Bool = false
    @State private var showBootConsole: Bool = true
    @State private var frameCounter: Int = 0
    @State private var loadedPEInfo: BramaPEExecutableInfo? = nil
    @State private var runtimeStatus: BramaRuntimeModulesStatus? = nil
    
    // Interactive 60 FPS Sandbox / Character State
    @State private var avatarOffset: CGSize = .zero
    @State private var avatarVelocityY: CGFloat = 0
    @State private var facingRight: Bool = true
    @State private var isSlashing: Bool = false
    @State private var isFocusingSoul: Bool = false
    @State private var soulCharge: Double = 0.75
    @State private var hitCounter: Int = 0
    @State private var targetDummyOffset: CGFloat = 95
    @State private var dummyHitFlash: Bool = false
    
    private let renderTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            // Absolute Solid Black Background
            Color.black
                .ignoresSafeArea()
            
            // Fullscreen Metal Canvas (GPU Rendering via Apple MetalKit)
            MetalViewportView()
                .ignoresSafeArea()
            
            // Virtual Game Display Screen (Always visible, transitions from boot to interactive arena)
            virtualGameScreenView
                .transition(.opacity)
            
            // In-Game Boot Terminal / Loader Console
            if showBootConsole {
                bootConsoleView
                    .transition(.opacity)
                    .zIndex(50)
            }
            
            // In-Game MangoHUD (Top Left)
            if perfManager.overlayLevel != .off {
                VStack {
                    HStack {
                        inGameHUD
                        Spacer()
                    }
                    .padding(.top, 14)
                    .padding(.leading, 20)
                    Spacer()
                }
                .allowsHitTesting(false)
                .zIndex(60)
            }
            
            // Top-Center Floating Pause Island (Never overlaps with side bumpers!)
            VStack {
                HStack {
                    Spacer()
                    Button(action: {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            showInGameMenu.toggle()
                        }
                    }) {
                        HStack(spacing: 8) {
                            Image(systemName: "pause.fill")
                                .font(.system(size: 11, weight: .black))
                            Text("MENÚ DE PAUSA")
                                .font(.system(size: 11, weight: .black, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(Color.black.opacity(0.85))
                        )
                        .overlay(
                            Capsule()
                                .stroke(Color(red: 0.1, green: 0.62, blue: 1.0).opacity(0.8), lineWidth: 1.5)
                        )
                        .shadow(color: .black.opacity(0.5), radius: 6, x: 0, y: 3)
                    }
                    Spacer()
                }
                .padding(.top, 10)
                
                Spacer()
            }
            .zIndex(100)
            
            // Touch Gamepad Controls Overlay
            if controllerManager.showVirtualTouchControls {
                VirtualGamepadOverlayView(onMenuPressed: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showInGameMenu = true
                    }
                })
                .zIndex(80)
            }
            
            // In-Game Pause Modal
            if showInGameMenu {
                Color.black.opacity(0.65)
                    .ignoresSafeArea()
                    .onTapGesture {
                        withAnimation { showInGameMenu = false }
                    }
                    .zIndex(110)
                
                inGamePauseDialog
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
                    .zIndex(120)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            startBootSequence()
        }
        .onDisappear {
            BramaCore.shared().terminateActiveProcess()
        }
        .onChange(of: controllerManager.actionPulseID) { _ in
            handleControllerAction(controllerManager.lastButtonPressed)
        }
        .onReceive(renderTimer) { _ in
            frameCounter &+= 1
            updatePhysicsTick()
        }
    }
    
    // MARK: - Interactive 60 FPS Virtual Game Screen Display
    private var virtualGameScreenView: some View {
        ZStack {
            // 16:10 Viewport Frame
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: game.bannerGradient + [Color(red: 0.04, green: 0.06, blue: 0.11)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .aspectRatio(16/10, contentMode: .fit)
                .overlay(
                    ZStack {
                        // Subtle atmospheric particles
                        ForEach(0..<8, id: \.self) { idx in
                            let phase = Double(frameCounter) * 0.025 + Double(idx) * 1.1
                            Circle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 6, height: 6)
                                .offset(
                                    x: CGFloat(cos(phase) * 180.0) + CGFloat(idx * 25 - 90),
                                    y: CGFloat(sin(phase * 0.8) * 70.0)
                                )
                        }
                        
                        // Top-left In-Game Soul / Health HUD inside the viewport
                        VStack {
                            HStack(spacing: 12) {
                                // Soul Vessel Orb
                                ZStack {
                                    Circle()
                                        .fill(Color.black.opacity(0.65))
                                        .frame(width: 42, height: 42)
                                    Circle()
                                        .trim(from: 0, to: soulCharge)
                                        .stroke(Color.cyan, lineWidth: 4)
                                        .rotationEffect(.degrees(-90))
                                        .frame(width: 34, height: 34)
                                    Image(systemName: game.systemIcon)
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundColor(.white)
                                }
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    // 5 Masks / Health pips
                                    HStack(spacing: 5) {
                                        ForEach(0..<5, id: \.self) { _ in
                                            Capsule()
                                                .fill(Color.white)
                                                .frame(width: 10, height: 14)
                                                .shadow(color: .cyan.opacity(0.6), radius: 3)
                                        }
                                    }
                                    Text("\(game.title.uppercased()) • GOLPES: \(hitCounter)")
                                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                                        .foregroundColor(.white.opacity(0.85))
                                }
                                
                                Spacer()
                                
                                // Live Controller Input Indicator
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color.green)
                                        .frame(width: 7, height: 7)
                                    Text("INPUT: \(controllerManager.lastButtonPressed)")
                                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                                        .foregroundColor(.cyan)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.black.opacity(0.7))
                                .cornerRadius(8)
                            }
                            .padding(16)
                            
                            Spacer()
                        }
                        
                        // Arena Floor Platform
                        VStack {
                            Spacer()
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.black.opacity(0.55))
                                    .frame(height: 18)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .stroke(Color.cyan.opacity(0.45), lineWidth: 1)
                                    )
                            }
                            .padding(.horizontal, 36)
                            .padding(.bottom, 64)
                        }
                        
                        // Interactive Target Crystal / Enemy Dummy
                        VStack(spacing: 4) {
                            Image(systemName: "rhombus.fill")
                                .font(.system(size: 30))
                                .foregroundColor(dummyHitFlash ? .white : .orange)
                                .scaleEffect(dummyHitFlash ? 1.3 : 1.0)
                                .shadow(color: dummyHitFlash ? .white : .orange, radius: 10)
                            Text("OBJETIVO")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(.orange.opacity(0.9))
                        }
                        .offset(x: targetDummyOffset, y: 38)
                        
                        // Playable Hero Avatar (Moves with D-Pad / Stick, Jumps with A, Attacks with X, Focuses with Y)
                        ZStack {
                            if isFocusingSoul {
                                Circle()
                                    .stroke(Color.cyan, lineWidth: 3)
                                    .frame(width: 68, height: 68)
                                    .shadow(color: .cyan, radius: 12)
                            }
                            
                            // Nail Slash Arc when pressing X
                            if isSlashing {
                                Capsule()
                                    .fill(
                                        LinearGradient(
                                            colors: [.white, .cyan],
                                            startPoint: .leading,
                                            endPoint: .trailing
                                        )
                                    )
                                    .frame(width: 66, height: 14)
                                    .offset(x: facingRight ? 42 : -42, y: 0)
                                    .shadow(color: .cyan, radius: 8)
                            }
                            
                            // Hero Body
                            VStack(spacing: 2) {
                                ZStack {
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 34, height: 34)
                                        .shadow(color: .cyan.opacity(0.8), radius: 8)
                                    
                                    // Eyes facing direction
                                    HStack(spacing: 5) {
                                        Circle()
                                            .fill(Color.black)
                                            .frame(width: 6, height: 8)
                                        Circle()
                                            .fill(Color.black)
                                            .frame(width: 6, height: 8)
                                    }
                                    .offset(x: facingRight ? 4 : -4, y: 1)
                                }
                                
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color(red: 0.15, green: 0.22, blue: 0.35))
                                    .frame(width: 22, height: 18)
                            }
                        }
                        .offset(x: avatarOffset.width, y: 34 + avatarOffset.height)
                        
                        // Bottom Runtime Telemetry Bar inside Viewport
                        VStack {
                            Spacer()
                            HStack(spacing: 12) {
                                if let pe = loadedPEInfo {
                                    Text(String(format: "PE32+ @ 0x%llX • ENTRY 0x%04X",
                                                pe.mappedBaseAddress, pe.entryPointRVA))
                                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                                        .foregroundColor(.cyan)
                                }
                                
                                Spacer()
                                
                                Text("Controles: [D-Pad] Mover • [A] Saltar • [X] Atacar • [B] Dash • [Y] Energía")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.85))
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(Color.black.opacity(0.75))
                            .cornerRadius(8)
                            .padding(.horizontal, 20)
                            .padding(.bottom, 12)
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(Color.white.opacity(0.22), lineWidth: 1.5)
                )
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
        }
    }
    
    // MARK: - Controller & Physics Engine
    private func handleControllerAction(_ button: String) {
        switch button {
        case "IZQUIERDA":
            facingRight = false
            withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.8)) {
                avatarOffset.width = max(-190, avatarOffset.width - 28)
            }
        case "DERECHA":
            facingRight = true
            withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.8)) {
                avatarOffset.width = min(190, avatarOffset.width + 28)
            }
        case "ARRIBA", "A":
            if avatarOffset.height >= -5 {
                avatarVelocityY = -9.5
            }
        case "B", "R1", "R2":
            // Dash
            let dashDelta: CGFloat = facingRight ? 65 : -65
            withAnimation(.easeOut(duration: 0.15)) {
                avatarOffset.width = min(190, max(-190, avatarOffset.width + dashDelta))
            }
        case "X", "L1":
            // Nail Slash Attack
            isSlashing = true
            let attackReach = avatarOffset.width + (facingRight ? 42 : -42)
            if abs(attackReach - targetDummyOffset) < 48 && abs(avatarOffset.height) < 45 {
                hitCounter += 1
                soulCharge = min(1.0, soulCharge + 0.12)
                dummyHitFlash = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    dummyHitFlash = false
                    withAnimation(.spring()) {
                        targetDummyOffset = CGFloat.random(in: -140...140)
                    }
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                isSlashing = false
            }
        case "Y", "L2":
            // Soul Focus / Burst
            isFocusingSoul = true
            soulCharge = min(1.0, soulCharge + 0.2)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                isFocusingSoul = false
            }
        case "DPAD", "STICK":
            let dx = controllerManager.moveVector.width
            if abs(dx) > 0.1 {
                facingRight = dx > 0
                avatarOffset.width = min(190, max(-190, avatarOffset.width + dx * 12))
            }
        default:
            break
        }
    }
    
    private func updatePhysicsTick() {
        if avatarOffset.height < 0 || avatarVelocityY < 0 {
            avatarOffset.height += avatarVelocityY
            avatarVelocityY += 0.55 // Gravity
            if avatarOffset.height >= 0 {
                avatarOffset.height = 0
                avatarVelocityY = 0
            }
        }
    }
    
    // MARK: - Boot Console View
    private var bootConsoleView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                Text("Brama Execution Runtime • \(game.title)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: {
                    withAnimation { showBootConsole = false }
                }) {
                    Text("Ocultar Consola")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.cyan)
                }
            }
            .padding(.bottom, 4)
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(0..<bootLogs.count, id: \.self) { index in
                            Text(bootLogs[index])
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(colorForLog(bootLogs[index]))
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: bootLogs.count) { count in
                    if count > 0 {
                        proxy.scrollTo(count - 1, anchor: .bottom)
                    }
                }
            }
            .frame(height: 120)
        }
        .padding(14)
        .background(Color.black.opacity(0.88))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .frame(maxWidth: 500)
        .padding(.horizontal, 24)
    }
    
    // MARK: - In-Game Pause Dialog
    private var inGamePauseDialog: some View {
        VStack(spacing: 20) {
            VStack(spacing: 4) {
                Text(game.title)
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                Text("Partida en Pausa")
                    .font(.system(size: 13))
                    .foregroundColor(.gray)
            }
            
            VStack(spacing: 12) {
                Button(action: {
                    withAnimation { showInGameMenu = false }
                }) {
                    HStack {
                        Image(systemName: "play.fill")
                        Text("Continuar Jugando")
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(red: 0.1, green: 0.62, blue: 1.0))
                    .cornerRadius(10)
                }
                
                Button(action: {
                    withAnimation {
                        showBootConsole.toggle()
                        showInGameMenu = false
                    }
                }) {
                    HStack {
                        Image(systemName: "terminal.fill")
                        Text(showBootConsole ? "Ocultar Consola de Wine" : "Ver Consola de Wine / Logs")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(10)
                }
                
                Button(action: {
                    withAnimation {
                        controllerManager.showVirtualTouchControls.toggle()
                    }
                }) {
                    HStack {
                        Image(systemName: controllerManager.showVirtualTouchControls ? "hand.tap.fill" : "hand.tap")
                        Text(controllerManager.showVirtualTouchControls ? "Ocultar Mando Táctil" : "Mostrar Mando Táctil")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.08))
                    .cornerRadius(10)
                }
                
                Button(action: {
                    dismiss()
                }) {
                    HStack {
                        Image(systemName: "xmark.circle.fill")
                        Text("Salir al Menú Principal")
                    }
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(0.12))
                    .cornerRadius(10)
                }
            }
        }
        .padding(24)
        .frame(width: 320)
        .background(Color(red: 0.1, green: 0.13, blue: 0.18).opacity(0.96))
        .cornerRadius(18)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
    
    // MARK: - In-Game HUD
    private var inGameHUD: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Text("FPS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray)
                Text(String(format: "%.1f", perfManager.currentFPS))
                    .font(.system(size: 12, weight: .heavy, design: .monospaced))
                    .foregroundColor(.green)
            }
            
            HStack(spacing: 4) {
                Text("GPU")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray)
                Text("\(perfManager.gpuUtilizationPercent)%")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
            }
            
            HStack(spacing: 4) {
                Text("RES")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.gray)
                Text(game.screenResolution.prefix(8))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.cyan)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.75))
        .cornerRadius(6)
    }
    
    // MARK: - Boot Execution Engine
    private func startBootSequence() {
        bootLogs.removeAll()
        
        DispatchQueue.global(qos: .userInitiated).async {
            let prefixURL = GameStorageManager.shared.winePrefixesDirectory
                .appendingPathComponent(self.game.winePrefixName)
                .path
            
            DispatchQueue.main.async {
                self.bootLogs.append("[BRAMA] Initializing Apple Silicon Metal GPU viewport...")
                self.bootLogs.append("[BRAMA] Target resolution: \(self.game.screenResolution) • Scaling: \(self.game.scalingMode)")
            }
            
            let jitAvailable = BramaCore.shared().isJITAvailable()
            
            DispatchQueue.main.async {
                self.perfManager.isJITEnabled = jitAvailable
                self.bootLogs.append("[JIT] Dynamic code generation: \(jitAvailable ? "GRANTED (Active JIT)" : "STANDARD (Interpreter)")")
            }
            
            _ = BramaCore.shared().launchExecutable(
                atPath: self.game.executablePath,
                prefixPath: prefixURL,
                arguments: self.game.launchArguments
            ) { log in
                DispatchQueue.main.async {
                    self.bootLogs.append(log)
                }
            }
            
            let peInfo = BramaCore.shared().lastLoadedExecutable
            let rtStatus = BramaCore.shared().runtimeStatus
            
            DispatchQueue.main.async {
                self.loadedPEInfo = peInfo
                self.runtimeStatus = rtStatus
                self.isBootSequenceFinished = true
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
                self.bootLogs.append("[BRAMA] Render loop attached. Interactive controls ready.")
                withAnimation(.easeInOut(duration: 0.35)) {
                    self.showBootConsole = false
                }
            }
        }
    }
    
    private func colorForLog(_ text: String) -> Color {
        if text.contains("[JIT]") { return .green }
        if text.contains("[GRAPHICS]") || text.contains("[DXMT]") { return .cyan }
        if text.contains("[WINE]") { return .yellow }
        if text.contains("[EXEC]") { return .orange }
        return .white.opacity(0.85)
    }
}
