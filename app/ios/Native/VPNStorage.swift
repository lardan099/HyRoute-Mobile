import Foundation

enum VPNStorage {
  private static var sharedDirectory: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.io.hyroute.mobile")
  }

  static var sharedGeodata: URL? {
    sharedDirectory?.appendingPathComponent("geo", isDirectory: true)
  }

  static var tunnelJournal: String {
    sharedDirectory?.appendingPathComponent("tunnel-journal.json").path ?? ""
  }

  static func providerJournal() -> String {
    let files = FileManager.default
    if let sharedDirectory, files.isWritableFile(atPath: sharedDirectory.path) {
      return tunnelJournal
    }
    guard let cache = files.urls(for: .cachesDirectory, in: .userDomainMask).first else { return "" }
    try? files.createDirectory(at: cache, withIntermediateDirectories: true)
    return cache.appendingPathComponent("tunnel-journal.json").path
  }

  private static var recoveryDirectory: URL? {
    sharedDirectory?.appendingPathComponent("VPN Recovery", isDirectory: true)
  }

  private static var recoveryFile: URL? {
    recoveryDirectory?.appendingPathComponent("state.json")
  }

  static var canRecover: Bool { recoveryDirectory != nil }

  static func recoveryState() -> String? {
    guard let file = recoveryFile else { return nil }
    return try? String(contentsOf: file, encoding: .utf8)
  }

  static func saveRecoveryState(_ raw: String, create: Bool) throws {
    guard var directory = recoveryDirectory, let file = recoveryFile else {
      if !create { return }
      throw CocoaError(.fileNoSuchFile)
    }
    let files = FileManager.default
    if !create && !files.fileExists(atPath: file.path) { return }
    guard let snapshot = HyRouteRecoveryState(raw) else { throw CocoaError(.fileWriteUnknown) }
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    try Data(snapshot.utf8).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }

  static func clearRecoveryState() throws {
    guard let file = recoveryFile else { return }
    do { try FileManager.default.removeItem(at: file) }
    catch let error as CocoaError where error.code == .fileNoSuchFile { }
  }

  static func prepareGeodata(legacy: URL) throws -> URL {
    guard let directory = sharedGeodata else { return legacy }
    let files = FileManager.default
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in ["geoip.dat", "geosite.dat", "geo.json", "mobile-geo.json"] {
      let source = legacy.appendingPathComponent(name)
      let destination = directory.appendingPathComponent(name)
      if files.fileExists(atPath: source.path) && !files.fileExists(atPath: destination.path) {
        try files.copyItem(at: source, to: destination)
      }
    }
    return directory
  }
}

struct ProbeCommand: Codable {
  enum Action: String, Codable { case start, status, cancel }
  let action: Action
  let token: UUID
  var scope: String?
  var id: String?
  var state: String?
}

struct TrafficCommand: Codable {
  enum Action: String, Codable { case trafficStatus, trafficSet, trafficClear, vpnJournal }
  let action: Action
  var enabled: Bool?
}
