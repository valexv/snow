import Metal
import QuartzCore

/// Draws the guest's display into a Metal layer, scaled, with the CRT effect
/// (Shaders.metal) when it's on. It renders straight into the layer at its size in
/// pixels, so the effect comes out at the window's resolution.
@MainActor
final class ScreenRenderer {
    /// What the display is drawn into. Its owner sizes it.
    let layer = CAMetalLayer()

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let plainPipeline: MTLRenderPipelineState
    private let crtPipeline: MTLRenderPipelineState
    private let linearSampler: MTLSamplerState
    private let nearestSampler: MTLSamplerState

    /// Frames are written into these in turn, so one isn't written while the GPU
    /// still reads it for an earlier draw
    private var inputs: [MTLTexture] = []
    private var currentInput: MTLTexture?
    private var frameSize = (width: 0, height: 0)
    /// Keeps the CPU at most this many draws ahead of the GPU
    private let inFlight = DispatchSemaphore(value: ScreenRenderer.maxInFlight)
    /// One fewer than the layer's drawables (3), so drawing rarely waits for one
    private static let maxInFlight = 2

    private static let pixelFormat = MTLPixelFormat.bgra8Unorm

    /// Nil if Metal or the shaders aren't available
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(),
            let library = device.makeDefaultLibrary(),
            let vertex = library.makeFunction(name: "fullscreenVertex")
        else { return nil }

        func pipeline(_ name: String) -> MTLRenderPipelineState? {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = library.makeFunction(name: name)
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }
        func sampler(_ filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
            let descriptor = MTLSamplerDescriptor()
            descriptor.minFilter = filter
            descriptor.magFilter = filter
            descriptor.sAddressMode = .clampToEdge
            descriptor.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: descriptor)
        }
        guard let plain = pipeline("plainCopy"), let crt = pipeline("crtLottes"),
            let linear = sampler(.linear), let nearest = sampler(.nearest)
        else { return nil }

        self.device = device
        self.queue = queue
        self.plainPipeline = plain
        self.crtPipeline = crt
        self.linearSampler = linear
        self.nearestSampler = nearest

        layer.device = device
        layer.pixelFormat = Self.pixelFormat
        layer.framebufferOnly = true
        // The display's pixels are sRGB values, and pass through the effect as such
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = true
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    /// Takes a new frame of the display: RGBA, rows without padding. Returns false if
    /// it isn't one.
    @discardableResult
    func upload(width: Int, height: Int, pixels: Data) -> Bool {
        guard width > 0, height > 0, pixels.count >= width * height * 4,
            prepareTextures(width: width, height: height)
        else { return false }
        // The next texture in turn. Draws in flight read at most the last
        // maxInFlight frames, so the one after them in turn is free.
        let index = currentInput.flatMap { current in inputs.firstIndex { $0 === current } }
        let input = inputs[((index ?? -1) + 1) % inputs.count]
        pixels.withUnsafeBytes { bytes in
            input.replace(
                region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: bytes.baseAddress!, bytesPerRow: width * 4)
        }
        currentInput = input
        return true
    }

    /// Draws the newest frame into the layer, at a size in pixels. Never waits for
    /// the GPU, which would hold up the main thread, and with it resizing the window:
    /// returns false if it's still busy with earlier draws, to try again later.
    ///
    /// Frames are presented on their own, not with Core Animation transactions: with
    /// those, a drawable only comes back when the transaction commits, and the
    /// several layouts of a resize step would wait for one.
    ///
    /// - Parameter crtParameters: the CRT effect's settings, in the order the shader
    ///   takes them, or nil to draw without it
    func draw(_ algorithm: ScalingAlgorithm, crtParameters: [Float]?, size drawableSize: CGSize)
        -> Bool
    {
        guard let input = currentInput, drawableSize.width >= 1, drawableSize.height >= 1 else {
            // Nothing to draw yet, so nothing to try again
            return true
        }
        guard inFlight.wait(timeout: .now()) == .success else { return false }
        guard let commands = queue.makeCommandBuffer() else {
            inFlight.signal()
            return false
        }
        commands.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        // Its drawables are made again at a new size, so this changes at most once
        // per draw rather than at every step of a resize
        if layer.drawableSize != drawableSize {
            layer.drawableSize = drawableSize
        }
        // With fewer draws in flight than the layer has drawables, one is normally
        // free at once
        guard let drawable = layer.nextDrawable() else {
            commands.commit()
            return false
        }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .dontCare
        descriptor.colorAttachments[0].storeAction = .store
        if let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) {
            encoder.setFragmentTexture(input, index: 0)
            encoder.setFragmentSamplerState(
                algorithm == .nearestNeighbor ? nearestSampler : linearSampler, index: 0)
            if var parameters = crtParameters, !parameters.isEmpty {
                encoder.setRenderPipelineState(crtPipeline)
                var sizes = [
                    SIMD2<Float>(Float(input.width), Float(input.height)),
                    SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height)),
                ]
                encoder.setFragmentBytes(
                    &sizes, length: MemoryLayout<SIMD2<Float>>.stride * sizes.count, index: 0)
                encoder.setFragmentBytes(
                    &parameters, length: MemoryLayout<Float>.stride * parameters.count, index: 1)
            } else {
                encoder.setRenderPipelineState(plainPipeline)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        commands.present(drawable)
        commands.commit()
        return true
    }

    private func prepareTextures(width: Int, height: Int) -> Bool {
        if frameSize == (width, height), !inputs.isEmpty {
            return true
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = .shaderRead
        let count = Self.maxInFlight + 1
        let inputs = (0..<count).compactMap { _ in device.makeTexture(descriptor: descriptor) }
        currentInput = nil
        guard inputs.count == count else {
            self.inputs = []
            frameSize = (0, 0)
            return false
        }
        self.inputs = inputs
        frameSize = (width, height)
        return true
    }
}
