import CoreGraphics
import XCTest
@testable import OverblastFeedbackCore

/// The UI pass's testable parts: the theme's resolution, the pick thumbnail's crop, and the
/// screenshot editor's covers and blurs on a real bitmap.
final class ThemeAndEditingTests: XCTestCase {
  // MARK: Theme

  func testTheThemeResolves() throws {
    XCTAssertEqual(FeedbackTheme.system.accent, nil)
    XCTAssertEqual(FeedbackTheme.system.resolvedCornerRadius, 12)
    XCTAssertEqual(FeedbackTheme(cornerRadius: 80).resolvedCornerRadius, 28)
    XCTAssertEqual(FeedbackTheme(cornerRadius: -3).resolvedCornerRadius, 0)
    XCTAssertEqual(FeedbackTheme(cornerRadius: .nan).resolvedCornerRadius, 12)
    XCTAssertEqual(FeedbackTheme(cornerRadius: 20).cornerRadius(forHeight: 30), 15, "a short chip is a capsule")

    let installed = ["Avenir Next", "Helvetica Neue"]
    XCTAssertNil(FeedbackTheme.system.resolvedFontFamily(installed: installed))
    XCTAssertEqual(FeedbackTheme(fontFamily: "  avenir next ").resolvedFontFamily(installed: installed), "Avenir Next")
    XCTAssertNil(FeedbackTheme(fontFamily: "Comic Papyrus").resolvedFontFamily(installed: installed), "not installed: the system font")
    XCTAssertNil(FeedbackTheme(fontFamily: "").resolvedFontFamily(installed: installed))
    XCTAssertEqual(FeedbackOptions().theme, .system)
  }

  func testHexColours() throws {
    let brand = try XCTUnwrap(FeedbackTheme.Color(hex: "#FF6600"))
    XCTAssertEqual(brand.red, 1)
    XCTAssertEqual(brand.green, 0.4, accuracy: 0.002)
    XCTAssertEqual(brand.blue, 0)
    XCTAssertEqual(brand.alpha, 1)
    XCTAssertEqual(FeedbackTheme.Color(hex: "0f0"), FeedbackTheme.Color(red: 0, green: 1, blue: 0))
    XCTAssertEqual(try XCTUnwrap(FeedbackTheme.Color(hex: "#00000080")).alpha, 128.0 / 255, accuracy: 0.001)
    XCTAssertNil(FeedbackTheme.Color(hex: "orange"))
    XCTAssertNil(FeedbackTheme.Color(hex: "#12345"))
    XCTAssertTrue(FeedbackTheme.Color(red: 0.1, green: 0.2, blue: 0.6).prefersLightForeground)
    XCTAssertFalse(FeedbackTheme.Color(red: 1, green: 0.9, blue: 0.3).prefersLightForeground)
    XCTAssertEqual(FeedbackTheme.Color(red: 2, green: -1, blue: 0.5).red, 1)
  }

  // MARK: The pick's thumbnail

  func testTheThumbnailCropFramesTheElementWithAMargin() {
    let size = CGSize(width: 400, height: 800)
    // A 90 × 40 button: 16 points round it, square.
    let crop = PickThumbnail.cropRect(for: CGRect(x: 300, y: 110, width: 90, height: 40), in: size)
    XCTAssertEqual(crop.width, crop.height)
    XCTAssertEqual(crop.width, 122)
    XCTAssertEqual(crop.midY, 130, "centred on the element vertically")
    XCTAssertEqual(crop.maxX, 400, "pushed back inside the picture on the right")
    XCTAssertTrue(crop.contains(CGRect(x: 300, y: 110, width: 90, height: 40)))

    // A hairline still gets the minimum side.
    let thin = PickThumbnail.cropRect(for: CGRect(x: 100, y: 400, width: 200, height: 1), in: size, aspect: 2)
    XCTAssertEqual(thin.height, 116)
    XCTAssertEqual(thin.width, 232)
    XCTAssertEqual(thin.midX, 200)

    // Bigger than the picture: the whole width, in ratio.
    let huge = PickThumbnail.cropRect(for: CGRect(x: 0, y: 0, width: 400, height: 800), in: size)
    XCTAssertEqual(huge.width, 400)
    XCTAssertEqual(huge.height, 400)
    XCTAssertGreaterThanOrEqual(huge.minY, 0)
    XCTAssertLessThanOrEqual(huge.maxY, 800)

    // The tiny element at the top-left corner stays inside.
    let corner = PickThumbnail.cropRect(for: CGRect(x: 0, y: 0, width: 10, height: 10), in: size)
    XCTAssertEqual(corner.origin, .zero)
    XCTAssertEqual(PickThumbnail.pixelRect(CGRect(x: 1.2, y: 2.6, width: 10, height: 10), scale: 3, pixelSize: CGSize(width: 30, height: 30)),
                   CGRect(x: 3, y: 7, width: 27, height: 23))
  }

  // MARK: Covers and blurs

