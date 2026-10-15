#if canImport(UIKit) || os(macOS)
import OverblastFeedbackCore
import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// `FeedbackTheme` turned into the platform's colours and fonts. Fonts always follow the person's
/// text size: a brand family is scaled the way the system font would be for the same text style.
@MainActor
enum ThemeUI {
  static var theme: FeedbackTheme { OverblastFeedback.options.theme }
  static var radius: CGFloat { CGFloat(theme.resolvedCornerRadius) }

  #if canImport(UIKit)
  /// The theme's accent, else the app window's tint.
  static func accent(_ window: UIWindow? = nil) -> UIColor {
    if let c = theme.accent { return UIColor(cgColor: c.cgColor) }
    return (window ?? ScreenContext.appWindow())?.tintColor ?? .tintColor
  }

  /// White or black, whichever reads on the accent.
  static func onAccent(_ window: UIWindow? = nil) -> UIColor {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    let resolved = accent(window).resolvedColor(with: (window ?? ScreenContext.appWindow())?.traitCollection ?? .current)
    guard resolved.getRed(&r, green: &g, blue: &b, alpha: &a) else { return .white }
    return FeedbackTheme.Color(red: Double(r), green: Double(g), blue: Double(b)).prefersLightForeground ? .white : .black
  }

  /// A font for `style` in the theme's family (or the system's), scaled for Dynamic Type and kept
  /// scaling by `adjustsFontForContentSizeCategory`.
  static func font(_ style: UIFont.TextStyle, weight: UIFont.Weight = .regular) -> UIFont {
    let metrics = UIFontMetrics(forTextStyle: style)
    let size = defaultSize(style)
    if let family = theme.resolvedFontFamily(installed: UIFont.familyNames) {
      var descriptor = UIFontDescriptor(fontAttributes: [.family: family])
      if weight >= .semibold, let bold = descriptor.withSymbolicTraits(.traitBold) { descriptor = bold }
      return metrics.scaledFont(for: UIFont(descriptor: descriptor, size: size))
    }
    if weight == .regular { return UIFont.preferredFont(forTextStyle: style) }
    return metrics.scaledFont(for: UIFont.systemFont(ofSize: size, weight: weight))
  }

  /// The sizes at the default text size (Apple's type ramp), which `UIFontMetrics` scales from.
  static func defaultSize(_ style: UIFont.TextStyle) -> CGFloat {
    switch style {
    case .largeTitle: return 34
    case .title1: return 28
    case .title2: return 22
    case .title3: return 20
    case .headline, .body: return 17
    case .callout: return 16
    case .subheadline: return 15
    case .footnote: return 13
    case .caption1: return 12
    case .caption2: return 11
    default: return 17
    }
  }

  static var accentColor: Color { Color(uiColor: accent()) }
  static var installedFamilies: [String] { UIFont.familyNames }
  #else
  static func accent(_ window: NSWindow? = nil) -> NSColor {
    if let c = theme.accent { return NSColor(cgColor: c.cgColor) ?? .controlAccentColor }
    return .controlAccentColor
  }

  static var accentColor: Color {
    if let c = theme.accent { return Color(cgColor: c.cgColor) }
    return .accentColor
  }

  static var installedFamilies: [String] { NSFontManager.shared.availableFontFamilies }
  #endif

  /// The SwiftUI font for `style`: the theme's family scaled relative to the style, or the system's.
  static func swiftUIFont(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
    let bold = weight == .semibold || weight == .bold || weight == .heavy || weight == .black
    if let family = theme.resolvedFontFamily(installed: installedFamilies), let name = fontName(family: family, bold: bold) {
      return Font.custom(name, size: swiftUISize(style), relativeTo: style)
    }
    return Font.system(style).weight(weight)
  }

  /// A face of `family` by its font name: `Font.custom` takes a font's name, and a family name alone
  /// is not resolved on every platform (a Mac falls back to the system font for "Avenir Next").
  static func fontName(family: String, bold: Bool) -> String? {
    #if canImport(UIKit)
    var descriptor = UIFontDescriptor(fontAttributes: [.family: family])
    if bold, let b = descriptor.withSymbolicTraits(.traitBold) { descriptor = b }
    let font = UIFont(descriptor: descriptor, size: 17)
    return font.familyName.caseInsensitiveCompare(family) == .orderedSame ? font.fontName : nil
    #else
    var descriptor = NSFontDescriptor(fontAttributes: [.family: family])
    if bold { descriptor = descriptor.withSymbolicTraits(.bold) }
    guard let font = NSFont(descriptor: descriptor, size: 13), font.familyName?.caseInsensitiveCompare(family) == .orderedSame else { return nil }
    return font.fontName
    #endif
  }

  /// The style's size at the default text size on this platform (a Mac's body is 13 points, an
  /// iPhone's 17), which `relativeTo:` scales from.
  static func swiftUISize(_ style: Font.TextStyle) -> CGFloat {
    #if os(macOS)
    switch style {
    case .largeTitle: return 26
    case .title: return 22
    case .title2: return 17
    case .title3: return 15
    case .headline, .body: return 13
    case .callout: return 12
    case .subheadline: return 11
    case .footnote: return 10
    case .caption, .caption2: return 10
    @unknown default: return 13
    }
    #else
    switch style {
    #if os(visionOS)
    case .extraLargeTitle: return 48
    case .extraLargeTitle2: return 40
    #endif
    case .largeTitle: return 34
    case .title: return 28
    case .title2: return 22
    case .title3: return 20
    case .headline, .body: return 17
    case .callout: return 16
    case .subheadline: return 15
    case .footnote: return 13
    case .caption: return 12
    case .caption2: return 11
    @unknown default: return 17
    }
    #endif
  }
}
#endif
