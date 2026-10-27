//
//  MetalViewportView.swift
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

import SwiftUI
import MetalKit

struct MetalViewportView: UIViewRepresentable {
    var targetFPSLimit: Int = 60
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.delegate = context.coordinator
        mtkView.backgroundColor = .black
        mtkView.isOpaque = true
        mtkView.clearColor = MTLClearColor(red: 0.04, green: 0.06, blue: 0.09, alpha: 1.0)
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.preferredFramesPerSecond = targetFPSLimit
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.isUserInteractionEnabled = false
        return mtkView
    }
    
    func updateUIView(_ uiView: MTKView, context: Context) {
        if uiView.preferredFramesPerSecond != targetFPSLimit {
            uiView.preferredFramesPerSecond = targetFPSLimit
        }
    }
    
    class Coordinator: NSObject, MTKViewDelegate {
        var parent: MetalViewportView
        var commandQueue: MTLCommandQueue?
        
        init(_ parent: MetalViewportView) {
            self.parent = parent
            let device = MTLCreateSystemDefaultDevice()
            let queue = device?.makeCommandQueue()
            self.commandQueue = queue
            super.init()
            BramaCore.shared().attachMetalDevice(device, commandQueue: queue)
        }
        
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Handle viewport resize (e.g. iPad orientation change)
        }
        
        func draw(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                  let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let commandQueue = commandQueue,
                  let commandBuffer = commandQueue.makeCommandBuffer() else {
                return
            }
            
            // Invoke DXMT / Metal swapchain frame presentation hook in BramaCore (and libdxmt.dylib)
            BramaCore.shared().presentDXMTFrame(
                with: commandBuffer,
                renderPassDescriptor: renderPassDescriptor
            )
            
            guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
                return
            }
            
            renderEncoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
