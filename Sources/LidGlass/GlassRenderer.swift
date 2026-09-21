import Foundation
import LidGlassCore
import Metal
import MetalKit
import CoreVideo
import QuartzCore

struct Uniforms {
    var theta: Float = 0
    var perspective: Float = 6
    var progress: Float = 0
    var strength: Float = 0.8

    var frostTop: Float = 1
    var frostBottom: Float = 0.2
    var grainScale: Float = 2
    var grainStrength: Float = 0.05

    var scatter: Float = 6
    var sheen: Float = 0.05
    var chroma: Float = 0
    var cornerRadius: Float = 48

    var edgeSoftness: Float = 2
    var paneAlpha: Float = 1
    var blurRadius: Float = 40
    var texWidth: Float = 1

    var texHeight: Float = 1
    var tintR: Float = 1
    var tintG: Float = 1
    var tintB: Float = 1

    var tintStrength: Float = 0.2
    var maxLod: Float = 6
    var isBackground: Float = 0
    var hingeAtTop: Float = 0
    var gloss: Float = 0
    var pad: Float = 0
}

/// Draws the captured display as a pane of glass tipping away on the lid's hinge.
final class GlassRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?

    /// Own mip chain: capture textures arrive with a single level, and the frost reads
    /// blurred levels instead of running a separate blur pass. Written on the capture
    /// queue and read on the main thread, so every access goes through the lock.
    private var mippedStorage: MTLTexture?
    private let mippedLock = NSLock()
    private var mipped: MTLTexture? {
        get { mippedLock.withLock { mippedStorage } }
        set { mippedLock.withLock { mippedStorage = newValue } }
    }

    /// Where the lid says the glass should be, written by the app controller.
    var foldTarget: Double = 0
    /// Where the glass actually is: the spring runs on drawn frames, not sensor samples.
    private(set) var fold: Double = 0
    private var foldVelocity: Double = 0
    private var lastStepTime = CACurrentMediaTime()
    var settings: Settings = .shared
    /// Replaces the chosen effect without touching saved settings.
    var effectOverride: GlassEffect?

    var hasFrame: Bool { mipped != nil }
    /// Called on the main thread the first time a frame reaches the renderer.
    var onFirstFrame: (() -> Void)?
    /// Called once on the main thread, after the next drawn frame is on screen.
    var onNextPresent: (() -> Void)?

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue() else { return nil }
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            NSLog("LidGlass: shader compilation failed: \(error)")
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "glassVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "glassFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        // Premultiplied alpha: the shader already folds alpha into the colour.
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        self.device = device
        self.commandQueue = queue
        self.pipeline = pipeline
        super.init()
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)
    }

    // MARK: - Frame intake

    /// Safe to call from the capture queue.
    func accept(pixelBuffer: CVPixelBuffer) {
        guard let textureCache else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        var wrapped: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &wrapped)
        guard status == kCVReturnSuccess, let wrapped, let source = CVMetalTextureGetTexture(wrapped) else { return }
        store(source: source)
    }

    /// Used by the settings preview, which works from a still image rather than a stream.
    func accept(texture: MTLTexture) {
        store(source: texture)
    }

    private func store(source: MTLTexture) {
        var current = mipped
        let wasEmpty = current == nil
        if current?.width != source.width || current?.height != source.height {
            current = makeMippedTexture(width: source.width, height: source.height)
        }
        guard let destination = current,
              let buffer = commandQueue.makeCommandBuffer(),
              let blit = buffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: source, sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: source.width, height: source.height, depth: 1),
                  to: destination, destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.generateMipmaps(for: destination)
        blit.endEncoding()
        buffer.commit()
        // Published after the copy is queued: later draws on the same queue see the pixels.
        mipped = destination
        if wasEmpty, let onFirstFrame {
            DispatchQueue.main.async(execute: onFirstFrame)
        }
    }

    private func makeMippedTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
        descriptor.usage = [.shaderRead, .renderTarget]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    func dropFrames() {
        mipped = nil
    }

    // MARK: - Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    /// Advances the fold to now. Called for every drawn frame, and by the controller
    /// while the overlay is hidden and nothing is drawing.
    func stepFold() {
        let now = CACurrentMediaTime()
        let deltaTime = min(now - lastStepTime, 0.1)
        lastStepTime = now
        (fold, foldVelocity) = FoldModel.step(fold: fold, velocity: foldVelocity, target: foldTarget,
                                              responsiveness: settings.responsiveness, deltaTime: deltaTime)
    }

    /// Puts the glass on the target at once, for a single offline frame.
    func settleFold() {
        fold = foldTarget
        foldVelocity = 0
    }

    /// True while the glass is still catching up with the lid.
    var isAnimating: Bool {
        abs(foldTarget - fold) > FoldModel.restingTolerance || abs(foldVelocity) > FoldModel.restingTolerance
    }

    func draw(in view: MTKView) {
        stepFold()
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer(),
              encode(pass: descriptor, into: buffer) else { return }
        if let onNextPresent {
            self.onNextPresent = nil
            drawable.addPresentedHandler { _ in DispatchQueue.main.async(execute: onNextPresent) }
        }
        buffer.present(drawable)
        buffer.commit()
    }

    /// Renders one frame into a caller-owned texture, for the offline `--render` command.
    func render(into target: MTLTexture) {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = target
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let buffer = commandQueue.makeCommandBuffer(), encode(pass: descriptor, into: buffer) else { return }
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    /// Background dim first, then the pane over it.
    private func encode(pass: MTLRenderPassDescriptor, into buffer: MTLCommandBuffer) -> Bool {
        guard let texture = mipped, let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return false }
        var uniforms = self.uniforms(textureWidth: texture.width, textureHeight: texture.height,
                                     mipLevels: texture.mipmapLevelCount)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        for isBackground: Float in [1, 0] {
            uniforms.isBackground = isBackground
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        return true
    }

    private func uniforms(textureWidth: Int, textureHeight: Int, mipLevels: Int) -> Uniforms {
        let material = effectOverride.flatMap { materials[$0] } ?? settings.material
        var u = Uniforms()
        u.theta = Float(fold * FoldModel.maxTilt)
        // A near camera exaggerates the fold, a far one flattens it.
        u.perspective = Float(2.2 + (1 - settings.perspective) * 12)
        u.progress = Float(fold)
        u.strength = Float(settings.strength)
        u.frostTop = material.frostTop
        u.frostBottom = material.frostBottom
        u.grainScale = material.grainScale
        u.grainStrength = material.grainStrength
        u.scatter = material.scatter
        u.sheen = material.sheen
        u.chroma = material.chroma
        u.cornerRadius = Float(settings.cornerRadius)
        u.edgeSoftness = Float(settings.edgeSoftness)
        u.paneAlpha = material.paneAlpha
        // Material radii are tuned for a 3024 pixel wide capture.
        u.blurRadius = material.blurRadius * Float(textureWidth) / 3024
        u.texWidth = Float(textureWidth)
        u.texHeight = Float(textureHeight)
        u.tintR = material.tint.r
        u.tintG = material.tint.g
        u.tintB = material.tint.b
        u.tintStrength = material.tintStrength
        u.maxLod = Float(mipLevels - 1)
        u.hingeAtTop = settings.hingeEdge == .top ? 1 : 0
        u.gloss = material.gloss
        return u
    }
}
