import CoreGraphics
import CoreImage
import Foundation

/// A rectangle the reporter drew on the screenshot before sending: covered with a solid box, or
/// blurred. In the picture's points, from its top-left corner.
public struct ScreenshotEdit: Sendable, Equatable {
  public enum Kind: Sendable, Equatable { case cover, blur }

  public var rect: CGRect
  public var kind: Kind

  public init(rect: CGRect, kind: Kind) {
    self.rect = rect.standardized
    self.kind = kind
  }
}

/// Paints the reporter's covers and blurs into the screenshot, then paints the private-view masks
/// again on top, so no edit can ever uncover what the app marked private. The result replaces the
/// original: the pixels under a cover or a blur are not kept anywhere.
public enum ScreenshotRedaction {
  public static let defaultCoverGray: CGFloat = 0.18

  /// `image` is `pointSize` points (any pixel scale). Edits apply in order, later ones on top.
  public static func apply(
    _ edits: [ScreenshotEdit],
    to image: CGImage,
    pointSize: CGSize,
    masks: [CGRect] = [],
    maskGray: CGFloat = defaultCoverGray,
    coverColor: CGColor? = nil
  ) -> CGImage {
    guard !edits.isEmpty || !masks.isEmpty, pointSize.width > 0, pointSize.height > 0 else { return image }
    let width = image.width, height = image.height
    let scale = CGFloat(width) / pointSize.width
    guard let ctx = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return image }
    let full = CGRect(x: 0, y: 0, width: width, height: height)
    ctx.draw(image, in: full)

    let blurred = edits.contains { $0.kind == .blur } ? obscured(image, scale: scale) : nil
    let cover = coverColor ?? CGColor(srgbRed: defaultCoverGray, green: defaultCoverGray, blue: defaultCoverGray, alpha: 1)
    for edit in edits {
      let box = pixelRect(edit.rect, scale: scale, height: height)
      guard box.width > 0, box.height > 0 else { continue }
      switch edit.kind {
      case .cover:
        ctx.setFillColor(cover)
        ctx.fill(box)
      case .blur:
        guard let blurred else { continue }
        ctx.saveGState()
        ctx.clip(to: box)
        ctx.draw(blurred, in: full)
        ctx.restoreGState()
      }
    }
    ctx.setFillColor(CGColor(srgbRed: maskGray, green: maskGray, blue: maskGray, alpha: 1))
    for mask in masks {
      ctx.fill(pixelRect(mask, scale: scale, height: height))
    }
    return ctx.makeImage() ?? image
  }

  /// The whole picture made unreadable: pixellated into blocks of about 12 points, then blurred, so
  /// text under a blur cannot be read back the way a light Gaussian blur sometimes can.
  static func obscured(_ image: CGImage, scale: CGFloat) -> CGImage? {
    let input = CIImage(cgImage: image)
    let extent = input.extent
    let block = max(4, 12 * scale)
    let pixellated = input.clampedToExtent().applyingFilter("CIPixellate", parameters: [
      kCIInputScaleKey: block,
      kCIInputCenterKey: CIVector(x: 0, y: 0),
    ])
    let soft = pixellated.clampedToExtent().applyingGaussianBlur(sigma: Double(block) / 2).cropped(to: extent)
    let context = CIContext(options: [.cacheIntermediates: false])
    return context.createCGImage(soft, from: extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
  }

  /// A top-left rectangle in points as a bottom-left rectangle in pixels.
  static func pixelRect(_ rect: CGRect, scale: CGFloat, height: Int) -> CGRect {
    let r = rect.standardized
    return CGRect(x: r.minX * scale, y: CGFloat(height) - r.maxY * scale, width: r.width * scale, height: r.height * scale)
  }
}
