import CoreGraphics
import Foundation

/// The brand the report UI wears: an accent colour, a font family and a corner radius. Every part of
/// the UI takes it: the sheet, its buttons and chips, the pointer screen, the screenshot editor, the
/// error prompt and the crash offer. The defaults are the app's own tint, the system font and 12
/// points, so an app that sets nothing looks like itself.
public struct FeedbackTheme: Sendable, Equatable {
  /// A colour in sRGB, 0 to 1.
  public struct Color: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
      self.red = Color.unit(red)
      self.green = Color.unit(green)
      self.blue = Color.unit(blue)
      self.alpha = Color.unit(alpha)
    }

    /// `#RGB`, `#RRGGBB` or `#RRGGBBAA`, with or without the `#`. Nil when it is none of those.
    public init?(hex: String) {
      var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
      if s.hasPrefix("#") { s.removeFirst() }
      guard s.allSatisfy(\.isHexDigit) else { return nil }
      if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
      guard s.count == 6 || s.count == 8, let value = UInt64(s, radix: 16) else { return nil }
      let hasAlpha = s.count == 8
      let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
      let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
      let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
      let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
      self.init(red: r, green: g, blue: b, alpha: a)
    }

    public var cgColor: CGColor {
      CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// Whether white text reads on it (WCAG relative luminance under 0.5), for a button's label.
    public var prefersLightForeground: Bool {
      func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
      let l = 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
      return l < 0.5
    }

    static func unit(_ v: Double) -> Double { v.isFinite ? min(1, max(0, v)) : 0 }
  }

  /// Nil: the app's own tint (the key window's `tintColor`, or the app's accent colour).
  public var accent: Color?
  /// A font family installed in the app (`"Avenir Next"`). Nil, empty or not installed: the system
  /// font. Sizes always follow the person's text size setting.
  public var fontFamily: String?
  /// The radius of the fields, chips, buttons and thumbnails, 0 to 28 points.
  public var cornerRadius: Double

  public init(accent: Color? = nil, fontFamily: String? = nil, cornerRadius: Double = 12) {
    self.accent = accent
    self.fontFamily = fontFamily
    self.cornerRadius = cornerRadius
  }

  /// The app's own look: its tint, the system font, 12 points.
  public static let system = FeedbackTheme()

  public static let maxCornerRadius: Double = 28

  public var resolvedCornerRadius: Double {
    cornerRadius.isFinite ? min(Self.maxCornerRadius, max(0, cornerRadius)) : 12
  }

  /// The family to ask the system for, or nil for the system font. `installed` is the list of
  /// families the platform reports; a family that is not in it falls back to the system font rather
  /// than to whatever the platform substitutes.
  public func resolvedFontFamily(installed: [String]) -> String? {
    guard let family = fontFamily?.trimmingCharacters(in: .whitespacesAndNewlines), !family.isEmpty else { return nil }
    return installed.first { $0.caseInsensitiveCompare(family) == .orderedSame }
  }

  /// The radius for something `height` points tall: the theme's, but never more than half the height,
  /// so a short chip is a capsule rather than a blob.
  public func cornerRadius(forHeight height: Double) -> Double {
    min(resolvedCornerRadius, max(0, height / 2))
  }
}

/// The region of the frozen screenshot shown as the picked element's thumbnail in the form: the
/// element with a margin round it, at least `minSide` points on each side so a thin line is still
/// recognisable, in the thumbnail's aspect ratio, kept inside the picture.
public enum PickThumbnail {
  public static func cropRect(for frame: CGRect, in size: CGSize, aspect: CGFloat = 1, padding: CGFloat = 16, minSide: CGFloat = 72) -> CGRect {
    let bounds = CGRect(origin: .zero, size: size)
    guard size.width > 0, size.height > 0 else { return .zero }
    let target = frame.standardized.intersection(bounds).isNull ? CGRect(x: frame.midX, y: frame.midY, width: 0, height: 0) : frame.standardized
    let ratio = aspect > 0 && aspect.isFinite ? aspect : 1
    var w = max(target.width + padding * 2, minSide)
    var h = max(target.height + padding * 2, minSide)
    if w / h < ratio { w = h * ratio } else { h = w / ratio }
    // Larger than the picture: as large as fits, keeping the ratio.
    if w > size.width { w = size.width; h = w / ratio }
    if h > size.height { h = size.height; w = h * ratio }
    var x = target.midX - w / 2
    var y = target.midY - h / 2
    x = min(max(0, x), size.width - w)
    y = min(max(0, y), size.height - h)
    return CGRect(x: x, y: y, width: w, height: h)
  }

  /// `rect` (points) in pixels of a picture `scale` pixels per point, whole pixels, inside the picture.
  public static func pixelRect(_ rect: CGRect, scale: CGFloat, pixelSize: CGSize) -> CGRect {
    let r = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
    return r.intersection(CGRect(origin: .zero, size: pixelSize))
  }
}
