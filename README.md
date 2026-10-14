# Overblast feedback for iOS

A person using your app shakes the phone, says what is wrong, optionally points at the part of the
screen that is wrong, and sends it. The report lands in your [Overblast](https://overblast.app)
workspace as a **task**, with the element they pointed at, the recent logs, the device, their account
reference in your product, and a screenshot when they chose to attach one.

```swift
.package(url: "https://github.com/Yumankind/overblast-feedback-ios", from: "0.1.0")
```

```swift
import OverblastFeedback

OverblastFeedback.start(key: "obfk_...")      // once, at launch
```

iOS 15. Swift 6 language mode. **No dependencies.** Two products: `OverblastFeedback` (the sheet,
shake, screenshot and tap-to-select, UIKit) and `OverblastFeedbackCore` (the payload, the client,
logs and the kept-report store, Foundation only, and also built for macOS 13). Importing the first
gives you both.

## Quick start

The key is on the console's **Feedback keys** page. It is public, like a Sentry DSN: it ships inside
your app and grants nothing but "file a report into this workspace". Leave the key's web origins empty
for a native-only key.

```swift
// UIKit
func application(_ application: UIApplication, didFinishLaunchingWithOptions …) -> Bool {
  OverblastFeedback.start(key: "obfk_...")
  return true
}

// SwiftUI
@main struct MyApp: App {
  init() { OverblastFeedback.start(key: "obfk_...") }
  var body: some Scene { WindowGroup { ContentView() } }
}
```

After your own sign-in, tell it who is reporting. With an email the sheet does not ask for one:

```swift
OverblastFeedback.setReporter(email: user.email, name: user.name, accountRef: user.id)
OverblastFeedback.setReporter()                           // after sign-out
```

That is the whole integration. Shake the device (in the simulator: Device > Shake) and the sheet
opens. For people who will never think to shake a phone, open it from a button too:

```swift
Button("Report a problem") { OverblastFeedback.present() }
```

## What it does

| | |
|---|---|
| `start(key:endpoint:reporter:options:)` | Sets up, installs shake-to-report, and tries any kept reports once. |
| `setReporter(email:name:accountRef:)` | Who is using the app. Works before `start` too. |
| `present(category:message:)` | Opens the sheet. Nothing happens while one is already open. |
| `isShakeEnabled` | Shake-to-report, switchable at run time. |
| `log(_:_:)`, `debug`/`info`/`warn`/`error` | A line for the next report's logs. |
| `report(message:category:…)` | Sends a report with no UI at all. |
| `captureScreenshot(highlighting:)` | The screenshot the sheet would take, for `report`. |
| `element(at:in:)` | The element under a point, as "Point at the problem" finds it. |
| `retryPending()`, `pendingCount` | Reports kept after a rate limit or with no connection. |
| `recordNetwork()` | The opt-in network recorder for `URLSession.shared`. |
| `view.overblastPrivate = true`, `.overblastPrivate()` | Never in a screenshot. |
| `.overblastElement("id")` | Makes a SwiftUI view selectable by name (see below). |

The sheet has a message (required), a category (bug, idea, question, other; bug by default), **Point
at the problem**, **Include screenshot** (off), an email field when you did not supply one, and a line
saying exactly what will be sent. It uses system fonts and colours, so Dynamic Type, dark mode and
VoiceOver work as they do in the rest of your app. It opens in a window of its own above yours, so it
never touches your view controller hierarchy.

## Options

```swift
OverblastFeedback.start(key: "obfk_...", options: FeedbackOptions(
  shakeToReport: true,          // false: open it only with present()
  captureOSLog: true,           // merge this process's unified log into the report's logs
  osLogWindow: 300,             // ...for the last five minutes
  includeLogs: true,            // false: send no logs at all
  recordNetwork: false,         // true: register the network recorder for URLSession.shared
  extra: ["plan": "pro"],       // on every report's context (≤ 20 keys, values ≤ 200)
  retryPendingOnStart: true
))
```

## Privacy

What leaves the device, and only when the person presses Send:

- **The message** they typed, and the category.
- **The element** they pointed at, if they did: its class path, type, accessibility identifier,
  accessibility label or visible text, and where it was on screen. Never a text field's content (its
  placeholder at most), and no label at all inside a private view.
