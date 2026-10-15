import Foundation
import XCTest

/// Defaults that live in memory and never reach cfprefsd.
///
/// The tests used to make a real suite per test with `UserDefaults(suiteName:)`, and each one is a plist
/// in ~/Library/Preferences. Deskslap found about ninety left behind. Emptying the domains and deleting
/// the files did not hold either: cfprefsd writes them back on its own schedule, sometimes as the test
/// process exits, after any cleanup a test can run. So nothing here touches the real store.
///
/// The library calls `object`, `string`, `data` and `set` on the defaults it is handed, and the
/// migration reads, replaces and removes whole domains by name on the `domains` defaults; those are
/// the calls overridden, all against one shared `Store`, so a suite and the domains view of the same
/// store agree the way real defaults do.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
  final class Store: @unchecked Sendable {
    private let lock = NSLock()
    private var domains: [String: [String: Any]] = [:]

    func values(_ name: String) -> [String: Any]? { lock.withLock { domains[name] } }
    func replace(_ name: String, with values: [String: Any]?) { lock.withLock { domains[name] = values } }
    func update(_ name: String, _ change: (inout [String: Any]) -> Void) {
      lock.withLock {
        var values = domains[name] ?? [:]
        change(&values)
        domains[name] = values.isEmpty ? nil : values
      }
    }
  }

  let store: Store
  /// The suite this view reads and writes; nil for the domains view, which only answers by name.
  let name: String?

  init?(store: Store, name: String?) {
    self.store = store
    self.name = name
    // A nil suite name gives the process's own search list; nothing below reads from it.
    super.init(suiteName: nil)
  }

  /// A suite of its own, in a store of its own: the common case.
  static func suite(_ name: String = "scratch") -> MemoryDefaults {
    MemoryDefaults(store: Store(), name: name)!
  }

  func suite(_ name: String) -> MemoryDefaults { MemoryDefaults(store: store, name: name)! }
  var domainsView: MemoryDefaults { MemoryDefaults(store: store, name: nil)! }

  override func object(forKey defaultName: String) -> Any? {
    guard let name else { return nil }
    return store.values(name)?[defaultName]
  }
  override func set(_ value: Any?, forKey defaultName: String) {
    guard let name else { return }
    store.update(name) { $0[defaultName] = value }
  }
  override func removeObject(forKey defaultName: String) { set(nil, forKey: defaultName) }
  override func set(_ value: Int, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
  override func set(_ value: Double, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
  override func set(_ value: Float, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
  override func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
  override func set(_ url: URL?, forKey defaultName: String) { set(url as Any?, forKey: defaultName) }
  override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
  override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
  override func array(forKey defaultName: String) -> [Any]? { object(forKey: defaultName) as? [Any] }
  override func dictionary(forKey defaultName: String) -> [String: Any]? { object(forKey: defaultName) as? [String: Any] }
  override func integer(forKey defaultName: String) -> Int { (object(forKey: defaultName) as? NSNumber)?.intValue ?? 0 }
  override func double(forKey defaultName: String) -> Double { (object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0 }
  override func bool(forKey defaultName: String) -> Bool { (object(forKey: defaultName) as? NSNumber)?.boolValue ?? false }
  override func url(forKey defaultName: String) -> URL? { object(forKey: defaultName) as? URL }

  override func persistentDomain(forName domainName: String) -> [String: Any]? { store.values(domainName) }
  override func setPersistentDomain(_ domain: [String: Any], forName domainName: String) { store.replace(domainName, with: domain) }
  override func removePersistentDomain(forName domainName: String) { store.replace(domainName, with: nil) }
  override func synchronize() -> Bool { true }
}

extension XCTestCase {
  /// A defaults suite of this test's own, in memory (see `MemoryDefaults`). The prefix only names it.
  func scratchDefaults(_ prefix: String = "obf-tests") -> UserDefaults {
    MemoryDefaults.suite(prefix)
  }
}
