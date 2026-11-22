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
