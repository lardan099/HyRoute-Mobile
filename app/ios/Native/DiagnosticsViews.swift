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
    return try await session.hyRouteMessage(message)
  }
}

extension NETunnelProviderSession {
  func hyRouteMessage(_ message: Data) async throws -> Data {
    return try await withCheckedThrowingContinuation { continuation in
      do {
        try sendProviderMessage(message) { response in
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

struct TrafficEvent: Decodable, Identifiable {
  let id: UInt64
  let flow: UInt32
  let time: Int64
  let stage: String
  let destination: String
  let profile: String
  let rule: String?
  let error: String?

  var date: Date { Date(timeIntervalSince1970: Double(time) / 1000) }

  var title: String {
    switch stage {
    case "hop": return "Узел цепочки"
    case "blocked": return "Заблокировано"
    case "dialError": return "Ошибка соединения"
    case "error": return "Ошибка передачи"
    default: return "Маршрут"
    }
  }

  var detail: String { [profile, rule, error].compactMap { $0 }.joined(separator: " · ") }
}

struct TrafficJournalPage: View {
  @ObservedObject var client: Client
  @State private var search = ""
  @State private var onlyErrors = false
  @State private var writing = false
  @State private var issue: String?

  private var visible: [TrafficEvent] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return client.trafficEvents.filter { event in
      (!onlyErrors || event.error != nil || event.stage == "blocked") &&
        (query.isEmpty || [event.destination, event.detail, String(event.flow)].contains {
          $0.localizedCaseInsensitiveContains(query)
        })
    }
  }

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 12) {
        VStack(alignment: .leading, spacing: 10) {
          Toggle("Запись подключений", isOn: Binding(
            get: { client.trafficLogging },
            set: { enabled in Task { await perform { try await client.setTrafficLogging(enabled) } } }
          ))
          .accessibilityIdentifier("trafficLogging")
          .disabled(writing)
          Text("Адреса хранятся в памяти VPN. После остановки доступны записи, которые уже открыло приложение.")
            .font(.footnote).foregroundStyle(HyStyle.muted)
          if let issue { Text(issue).font(.footnote).foregroundStyle(HyStyle.failure) }
        }
        .hyCard()

        Picker("События", selection: $onlyErrors) {
          Text("Все").tag(false)
          Text("Ошибки и блокировки").tag(true)
        }
        .pickerStyle(.segmented)

        if visible.isEmpty {
          Text(emptyMessage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(HyStyle.muted)
            .hyCard()
        } else {
          ForEach(visible) { event in
            VStack(alignment: .leading, spacing: 4) {
              Text(event.destination).font(.body.weight(.semibold))
              Text(event.detail).font(.subheadline).foregroundStyle(HyStyle.ink)
              Text("\(event.date.formatted(date: .omitted, time: .standard)) · \(event.title) · #\(event.flow)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(event.error == nil ? HyStyle.muted : HyStyle.failure)
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hyCard(padding: 12)
          }
        }
      }
      .padding(16)
    }
    .hyScreen()
    .navigationTitle("Журнал подключений")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $search, prompt: "Адрес, профиль или номер")
    .task(id: client.vpnStatus) {
      guard client.vpnStatus == .connected else { return }
      while !Task.isCancelled {
        if !writing {
          do { try await client.refreshTrafficLog(); issue = nil }
          catch { if !Task.isCancelled { issue = "VPN не ответил на запрос журнала." } }
        }
        do { try await Task.sleep(for: .seconds(2)) } catch { return }
      }
    }
    .toolbar {
      Menu {
        Button {
          UIPasteboard.general.string = visible.map {
            "\($0.date.formatted()) · #\($0.flow) · \($0.title) · \($0.destination) · \($0.detail)"
          }.joined(separator: "\n")
        } label: {
          Label("Копировать записи", systemImage: "doc.on.doc")
        }
        .disabled(visible.isEmpty)
        Button(role: .destructive) {
          Task { await perform { try await client.clearTrafficLog() } }
        } label: {
          Label("Очистить журнал", systemImage: "trash")
        }
        .disabled(writing || client.trafficEvents.isEmpty)
      } label: {
        Label("Действия с журналом", systemImage: "ellipsis.circle")
      }
    }
  }

  private var emptyMessage: String {
    if !client.trafficLogging { return "Включите запись подключений." }
    if client.vpnStatus != .connected { return "Подключите VPN, чтобы увидеть события." }
    return search.isEmpty && !onlyErrors ? "Откройте сайт или приложение. Здесь появится его маршрут." :
      "Под фильтр ничего не попало."
  }

  private func perform(_ operation: () async throws -> Void) async {
    guard !writing else { return }
    writing = true
    defer { writing = false }
    do { try await operation(); issue = nil }
    catch { issue = "Не удалось изменить журнал. Повторите после подключения VPN." }
  }
}
