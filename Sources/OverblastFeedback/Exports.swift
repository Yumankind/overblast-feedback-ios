// One import gives an app both halves: `import OverblastFeedback` brings the core (payload, client,
// logs, pending store) along with the UIKit sheet. On a platform without UIKit this module is the
// core and nothing else.
@_exported import OverblastFeedbackCore
