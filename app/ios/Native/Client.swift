import Foundation
import NetworkExtension
import SwiftUI

private enum CoreError: Error { case invalidResult, missingTunnelExtension }

private actor NativeCore {
  private let store = ClientStore()

  func load() throws -> ClientState {
    let folder = try store.prepareDirectory()
    let legacy = folder.appendingPathComponent("geo", isDirectory: true)
    HyRouteConfigureGeo(try VPNStorage.prepareGeodata(legacy: legacy).path)
    return try view(store.read())
  }

  func vpnState() throws -> String { try store.read() }

  func journalPath() throws -> String {
    try store.prepareDirectory().appendingPathComponent("vpn-journal.json").path
  }

  func record(_ event: String) {
    if let path = try? journalPath() { HyRouteRecordVPNEvent(path, event) }
  }

  func recordVPNError(_ event: String, source: String, code: Int32) {
    if let path = try? journalPath() { HyRouteRecordVPNError(path, event, source, code) }
  }

  func journal() throws -> [String] {
    let raw = HyRouteVPNJournal(try journalPath(), VPNStorage.tunnelJournal)
    return try JSONDecoder().decode([String].self, from: Data(raw.utf8))
  }

  func importSubscription(_ input: String) throws -> ClientState {
    let url = URLComponents(string: input)
    let fromURL = url?.scheme?.lowercased() == "https" &&
      !(url?.host?.isEmpty ?? true) && input.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    return try persist(HyRouteAddSubscription(try store.read(), input, fromURL))
  }

  func refresh(_ id: String) throws -> ClientState {
    try persist(HyRouteRefreshSubscription(try store.read(), id))
  }

  func save(_ settings: ClientSettings) throws -> ClientState {
    let raw = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
    return try persist(HyRouteSaveSettings(try store.read(), raw))
  }

  func geoTags(update: Bool) throws -> [String] {
    if update && !HyRouteUpdateGeo() { throw CoreError.invalidResult }
    guard let tags = HyRouteGeoTags() else { throw CoreError.invalidResult }
    return try JSONDecoder().decode([String].self, from: Data(tags.utf8))
  }

  private func persist(_ raw: String?) throws -> ClientState {
    guard let raw else { throw CoreError.invalidResult }
    let state = try view(raw)
    try store.write(raw)
    return state
  }

  private func view(_ raw: String) throws -> ClientState {
    guard let sanitized = HyRouteStateView(raw) else { throw CoreError.invalidResult }
    return try JSONDecoder().decode(ClientState.self, from: Data(sanitized.utf8))
  }
}

@MainActor
final class Client: ObservableObject {
  private let core = NativeCore()
  private var manager: NETunnelProviderManager?
  private var startup: (state: VPNStartup, began: ContinuousClock.Instant)?
  private var watchdog: Task<Void, Never>?
  private var attemptID = UUID()
  private var stoppingVPN = false
  private var mayRetryExtension = false
  @Published private(set) var state = ClientState()
  @Published private(set) var ready = false
  @Published private(set) var busy = false
  @Published private(set) var vpnBusy = false
  @Published private(set) var vpnStatus: NEVPNStatus = .invalid
  @Published var error: String?

  func load() async {
    if await change("Не удалось открыть хранилище HyRoute.", {
      let snapshot = try await self.core.load()
      self.manager = try? await self.vpnManager()
      return snapshot
    }) {
      syncVPNStatus()
      ready = true
    }
  }

  func toggleVPN() async {
    guard !vpnBusy, !stoppingVPN else { return }
    attemptID = UUID()
    if vpnStatus == .connected || vpnStatus == .connecting || vpnStatus == .reasserting {
      finishStartup()
      stoppingVPN = true
      (manager?.connection as? NETunnelProviderSession)?.stopTunnel()
      await core.record("vpn_stop")
      syncVPNStatus()
      return
    }
    guard state.selected != nil, vpnStatus != .disconnecting else { return }
    vpnBusy = true
    defer { vpnBusy = false }
    mayRetryExtension = true
    await core.record("vpn_request")
    await launchVPN()
  }

  private func launchVPN() async {
    do {
      let snapshot = try await core.vpnState()
      do {
        try await requestTunnel(snapshot)
      } catch let error as NEVPNError where error.code == .configurationStale {
        await core.record("vpn_preferences_stale")
        try await requestTunnel(snapshot)
      }
      watchStartup()
      await core.record("vpn_handoff")
    } catch CoreError.missingTunnelExtension {
      await core.record("vpn_provider_missing")
      error = "В установленной сборке нет Packet Tunnel. При подписи IPA сохраните VPN-расширение."
    } catch {
      await logVPNError(error, event: "vpn_system_error")
      self.error = "iOS отклонила запуск VPN. Код \((error as NSError).code). Подробности в журнале."
      syncVPNStatus()
    }
  }

