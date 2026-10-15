// One import gives an app both halves: `import OverblastFeedback` brings the core (payload, client,
// logs, pending store) along with the sheet: UIKit on iOS, iPadOS and visionOS, AppKit and SwiftUI on
// macOS. On any other platform this module is the core and nothing else.
@_exported import OverblastFeedbackCore
