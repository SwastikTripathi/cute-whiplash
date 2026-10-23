import CoreGraphics
import Metal
import SpriteKit

/// Renders an SKScene without any window, via SKRenderer + Metal, so animations can be inspected as PNGs.
///
/// Scenes rendered here have no SKView: `didMove(to:)` is never called and `view` is nil.
/// Set scenes up in `init`/`sceneDidLoad()`, and drive time only from `update(_:)`.
final class OffscreenRenderer {
    let pixelWidth: Int
    let pixelHeight: Int
    let scene: SKScene

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let renderer: SKRenderer
    private let texture: MTLTexture

    /// `pointSize` is the scene size in points; `scale` is pixels per point of the output image.
    init?(scene: SKScene, pointSize: CGSize, scale: CGFloat = 1) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        let width = max(1, Int((pointSize.width * scale).rounded()))
        let height = max(1, Int((pointSize.height * scale).rounded()))
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = device.hasUnifiedMemory ? .shared : .managed
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }

        self.device = device
        self.queue = queue
        self.texture = texture
        self.pixelWidth = width
        self.pixelHeight = height
        self.scene = scene

        scene.size = pointSize
        scene.scaleMode = .fill
        renderer = SKRenderer(device: device)
        renderer.scene = scene
        renderer.ignoresSiblingOrder = false
    }

    /// Runs actions, physics and `scene.update(_:)` up to `time` (seconds, monotonically increasing).
    func update(atTime time: TimeInterval) {
        // SKRenderer treats a first time of 0 as "now" on the media clock and then ignores every later,
        // smaller time, freezing the scene after two updates. Any non-zero base avoids that.
        renderer.update(atTime: time + Self.timeBase)
    }

    private static let timeBase: TimeInterval = 1

    /// Draws the current state and reads it back. Transparent where the scene draws nothing.
    func snapshot() -> CGImage? {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        (scene.backgroundColor.usingColorSpace(.sRGB) ?? .clear).getRed(&r, green: &g, blue: &b, alpha: &a)
        pass.colorAttachments[0].clearColor = MTLClearColorMake(Double(r * a), Double(g * a), Double(b * a), Double(a))
        pass.colorAttachments[0].storeAction = .store

        guard let commands = queue.makeCommandBuffer() else { return nil }
        renderer.render(withViewport: CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight),
                        commandBuffer: commands,
                        renderPassDescriptor: pass)
        if texture.storageMode == .managed, let blit = commands.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        commands.commit()
        commands.waitUntilCompleted()

        let bytesPerRow = pixelWidth * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * pixelHeight)
        texture.getBytes(&bytes, bytesPerRow: bytesPerRow,
                         from: MTLRegionMake2D(0, 0, pixelWidth, pixelHeight), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
