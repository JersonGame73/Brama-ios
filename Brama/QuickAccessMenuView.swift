//
//  QuickAccessMenuView.swift
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

import SwiftUI

struct QuickAccessMenuView: View {
    @ObservedObject var perfManager = PerformanceManager.shared
    @ObservedObject var controllerManager = ControllerManager.shared
    @Binding var isPresented: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Label("Rendimiento Brama", systemImage: "gauge.with.needle.fill")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Spacer()
                
                Button(action: {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isPresented = false
                    }
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundColor(.gray)
                }
            }
            .padding(.bottom, 6)
            
            Divider()
                .background(Color.white.opacity(0.15))
            
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    
                    // JIT Status Section
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("ESTADO DE JIT (COMPILACIÓN)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.gray)
                            Spacer()
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(perfManager.isJITEnabled ? Color.green : Color.red)
                                    .frame(width: 8, height: 8)
                                Text(perfManager.isJITEnabled ? "ACTIVO" : "REQUERIDO")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundColor(perfManager.isJITEnabled ? .green : .red)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.4))
                            .cornerRadius(12)
                        }
                        
                        Text(perfManager.isJITEnabled ? "JIT habilitado vía depuración / sideloading para máxima velocidad." : "Activa JIT vía AltStore o SideStore para ejecutar a 60 FPS.")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.7))
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(10)
                    
                    // Overlay Level
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NIVEL DE OVERLAY (HUD)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.gray)
                        
                        Picker("Overlay", selection: $perfManager.overlayLevel) {
                            ForEach(OverlayLevel.allCases) { level in
                                Text(level.title).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    
                    // FPS Limiter
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("LÍMITE DE CUADROS (FPS)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.gray)
                            Spacer()
                            Text("\(perfManager.targetFPSLimit) FPS")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(Color(red: 0.1, green: 0.62, blue: 1.0))
                        }
                        
                        HStack(spacing: 8) {
                            ForEach([30, 40, 60, 120], id: \.self) { fps in
                                Button(action: {
                                    perfManager.targetFPSLimit = fps
                                }) {
                                    Text("\(fps)")
                                        .font(.system(size: 13, weight: .semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 7)
                                        .background(perfManager.targetFPSLimit == fps ? Color(red: 0.1, green: 0.62, blue: 1.0) : Color.white.opacity(0.08))
                                        .foregroundColor(perfManager.targetFPSLimit == fps ? .white : .gray)
                                        .cornerRadius(8)
                                }
                            }
                        }
                    }
                    
                    // Virtual Touch Controls Toggle
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: $controllerManager.showVirtualTouchControls) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Mando Táctil en Pantalla")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.white)
                                Text("Muestra sticks y botones táctiles")
                                    .font(.system(size: 11))
                                    .foregroundColor(.gray)
                            }
                        }
                        .tint(Color(red: 0.1, green: 0.62, blue: 1.0))
                    }
                    
                    // Real-time Metrics Info Card
                    VStack(alignment: .leading, spacing: 8) {
                        Text("ESTADÍSTICAS DEL SISTEMA")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.gray)
                        
                        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                            GridRow {
                                Text("GPU")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                                Text("\(perfManager.gpuUtilizationPercent)% Metal")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            GridRow {
                                Text("RAM")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                                Text("\(perfManager.memoryUsedMB) MB")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundColor(.white)
                            }
                            GridRow {
                                Text("Temperatura")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                                HStack(spacing: 4) {
                                    Circle()
                                        .fill(perfManager.thermalColor)
                                        .frame(width: 6, height: 6)
                                    Text(perfManager.thermalStateText)
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundColor(perfManager.thermalColor)
                                }
                            }
                            GridRow {
                                Text("Mando Físico")
                                    .font(.system(size: 12))
                                    .foregroundColor(.gray)
                                Text(controllerManager.controllerName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(controllerManager.isPhysicalControllerConnected ? .green : .white.opacity(0.7))
                            }
                        }
                    }
                    .padding(12)
                    .background(Color.white.opacity(0.04))
                    .cornerRadius(10)
                }
            }
        }
        .padding(16)
        .frame(width: 320)
        .background(
            Color(red: 0.08, green: 0.11, blue: 0.15)
                .opacity(0.97)
        )
        .overlay(
            Rectangle()
                .frame(width: 1)
                .foregroundColor(Color.white.opacity(0.1)),
            alignment: .leading
        )
    }
}
