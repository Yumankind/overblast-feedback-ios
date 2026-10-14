import Foundation

/// The install's random id and the facts about the device that go in `context`.
public enum DeviceInfo {
  public static let sdkName = "overblast-feedback-ios"
  public static let sdkVersion = "0.1.0"

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

  public static var osName: String {
    #if os(iOS)
    #if targetEnvironment(macCatalyst)
    return "macOS"
    #else
    return ProcessInfo.processInfo.isiOSAppOnMac ? "macOS" : "iOS"
    #endif
    #elseif os(visionOS)
    return "visionOS"
    #elseif os(macOS)
    return "macOS"
    #else
    return "unknown"
    #endif
  }

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