- **The screenshot**, only when they turned on **Include screenshot**. It is **off on every report**;
  they see the image before sending and can remove it.
- **Logs from this session**: the last 500 lines, at most 256 KB.
- **Device and app details**: app version and build, iOS version, model identifier (`iPhone15,3`),
  locale, time zone, screen size, the name of the screen they were on, and a random per-install id
  (in a `UserDefaults` suite of its own) that the service uses for per-device rate limits instead of
  your users' IP address.
- **Their email**, only if you passed one or they typed one.

**Marking views private.** A private view, and everything inside it, is painted over with a solid box
inside the renderer, so its pixels never exist in any image this library holds:

```swift
balanceLabel.overblastPrivate = true                    // UIKit

Text(account.balance).overblastPrivate()                // SwiftUI
```

Or, without importing the module, give the view an `accessibilityIdentifier` that starts with
`overblast.private`.

The SwiftUI modifier puts an invisible UIKit view behind yours (a `UIViewRepresentable` in a
`.background`); SwiftUI lays it out exactly where your view is drawn, scrolling included, and that
frame is what gets masked. It cannot mask what is drawn outside the view's own frame (a shadow, or an
overlay moved with `offset`); mark the container in that case.

**Always blanked**, whatever you mark: every secure text field (`isSecureTextEntry`, which includes
SwiftUI's `SecureField`) and every field whose `textContentType` is a password, a new password, a
one-time code or a card number.

**Redaction.** Before logs and network URLs leave the device, anything that looks like a bearer token,
an API key (`sk-…`, `ob_live_…`, `obfk_…`), a JWT, a card number (13 to 19 digits that pass the Luhn
check) or a `password=` / `token=` / `api_key: …` value is replaced by `[redacted]`. The reporter's
own message is never altered.

## Pointing at the problem

**Point at the problem** shows the frozen screenshot full screen. The person taps, and the library
searches your **live** view hierarchy under that point.

- **UIKit** finds the deepest visible view there, including ones that take no touches (a `UILabel`, a
  `UIImageView`), with a `UIControl` treated as one piece. The path runs from the window down, with a
  view controller's root view named after the view controller and UIKit's private wrappers left out:
  `["UIWindow", "UINavigationController", "CartViewController", "UIStackView", "UIButton"]`.
- **SwiftUI is coarser.** Most of a SwiftUI screen is drawn by one hosting view and has no `UIView`
  of its own, and SwiftUI publishes its accessibility elements **only while an assistive technology
  is running** (VoiceOver, Voice Control, Switch Control, UI tests). So beneath a hosting view the
  library tries, in order:
  1. the accessibility elements, when they exist: the smallest one under the finger wins, its `type`
     comes from its traits (`Button`, `Text`, `Image`, `Header`, `Link`, …) and its `id` is its
     `.accessibilityIdentifier(...)`;
  2. a view you marked with `.overblastElement("cart.checkout")`, found like a UIKit view: `id` is
     the name you gave, `type` is the marked view's own type (`Button`, `CartRow`), and the rectangle
     is its frame;
  3. otherwise the hosting view itself, with a 44-point square round the tap as the rectangle, so the
     report still says where.

  With nobody running VoiceOver, which is most of your users, step 2 is what makes SwiftUI reports
  precise. Mark the views your team will want to find:

  ```swift
  Button("Checkout") { … }
    .overblastElement("cart.checkout")              // optional label: .overblastElement("…", label: "Checkout")
  ```

  A UIKit view inside SwiftUI (a `UIViewRepresentable`) is found exactly, by its class, as is
  SwiftUI's own `TextField` and `SecureField`, which are UIKit text fields underneath.
- **Overlays that let touches through** (a transparent full-screen layer, a floating bar host) are
  looked through, the way a tap would be: what is selected is what the person sees.

The element's box is drawn on the screenshot (when there is one) and the report says so.

## Logs

```swift
OverblastFeedback.log(.error, "Checkout failed: \(error)")
OverblastFeedback.info("cart loaded, \(items.count) items")
```

The lines go into an in-memory ring of 500, cheap and thread-safe, nothing written to disk.

With `captureOSLog` on, the report also carries the last five minutes of **this process's** unified
log (`OSLogStore(scope: .currentProcessIdentifier)`): what your app and its frameworks logged through
`Logger`, `os_log` and `NSLog`. It does not see `print` (stdout is not the unified log), other
processes, or anything from before this launch. The two sources are merged by time and capped to the
newest 500 lines and 256 KB.

## Network

Off by default, because it sits in the path of your requests:

```swift
OverblastFeedback.recordNetwork()                          // URLSession.shared
OverblastNetworkRecorder.install(in: myConfiguration)       // a session you build yourself
```

Each entry is the method, the URL **without** query string or fragment, the status (0 when there was
no answer) and the time taken. No bodies, no headers. It is a `URLProtocol`, so it only sees
`URLSession` traffic registered with it: not WebKit, not a third-party SDK's own session, not
`Network.framework`. Recorded requests get the system's default handling of authentication challenges,
so leave it off in an app that pins certificates in a session delegate.

## Without the sheet

```swift
let shot = OverblastFeedback.captureScreenshot()          // only if the person agreed to it
try await OverblastFeedback.report(
  message: "Payment sheet froze",
  category: .bug,
  reporter: FeedbackReporter(email: "ana@example.com"),
  screenshot: shot
)
```

## Errors and kept reports

Every refusal from the service carries a sentence written to be shown to the reporter, and
`FeedbackError.message` is that sentence verbatim:

```swift
do { try await OverblastFeedback.report(message: text) }
catch let error as FeedbackError {
  switch error {
  case .rateLimited, .offline:  break        // kept; sent on the next launch or by retryPending()
  case .storageFull:            break        // filed, without the screenshot; do not resend
  case .refused(_, _, let message, _): show(message)          // the code and field are there too
  case .invalidReport(_, let message): show(message)   // caught before sending
  case .notStarted: break
  }
}
```

A report refused with `429` (the service allows 10 an hour and 30 a day per device) or with no
connection is kept in Application Support, excluded from backups, and tried **once** on the next
launch and whenever you call `retryPending()`. Never on a timer and never in a loop: one refusal ends
the run. At most ten are kept, none for longer than a week.

## How reports appear in Overblast

Each report becomes a **task** in the workspace, titled `Bug: <first line>` (or `Idea:`,
`Question:`, `Feedback:`), tagged `feedback`, the category and `ios`, and assigned to the group the key
names, if any. The screenshot and a `feedback-report.json` (element, logs, network, context) are
attached to it.

**An email conversation is opened only when the report carries an email address**, yours via
`setReporter` or one the person typed. No mail is sent when the report arrives; the thread starts when
someone on your team replies from the task. Without an email there is nobody to answer and no
conversation.

## Shake, and what can hide it

`start` replaces `-[UIWindow motionEnded:withEvent:]` once, so your app does not have to subclass
anything. The method is first added to `UIWindow` with the implementation it inherits, and only that
entry is replaced: every other responder keeps UIKit's own, and the original is always called first,
so your own shake handling still sees every shake. Two shakes within 1.5 seconds are one.

A shake reaches the window by travelling up the responder chain. A view or view controller that
overrides `motionEnded` without calling `super` swallows it, and then the sheet does not open; use
`present()` from a button in such an app. `isShakeEnabled = false` (or `shakeToReport: false`) turns
it off; with the option off from the start, nothing is replaced at all.

## Sample

`Samples/FeedbackSample` is a single SwiftUI file: start, the reporter, a private view, a secure field,
a log line and a "Report a problem" button.

## Licence

MIT.
