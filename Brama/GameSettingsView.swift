//
//  GameSettingsView.swift
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case compatibility = "Compatibilidad"
    case performance = "Rendimiento"
    case storage = "Archivos"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .compatibility: return "gearshape.2.fill"
        case .performance: return "gauge.with.needle.fill"
        case .storage: return "folder.fill"
        }
    }
}

struct GameSettingsView: View {
    @Binding var game: GameTitle
    @ObservedObject var storageManager = GameStorageManager.shared
    @Environment(\.dismiss) private var dismiss
    
    @State private var activeTab: SettingsTab = .general
    @State private var showDeleteAlert: Bool = false
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.08, green: 0.11, blue: 0.16)
                    .ignoresSafeArea()
                
                HStack(spacing: 0) {
                    // Left Sidebar Tabs (SteamOS Style)
                    VStack(alignment: .leading, spacing: 6) {
                        // Game Preview Pill
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(LinearGradient(colors: game.bannerGradient, startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 32, height: 42)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(game.title)
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Text("Propiedades")
                                    .font(.system(size: 11))
                                    .foregroundColor(.gray)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .padding(.bottom, 12)
                        
                        ForEach(SettingsTab.allCases) { tab in
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.18)) {
                                    activeTab = tab
                                }
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: tab.iconName)
                                        .font(.system(size: 14))
                                        .frame(width: 20)
                                    Text(tab.rawValue)
                                        .font(.system(size: 14, weight: activeTab == tab ? .bold : .medium))
                                    Spacer()
                                }
                                .foregroundColor(activeTab == tab ? .white : .gray)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(activeTab == tab ? Color(red: 0.1, green: 0.62, blue: 1.0) : Color.clear)
                                .cornerRadius(8)
                            }
                        }
                        
                        Spacer()
                    }
                    .frame(width: 200)
                    .padding(16)
                    .background(Color.black.opacity(0.3))
                    
                    Divider()
                        .background(Color.white.opacity(0.1))
                    
                    // Right Content Area
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            switch activeTab {
                            case .general:
                                generalTabContent
                            case .compatibility:
                                compatibilityTabContent
                            case .performance:
                                performanceTabContent
                            case .storage:
                                storageTabContent
                            }
                        }
                        .padding(24)
                    }
                }
            }
            .navigationTitle("Ajustes del Juego")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cerrar") {
                        storageManager.updateGame(game)
                        dismiss()
                    }
                    .foregroundColor(Color(red: 0.1, green: 0.62, blue: 1.0))
                }
            }
        }
    }
    
    // MARK: - Tab Contents
    private var generalTabContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(title: "INFORMACIÓN PRINCIPAL")
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Título del Juego")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
                TextField("Título", text: $game.title)
                    .textFieldStyle(SteamOSTextFieldStyle())
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Ruta del Ejecutable Windows (.exe)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
                TextField("C:\\Games\\game.exe", text: $game.executablePath)
                    .textFieldStyle(SteamOSTextFieldStyle())
            }
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Parámetros de Inicio")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
                TextField("ej. -dx11 -windowed -novid", text: $game.launchArguments)
                    .textFieldStyle(SteamOSTextFieldStyle())
            }
        }
    }
    
    private var compatibilityTabContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(title: "CAPAS DE COMPATIBILIDAD (PROTON / WINE)")
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Motor de Traducción CPU (x86_64 -> ARM64)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
                Picker("Motor CPU", selection: $game.translationEngine) {
                    ForEach(TranslationEngine.allCases) { engine in
                        Text(engine.rawValue).tag(engine)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Capa de Traducción Gráfica (DirectX / Vulkan a Metal)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
                Picker("Backend Gráfico", selection: $game.graphicsBackend) {
                    ForEach(GraphicsBackend.allCases) { backend in
                        Text(backend.rawValue).tag(backend)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Nivel de Compatibilidad Verificado")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
                Picker("Compatibilidad", selection: $game.compatibility) {
                    ForEach(CompatibilityTier.allCases) { tier in
                        Text(tier.rawValue).tag(tier)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color(red: 0.1, green: 0.62, blue: 1.0))
            }
        }
    }
    
    private var performanceTabContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(title: "RESOLUCIÓN Y ESCALADO GRÁFICO")
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Resolución de Renderizado Interno")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
                
                let resolutions = ["1280x800 (Steam Deck)", "1920x1080 (Full HD)", "1280x720 (720p)", "Nativa del iPad"]
                Picker("Resolución", selection: $game.screenResolution) {
                    ForEach(resolutions, id: \.self) { res in
                        Text(res).tag(res)
                    }
                }
                .pickerStyle(.menu)
                .tint(Color(red: 0.1, green: 0.62, blue: 1.0))
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Filtro de Escalado a Pantalla Completa")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
                
                let scalers = ["FSR (Metal Super Resolution)", "Lineal", "Entero (Pixel Art)"]
                Picker("Escalado", selection: $game.scalingMode) {
                    ForEach(scalers, id: \.self) { mode in
                        Text(mode).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Límite de Cuadros para este juego")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.gray)
                    Spacer()
                    Text("\(game.targetFPS) FPS")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(Color(red: 0.1, green: 0.62, blue: 1.0))
                }
                
                HStack(spacing: 8) {
                    ForEach([30, 40, 60, 120], id: \.self) { fps in
                        Button(action: { game.targetFPS = fps }) {
                            Text("\(fps)")
                                .font(.system(size: 12, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(game.targetFPS == fps ? Color(red: 0.1, green: 0.62, blue: 1.0) : Color.white.opacity(0.08))
                                .foregroundColor(game.targetFPS == fps ? .white : .gray)
                                .cornerRadius(8)
                        }
                    }
                }
            }
        }
    }
    
    private var storageTabContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            sectionHeader(title: "PREFIJO DE WINE Y ARCHIVOS LOCALES")
            
            VStack(alignment: .leading, spacing: 6) {
                Text("Contenedor / Prefijo Asignado")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.gray)
                Text("~/Documents/WinePrefixes/\(game.winePrefixName)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)
            }
            
            Button(action: {
                showDeleteAlert = true
            }) {
                HStack {
                    Image(systemName: "trash.fill")
                    Text("Eliminar Juego de Brama")
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.red)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.red.opacity(0.12))
                .cornerRadius(8)
            }
            .alert("¿Eliminar \(game.title)?", isPresented: $showDeleteAlert) {
                Button("Eliminar", role: .destructive) {
                    storageManager.deleteGame(game)
                    dismiss()
                }
                Button("Cancelar", role: .cancel) {}
            } message: {
                Text("Esta acción eliminará el acceso directo y la configuración de este juego en tu biblioteca.")
            }
        }
    }
    
    private func sectionHeader(title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundColor(.gray)
    }
}

fileprivate struct SteamOSTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(.system(size: 13, design: .monospaced))
            .foregroundColor(.white)
            .padding(10)
            .background(Color.white.opacity(0.06))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
    }
}
