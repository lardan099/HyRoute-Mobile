import Foundation

@main
struct GeodataTransferTests {
  static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let sandbox = root.appendingPathComponent("extension")
    defer { try? FileManager.default.removeItem(at: root) }
    let receiver = GeodataReceiver(directory: sandbox)
    let destination = receiver.archive
    let inline = Data(repeating: 0x42, count: GeodataTransfer.inlineLimit)
    let options: [String: NSObject] = ["state": "fixture" as NSString, "geoSnapshot": inline as NSData]
    let encodedOptions = try PropertyListSerialization.data(fromPropertyList: options, format: .binary, options: 0)
    let decodedOptions = try PropertyListSerialization.propertyList(from: encodedOptions, format: nil) as? [String: Any]
    precondition((decodedOptions?["geoSnapshot"] as? Data) == inline)
    let first = Data(repeating: 0x34, count: GeodataTransfer.chunkSize * 2 + 1)
    let replacement = Data(repeating: 0x78, count: first.count)
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

    try await GeodataTransfer.sendSnapshot(first, token: UUID(), exchange: exchange)
    let received = try Data(contentsOf: destination)
    precondition(received == first && chunks == 3)
    try await GeodataTransfer.sendSnapshot(first, token: UUID(), exchange: exchange)
    precondition(chunks == 3)

    do {
      try await GeodataTransfer.sendSnapshot(replacement, token: UUID()) { command in
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

    try await GeodataTransfer.sendSnapshot(replacement, token: UUID(), exchange: exchange)
    let updated = try Data(contentsOf: destination)
    precondition(updated == replacement)
    print("Geodata transfer tests passed")
  }
}
