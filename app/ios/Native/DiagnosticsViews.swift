import NetworkExtension
import SwiftUI
import UIKit

private enum ProbeError: Error { case unavailable }

struct ProbeSnapshot: Decodable {
  struct Row: Decodable {
    let profileId: String
    let name: String
    let host: String?
    let status: String
    let ms: Int?

    var label: String {
      switch status {
      case "ok": return "\(ms ?? 0) мс"
      case "pending": return "В очереди"
      case "running": return "Проверка…"
      case "timeout": return "Тайм-аут"
      case "dns": return "Ошибка DNS"
      case "configuration": return "Ошибка профиля"
      case "response": return "Ответ не 204"
      case "cancelled": return "Отменено"
      default: return "Нет соединения"
      }
    }
  }

  let done: Bool
  let results: [Row]
}

@MainActor
final class ProbeHandle {
  private let token = UUID()
  private let snapshot: String
  private let scope: String
  private let id: String
  private let journal: String
  private let session: NETunnelProviderSession?
  private var localProbe: NSObject?
  #if targetEnvironment(simulator)
  var simulatorResult: ProbeSnapshot?
  #endif

  init(snapshot: String, scope: String, id: String, journal: String, session: NETunnelProviderSession?) {
    self.snapshot = snapshot
    self.scope = scope
    self.id = id
    self.journal = journal
    self.session = session
  }

  func start() async throws -> ProbeSnapshot {
    #if targetEnvironment(simulator)
    if let simulatorResult { return simulatorResult }
    #endif
    if let session {
      let data = try await send(ProbeCommand(action: .start, token: token, scope: scope, id: id, state: snapshot), to: session)
      return try JSONDecoder().decode(ProbeSnapshot.self, from: data)
    }
    localProbe = HyRouteStartProbe(snapshot, scope, id, journal)
    return try await status()
  }

  func status() async throws -> ProbeSnapshot {
    if let session {
      let data = try await send(ProbeCommand(action: .status, token: token), to: session)
      return try JSONDecoder().decode(ProbeSnapshot.self, from: data)
    }
    guard let localProbe, let status = HyRouteProbeSnapshot(localProbe) else { throw ProbeError.unavailable }
    return try JSONDecoder().decode(ProbeSnapshot.self, from: Data(status.utf8))
  }

  func cancel() async {
    if let session {
      _ = try? await send(ProbeCommand(action: .cancel, token: token), to: session)
    } else if let localProbe {
      HyRouteCancelProbe(localProbe)
      self.localProbe = nil
    }
  }

  private func send(_ command: ProbeCommand, to session: NETunnelProviderSession) async throws -> Data {
    let message = try JSONEncoder().encode(command)
    return try await withCheckedThrowingContinuation { continuation in
      do {
        try session.sendProviderMessage(message) { response in
          if let response { continuation.resume(returning: response) }
          else { continuation.resume(throwing: ProbeError.unavailable) }
        }
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}

struct VPNJournalPage: View {
  @ObservedObject var client: Client
  @State private var lines: [String] = []
  @State private var loading = true
  @State private var failed = false

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 0) {
        if loading {
          ProgressView("Читаем журнал").padding(12)
        } else if failed || lines.isEmpty {
          HyRow(title: failed ? "Не удалось прочитать журнал" : "Событий пока нет",
                symbol: "list.bullet.rectangle", disclosure: false)
            .padding(12)
        } else {
          ForEach(lines.indices, id: \.self) { index in
            let line = lines[index]
            let split = line.range(of: "  ")
            VStack(alignment: .leading, spacing: 5) {
              if let split {
                Text(line[..<split.lowerBound]).font(.caption.monospacedDigit().weight(.medium))
                  .foregroundStyle(HyStyle.muted)
              }
              Text(split.map { String(line[$0.upperBound...]) } ?? line)
                .font(.body.weight(.medium)).foregroundStyle(HyStyle.ink)
                .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            if index < lines.count - 1 { Divider().overlay(HyStyle.stroke).padding(.horizontal, 12) }
          }
        }
      }
      .hyCard(padding: 0)
      .padding(16)
    }
    .hyScreen()
    .navigationTitle("Журнал VPN")
    .navigationBarTitleDisplayMode(.inline)
    .refreshable { await load() }
    .task {
      while !Task.isCancelled {
        await load()
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
      }
    }
    .toolbar {
      Button { UIPasteboard.general.string = lines.joined(separator: "\n") } label: {
        Label("Копировать журнал", systemImage: "doc.on.doc")
      }
      .disabled(lines.isEmpty)
    }
  }

  private func load() async {
    do {
      lines = try await client.journal()
      failed = false
    } catch {
      failed = true
    }
    loading = false
  }
}
