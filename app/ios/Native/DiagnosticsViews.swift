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

  static func groupLabel(_ rows: [Row]) -> String {
    if rows.contains(where: { ["running", "pending"].contains($0.status) }) { return "Проверка узлов…" }
    let values = rows.compactMap(\.ms)
    if let best = values.min() { return "\(values.count) из \(rows.count) · от \(best) мс" }
    return "Узлы не ответили"
  }
}

@MainActor
final class SubscriptionMeasurements: ObservableObject {
  struct Request {
    let token = UUID()
    let subscriptionID: String
    let scope: String
    let target: String
    let previousResults: [String: [ProbeSnapshot.Row]]
  }

  @Published private(set) var request: Request?
  @Published private(set) var results: [String: [ProbeSnapshot.Row]] = [:]
  @Published private(set) var failedSubscription: String?

  func start(_ subscription: Subscription, profile: VPNProfile? = nil) {
    guard request == nil else { return }
    failedSubscription = nil
    let previous = results
    let targets = Set(profile.map { [$0.id] } ?? subscription.servers.map(\.id))
    results = results.filter { !targets.contains($0.key) }
    request = Request(subscriptionID: subscription.id, scope: profile == nil ? "subscription" : "profile",
                      target: profile?.id ?? subscription.id, previousResults: previous)
  }

  func cancel() {
    guard let request else { return }
    let completed = results.compactMapValues { rows -> [ProbeSnapshot.Row]? in
      let final = rows.filter { !["pending", "running"].contains($0.status) }
      return final.isEmpty ? nil : final
    }
    results = request.previousResults.merging(completed) { _, newer in newer }
    self.request = nil
  }

  func run(_ task: Request, using client: Client) async {
    defer {
      if request?.token == task.token {
        if Task.isCancelled { cancel() }
        else { request = nil }
      }
    }
    do {
      let handle = try await client.probeHandle(scope: task.scope, id: task.target)
      do {
        try Task.checkCancellation()
        var current = try await handle.start()
        while !Task.isCancelled && request?.token == task.token {
          results.merge(Dictionary(grouping: current.results, by: \.profileId)) { _, updated in updated }
          if current.done { break }
          try await Task.sleep(for: .milliseconds(400))
          current = try await handle.status()
        }
      } catch {
        await handle.cancel()
        throw error
      }
      await handle.cancel()
    } catch {
      if !Task.isCancelled && request?.token == task.token {
        cancel()
        failedSubscription = task.subscriptionID
      }
    }
  }
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
  var simulatorDelay: Duration = .zero
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
    if let simulatorResult {
      if simulatorDelay > .zero { try await Task.sleep(for: simulatorDelay) }
      return simulatorResult
    }
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
  @State private var events: [VPNJournalEvent] = []
  @State private var loading = true
  @State private var failed = false

