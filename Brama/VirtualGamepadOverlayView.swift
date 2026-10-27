//
//  VirtualGamepadOverlayView.swift
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

import SwiftUI

struct VirtualGamepadOverlayView: View {
    @ObservedObject var controllerManager = ControllerManager.shared
    var onMenuPressed: (() -> Void)? = nil
    
    var body: some View {
        ZStack {
            // Top Bumpers (L1, L2 at Top-Left, R1, R2 at Top-Right)
            VStack {
                HStack {
                    HStack(spacing: 8) {
                        BumperButton(label: "L2")
                        BumperButton(label: "L1")
                    }
                    .padding(.leading, 24)
                    
                    Spacer()
                    
                    HStack(spacing: 8) {
                        BumperButton(label: "R1")
                        BumperButton(label: "R2")
                    }
                    .padding(.trailing, 24)
                }
                .padding(.top, 10)
                
                Spacer()
            }
            
            // Bottom Handheld Utility Buttons (Steam / Brama button & Quick Access)
            VStack {
                Spacer()
                HStack {
                    // STEAM / BRAMA PAUSE BUTTON (Direct on-screen button!)
                    Button(action: {
                        onMenuPressed?()
                    }) {
                        HStack(spacing: 6) {
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 13, weight: .bold))
                            Text("BRAMA")
                                .font(.system(size: 12, weight: .black, design: .rounded))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color(red: 0.1, green: 0.62, blue: 1.0).opacity(0.85))
                        .cornerRadius(18)
                        .overlay(
                            RoundedRectangle(cornerRadius: 18)
                                .stroke(Color.white.opacity(0.4), lineWidth: 1.5)
                        )
                        .shadow(color: Color(red: 0.1, green: 0.62, blue: 1.0).opacity(0.5), radius: 6, x: 0, y: 2)
                    }
                    .padding(.leading, 32)
                    .padding(.bottom, 12)
                    
                    Spacer()
                    
                    // QUICK ACCESS BUTTON ("...")
                    Button(action: {
                        onMenuPressed?()
                    }) {
                        Text("...")
                            .font(.system(size: 14, weight: .black))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.2))
                            .clipShape(Circle())
                            .overlay(
                                Circle()
                                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
                            )
                    }
                    .padding(.trailing, 32)
                    .padding(.bottom, 12)
                }
            }
            
            // Left Side: D-Pad
            VStack {
                Spacer()
                HStack {
                    VStack(spacing: 4) {
                        DPadButton(direction: "chevron.up")
                        HStack(spacing: 24) {
                            DPadButton(direction: "chevron.left")
                            DPadButton(direction: "chevron.right")
                        }
                        DPadButton(direction: "chevron.down")
                    }
                    .padding(.leading, 32)
                    .padding(.bottom, 60)
                    
                    Spacer()
                    
                    // Right Side: Action Buttons (A, B, X, Y)
                    VStack(spacing: 6) {
                        ActionButton(label: "Y", color: .yellow)
                        HStack(spacing: 28) {
                            ActionButton(label: "X", color: .blue)
                            ActionButton(label: "B", color: .red)
                        }
                        ActionButton(label: "A", color: .green)
                    }
                    .padding(.trailing, 32)
                    .padding(.bottom, 60)
                }
            }
        }
        .allowsHitTesting(true)
    }
}

fileprivate struct BumperButton: View {
    let label: String
    
    var body: some View {
        Button(action: {}) {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 50, height: 28)
                .background(Color.white.opacity(0.18))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
        }
    }
}

fileprivate struct DPadButton: View {
    let direction: String
    
    var body: some View {
        Button(action: {}) {
            Image(systemName: direction)
                .font(.system(size: 14, weight: .bold))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 40, height: 40)
                .background(Color.white.opacity(0.2))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.3), lineWidth: 1)
                )
        }
    }
}

fileprivate struct ActionButton: View {
    let label: String
    let color: Color
    
    var body: some View {
        Button(action: {}) {
            Text(label)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .foregroundColor(color)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.2))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(color.opacity(0.8), lineWidth: 1.5)
                )
        }
    }
}
