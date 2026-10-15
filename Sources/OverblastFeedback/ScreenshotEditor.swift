#if canImport(UIKit) || os(macOS)
import Combine
import OverblastFeedbackCore
import SwiftUI

/// The screenshot editor: the person drags over anything they would rather not send, and it is
/// covered with a solid box or blurred. The result replaces the screenshot; the private-view masks
/// are painted again on top of every edit, so they can never be removed. One SwiftUI view for iOS,
/// iPadOS, visionOS and macOS.
@MainActor
final class ScreenshotEditorModel: ObservableObject {
  let original: CGImage
  let pointSize: CGSize
  let masks: [CGRect]
  @Published var mode: ScreenshotEdit.Kind = .cover
  @Published private(set) var edits: [ScreenshotEdit]
  @Published private(set) var preview: CGImage
  /// The rectangle being drawn, in picture points.
  @Published var drawing: CGRect?
  var onFinish: (_ edits: [ScreenshotEdit]?) -> Void = { _ in }

  init(original: CGImage, pointSize: CGSize, masks: [CGRect], edits: [ScreenshotEdit]) {
    self.original = original
    self.pointSize = pointSize
    self.masks = masks
    self.edits = edits
    self.preview = ScreenshotRedaction.apply(edits, to: original, pointSize: pointSize, masks: masks)
  }

  func add(_ rect: CGRect) {
    let r = rect.standardized.intersection(CGRect(origin: .zero, size: pointSize))
    guard r.width >= 4, r.height >= 4 else { return }
    edits.append(ScreenshotEdit(rect: r, kind: mode))
    render()
  }

  func undo() {
    guard !edits.isEmpty else { return }
    edits.removeLast()
    render()
  }

  func clear() {
    edits.removeAll()
    render()
  }

  private func render() {
    preview = ScreenshotRedaction.apply(edits, to: original, pointSize: pointSize, masks: masks)
  }
}

struct ScreenshotEditorView: View {
  @ObservedObject var model: ScreenshotEditorModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button(Strings.cancel) { model.onFinish(nil) }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Text(Strings.editTitle).font(ThemeUI.swiftUIFont(.headline))
          .accessibilityAddTraits(.isHeader)
        Spacer()
        Button(Strings.done) { model.onFinish(model.edits) }
          .keyboardShortcut(.defaultAction)
          .font(ThemeUI.swiftUIFont(.body, weight: .semibold))
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)

      Text(Strings.editHint)
        .font(ThemeUI.swiftUIFont(.footnote))
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)

      GeometryReader { geo in
        let scale = min(geo.size.width / max(model.pointSize.width, 1), geo.size.height / max(model.pointSize.height, 1))
        let shown = CGSize(width: model.pointSize.width * scale, height: model.pointSize.height * scale)
        ZStack(alignment: .topLeading) {
          Image(decorative: model.preview, scale: CGFloat(model.preview.width) / max(model.pointSize.width, 1))
            .resizable()
            .interpolation(.high)
            .frame(width: shown.width, height: shown.height)
          if let r = model.drawing {
            RoundedRectangle(cornerRadius: 3)
              .fill(model.mode == .cover ? Color(white: 0.18).opacity(0.85) : ThemeUI.accentColor.opacity(0.25))
              .overlay(RoundedRectangle(cornerRadius: 3).stroke(ThemeUI.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4])))
              .frame(width: r.width * scale, height: r.height * scale)
              .offset(x: r.minX * scale, y: r.minY * scale)
              .allowsHitTesting(false)
          }
        }
        .frame(width: shown.width, height: shown.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: min(ThemeUI.radius, 12)))
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
              model.drawing = CGRect(
                x: min(value.startLocation.x, value.location.x) / scale,
                y: min(value.startLocation.y, value.location.y) / scale,
                width: abs(value.location.x - value.startLocation.x) / scale,
                height: abs(value.location.y - value.startLocation.y) / scale
              )
            }
            .onEnded { _ in
              if let r = model.drawing { model.add(r) }
              model.drawing = nil
            }
        )
        .accessibilityElement()
        .accessibilityLabel(Strings.screenshotPreview)
        .accessibilityHint(Strings.editHint)
        .accessibilityAddTraits(.isImage)
        .frame(width: geo.size.width, height: geo.size.height)
      }
      .padding(.horizontal, 12)

      HStack(spacing: 12) {
        Picker(Strings.editMode, selection: $model.mode) {
          Label(Strings.editCover, systemImage: "rectangle.fill").tag(ScreenshotEdit.Kind.cover)
          Label(Strings.editBlur, systemImage: "drop.halffull").tag(ScreenshotEdit.Kind.blur)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 260)
        Spacer(minLength: 8)
        Button { model.undo() } label: { Label(Strings.editUndo, systemImage: "arrow.uturn.backward") }
          .disabled(model.edits.isEmpty)
        Button(role: .destructive) { model.clear() } label: { Label(Strings.editClear, systemImage: "trash") }
          .disabled(model.edits.isEmpty)
      }
      .labelStyle(.titleAndIcon)
      .font(ThemeUI.swiftUIFont(.subheadline))
      .padding(16)
    }
    .tint(ThemeUI.accentColor)
    #if os(macOS)
    .frame(minWidth: 520, minHeight: 480)
    #endif
  }
}
#endif
