import Foundation
import Metal
import MetalKit
import ImageIO
import UniformTypeIdentifiers

/// `LidGlass --render <input image> <output.png> <fold 0...1> [effect]`
///
/// Draws the glass over a still image without a screen, a stream, or any permission, so
/// material changes can be checked by eye, and on machines without the sensor.
func runRenderCommand(_ arguments: [String]) -> Int32 {
    guard arguments.count >= 3, let fold = Double(arguments[2]) else {
        FileHandle.standardError.write("usage: LidGlass --render <input> <output.png> <fold 0...1> [effect]\n".data(using: .utf8)!)
        return 2
    }
    var effect: GlassEffect?
    if arguments.count >= 4 {
        effect = GlassEffect(rawValue: arguments[3].capitalized)
        guard effect != nil else {
            FileHandle.standardError.write("unknown effect \(arguments[3])\n".data(using: .utf8)!)
            return 2
        }
    }

    guard let device = MTLCreateSystemDefaultDevice(), let renderer = GlassRenderer(device: device) else { return 1 }
    renderer.effectOverride = effect
    let loader = MTKTextureLoader(device: device)
    guard let source = try? loader.newTexture(URL: URL(fileURLWithPath: arguments[0]), options: [.SRGB: false]) else {
        FileHandle.standardError.write("could not load \(arguments[0])\n".data(using: .utf8)!)
        return 1
    }
    renderer.accept(texture: source)
    renderer.fold = min(max(fold, 0), 1)

    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .bgra8Unorm, width: source.width, height: source.height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let target = device.makeTexture(descriptor: descriptor) else { return 1 }
    renderer.render(into: target)

    let bytesPerRow = target.width * 4
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * target.height)
    target.getBytes(&pixels, bytesPerRow: bytesPerRow,
                    from: MTLRegionMake2D(0, 0, target.width, target.height), mipmapLevel: 0)

    // Premultiplied BGRA straight out of the render target.
    let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
    guard let context = CGContext(data: &pixels, width: target.width, height: target.height, bitsPerComponent: 8,
                                  bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: bitmapInfo),
          let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL,
                                                            UTType.png.identifier as CFString, 1, nil) else { return 1 }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? 0 : 1
}
