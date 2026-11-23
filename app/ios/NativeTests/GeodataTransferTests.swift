import Foundation

@main
struct GeodataTransferTests {
  static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let app = root.appendingPathComponent("app")
    let sandbox = root.appendingPathComponent("extension")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = app.appendingPathComponent(GeodataKind.geosite.filename)
    let destination = sandbox.appendingPathComponent(GeodataKind.geosite.filename)
    let receiver = GeodataReceiver(directory: sandbox)
    let first = Data(repeating: 0x34, count: GeodataTransfer.chunkSize * 2 + 1)
    let replacement = Data(repeating: 0x78, count: first.count)
    try first.write(to: source)
    var chunks = 0
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    func exchange(_ command: GeodataTransfer) throws -> GeodataTransfer.Reply {
      let message = try encoder.encode(command)
      precondition(message.count <= 64 * 1024)
      let decoded = try PropertyListDecoder().decode(GeodataTransfer.self, from: message)
      if decoded.action == .append { chunks += 1 }
      guard let reply = receiver.receive(decoded) else { throw CocoaError(.fileReadCorruptFile) }
      return reply
    }

    try await GeodataTransfer.send(.geosite, from: app, exchange: exchange)
    let received = try Data(contentsOf: destination)
    precondition(received == first && chunks == 3)
    try await GeodataTransfer.send(.geosite, from: app, exchange: exchange)
    precondition(chunks == 3)

    try replacement.write(to: source)
    do {
      try await GeodataTransfer.send(.geosite, from: app) { command in
        var damaged = command
        if var chunk = command.chunk, !chunk.isEmpty {
          chunk[0] ^= 0x1
          damaged.chunk = chunk
        }
        return try exchange(damaged)
      }
      preconditionFailure("corrupted data was accepted")
    } catch let error as CocoaError where error.code == .fileReadCorruptFile {}
    let unchanged = try Data(contentsOf: destination)
    precondition(unchanged == first)
    precondition(!FileManager.default.fileExists(atPath: sandbox.appendingPathComponent(".incoming").path))

    try await GeodataTransfer.send(.geosite, from: app, exchange: exchange)
    let updated = try Data(contentsOf: destination)
    precondition(updated == replacement)
    try FileManager.default.removeItem(at: source)
    try await GeodataTransfer.send(.geosite, from: app, exchange: exchange)
    precondition(!FileManager.default.fileExists(atPath: destination.path))
    print("Geodata transfer tests passed")
  }
}
