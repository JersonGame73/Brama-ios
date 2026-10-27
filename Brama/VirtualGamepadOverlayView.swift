//
//  VirtualGamepadOverlayView.swift
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

import SwiftUI

struct VirtualGamepadOverlayView: View {
    @ObservedObject var controllerManager = ControllerManager.shared
    
    var body: some View {
        ZStack {
            // Top Bumpers (L1, L2, R1, R2)
            VStack {
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        BumperButton(label: "L2")
                        BumperButton(label: "L1")
                    }
                    
                    Spacer()
                    
                    HStack(spacing: 8) {
                        BumperButton(label: "R1")
                        BumperButton(label: "R2")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)
                
                Spacer()
            }
            
            // Left Side: D-Pad & Left Stick
            VStack {
                Spacer()
                HStack {
                    VStack(spacing: 16) {
                        // Virtual D-Pad
                        VStack(spacing: 4) {
                            DPadButton(direction: "chevron.up")
                            HStack(spacing: 24) {
                                DPadButton(direction: "chevron.left")
                                DPadButton(direction: "chevron.right")
                            }
                            DPadButton(direction: "chevron.down")
                        }
                    }
                    .padding(.leading, 32)
                    .padding(.bottom, 32)
                    
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
                    .padding(.bottom, 32)
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
                .background(Color.white.opacity(0.12))
                .cornerRadius(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
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
                .frame(width: 38, height: 38)
                .background(Color.white.opacity(0.14))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.25), lineWidth: 1)
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
                .background(Color.white.opacity(0.14))
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .stroke(color.opacity(0.6), lineWidth: 1.5)
                )
        }
    }
}
