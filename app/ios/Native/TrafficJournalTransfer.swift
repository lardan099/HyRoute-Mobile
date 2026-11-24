import Foundation

struct TrafficCommand: Codable {
  enum Action: String, Codable { case trafficStatus, trafficSet, trafficClear, vpnJournal, trafficChunk }
  let action: Action
  var enabled: Bool?
  var transfer: UUID?
  var offset: Int?
}

struct TrafficJournalTransfer {
  struct InvalidResponse: Error {}

  static let pageSize = 3 * 1024
  static let maximumSize = 48 * 1024
  let token: UUID
  private let snapshot: Data

  init?(token: UUID, snapshot: Data) {
    guard (1...Self.maximumSize).contains(snapshot.count) else { return nil }
    self.token = token
    self.snapshot = snapshot
  }

  // The leading byte is 0 when more data is available and 1 on the last page.
  func page(at offset: Int) -> Data? {
    guard offset >= 0, offset < snapshot.count, offset % Self.pageSize == 0 else { return nil }
    let end = min(offset + Self.pageSize, snapshot.count)
    var reply = Data([end == snapshot.count ? 1 : 0])
    reply.append(snapshot.subdata(in: offset..<end))
    return reply
  }

  static func read(first: Data, next: (Int) async throws -> Data) async throws -> Data {
    if first.first == UInt8(ascii: "[") {
      // An already-running extension from the previous version can still send a raw array.
      guard first.count <= maximumSize else { throw InvalidResponse() }
      return first
    }

    var page = first
    var result = Data()
    while true {
      try Task.checkCancellation()
      guard let last = page.first, last == 0 || last == 1,
            (2...(pageSize + 1)).contains(page.count),
            result.count + page.count - 1 <= maximumSize else { throw InvalidResponse() }
      result.append(contentsOf: page.dropFirst())
      if last == 1 { return result }
      guard page.count == pageSize + 1, result.count < maximumSize else { throw InvalidResponse() }
      page = try await next(result.count)
    }
  }
}
