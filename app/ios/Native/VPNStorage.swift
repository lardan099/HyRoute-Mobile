import Foundation

enum VPNStorage {
  static var sharedGeodata: URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.io.hyroute.mobile")?
      .appendingPathComponent("geo", isDirectory: true)
  }

  static func prepareGeodata(legacy: URL) throws -> URL {
    guard let directory = sharedGeodata else { return legacy }
    let files = FileManager.default
    try files.createDirectory(at: directory, withIntermediateDirectories: true)
    for name in ["geoip.dat", "geosite.dat", "geo.json"] {
      let source = legacy.appendingPathComponent(name)
      let destination = directory.appendingPathComponent(name)
      if files.fileExists(atPath: source.path) && !files.fileExists(atPath: destination.path) {
        try files.copyItem(at: source, to: destination)
      }
    }
    return directory
  }
}
