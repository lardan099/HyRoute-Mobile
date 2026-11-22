import NetworkExtension
import SwiftUI
import UIKit

private enum ProbeError: Error { case unavailable }

struct ProbeSnapshot: Decodable {
  struct Row: Decodable {
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

  init(snapshot: String, scope: String, id: String, journal: String, session: NETunnelProviderSession?) {
    self.snapshot = snapshot
    self.scope = scope
    self.id = id
    self.journal = journal
    self.session = session
  }

  func start() async throws -> ProbeSnapshot {
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
    List {
      if loading {
        ProgressView("Читаем журнал")
      } else if failed || lines.isEmpty {
        Text(failed ? "Не удалось прочитать журнал" : "Событий пока нет")
          .foregroundStyle(.secondary)
      } else {
        ForEach(lines.indices, id: \.self) { index in
          Text(lines[index]).textSelection(.enabled)
        }
      }
    }
    .navigationTitle("Журнал VPN")
    .refreshable { await load() }
    .task { await load() }
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

struct ProbePage: View {
  @ObservedObject var client: Client
  let scope: String
  let id: String
  @State private var run = 0
  @State private var snapshot: ProbeSnapshot?
  @State private var running = true
  @State private var failed = false

  var body: some View {
    let results = snapshot?.results ?? []
    List {
      Section {
        if running { ProgressView("Проверяем задержку") }
        if failed { Text("Не удалось проверить выбранные серверы").foregroundStyle(.secondary) }
        ForEach(results.indices, id: \.self) { index in
          let row = results[index]
          HStack {
            VStack(alignment: .leading, spacing: 4) {
              Text(row.name)
              if let host = row.host { Text(host).font(.subheadline).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(row.label).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
          }
        }
      } footer: {
        Text("HTTPS-запрос через каждый сервер")
      }
    }
    .navigationTitle("Задержка серверов")
    .navigationBarTitleDisplayMode(.inline)
    .task(id: run) { await measure() }
    .toolbar {
      Button { run += 1 } label: { Label("Повторить замер", systemImage: "arrow.clockwise") }
        .disabled(running)
    }
  }

  private func measure() async {
    running = true
    failed = false
    snapshot = nil
    defer { running = false }
    do {
      let probe = try await client.probeHandle(scope: scope, id: id)
      do {
        try Task.checkCancellation()
        var current = try await probe.start()
        while !Task.isCancelled {
          snapshot = current
          if current.done { break }
          try await Task.sleep(for: .milliseconds(400))
          current = try await probe.status()
        }
      } catch {
        await probe.cancel()
        throw error
      }
      await probe.cancel()
    } catch {
      if !Task.isCancelled { failed = true }
    }
  }
}
