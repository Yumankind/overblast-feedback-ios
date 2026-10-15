# Overblast feedback for Apple platforms

A person using your app shakes the phone or presses **Report a problem**, says what is wrong,
optionally points at the part of the screen that is wrong, and sends it. The report lands in your
[Overblast](https://overblast.app) workspace as a **task**, with the element they pointed at, the
recent logs, the device, their account reference in your product, and a screenshot when they chose to
attach one. After an unexpected end, the next launch offers to send a report about it.

```swift
.package(url: "https://github.com/Yumankind/overblast-feedback-ios", from: "0.2.0")
```

```swift
import OverblastFeedback

OverblastFeedback.start(key: "obfk_...")      // once, at launch
```

Swift 6 language mode. **No dependencies.** Two products: `OverblastFeedback` (the sheet, the
screenshot, tap-to-select, shake; UIKit on iOS, iPadOS and visionOS, AppKit and SwiftUI on macOS) and
`OverblastFeedbackCore` (the payload, the client, the log buffer, sessions and the kept-report store,
Foundation only). Importing the first gives you both.

## Platforms

| Platform | Minimum | Opens the sheet | Captures |
|---|---|---|---|
| iPhone, iPad (iOS, iPadOS) | 15 | shake, and a button | the app's window |
| Apple Vision Pro (visionOS) | 1 | a button only (no shake reaches an app) | the app's 2D window |
| Mac (macOS) | 13 | a button or a menu item only | the key window's content |

The same calls work on all three: `start`, `setReporter`, `present`, `OverblastFeedbackButton`. The
report says which system it came from in `context.os` (`iOS`, `iPadOS`, `visionOS`, `macOS`);
`context.platform` is `ios` on all of them.

## Quick start

The key is on the console's **Feedback keys** page. It is public, like a Sentry DSN: it ships inside
your app and grants nothing but "file a report into this workspace". Leave the key's web origins empty
for a native-only key.

```swift
@main struct MyApp: App {
  init() { OverblastFeedback.start(key: "obfk_...") }
  var body: some Scene { WindowGroup { ContentView() } }
}

// UIKit
func application(_ application: UIApplication, didFinishLaunchingWithOptions …) -> Bool {
  OverblastFeedback.start(key: "obfk_...")
  return true
}
```

After your own sign-in, tell it who is reporting. With an email the sheet does not ask for one:

```swift
OverblastFeedback.setReporter(email: user.email, name: user.name, accountRef: user.id)
OverblastFeedback.setReporter()                           // after sign-out
```

### The Settings button (button mode)

On visionOS and macOS this is how the sheet opens, and on an iPhone or iPad it is the way in for
people who will never think to shake one. Put it in your Settings `Form`:

```swift
Form {
  Section("Help") {
    OverblastFeedbackButton()                                                    // "Report a problem"
    OverblastFeedbackButton("Report a problem", systemImage: "exclamationmark.bubble")
    OverblastFeedbackButton("Suggest a feature", systemImage: "lightbulb", category: .idea)
  }
}
```

It is an ordinary SwiftUI `Button` calling `OverblastFeedback.present()`, so it looks like every other
row. From UIKit or AppKit, call `OverblastFeedback.present()` from your own button or menu item.

- **iPhone and iPad:** shake works with no code; add the button for everyone else. Shake-only off:
  `FeedbackOptions(shakeToReport: false)`.
- **visionOS:** button mode only. Put the button in your Settings screen or an ornament.
- **macOS:** the sheet attaches to the **key window** and captures that window, so a button inside a
  Settings window reports the Settings window. To report about your main window, add the menu
  command, which leaves the main window key:

  ```swift
  WindowGroup { ContentView() }
    .commands { OverblastFeedbackCommands() }        // Help > Report a Problem…
  Settings { SettingsView() }                        // with an OverblastFeedbackButton in it
  ```

## What it does

| | |
|---|---|
| `start(key:endpoint:reporter:options:)` | Sets up, installs shake-to-report on iPhone and iPad, opens this launch's session, and tries any kept reports once. |
| `setReporter(email:name:accountRef:)` | Who is using the app. Works before `start` too. |
| `present(category:message:trigger:)` | Opens the sheet. Nothing happens while one is already open. `trigger` is `.button` unless you say `.shortcut` or `.agent`. |
| `OverblastFeedbackButton`, `OverblastFeedbackCommands` | The Settings button and the Help menu item. |
| `isShakeAvailable`, `isShakeEnabled` | Whether a shake can reach the app here (iPhone, iPad), and the switch. |
| `log(_:_:)`, `debug`/`info`/`warn`/`error` | A line for the next report's logs. |
| `report(message:category:…)` | Sends a report with no UI at all (`trigger: .api`). |
| `captureScreenshot(highlighting:)` | The screenshot the sheet would take, for `report`. |
| `element(at:in:)` | The element under a point, as "Point at the problem" finds it. |
| `previousSession`, `previousSessionCrash`, `forgetPreviousSession()` | The last session, when it ended unexpectedly. |
| `effectiveConfig`, `refreshRemoteConfig()` | What the key's owner has on, combined with your options. |
| `error(_:unexpected:)`, `log(_:_:unexpected:)` | An unexpected error, which can set off the error prompt. |
| `retryPending()`, `pendingCount` | Reports kept after a rate limit or with no connection. |
| `recordNetwork()` | The opt-in network recorder for `URLSession.shared`. |
| `view.overblastPrivate = true`, `.overblastPrivate()` | Never in a screenshot (`UIView`, `NSView`, SwiftUI). |
| `.overblastElement("id")` | Makes a SwiftUI view selectable by name (see below). |

The sheet has a message (required), a category (bug, idea, question, other; bug by default), **Point
at the problem**, **Include screenshot** (off), an email field when you did not supply one, and a line
saying exactly what will be sent. It uses system fonts and colours, so text size, dark mode and
VoiceOver work as they do in the rest of your app. On iOS and visionOS it opens in a window of its own
above yours; on macOS it is a sheet on your window. Your view controllers are never touched.

## Options

```swift
OverblastFeedback.start(key: "obfk_...", options: FeedbackOptions(
  shakeToReport: true,          // iPhone and iPad only; false everywhere else, whatever you pass
  captureOSLog: true,           // merge this process's own unified-log lines into the report's logs
  osLogWindow: 300,             // ...from the last five minutes
  includeLogs: true,            // false: send no logs at all
  recordNetwork: false,         // true: register the network recorder for URLSession.shared
  extra: ["plan": "pro"],       // on every report's context (≤ 20 keys, values ≤ 200)
  retryPendingOnStart: true,
  offerReportAfterCrash: true,  // ask once, at the launch after an unexpected end
  screenshots: true,            // false: never offer a screenshot
  errorPrompt: true,            // false: never show the error prompt
  device: true,                 // false: never register this device (for device verification)
  appHosts: ["api.example.com"] // your own API hosts, for the error prompt's server_error and network
))
```

### What the key decides

At `start` the library reads the key's settings from the service (`GET …/v1/feedback/config`), keeps
the answer in its own `UserDefaults` suite, reads it again at most every five minutes, and uses the
kept answer when the service cannot be reached. Before it has ever had an answer it behaves as the
defaults: no device registration, no error prompt, screenshots offered. The console's Feedback keys
page is where the owner sets them:

- **categories**: the kinds of report the key takes, the first being the sheet's default. With bug
  only, the sheet has no category choice and is titled "Report a problem"; with several, it offers
  only those. `report(category:)` with one the key does not take is not sent, and throws
  `.refused(403, "category_not_accepted", …)` ("This app only takes problem reports." for a
  bug-only key). `present()` and `OverblastFeedbackButton` with no category open on the key's
  default.
- **screenshots**: off means the sheet does not offer one at all.
- **errorPrompt**: on, with the kinds of error that count and the hours between prompts (below).
- **verification**: whether the library registers the device. This version registers none; the
  setting is read and gates that step for when it arrives.

Your options can only turn these **off**; they cannot turn on what the key has off.
`OverblastFeedback.effectiveConfig` is the combination, and `refreshRemoteConfig()` reads the
service again (at most every five minutes) if a long-lived app wants to.

## Privacy

What leaves the device, and only when the person presses Send:

- **The message** they typed, and the category.
- **The element** they pointed at, if they did: its class path, type, accessibility identifier,
  accessibility label or visible text, and where it was on screen. Never a text field's content (its
  placeholder at most), and no label at all inside a private view.