  var body: some View {
    let calendar = Calendar.autoupdatingCurrent
    let days = Dictionary(grouping: events) { calendar.startOfDay(for: $0.date) }
    return List {
      if loading { ProgressView("Читаем журнал") }
      if failed || (!loading && events.isEmpty) {
        Label(failed ? "Не удалось прочитать журнал" : "Событий пока нет",
              systemImage: failed ? "exclamationmark.circle" : "clock")
          .foregroundStyle(failed ? HyStyle.failure : HyStyle.muted)
          .listRowBackground(HyStyle.surface)
      }
      ForEach(days.keys.sorted(by: >), id: \.self) { day in
        Section {
          ForEach(days[day] ?? [], id: \.self) { event in
            VStack(alignment: .leading, spacing: 5) {
              Text(event.date.formatted(date: .omitted, time: .standard))
                .font(.caption.monospacedDigit()).foregroundStyle(HyStyle.muted)
              Text(event.message).font(.body).foregroundStyle(HyStyle.ink).textSelection(.enabled)
            }
            .padding(.vertical, 4)
            .listRowBackground(HyStyle.surface)
          }
        } header: {
          Text(day.formatted(date: .abbreviated, time: .omitted))
        }
      }
    }
    .hyList()
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
      Button { UIPasteboard.general.string = VPNJournalEvent.lines(events).joined(separator: "\n") } label: {
        Label("Копировать журнал", systemImage: "doc.on.doc")
      }
      .disabled(events.isEmpty)
      .accessibilityIdentifier("vpn-journal-copy")
    }
  }

  private func load() async {
    do {
      events = try await client.journal()
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
  var isProblem: Bool { error != nil || ["blocked", "dialError", "error"].contains(stage) }
}

struct TrafficJournalPage: View {
  @ObservedObject var client: Client
  @State private var search = ""
  @State private var onlyErrors = false
  @State private var writing = false
  @State private var issue: String?
  @State private var readFailed = false
  @State private var confirmingClear = false

  private var visible: [TrafficEvent] {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    return client.trafficEvents.filter { event in
      (!onlyErrors || event.isProblem) &&
        (query.isEmpty || [event.destination, event.detail, String(event.flow)].contains {
          $0.localizedCaseInsensitiveContains(query)
        })
    }
  }

  var body: some View {
    let events = visible
    return List {
      Section {
        VStack(alignment: .leading, spacing: 6) {
          Toggle("Запись подключений", isOn: Binding(
            get: { client.trafficLogging },
            set: { enabled in Task { await perform { try await client.setTrafficLogging(enabled) } } }
          ))
          .accessibilityIdentifier("trafficLogging")
          .disabled(writing)
          Text("Адреса хранятся в памяти VPN. После остановки доступны записи, которые уже открыло приложение.")
            .font(.footnote).foregroundStyle(HyStyle.muted)
          if let issue { Text(issue).font(.footnote).foregroundStyle(HyStyle.failure) }
          if readFailed {
            Text("VPN не ответил на запрос журнала.").font(.footnote).foregroundStyle(HyStyle.failure)
          }
        }
        .padding(.vertical, 4)
        Button { onlyErrors.toggle() } label: {
          Label("Только ошибки и блокировки", systemImage: onlyErrors ? "checkmark.circle.fill" : "line.3.horizontal.decrease.circle")
            .frame(minHeight: 44, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("traffic-only-errors")
        .accessibilityAddTraits(onlyErrors ? .isSelected : [])
      }
      .listRowBackground(HyStyle.surface)
      Section("События") {
        if events.isEmpty {
          Text(emptyMessage).foregroundStyle(HyStyle.muted)
            .accessibilityIdentifier("traffic-empty")
        } else {
          ForEach(events) { event in
            VStack(alignment: .leading, spacing: 5) {
              Text("\(event.date.formatted(date: .omitted, time: .standard)) · \(event.title) · #\(event.flow)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(event.isProblem ? HyStyle.failure : HyStyle.muted)
              Text(event.destination).font(.body.weight(.semibold))
              if !event.profile.isEmpty { Text("Профиль · \(event.profile)").foregroundStyle(HyStyle.muted).font(.subheadline) }
              if let rule = event.rule, !rule.isEmpty {
                Text("Правило · \(rule)").foregroundStyle(HyStyle.muted).font(.subheadline)
              }
              if let error = event.error, !error.isEmpty {
                Text(error).foregroundStyle(HyStyle.failure).font(.subheadline)
              }
            }
            .textSelection(.enabled)
            .padding(.vertical, 4)
          }
        }
      }
      .listRowBackground(HyStyle.surface)
    }
    .hyList()
    .navigationTitle("Журнал подключений")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $search, prompt: "Адрес, профиль или номер")
    .scrollDismissesKeyboard(.interactively)
    .task(id: client.vpnStatus) {
      guard client.vpnStatus == .connected else { return }
      while !Task.isCancelled {
        if !writing {
          do { try await client.refreshTrafficLog(); readFailed = false }
          catch { if !Task.isCancelled { readFailed = true } }
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
          confirmingClear = true
        } label: {
          Label("Очистить журнал", systemImage: "trash")
        }
        .disabled(writing || client.trafficEvents.isEmpty)
      } label: {
        Label("Действия с журналом", systemImage: "ellipsis.circle")
      }
      .accessibilityIdentifier("traffic-menu")
    }
    .alert("Очистить журнал подключений?", isPresented: $confirmingClear) {
      Button("Очистить", role: .destructive) {
        Task { await perform { try await client.clearTrafficLog() } }
      }
      Button("Отмена", role: .cancel) {}
    }
  }

  private var emptyMessage: String {
    if !client.trafficEvents.isEmpty { return "Под фильтр ничего не попало." }
    if !client.trafficLogging { return "Включите запись подключений." }
    if client.vpnStatus != .connected { return "Подключите VPN, чтобы увидеть события." }
    return "Откройте сайт или приложение. Здесь появится его маршрут."
  }

  private func perform(_ operation: () async throws -> Void) async {
    guard !writing else { return }
    writing = true
    defer { writing = false }
    do { try await operation(); issue = nil }
    catch { issue = "Не удалось изменить журнал. Повторите после подключения VPN." }
  }
}
