#if os(macOS)
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A frozen picture of the app's window content, taken before the sheet opens, with the private
/// parts already painted over.
///
/// HOW: the content view draws itself into a bitmap (`bitmapImageRepForCachingDisplay(in:)` and
/// `cacheDisplay(in:to:)`), which is the app drawing its own views. It needs no Screen Recording
/// permission and it can only ever see this app's own window: never the desktop, never another app,
/// never the title bar (which belongs to the window frame, not to the content).
///
/// WHAT IT CANNOT SEE: content that is not drawn through the view hierarchy. A Metal or OpenGL
/// layer, video, a web view's compositor layers, and the translucency of `NSVisualEffectView`
/// (sidebars, toolbars in a full-size content view) come out blank or flat. The window's background
/// colour is laid under everything, so a gap reads as background rather than as a hole.
@MainActor
struct ScreenCapture {
  /// The masked image, at most 2400 pixels on its long side.
  let image: CGImage
  /// The content view it was taken of, in points.
  let windowSize: CGSize
  /// The content-space rectangles (points from the top-left) that were blanked out. The element
  /// picker keeps labels inside them out of the report.
  let privateRects: [CGRect]

  static let maxPixels: CGFloat = 2400
  static let maskGray: CGFloat = 0.18

  static func take(of window: NSWindow) -> ScreenCapture? {
    guard let content = window.contentView else { return nil }
    let bounds = content.bounds
    guard bounds.width >= 1, bounds.height >= 1 else { return nil }
    let masks = PrivacyMask.rects(in: window)
    guard let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
    content.cacheDisplay(in: bounds, to: rep)
    guard let drawn = rep.cgImage else { return nil }

    let backing = window.backingScaleFactor > 0 ? window.backingScaleFactor : 2
    let scale = min(backing, maxPixels / max(bounds.width, bounds.height))
    let width = max(1, Int((bounds.width * scale).rounded()))
    let height = max(1, Int((bounds.height * scale).rounded()))
    guard let ctx = Bitmap.context(width: width, height: height) else { return nil }
    let full = CGRect(x: 0, y: 0, width: width, height: height)

    // The window's background, resolved for its own appearance (light or dark), under the content.
    var background = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
      background = (window.backgroundColor ?? NSColor.windowBackgroundColor).usingColorSpace(.sRGB)?.cgColor ?? background
    }
    ctx.setFillColor(background)
    ctx.fill(full)
    ctx.interpolationQuality = .high
    ctx.draw(drawn, in: full)

    ctx.setFillColor(CGColor(srgbRed: maskGray, green: maskGray, blue: maskGray, alpha: 1))
    for rect in masks {
      ctx.fill(Bitmap.pixelRect(rect, scale: scale, height: height))
    }
    guard let image = ctx.makeImage() else { return nil }
    return ScreenCapture(image: image, windowSize: bounds.size, privateRects: masks)
  }
}

/// CoreGraphics bitmaps in sRGB, and the flip from top-left points to bottom-left pixels.
enum Bitmap {
  static func context(width: Int, height: Int) -> CGContext? {
    CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
  }

  /// `rect` (points from the top-left) as pixels in a bitmap of `height` pixels, whose origin is at
  /// the bottom-left.
  static func pixelRect(_ rect: CGRect, scale: CGFloat, height: Int) -> CGRect {
    CGRect(x: rect.minX * scale, y: CGFloat(height) - rect.maxY * scale, width: rect.width * scale, height: rect.height * scale)
  }
}

@MainActor
enum ScreenshotRenderer {
  static let highlightColor = NSColor.systemRed

  /// `image` (a picture of `size` points) with a box drawn round `rect` (points from the top-left).
  /// The picture the team sees is the one the reporter saw, so the box is in the image itself.
  static func highlighted(_ image: CGImage, rect: CGRect, size: CGSize, color: NSColor = highlightColor) -> CGImage {
    let scale = CGFloat(image.width) / max(size.width, 1)
    guard let ctx = Bitmap.context(width: image.width, height: image.height) else { return image }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let box = Bitmap.pixelRect(rect.insetBy(dx: -2, dy: -2), scale: scale, height: image.height)
    let red = color.usingColorSpace(.sRGB)?.cgColor ?? CGColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)
    ctx.setFillColor(red.copy(alpha: 0.15) ?? red)
    ctx.fill(box)
    ctx.setStrokeColor(red)
    ctx.setLineWidth(3 * scale)
    let radius = min(4 * scale, box.width / 2, box.height / 2)
    ctx.addPath(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.strokePath()
    return ctx.makeImage() ?? image
  }

  /// The rectangle an element covers in a picture of `size` points.
  static func rect(for element: FeedbackElement, in size: CGSize) -> CGRect {
    CGRect(
      x: element.rect.x * size.width,
      y: element.rect.y * size.height,
      width: element.rect.w * size.width,
      height: element.rect.h * size.height
    )
  }

  /// JPEG at 0.8, stepped down in quality and then in size until it is within 5 MB.
  static func jpeg(_ image: CGImage) -> Data? {
    var current = image
    for _ in 0..<4 {
      for quality in [0.8, 0.6, 0.45] as [CGFloat] {
        if let data = encode(current, quality: quality), data.count <= FeedbackLimits.screenshotBytes {
          return data
        }
      }
      guard let smaller = scaled(current, by: 0.75) else { return nil }
      current = smaller
    }
    return nil
  }

  static func encode(_ image: CGImage, quality: CGFloat) -> Data? {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { return nil }
    return data as Data
  }

  static func scaled(_ image: CGImage, by factor: CGFloat) -> CGImage? {
    let w = max(1, Int(CGFloat(image.width) * factor)), h = max(1, Int(CGFloat(image.height) * factor))
    guard let ctx = Bitmap.context(width: w, height: h) else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
  }

  /// The image as AppKit shows it, at its size in points.
  static func nsImage(_ image: CGImage, size: CGSize) -> NSImage {
    NSImage(cgImage: image, size: size)
  }

  /// A finished screenshot for the payload.
  static func screenshot(from capture: ScreenCapture, element: FeedbackElement?, color: NSColor = highlightColor) -> FeedbackScreenshot? {
    var image = capture.image
    if let element, element.rect.w > 0, element.rect.h > 0 {
      image = highlighted(image, rect: rect(for: element, in: capture.windowSize), size: capture.windowSize, color: color)
    }
    guard let data = jpeg(image) else { return nil }
    return FeedbackScreenshot(jpeg: data, highlighted: element != nil)
  }
}
#endif