- **The screenshot**, only when they turned on **Include screenshot**. It is **off on every report**;
  they see the image before sending and can remove it.
- **Logs**: an excerpt of at most 500 lines and 256 KB, and, when there is more, the whole log
  buffer as a compressed file (see [Logs](#logs)). Redacted before they are stored.
- **How the app closed**, on a report made at the launch after an unexpected end: the exception or
  the crash MetricKit reported, with a short call stack.
- **Device and app details**: app version and build, system and version, model identifier
  (`iPhone15,3`, `Mac14,2`), locale, time zone, window size, the name of the screen they were on, when
  and how the report was opened, and a random per-install id (in a `UserDefaults` suite of its own)
  that the service uses for per-device rate limits instead of your users' IP address.
- **Their email**, only if you passed one or they typed one; their name and your account reference
  for them, only if you passed them.

**Your App Store privacy answers.** The package ships a privacy manifest
(`Sources/OverblastFeedbackCore/PrivacyInfo.xcprivacy`) that Xcode merges into your app's privacy
report: no tracking, no tracking domains, `UserDefaults` for the install id (reason `CA92.1`), and the
data types a report can carry, all linked to the user, none used for tracking, all for app
functionality: email address, name, user ID (your account reference), device ID, customer support
(the message), other user content (the screenshot and the selected element), crash data, and other
diagnostic data (logs, network summaries, device details). List the same types in App Store Connect;
that part is yours to answer.

**Marking views private.** A private view, and everything inside it, is painted over with a solid box
inside the renderer, so its pixels never exist in any image this library holds:

```swift
balanceLabel.overblastPrivate = true                    // UIKit (UIView) and AppKit (NSView)

Text(account.balance).overblastPrivate()                // SwiftUI, on every platform
```

Or, without importing the module, give the view an `accessibilityIdentifier` that starts with
`overblast.private`.

The SwiftUI modifier puts an invisible platform view behind yours (a `UIViewRepresentable` or
`NSViewRepresentable` in a `.background`); SwiftUI lays it out exactly where your view is drawn,
scrolling included, and that frame is what gets masked. It cannot mask what is drawn outside the
view's own frame (a shadow, or an overlay moved with `offset`); mark the container in that case.

**Always blanked**, whatever you mark: every secure text field (`isSecureTextEntry` on iOS,
`NSSecureTextField` on macOS, both of which include SwiftUI's `SecureField`) and every field whose
content type is a password, a new password, a one-time code or a card number.

**Redaction.** Before logs and network URLs leave the device, anything that looks like a bearer token,
an API key (`sk-…`, `ob_live_…`, `obfk_…`), a JWT, a card number (13 to 19 digits that pass the Luhn
check) or a `password=` / `token=` / `api_key: …` value is replaced by `[redacted]`. The reporter's
own message is never altered.

## Pointing at the problem

**Point at the problem** shows the frozen screenshot (full screen on iOS, in a sheet of its own on
macOS). The person taps or clicks, and the library searches your **live** view hierarchy under that
point.

- **UIKit and AppKit** find the deepest visible view there, including ones that take no touches (a
  `UILabel`, a `UIImageView`, an `NSImageView`), with a `UIControl` or `NSControl` treated as one
  piece. The path runs from the window down, with a view controller's root view named after the view
  controller and the frameworks' private wrappers left out:
  `["UIWindow", "UINavigationController", "CartViewController", "UIStackView", "UIButton"]`.
- **SwiftUI is coarser.** Most of a SwiftUI screen is drawn by one hosting view and has no view of
  its own, so beneath a hosting view the library tries, in order:
  1. on iOS and visionOS, the accessibility elements, which SwiftUI publishes **only while an
     assistive technology is running** (VoiceOver, Voice Control, Switch Control, UI tests): the
     smallest one under the finger wins, its `type` comes from its traits and its `id` is its
     `.accessibilityIdentifier(...)`;
  2. a view you marked with `.overblastElement("cart.checkout")`: `id` is the name you gave, `type` is
     the marked view's own type (`Button`, `CartRow`), and the rectangle is its frame. On macOS the
     marker comes first, before the accessibility element AppKit reports, and it also names SwiftUI's
     own AppKit controls (a SwiftUI `Button` on a Mac is a `SwiftUIAppKitButton`, the same class for
     every button, with no title an app can read);
  3. otherwise the hosting view itself, with a 44-point square round the tap as the rectangle, so the
     report still says where.

  With nobody running VoiceOver, which is most of your users, the marker is what makes SwiftUI
  reports precise. Mark the views your team will want to find:

  ```swift
  Button("Checkout") { … }
    .overblastElement("cart.checkout")              // optional label: .overblastElement("…", label: "Checkout")
  ```

  A UIKit or AppKit view inside SwiftUI (a representable) is found exactly, by its class, as are
  SwiftUI's text fields, which are platform text fields underneath.
- **Overlays that let touches through** (a transparent full-screen layer, a floating bar host) are
  looked through, the way a tap would be: what is selected is what the person sees.

The element's box is drawn on the screenshot (when there is one) and the report says so.

## Logs

```swift
OverblastFeedback.log(.error, "Checkout failed: \(error)")
OverblastFeedback.info("cart loaded, \(items.count) items")
```

The lines go into a buffer that stays bounded however fast or long your app logs:

- **Repeats collapse.** A line identical to the one before (same level, source and text) is stored
  once, with `repeat` (how many times in all) and `last` (when the latest was).
- **At most 50 lines a second** enter (warnings and errors always do, up to 200 a second); past that
  they are counted and dropped, and one line (`1,204 lines dropped in 3 s (too fast)`) marks the gap.
  Redaction runs only on the lines that are kept, so a storm costs little.
- **2 MB and 20,000 lines.** When full, the oldest go first, debug and info before warnings and
  errors.
- **On disk** the buffer is kept as it goes (at most every five seconds, at once on an error), in two
  rotating files of at most 4 MB together, so the lines from before a crash survive it (see below).
- Collection **stops when the sheet opens**, so the sheet's own activity never fills it.

With `captureOSLog` on, the report also carries the app's **own** lines from this process's unified
log (`OSLogStore(scope: .currentProcessIdentifier)`) from the last five minutes before the sheet
opened: what your app logged through `Logger`, `os_log` and `NSLog` at info level and above, with
Apple's own subsystems (`com.apple.*`) left out, put through the same rules. It does not see `print`
(stdout is not the unified log), other processes, or anything from before this launch.

A report sends the logs in two parts. **`logs`** is the excerpt: every warning and error in the two
minutes before the report was opened, then the newest other lines, at most 500 and 256 KB. When the
buffer holds more than that, **`logFile`** is all of it as gzip-compressed NDJSON, at most 4 MB; when
it would be larger the oldest lines are cut and the file's first line says so. A report with a
screenshot still fits the 8 MB body: the log file shrinks to make room.

## After a crash

`start` opens a session and the library closes it when the app goes to the background or terminates
cleanly (on macOS, when it terminates). If the last session never closed, the next launch offers once,
from the library's own alert, "The app closed unexpectedly. Send a report?". **Send report** opens the
sheet with that session's saved logs and what is known about how it ended (`crash` in the report,
`trigger: relaunch`); **Not now** forgets it.

- An uncaught Objective-C exception is recorded by the library's own handler, which then calls
  whichever handler was installed before it, so your crash reporter still sees every one. No signal
  handlers are installed.
- MetricKit's `MXCrashDiagnostic` (iOS 14, macOS 12, visionOS) arrives at a later launch; it is
  matched to the session by time and adds the exception type, signal, termination reason and a short
  call stack.
- A session that ended with neither is reported as `unknown`: often the system ending the app for
  memory or a watchdog, which leaves nothing an app can read.

`offerReportAfterCrash: false` turns the offer off; `OverblastFeedback.previousSession` and
`previousSessionCrash` are there to build your own. On macOS an exception thrown on the main thread is
normally caught and logged by AppKit and does not end the app, so it never reaches the handler.

## The error prompt

When the key's owner turns it on, a small pill can appear after something goes wrong: "Something
may have gone wrong. Tell us?", with **Report** and a close button. It is never a dialog: on iOS,
iPadOS and visionOS it sits above the bottom safe area (and inside the side ones), in a window of
the library's own that lets every other touch through; on a Mac it is a small panel at the bottom
right of the window that never takes focus. It uses your app's tint, fades in (not with Reduce
Motion), stays about eight seconds (longer on a Mac while the pointer is over it), and VoiceOver
announces it politely. **Report** opens the sheet as a bug (`trigger: error_prompt`), with the
moment of the tap as `openedAt`, so the error is among the lines just before.

What counts, of the kinds the key lists:

- **exception**: an error your app logs as unexpected. An uncaught Objective-C exception ends the
  app before anything can be shown (it is reported at the next launch instead, see above), and Swift
  has no catchable equivalent, so the library cannot see your app's failures by itself. Mark the ones
  that should count:

  ```swift
  OverblastFeedback.error("Checkout failed: \(error)", unexpected: true)
  OverblastFeedback.log(.error, "Sync gave up", unexpected: true)
  ```

- **server_error**: a request to one of your `appHosts` answered 500 to 599 (never 4xx, which is
  usually the person's own input). **network**: a request to one of them that never answered. Both
  are seen only through the network recorder (`recordNetwork()`), and requests to the feedback
  service itself never count.

When it may appear: at least ten seconds after `start`; not while the person is typing, meaning the
software keyboard is up or text changed in a text field or text view in the last five seconds (a
field that merely has focus does not hold it back; it waits up to 30 seconds, then gives up); not while the report sheet, an alert or the
crash offer is up; only in the foreground. How often: at most once per session, at most once per the
key's `minHoursBetween` on the device, and after the person closes it twice without reporting, not
again for seven days. Two errors a second apart are one prompt. Each prompt is a line in the log
(`error prompt shown`, `error prompt dismissed`, `error prompt went by itself`, `error prompt:
reporting`), so a report says whether the person had been prompted.

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
`Question:`, `Feedback:`, and `Crash:` for a report about an unexpected end), tagged `feedback`, the
category and `ios`, and assigned to the group the key names, if any. The screenshot, the log file and
a `feedback-report.json` (element, logs, network, context) are attached to it.

**An email conversation is opened only when the report carries an email address**, yours via
`setReporter` or one the person typed. No mail is sent when the report arrives; the thread starts when
someone on your team replies from the task. Without an email there is nobody to answer and no
conversation.

## Shake, and what can hide it

On an iPhone or iPad, `start` replaces `-[UIWindow motionEnded:withEvent:]` once, so your app does
not have to subclass anything. The method is first added to `UIWindow` with the implementation it
inherits, and only that entry is replaced: every other responder keeps UIKit's own, and the original
is always called first, so your own shake handling still sees every shake. Two shakes within 1.5
seconds are one.

A shake reaches the window by travelling up the responder chain. A view or view controller that
overrides `motionEnded` without calling `super` swallows it, and then the sheet does not open; use
the button in such an app. `isShakeEnabled = false` (or `shakeToReport: false`) turns it off; with the
option off from the start, nothing is replaced at all. On visionOS, on a Mac, and for an iPhone or
iPad app running on a Mac or on Apple Vision Pro, nothing is ever replaced.

## Limitations

- **visionOS:** the screenshot is the app's own 2D window, drawn by `drawHierarchy`. Immersive spaces,
  volumes and RealityKit content are not in it, and neither is anything behind the window.
- **macOS:** the screenshot is the key window's content, drawn by the views themselves
  (`cacheDisplay`), so it needs no Screen Recording permission and can only ever show your own
  window: never the title bar, the desktop or another app. Content not drawn through the view
  hierarchy (Metal, video, web views' compositor layers, the translucency of sidebars and other
  `NSVisualEffectView`s) comes out flat or blank.
- **SwiftUI on macOS:** without `.overblastElement`, a click on SwiftUI-drawn text names only the
  hosting view and where; AppKit reports no accessibility element for it unless an assistive
  technology is running.

## Sample

`Samples/FeedbackSample` is a single SwiftUI file that compiles for iOS, visionOS and macOS: start,
the reporter, a private view, a secure field, a log line, the Settings button and the Help menu item.

## Changelog

### 0.2.0

- **visionOS** (button mode) and **macOS** (an AppKit sheet on the key window, the frozen window
  picture in a pointer sheet, the same API), alongside iOS and iPadOS.
- `OverblastFeedbackButton` and `OverblastFeedbackCommands` for button mode; `isShakeAvailable`;
  `shakeToReport` defaults to true only on iPhone and iPad.
- `context.os` says `iPadOS` on an iPad, `visionOS` and `macOS` where they apply.
- Reports carry `context.openedAt` and `context.trigger`, and collection stops when the sheet opens.
- Logs: repeats collapse, a per-second intake cap, a 2 MB / 20,000-line buffer with priority
  eviction, the excerpt, and the whole log as a gzip NDJSON `logFile`.
- The unified log keeps only the app's own lines (info and above, no `com.apple.*`).
- After an unexpected end: the session marker, the log kept on disk, the chained exception handler,
  MetricKit's crash diagnostic, and the offer at the next launch (`crash`, `trigger: relaunch`).
- The key's settings (`GET /v1/feedback/config`): categories, screenshots, the error prompt, verification;
  options can only turn them off.
- The error prompt, a pill after an unexpected error, a 5xx or a request with no answer from the
  app's own hosts.
- A privacy manifest.
- The sheet stays inside a sideways safe area (iPhone Duo's closed display, landscape).
- Sizes are decimal: the screenshot at most 5,000,000 bytes, the body 8,000,000.

### 0.1.0

- First release: shake-to-report on iOS, tap-to-select on a frozen screenshot, logs, the kept-report
  store.

## Licence

MIT.
