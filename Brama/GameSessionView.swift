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
    
    private let renderTimer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            // Absolute Solid Black Background (Prevents any white flash in Light Mode)
            Color.black
                .ignoresSafeArea()
            
            // Fullscreen Metal Canvas (GPU Rendering via Apple MetalKit)
            MetalViewportView()
                .ignoresSafeArea()
            
            // Virtual Game Display Screen (Active when boot finishes)
            if isBootSequenceFinished {
                virtualGameScreenView
                    .transition(.opacity)
            }
            
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
        .onReceive(renderTimer) { _ in
            frameCounter += 1
        }
    }
    
    // MARK: - Virtual Game Screen Display
    private var virtualGameScreenView: some View {
        ZStack {
            // Game Artwork Canvas
            RoundedRectangle(cornerRadius: 12)
                .fill(
                    LinearGradient(
                        colors: game.bannerGradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .aspectRatio(16/10, contentMode: .fit)
                .overlay(
                    // Scanline / CRT effect
                    VStack(spacing: 4) {
                        ForEach(0..<40, id: \.self) { _ in
                            Divider()
                                .background(Color.black.opacity(0.12))
                        }
                    }
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .padding(24)
            
            // In-Game Center Title & Render Status + PE32+ Telemetry Badge
            VStack(spacing: 10) {
                Text(game.title)
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.8), radius: 8, x: 0, y: 4)
                
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                    Text("VENTANA ACTIVA • \(game.screenResolution)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.9))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.black.opacity(0.65))
                .cornerRadius(12)
                
                if let pe = loadedPEInfo {
                    VStack(spacing: 4) {
                        Text(String(format: "PE32+ MAPPED @ 0x%llX • ENTRY RVA 0x%04X • %@",
                                    pe.mappedBaseAddress, pe.entryPointRVA, pe.architectureName))
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundColor(.cyan)
                        
                        if !pe.importedDLLs.isEmpty {
                            Text("DLLs: \(pe.importedDLLs.joined(separator: " • "))")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundColor(.white.opacity(0.75))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.black.opacity(0.72))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.cyan.opacity(0.35), lineWidth: 1)
                    )
                }
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
                    Text(isBootSequenceFinished ? "Cerrar Consola" : "Minimizar")
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
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
            .frame(height: 140)
        }
        .padding(14)
        .background(Color.black.opacity(0.88))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.25), lineWidth: 1)
        )
        .frame(maxWidth: 520)
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
                self.bootLogs.append("[JIT] Dynamic code generation: \(jitAvailable ? "GRANTED (Active JIT)" : "RESTRICTED (Interpreter)")")
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
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                self.bootLogs.append("[BRAMA] Render loop successfully attached. Handheld controls ready.")
                self.isBootSequenceFinished = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    withAnimation {
                        self.showBootConsole = false
                    }
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