  private func requestTunnel(_ snapshot: String) async throws {
    let current = try await vpnManager()
    if !current.isEnabled {
      await core.record("vpn_permission")
      current.isEnabled = true
      try await current.saveToPreferences()
      try await current.loadFromPreferences()
    }
    manager = current
    guard let session = current.connection as? NETunnelProviderSession else { throw CoreError.invalidResult }
    try session.startTunnel(options: ["state": snapshot as NSString])
  }

  func journal() async throws -> [String] { try await core.journal() }

  func probeHandle(scope: String, id: String) async throws -> ProbeHandle {
    #if targetEnvironment(simulator)
    if ProcessInfo.processInfo.environment["HYROUTE_UI_TEST"] == "1" {
      let profiles = scope == "profile" ? state.profiles.filter { $0.id == id } :
        state.subscriptions.first { $0.id == id }?.servers.filter { $0.missing != true } ?? []
      let handle = ProbeHandle(snapshot: "", scope: scope, id: id, journal: "", session: nil)
      let rows = profiles.flatMap { profile in
        (0..<(profile.balance == true ? 2 : 1)).map { index in
          ProbeSnapshot.Row(profileId: profile.id, name: profile.title, host: "node\(index + 1).example.test",
                            status: "ok", ms: (scope == "profile" ? 33 : 42) + index)
        }
      }
      handle.simulatorResult = ProbeSnapshot(done: true, results: rows)
      return handle
    }
    #endif
    let snapshot = try await core.vpnState()
    let journal = try await core.journalPath()
    let session = vpnStatus == .connected ? manager?.connection as? NETunnelProviderSession : nil
    return ProbeHandle(snapshot: snapshot, scope: scope, id: id, journal: journal, session: session)
  }

  func syncVPNStatus() {
    guard let connection = manager?.connection else { return }
    let status = connection.status
    if var observation = startup {
      let outcome = observation.state.observe(status, elapsed: observation.began.duration(to: .now))
      startup = observation
      if outcome == .waiting {
        vpnStatus = .connecting
        return
      }
      finishStartup()
      if outcome == .rejected {
        reportDisconnect(connection, event: "vpn_start_failed", message: "iOS отключила VPN во время запуска. Подробности в журнале.")
      } else if outcome == .timedOut {
        stoppingVPN = true
        connection.stopVPNTunnel()
        error = "VPN не запустился за 35 секунд."
        Task { await core.record("vpn_start_timeout") }
      }
    } else if status == .disconnected || status == .invalid {
      if !stoppingVPN && (vpnStatus == .connected || vpnStatus == .reasserting) {
        reportDisconnect(connection, event: "vpn_disconnect", message: "iOS отключила активный VPN. Подробности в журнале.")
      }
      stoppingVPN = false
    }
    vpnStatus = stoppingVPN ? .disconnecting : status
  }

  private func watchStartup() {
    finishStartup()
    startup = (VPNStartup(), .now)
    watchdog = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        guard let self, self.startup != nil else { return }
        self.syncVPNStatus()
      }
    }
    syncVPNStatus()
  }

  private func finishStartup() {
    startup = nil
    watchdog?.cancel()
    watchdog = nil
  }

  private func reportDisconnect(_ connection: NEVPNConnection, event: String, message: String) {
    error = message
    let attempt = attemptID
    Task { [weak self] in
      guard let self else { return }
      await self.core.record(event)
      do {
        try await connection.fetchLastDisconnectError()
      } catch {
        await self.logVPNError(error, event: "vpn_ios_error")
        guard self.attemptID == attempt, self.vpnStatus != .connected else { return }
        let detail = error as NSError
        if event == "vpn_start_failed", self.mayRetryExtension,
           self.vpnStatus == .disconnected || self.vpnStatus == .invalid,
           detail.domain == NEVPNConnectionErrorDomain,
           NEVPNConnectionError(rawValue: detail.code) == .pluginFailed {
          self.mayRetryExtension = false
          self.error = nil
          self.vpnBusy = true
          defer { self.vpnBusy = false }
          await self.core.record("vpn_extension_retry")
          await self.launchVPN()
          return
        }
        if detail.domain == TunnelStartError.errorDomain,
           let tunnelError = TunnelStartError(rawValue: detail.code) {
          self.error = tunnelError.userMessage
        } else if detail.domain == NEVPNConnectionErrorDomain,
                  NEVPNConnectionError(rawValue: detail.code) == .pluginFailed {
          self.error = "iOS не смогла запустить VPN-расширение (код \(detail.code))."
        } else {
          self.error = message + " Код \(detail.code)."
        }
      }
    }
  }

