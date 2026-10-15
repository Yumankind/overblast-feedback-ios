import Foundation

/// The install's random id and the facts about the device that go in `context`.
public enum DeviceInfo {
  public static let sdkName = "overblast-feedback-ios"
  public static let sdkVersion = "0.2.0"

  /// The `UserDefaults` suite the device id lives in. A suite of its own, so an app that clears its
  /// standard defaults on sign-out does not make every report look like a new device.
  public static let defaultsSuite = "network.deployd.overblast-feedback"
  static let deviceIdKey = "deviceId"

  /// A random id kept per install: 32 lowercase hex characters, made on first use. It identifies
  /// nothing about the person or the hardware; it lets the worker count reports per device (§4)
  /// instead of per IP, which a whole office shares. Reinstalling the app makes a new one.
  public static func deviceId(defaults: UserDefaults? = nil) -> String {
    let store = defaults ?? UserDefaults(suiteName: defaultsSuite) ?? .standard
    if let existing = store.string(forKey: deviceIdKey), FeedbackText.isValidDeviceId(existing) {
      return existing
    }
    let fresh = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    store.set(fresh, forKey: deviceIdKey)
    return fresh
  }

  /// The hardware model identifier: `iPhone15,3`, `iPad13,4`, `Mac14,2`. On the simulator, the
  /// model it simulates.
  public static func modelIdentifier() -> String {
    if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !simulated.isEmpty {
      return simulated
    }
    #if os(macOS)
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    if size > 0 {
      var buffer = [CChar](repeating: 0, count: size)
      sysctlbyname("hw.model", &buffer, &size, nil, 0)
      let model = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      if !model.isEmpty { return model }
    }
    #endif
    var info = utsname()
    uname(&info)
    return withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  /// Where this process is running, which is not always what it was compiled for: an iPhone or iPad
  /// app also runs on a Mac with Apple silicon and on Apple Vision Pro.
  public enum Runtime: String, Sendable, CaseIterable {
    /// An iOS build on an iPhone, iPad or iPod touch, or on their simulators.
    case iOS
    /// A Mac Catalyst build.
    case macCatalyst
    /// An unmodified iPhone or iPad app on a Mac with Apple silicon ("Designed for iPad").
    case iOSAppOnMac
    /// An unmodified iPhone or iPad app on Apple Vision Pro ("Designed for iPad" on visionOS).
    case iOSAppOnVision
    /// A native visionOS build.
    case visionOS
    /// A native macOS (AppKit) build.
    case macOS
  }

  public static var runtime: Runtime {
    #if os(iOS)
    #if targetEnvironment(macCatalyst)
    return .macCatalyst
    #else
    if ProcessInfo.processInfo.isiOSAppOnMac { return .iOSAppOnMac }
    if isiOSAppOnVision { return .iOSAppOnVision }
    return .iOS
    #endif
    #elseif os(visionOS)
    return .visionOS
    #else
    return .macOS
    #endif
  }

  /// `ProcessInfo.isiOSAppOnVision` arrived with the iOS 26.1 SDK. Asked by selector rather than by
  /// name, so the package still compiles against an older SDK and answers false on an older system.
  static var isiOSAppOnVision: Bool {
    let info = ProcessInfo.processInfo
    guard info.responds(to: NSSelectorFromString("isiOSAppOnVision")) else { return false }
    return (info.value(forKey: "isiOSAppOnVision") as? Bool) ?? false
  }

  /// `context.os`: `iOS`, `iPadOS`, `visionOS` or `macOS`.
  public static var osName: String { osName(runtime: runtime, model: modelIdentifier()) }

  /// The system's own name for where the app runs. An iPad says iPadOS, because that is what its
  /// owner calls it and what a team filters by; an iPhone app on a Mac or on Apple Vision Pro says the
  /// system it is actually on. `context.platform` stays `ios` in every case (contract §3.1).
  public static func osName(runtime: Runtime, model: String) -> String {
    switch runtime {
    case .iOS: return model.hasPrefix("iPad") ? "iPadOS" : "iOS"
    case .macCatalyst, .iOSAppOnMac, .macOS: return "macOS"
    case .iOSAppOnVision, .visionOS: return "visionOS"
    }
  }

  /// True only where shaking the device reaches the app: an iPhone or iPad. A Mac has no motion
  /// events, and Apple Vision Pro delivers none to apps, so there the sheet opens from a button.
  public static var deliversShake: Bool { deliversShake(on: runtime) }

  public static func deliversShake(on runtime: Runtime) -> Bool { runtime == .iOS }

  public static var osVersion: String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
  }

  /// `CFBundleShortVersionString` and `CFBundleVersion` of the main bundle.
  public static func appVersion(bundle: Bundle = .main) -> (version: String?, build: String?) {
    (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
     bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
  }

  /// A BCP 47 tag (`pt-PT`), not Foundation's underscore form.
  public static var localeIdentifier: String {
    let preferred = Locale.preferredLanguages.first
    return preferred ?? Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
  }

  /// The base context: everything that does not need a screen. The UI half adds the screen, the
  /// title and the viewport.
  public static func baseContext(deviceId: String?, extra: [String: String]?) -> FeedbackContext {
    let app = appVersion()
    return FeedbackContext(
      platform: "ios",
      appVersion: app.version,
      build: app.build,
      os: osName,
      osVersion: osVersion,
      device: modelIdentifier(),
      locale: localeIdentifier,
      timeZone: TimeZone.current.identifier,
      sdk: FeedbackSDK(name: sdkName, version: sdkVersion),
      deviceId: deviceId,
      extra: (extra?.isEmpty ?? true) ? nil : extra
    )
  }
}
