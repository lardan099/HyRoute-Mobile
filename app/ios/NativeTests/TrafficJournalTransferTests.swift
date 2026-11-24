import Foundation

@main
struct TrafficJournalTransferTests {
  struct Event: Codable, Equatable {
    let id: Int
    let profile: String
    let destination: String
  }

  static func main() async throws {
    let events = (1...120).map {
      Event(id: $0, profile: String(repeating: "Франкфурт 🌍 ", count: 9),
            destination: "server-\($0).example.test:443")
    }
    let payload = try JSONEncoder().encode(events)
    precondition(payload.count > 5 * TrafficJournalTransfer.pageSize)
    let token = UUID()
    let transfer = TrafficJournalTransfer(token: token, snapshot: payload)!
    precondition(transfer.token == token)
    precondition(transfer.page(at: -1) == nil && transfer.page(at: 1) == nil)
    precondition(transfer.page(at: TrafficJournalTransfer.maximumSize) == nil)

    let messageLimit = 4096
    precondition(payload.count > messageLimit)
    var requests = 0
    let restored = try await TrafficJournalTransfer.read(first: transfer.page(at: 0)!) { offset in
      requests += 1
      precondition(offset == requests * TrafficJournalTransfer.pageSize)
      let reply = transfer.page(at: offset)!
      precondition(reply.count <= messageLimit)
      return reply
    }
    precondition(restored == payload && requests > 1)
    let decoded = try JSONDecoder().decode([Event].self, from: restored)
    precondition(decoded == events)

    let previousVersion = Data("[]".utf8)
    let legacy = try await TrafficJournalTransfer.read(first: previousVersion) { _ in
      preconditionFailure("Legacy replies must not fetch another page")
    }
    precondition(legacy == previousVersion)

    do {
      _ = try await TrafficJournalTransfer.read(first: transfer.page(at: 0)!) { _ in Data() }
      preconditionFailure("An incomplete snapshot must not be shown")
    } catch is TrafficJournalTransfer.InvalidResponse {}

    print("Traffic journal transfer tests passed")
  }
}