#if targetEnvironment(simulator)
  func loadLayoutPreview() -> Bool {
    let fixture = """
    {
      "subscriptions": [{"id":"preview","title":"Серверы","canRefresh":true,"servers":[
        {"id":"auto","name":"Автовыбор","protocol":"vless","balance":true,"balanceStrategy":"leastPing"},
        {"id":"fi","name":"🇫🇮 Хельсинки · Северный узел | Hysteria 2","protocol":"hysteria2"},
        {"id":"nl","name":"🇳🇱 Амстердам · Резервный сервер | VLESS","protocol":"vless"},
        {"id":"jp","name":"🇯🇵 Токио · Восточная Азия | Hysteria 2","protocol":"hysteria2"},
        {"id":"de","name":"🇩🇪 Франкфурт · Основной европейский сервер | VLESS","protocol":"vless"},
        {"id":"old","name":"Старый сервер","protocol":"vless","missing":true}
      ]}],
      "settings":{"selected":"auto","routing":{"defaultAction":"tunnel","rules":[
        {"action":"direct","domains":["geosite:ru"]},
        {"action":"block","domains":["geosite:category-ads-all"]},
        {"action":"tunnel","domains":["geosite:telegram"],"profile":"old"},
        {"action":"tunnel","domains":["geosite:discord"],"profile":"fi"},
        {"action":"tunnel","domains":["geosite:youtube"]},
        {"action":"direct","domains":["geoip:private"]},
        {"action":"tunnel","domains":["example.test"]},
        {"action":"direct","domains":["example.org"]}
      ],"viaProfiles":{"auto":"old","fi":"jp"}}}
    }
    """
    guard let preview = try? JSONDecoder().decode(ClientState.self, from: Data(fixture.utf8)) else { return false }
    state = preview
    ready = true
    return true
  }
#endif

  private func logVPNError(_ error: Error, event: String) async {
    let detail = error as NSError
    let source = detail.domain == TunnelStartError.errorDomain ? "PacketTunnel" : detail.domain
    await core.recordVPNError(event, source: source, code: Int32(clamping: detail.code))
  }

  private func vpnManager() async throws -> NETunnelProviderManager {
    guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("HyRouteTunnel.appex"),
          let tunnelBundle = Bundle(url: url),
          let providerID = tunnelBundle.bundleIdentifier else { throw CoreError.missingTunnelExtension }
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
    if let installed = managers.first(where: {
      ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID
    }) {
      try await installed.loadFromPreferences()
      return installed
    }
    let configuration = NETunnelProviderProtocol()
    configuration.providerBundleIdentifier = providerID
    configuration.serverAddress = "HyRoute"
    let newManager = NETunnelProviderManager()
    newManager.protocolConfiguration = configuration
    newManager.localizedDescription = "HyRoute"
    return newManager
  }

  func importSubscription(_ input: String, reportError: Bool = true) async -> Bool {
    await change("Не удалось импортировать подписку. Проверьте ссылку или формат.", reportError: reportError) {
      try await self.core.importSubscription(input.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  func refresh(_ id: String) async {
    _ = await change("Не удалось обновить подписку. Сохранён предыдущий список.") {
      try await self.core.refresh(id)
    }
  }

  func select(_ id: String) async -> Bool {
    var next = state.settings
    next.selected = id
    return await save(next)
  }

  func saveRouting(_ routing: Routing, reportError: Bool = true) async -> Bool {
    var next = state.settings
    next.routing = routing
    next.selected = state.selected?.id
    return await save(next, reportError: reportError)
  }

  func geoTags(update: Bool) async throws -> [String] {
    try await core.geoTags(update: update)
  }

  private func save(_ settings: ClientSettings, reportError: Bool = true) async -> Bool {
    await change("Не удалось сохранить. Проверьте адреса, порты и цепочки профилей.", reportError: reportError) {
      try await self.core.save(settings)
    }
  }

  private func change(_ failure: String, reportError: Bool = true, _ operation: () async throws -> ClientState) async -> Bool {
    guard !busy else { return false }
    busy = true
    defer { busy = false }
    do {
      state = try await operation()
      return true
    } catch {
      if reportError { self.error = failure }
      return false
    }
  }
}