  /// 100 × 100 points at 2 pixels a point: black and white stripes 2 points wide on the left half,
  /// solid blue on the right.
  private func testImage() throws -> CGImage {
    let ctx = try XCTUnwrap(CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 200))
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    for x in stride(from: 0, to: 100, by: 8) { ctx.fill(CGRect(x: x, y: 0, width: 4, height: 200)) }
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 100, y: 0, width: 100, height: 200))
    return try XCTUnwrap(ctx.makeImage())
  }

  /// RGB at a top-left point.
  private func pixel(_ image: CGImage, _ x: CGFloat, _ y: CGFloat) -> [Double] {
    var data = [UInt8](repeating: 0, count: 4)
    let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let px = Int(x * 2), py = Int(y * 2)
    ctx.draw(image, in: CGRect(x: -px, y: py - image.height + 1, width: image.width, height: image.height))
    return data.prefix(3).map { Double($0) / 255 }
  }

  /// The spread of brightness along a row segment: stripes are high, a blur is low.
  private func contrast(_ image: CGImage, y: CGFloat, from x0: CGFloat, to x1: CGFloat) -> Double {
    let values = stride(from: x0, to: x1, by: 0.5).map { pixel(image, $0, y)[0] }
    return (values.max() ?? 0) - (values.min() ?? 0)
  }

  func testACoverIsSolidAndNothingElseChanges() throws {
    let image = try testImage()
    let edited = ScreenshotRedaction.apply([ScreenshotEdit(rect: CGRect(x: 10, y: 10, width: 20, height: 20), kind: .cover)], to: image, pointSize: CGSize(width: 100, height: 100))
    for (x, y) in [(12.0, 12.0), (20.0, 20.0), (29.0, 29.0)] {
      let p = pixel(edited, x, y)
      XCTAssertEqual(p[0], 0.18, accuracy: 0.02)
      XCTAssertEqual(p[0], p[2], accuracy: 0.02)
    }
    XCTAssertEqual(pixel(edited, 70, 50), [0, 0, 1])
    XCTAssertEqual(pixel(edited, 1, 50), pixel(image, 1, 50))
    XCTAssertEqual(edited.width, image.width)
  }

  func testABlurMakesStripesUnreadableOnlyInsideItsRectangle() throws {
    let image = try testImage()
    let edited = ScreenshotRedaction.apply([ScreenshotEdit(rect: CGRect(x: 0, y: 40, width: 50, height: 30), kind: .blur)], to: image, pointSize: CGSize(width: 100, height: 100))
    XCTAssertGreaterThan(contrast(image, y: 55, from: 5, to: 45), 0.9)
    XCTAssertLessThan(contrast(edited, y: 55, from: 15, to: 35), 0.5, "the stripes are gone inside")
    XCTAssertGreaterThan(contrast(edited, y: 20, from: 5, to: 45), 0.9, "and untouched above")
    XCTAssertGreaterThan(contrast(edited, y: 85, from: 5, to: 45), 0.9, "and below")
    XCTAssertEqual(pixel(edited, 80, 55), [0, 0, 1])
  }

  func testThePrivateMasksStayOnTopOfEveryEdit() throws {
    let image = try testImage()
    let mask = CGRect(x: 60, y: 60, width: 30, height: 30)
    let edited = ScreenshotRedaction.apply(
      [ScreenshotEdit(rect: CGRect(x: 50, y: 50, width: 50, height: 50), kind: .blur),
       ScreenshotEdit(rect: CGRect(x: 55, y: 55, width: 10, height: 10), kind: .cover)],
      to: image, pointSize: CGSize(width: 100, height: 100), masks: [mask]
    )
    let p = pixel(edited, 75, 75)
    XCTAssertEqual(p[0], 0.18, accuracy: 0.02)
    XCTAssertEqual(p[2], 0.18, accuracy: 0.02)
    // No edits and no masks: the same image back.
    XCTAssertTrue(ScreenshotRedaction.apply([], to: image, pointSize: CGSize(width: 100, height: 100)) === image)
    // A rectangle drawn from bottom-right to top-left counts the same.
    XCTAssertEqual(ScreenshotEdit(rect: CGRect(x: 30, y: 30, width: -20, height: -20), kind: .cover).rect, CGRect(x: 10, y: 10, width: 20, height: 20))
  }
}

/// Contract §3.3: `known` on the 201, and the thank-you it chooses.
final class KnownIssueTests: XCTestCase {
  func testKnownIsReadAndChoosesTheThankYou() throws {
    let known = try FeedbackClient.interpret(status: 201, data: Data(#"{"id":"fbr_1","taskId":"t1","conversationId":null,"known":true}"#.utf8))
    XCTAssertTrue(known.known)
    let fresh = try FeedbackClient.interpret(status: 201, data: Data(#"{"id":"fbr_2","taskId":"t2","conversationId":null}"#.utf8))
    XCTAssertFalse(fresh.known, "absent is false")
    let messages = FeedbackMessages()
    XCTAssertEqual(messages.thankYou(for: known), "Thanks. We already know about this one and we're on it.")
    XCTAssertEqual(messages.thankYou(for: fresh), "Sent. Thank you.")
    XCTAssertEqual(FeedbackMessages(sentKnownIssue: "On it!").thankYou(for: known), "On it!")
  }
}
