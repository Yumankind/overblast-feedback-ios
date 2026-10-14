#if canImport(UIKit)
import UIKit

/// A frozen picture of the app's window, taken before the sheet opens, with the private parts
/// already painted over.
@MainActor
struct ScreenCapture {
  /// The masked image, at most 2400 pixels on its long side.
  let image: UIImage
  /// The window it was taken of, in points.
  let windowSize: CGSize
  /// The window-space rectangles that were blanked out. The element picker keeps labels inside
  /// them out of the report.
  let privateRects: [CGRect]

  static let maxPixels: CGFloat = 2400
  static let maskColor = UIColor(white: 0.18, alpha: 1)

  static func take(of window: UIWindow) -> ScreenCapture {
    let bounds = window.bounds
    let masks = PrivacyMask.rects(in: window)
    let format = UIGraphicsImageRendererFormat()
    let longSide = max(bounds.width, bounds.height, 1)
    format.scale = min(window.traitCollection.displayScale > 0 ? window.traitCollection.displayScale : 2, maxPixels / longSide)
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
    let image = renderer.image { ctx in
      UIColor.systemBackground.setFill()
      ctx.fill(bounds)
      // `afterScreenUpdates: false` draws what is on screen now, without forcing a layout pass that
      // could catch the app mid-animation; it is the frame the person was looking at when they shook.
      window.drawHierarchy(in: bounds, afterScreenUpdates: false)
      maskColor.setFill()
      for rect in masks { ctx.fill(rect) }
    }
    return ScreenCapture(image: image, windowSize: bounds.size, privateRects: masks)
  }
}

@MainActor
enum ScreenshotRenderer {
  static let highlightColor = UIColor.systemRed

  /// `image` with a box drawn round `rect` (window points). The picture the team sees is the one the
  /// reporter saw, so the box is in the image itself rather than in metadata a viewer might not draw.
  static func highlighted(_ image: UIImage, rect: CGRect) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
    return renderer.image { ctx in
      image.draw(at: .zero)
      let box = rect.insetBy(dx: -2, dy: -2)
      highlightColor.withAlphaComponent(0.15).setFill()
      ctx.fill(box)
      highlightColor.setStroke()
      let path = UIBezierPath(roundedRect: box, cornerRadius: 4)
      path.lineWidth = 3
      path.stroke()
    }
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
  static func jpeg(_ image: UIImage) -> Data? {
    var current = image
    for _ in 0..<4 {
      for quality in [0.8, 0.6, 0.45] as [CGFloat] {
        if let data = current.jpegData(compressionQuality: quality), data.count <= FeedbackLimits.screenshotBytes {
          return data
        }
      }
      current = scaled(current, by: 0.75)
    }
    return nil
  }

  static func scaled(_ image: UIImage, by factor: CGFloat) -> UIImage {
    let format = UIGraphicsImageRendererFormat()
    format.scale = image.scale * factor
    format.opaque = true
    return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
      image.draw(in: CGRect(origin: .zero, size: image.size))
    }
  }

  /// A finished screenshot for the payload.
  static func screenshot(from capture: ScreenCapture, element: FeedbackElement?) -> FeedbackScreenshot? {
    var image = capture.image
    if let element, element.rect.w > 0, element.rect.h > 0 {
      image = highlighted(image, rect: rect(for: element, in: capture.windowSize))
    }
    guard let data = jpeg(image) else { return nil }
    return FeedbackScreenshot(jpeg: data, highlighted: element != nil)
  }
}
#endif
