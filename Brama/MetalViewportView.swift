//
//  MetalViewportView.swift
//  Brama
//
//  Created by Gerson Larrahondo on 27/10/26.
//

import SwiftUI
import UIKit
import Metal
import QuartzCore

/// Persistent CAMetalLayer-backed view owned by DXMT (DirectX 11/12) and Winios (GDI/Desktop).
/// Unlike MTKView, it never clears or overwrites drawables on a host timer, allowing the guest
/// Wine / DXMT swapchain thread to call `nextDrawable` and present directly to the screen.
final class BramaMetalSurfaceView: UIView {
    override class var layerClass: AnyClass {
        CAMetalLayer.self
    }

    var metalLayer: CAMetalLayer {
        // swiftlint:disable:next force_cast
        layer as! CAMetalLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureMetalSurface()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureMetalSurface()
    }

    private func configureMetalSurface() {
        backgroundColor = .black
        isOpaque = true
        isUserInteractionEnabled = true
        isMultipleTouchEnabled = false

        let device = MTLCreateSystemDefaultDevice()
        let queue = device?.makeCommandQueue()
        BramaCore.shared().attachMetalDevice(device, commandQueue: queue)

        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.presentsWithTransaction = false
        metalLayer.contentsGravity = .resizeAspect
        metalLayer.backgroundColor = UIColor.black.cgColor
        // Initial 720p drawable size; DXMT / Winios resizes it when the game creates its swapchain
        metalLayer.drawableSize = CGSize(width: 1280, height: 720)

        BramaCore.shared().registerDisplay(metalLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }
        BramaCore.shared().registerDisplay(metalLayer)
        BramaCore.shared().updateViewportFrame(bounds, desktopRect: bounds)
    }

    private func guestCoordinates(for touch: UITouch) -> (Int32, Int32) {
        let pt = touch.location(in: self)
        let viewW = max(1.0, bounds.width)
        let viewH = max(1.0, bounds.height)
        let guestSize = BramaCore.shared().guestScreenSize()
        let guestW = guestSize.width > 0 ? guestSize.width : 1280.0
        let guestH = guestSize.height > 0 ? guestSize.height : 720.0

        let rawX = Int32((pt.x / viewW) * guestW)
        let rawY = Int32((pt.y / viewH) * guestH)
        let clampedX = max(0, min(Int32(guestW) - 1, rawX))
        let clampedY = max(0, min(Int32(guestH) - 1, rawY))
        return (clampedX, clampedY)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let (gx, gy) = guestCoordinates(for: touch)
        BramaCore.shared().postTouchDownAt(x: gx, y: gy)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let (gx, gy) = guestCoordinates(for: touch)
        BramaCore.shared().postTouchMoveAt(x: gx, y: gy)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let (gx, gy) = guestCoordinates(for: touch)
        BramaCore.shared().postTouchUpAt(x: gx, y: gy)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let (gx, gy) = guestCoordinates(for: touch)
        BramaCore.shared().postTouchUpAt(x: gx, y: gy)
    }
}

struct MetalViewportView: UIViewRepresentable {
    var targetFPSLimit: Int = 60

    func makeUIView(context: Context) -> BramaMetalSurfaceView {
        let view = BramaMetalSurfaceView(frame: .zero)
        return view
    }

    func updateUIView(_ uiView: BramaMetalSurfaceView, context: Context) {
        BramaCore.shared().registerDisplay(uiView.metalLayer)
    }
}
