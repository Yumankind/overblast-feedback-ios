#if os(macOS)
import AppKit
import Combine
import SwiftUI

/// "Point at the problem" on a Mac: the frozen picture of the window, in a sheet of its own. A click
/// is turned back into a point in the window's content and the LIVE view hierarchy under it is
/// searched, so the element is the real view and not a guess from pixels. The box drawn here is the
/// box that will be drawn on the screenshot.
@MainActor
final class PointerModel: ObservableObject {
  let capture: ScreenCapture
  let image: NSImage
  private weak var appWindow: NSWindow?
  @Published private(set) var selection: ElementPicker.Selection?
  var onFinish: (_ keep: Bool, _ selection: ElementPicker.Selection?) -> Void = { _, _ in }

  init(capture: ScreenCapture, appWindow: NSWindow, selection: ElementPicker.Selection?) {
    self.capture = capture
    self.image = ScreenshotRenderer.nsImage(capture.image, size: capture.windowSize)
    self.appWindow = appWindow
    self.selection = selection
  }

  /// `point` in the window's content points, from the top-left corner.
  func pick(at point: CGPoint) {
    guard let appWindow else { return }
    selection = ElementPicker.select(at: point, in: appWindow, privateRects: capture.privateRects)
    if let selection { Announce.say(Strings.selected(selection.element)) }
  }

  /// Done hands the selection back; Cancel leaves whatever the sheet had before.
  func finish(keep: Bool) { onFinish(keep, selection) }

  /// The size the picture is shown at: the window's own size when the sheet fits inside it, else
  /// scaled down to fit, and never smaller than half size on a tiny window when the screen has room.
  static func displayScale(content: CGSize, window: CGSize, screen: CGSize?) -> CGFloat {
    let bar: CGFloat = 56
    let w = max(content.width, 1), h = max(content.height, 1)
    var scale = min(1, (window.width - 40) / w, (window.height - bar - 40) / h)
    if scale < 0.5, let screen {
      scale = min(1, (screen.width * 0.9) / w, (screen.height * 0.85 - bar) / h)
    }
    return max(scale, 0.1)
  }
}

struct PointerView: View {
  @ObservedObject var model: PointerModel
  let scale: CGFloat
  @State private var cursorPushed = false

  private var displaySize: CGSize {
    CGSize(width: model.capture.windowSize.width * scale, height: model.capture.windowSize.height * scale)
  }

  var body: some View {
    VStack(spacing: 0) {
      ZStack(alignment: .topLeading) {
        Image(nsImage: model.image)
          .resizable()
          .interpolation(.high)
          .frame(width: displaySize.width, height: displaySize.height)
        if let selection = model.selection {
          let r = selection.frame
          RoundedRectangle(cornerRadius: 4)
            .fill(Color.red.opacity(0.15))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.red, lineWidth: 3))
            .frame(width: r.width * scale + 4, height: r.height * scale + 4)
            .offset(x: r.minX * scale - 2, y: r.minY * scale - 2)
            .allowsHitTesting(false)
        }
      }
      .frame(width: displaySize.width, height: displaySize.height, alignment: .topLeading)
      .clipped()
      .contentShape(Rectangle())
      .onTapGesture(count: 1) { location in
        model.pick(at: CGPoint(x: location.x / scale, y: location.y / scale))
      }
      .onHover { inside in
        if inside, !cursorPushed {
          NSCursor.crosshair.push()
          cursorPushed = true
        } else if !inside, cursorPushed {
          NSCursor.pop()
          cursorPushed = false
        }
      }
      .onDisappear {
        if cursorPushed {
          NSCursor.pop()
          cursorPushed = false
        }
      }
      .accessibilityElement()
      .accessibilityLabel(Strings.pointerImage)
      .accessibilityHint(Strings.pointerImageHint)
      .accessibilityAddTraits(.isImage)

      Divider()

      HStack(spacing: 12) {
        Button(Strings.cancel) { model.finish(keep: false) }
          .keyboardShortcut(.cancelAction)
        Spacer(minLength: 8)
        Text(model.selection.map { Strings.selected($0.element) } ?? Strings.pointerHint)
          .font(.callout)
          .lineLimit(2)
          .multilineTextAlignment(.center)
        Spacer(minLength: 8)
        Button(Strings.done) { model.finish(keep: true) }
          .keyboardShortcut(.defaultAction)
          .disabled(model.selection == nil)
      }
      .padding(12)
    }
    .frame(width: max(displaySize.width, 360))
  }
}
#endif
