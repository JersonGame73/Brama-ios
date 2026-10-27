//
//  MetalViewportView.swift
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

import SwiftUI
import MetalKit

struct MetalViewportView: UIViewRepresentable {
    @ObservedObject var perfManager = PerformanceManager.shared
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.clearColor = MTLClearColor(red: 0.05, green: 0.07, blue: 0.1, alpha: 1.0)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = perfManager.targetFPSLimit
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        uiView.preferredFramesPerSecond = perfManager.targetFPSLimit
    }
    
    class Coordinator: NSObject, MTKViewDelegate {
        var parent: MetalViewportView
        var commandQueue: MTLCommandQueue?
        private var frameCount: Int = 0
        
        init(_ parent: MetalViewportView) {
            self.parent = parent
            if let device = MTLCreateSystemDefaultDevice() {
                self.commandQueue = device.makeCommandQueue()
            }
            super.init()
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle viewport resize (e.g. iPad orientation change)
        }
        
        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let commandQueue = commandQueue else {
                return
            }
            
            frameCount += 1
            
            // Subtle dynamic background pulse to visually verify active Metal GPU rendering pipeline
            let time = Double(frameCount) * 0.02
            let redPulse = 0.04 + sin(time) * 0.01
            let bluePulse = 0.08 + cos(time) * 0.02
            
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: redPulse,
                green: 0.06,
                blue: bluePulse,
                alpha: 1.0
            )
            
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                return
            }
            
            renderEncoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
