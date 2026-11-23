import CryptoKit
import Foundation
import NetworkExtension
import SwiftUI

private enum CoreError: Error { case invalidResult, missingTunnelExtension }
private struct ClientMessage: LocalizedError {
  let text: String
  var errorDescription: String? { text }
}

private func vpnFingerprint(_ snapshot: String) -> Data? {
  HyRouteRecoveryState(snapshot).map { Data(SHA256.hash(data: Data($0.utf8))) }
}

actor NativeCore {
  static let shared = NativeCore()
  private let store = ClientStore()
  #if targetEnvironment(simulator)
  private var routingFixture: String?

  func loadRoutingFixture() throws -> ClientState {
    let fixture = """
    {"subscriptions":[{"id":"demo","url":"https://example.test/sub","refreshedAt":1795400000,
      "snapshot":{"title":"Тестовая подписка","userInfo":"upload=1073741824; download=2147483648; total=10737418240; expire=1893456000",
      "servers":[{"id":"demo-node","name":"Тестовый сервер","host":"192.0.2.2","ports":"443","auth":"fixture"}]}}],
      "settings":{"selected":"demo-node","routing":{"defaultAction":"tunnel","rules":[
        {"name":"Сайт без VPN","domains":["example.org"],"action":"direct"}]}}}
    """
    routingFixture = fixture
    return try view(fixture)
  }
  #endif

  func load() throws -> ClientState {
    HyRouteConfigureGeo(try geodataDirectory().path)
    return try view(store.read())
  }

  func geodataDirectory() throws -> URL {
    let folder = try store.prepareDirectory()
    let legacy = folder.appendingPathComponent("geo", isDirectory: true)
    return try VPNStorage.prepareGeodata(legacy: legacy)
  }

  func geodataVersions() throws -> [String: Date] {
    let directory = try geodataDirectory()
    var dates: [String: Date] = [:]
    for name in ["geoip.dat", "geosite.dat"] {
      dates[name] = try? directory.appendingPathComponent(name)
        .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
    return dates
  }

  func geodataSnapshot(for state: String) throws -> Data {
    guard !HyRouteVPNGeodataKinds(state).isEmpty else { return Data() }
    guard let data = HyRouteVPNGeodataSnapshot(state, try geodataDirectory().path), !data.isEmpty else {
      throw CoreError.invalidResult
    }
    return data
  }

  func vpnState() throws -> String { try store.read() }

  func prepareRecovery() throws {
    try VPNStorage.saveRecoveryState(store.read(), create: true)
  }

  func clearRecovery() throws { try VPNStorage.clearRecoveryState() }

  func unavailableGeo(in snapshot: String) -> [String] {
    let raw = HyRouteUnavailableGeo(snapshot)
    guard let categories = try? JSONDecoder().decode([String].self, from: Data(raw.utf8)) else { return [] }
    return Set(categories).sorted()
  }

  func journalPath() throws -> String {
    try store.prepareDirectory().appendingPathComponent("vpn-journal.json").path
  }

  func record(_ event: String) {
    if let path = try? journalPath() { HyRouteRecordVPNEvent(path, event) }
  }

  func recordVPNError(_ event: String, source: String, code: Int32) {
    if let path = try? journalPath() { HyRouteRecordVPNError(path, event, source, code) }
  }

  func journal() throws -> [VPNJournalEvent] {
    let raw = HyRouteVPNJournalEvents(try journalPath(), VPNStorage.tunnelJournal)
    return try JSONDecoder().decode([VPNJournalEvent].self, from: Data(raw.utf8))
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

  func autoRefresh(maintenance: NSObject? = nil) async throws -> ClientState {
    let before = try store.read()
    let updated = await Task.detached(priority: .utility) {
      if let maintenance { return HyRouteRefreshWithMaintenance(maintenance, before) }
      return HyRouteAutoRefreshSubscriptions(before)
    }.value
    try Task.checkCancellation()
    let current = try store.read()
    if let updated, updated != current, current == before { return try persist(updated) }
    return try view(current)
  }

  func save(_ settings: ClientSettings) throws -> ClientState {
    let raw = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
    var issue: NSString?
    guard let updated = HyRouteSaveSettingsWithIssue(try routingState(), raw, &issue) else {
      throw ClientMessage(text: (issue as String?) ?? "Не удалось сохранить настройки VPN.")
    }
    #if targetEnvironment(simulator)
    if routingFixture != nil {
      routingFixture = updated
      return try view(updated)
    }
    #endif
    return try persist(updated)
  }

  func changeRoutingProfile(_ operation: String, id: String, name: String) throws -> ClientState {
    let before = try routingState()
    var issue: NSString?
    guard let updated = HyRouteChangeRoutingProfile(before, operation, id, name, &issue) else {
      throw ClientMessage(text: (issue as String?) ?? "Не удалось изменить профиль правил.")
    }
    if updated == before { return try view(before) }
    #if targetEnvironment(simulator)
    if routingFixture != nil {
      routingFixture = updated
      return try view(updated)
    }
    #endif
    return try persist(updated)
  }

  func changeServerGroup(id: String, group: ServerGroup?) throws -> ClientState {
    let definition = try group.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) } ?? ""
    var issue: NSString?
    guard let result = HyRouteChangeServerGroup(try store.read(), id, definition, &issue) else {
      throw ClientMessage(text: (issue as String?) ?? "Не удалось сохранить группу.")
    }
    return try persist(result)
  }

  func checkRoute(_ address: String, ip: String, transport: String) throws -> CheckedRoute {
    var issue: NSString?
    guard let result = HyRouteCheckClientRoute(try routingState(), address, ip, transport, &issue) else {
      throw ClientMessage(text: (issue as String?) ?? "Не удалось проверить маршрут.")
    }
    return try JSONDecoder().decode(CheckedRoute.self, from: Data(result.utf8))
  }

  private func routingState() throws -> String {
    #if targetEnvironment(simulator)
    if let routingFixture { return routingFixture }
    #endif
    return try store.read()
  }

  private func persist(_ raw: String?) throws -> ClientState {
    guard let raw else { throw CoreError.invalidResult }
    let state = try view(raw)
    try store.write(raw)
    do { try VPNStorage.saveRecoveryState(raw, create: false) }
    catch {
      try? VPNStorage.clearRecoveryState()
      record("vpn_recovery_storage_error")
    }
    return state
  }

  private func view(_ raw: String) throws -> ClientState {
    guard let sanitized = HyRouteStateView(raw) else { throw CoreError.invalidResult }
    return try JSONDecoder().decode(ClientState.self, from: Data(sanitized.utf8))
  }
}

@MainActor
final class Client: ObservableObject {
  private let core = NativeCore.shared
  private var manager: NETunnelProviderManager?
  private var startup: (state: VPNStartup, began: ContinuousClock.Instant)?
  private var watchdog: Task<Void, Never>?
  private var attemptID = UUID()
  private var stoppingVPN = false
  private var mayRetryExtension = false
  private var updatingAutomatically = false
  private var stateRevision = 0
  private var startingFingerprint: Data?
  private var privateTunnelJournal: [VPNJournalEvent] = []
  @Published private(set) var preferencesPending = false
  @Published private(set) var restartingVPN = false
  @Published private(set) var trafficLogging = UserDefaults.standard.bool(forKey: "vpnTrafficLogging")
  @Published private(set) var trafficEvents: [TrafficEvent] = []
  @Published private(set) var state = ClientState()
  @Published private(set) var ready = false
  @Published private(set) var busy = false
  @Published private(set) var vpnBusy = false
  @Published private(set) var vpnStatus: NEVPNStatus = .invalid
  @Published private(set) var autoReconnect = UserDefaults.standard.bool(forKey: "vpnAutoReconnect")
  @Published private(set) var blockOnDrop = UserDefaults.standard.bool(forKey: "vpnBlockOnDrop")
  @Published var error: String?

  func load() async {
    if await change("Не удалось открыть хранилище HyRoute.", {
      let snapshot = try await self.core.load()
      self.manager = try? await self.vpnManager()
      return snapshot
    }) {
      syncVPNStatus()
      ready = true
      await checkAppliedSettings()
    }
  }

  func toggleVPN() async {
    guard !restartingVPN else { return }
    await changeVPNStatus()
  }

  var canApplyVPNChanges: Bool {
    preferencesPending && [.connected, .reasserting, .connecting].contains(vpnStatus)
  }

  func reconnectVPN() async {
    guard canApplyVPNChanges, !restartingVPN, !vpnBusy, !stoppingVPN else { return }
    restartingVPN = true
    defer { restartingVPN = false }
    await changeVPNStatus()
    guard stoppingVPN || vpnStatus == .disconnected || vpnStatus == .invalid else { return }
    let deadline = ContinuousClock.now + .seconds(10)
    while vpnStatus != .disconnected && vpnStatus != .invalid && ContinuousClock.now < deadline {
      do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
      syncVPNStatus()
    }
    guard vpnStatus == .disconnected || vpnStatus == .invalid else {
      error = "VPN ещё отключается. Повторите подключение после остановки."
      return
    }
    await changeVPNStatus()
  }

  private func changeVPNStatus() async {
    guard !vpnBusy, !stoppingVPN else { return }
    attemptID = UUID()
    if vpnStatus == .connected || vpnStatus == .connecting || vpnStatus == .reasserting {
      finishStartup()
      startingFingerprint = nil
      stoppingVPN = true
      do {
        if manager?.isOnDemandEnabled == true { try await disarmRecovery() }
      } catch {
        stoppingVPN = false
        self.error = "Не удалось отключить автовосстановление VPN. Повторите попытку."
        return
      }
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
    startingFingerprint = nil
    do {
      let snapshot = try await core.vpnState()
      let unavailableGeo = await core.unavailableGeo(in: snapshot)
      if !unavailableGeo.isEmpty {
        await core.recordVPNError("vpn_geo_local_error", source: "HyRoute", code: Int32(TunnelStartError.geodata.rawValue))
        let shown = unavailableGeo.prefix(4).joined(separator: ", ")
        let extra = unavailableGeo.count > 4 ? " и ещё \(unavailableGeo.count - 4)" : ""
        error = "Недоступны категории \(shown)\(extra). В «Правилах» откройте «Настройки», затем «Базы правил». Обновите базы или выберите доступные категории."
        return
      }
      do {
        try await requestTunnel(snapshot)
      } catch let error as NEVPNError where error.code == .configurationStale {
        await core.record("vpn_preferences_stale")
        try await requestTunnel(snapshot)
      }
      startingFingerprint = vpnFingerprint(snapshot)
      watchStartup()
      await core.record("vpn_handoff")
    } catch CoreError.missingTunnelExtension {
      await core.record("vpn_provider_missing")
      error = "В установленной сборке нет Packet Tunnel. При подписи IPA сохраните VPN-расширение."
    } catch let message as ClientMessage {
      error = message.text
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
      try await saveVPNPreferences(current)
    }
    manager = current
    guard let configuration = current.protocolConfiguration as? NETunnelProviderProtocol else {
      throw CoreError.invalidResult
    }

    // A manual start may be offered even if another signing tool gave the
    // application and the provider different access to their shared container.
    let activeStatuses: [NEVPNStatus] = [.connecting, .connected, .reasserting]
    guard let session = current.connection as? NETunnelProviderSession else { throw CoreError.invalidResult }
    guard !activeStatuses.contains(session.status) else { return }

    if autoReconnect {
      do {
        try await core.prepareRecovery()
        let check = GeodataTransfer(action: .checkRecovery, token: UUID())
        guard try await sendGeodataCommand(check, to: session) == .ready else { throw CoreError.invalidResult }
      } catch {
        await core.record("vpn_recovery_storage_error")
        throw ClientMessage(text: "Расширению недоступно хранилище для автозапуска. Отключите автовосстановление в «Защите VPN» и подключитесь вручную.")
      }
    }
    let block = autoReconnect && blockOnDrop
    if current.isOnDemandEnabled != autoReconnect || configuration.includeAllNetworks != block {
      current.isOnDemandEnabled = autoReconnect
      current.onDemandRules = autoReconnect ? [NEOnDemandRuleConnect()] : []
      configuration.includeAllNetworks = block
      configuration.providerConfiguration = ["recovery": autoReconnect]
      current.protocolConfiguration = configuration
      try await saveVPNPreferences(current)
    }
    guard let updatedSession = current.connection as? NETunnelProviderSession else { throw CoreError.invalidResult }
    guard !activeStatuses.contains(updatedSession.status) else { return }
    try await startManualTunnel(snapshot, with: updatedSession)
  }

  private func startManualTunnel(_ snapshot: String, with session: NETunnelProviderSession) async throws {
    let geodata: Data
    do { geodata = try await core.geodataSnapshot(for: snapshot) }
    catch {
      await logVPNError(error, event: "vpn_geo_bundle_error")
      throw ClientMessage(text: "Не удалось подготовить категории GeoSite/GeoIP. Проверьте базы в настройках правил.")
    }
    var options: [String: NSObject] = ["state": snapshot as NSString, "trafficLogging": NSNumber(value: trafficLogging)]
    if geodata.isEmpty {
      try session.startTunnel(options: options)
      return
    }
    if geodata.count <= GeodataTransfer.inlineLimit {
      options["geoSnapshot"] = geodata as NSData
      await core.record("vpn_geo_inline")
      do {
        try session.startTunnel(options: options)
        return
      } catch let error as NEVPNError where error.code == .configurationStale {
        throw error
      } catch {
        await logVPNError(error, event: "vpn_geo_inline_rejected")
        options.removeValue(forKey: "geoSnapshot")
      }
    }

    let token = UUID()
    options["geoTransferToken"] = token.uuidString as NSString
    try session.startTunnel(options: options)
    await core.record("vpn_geo_transfer_after_start")
    do {
      try await waitForGeodataReceiver(token, session: session)
      try await GeodataTransfer.sendSnapshot(geodata, token: token) { command in
        try await self.sendGeodataCommand(command, to: session)
      }
    } catch {
      await logVPNError(error, event: "vpn_geo_transfer_error")
      session.stopTunnel()
      throw ClientMessage(text: "Не удалось передать большой набор категорий запущенному VPN-расширению. Подробности в журнале.")
    }
  }

  private func waitForGeodataReceiver(_ token: UUID, session: NETunnelProviderSession) async throws {
    let check = GeodataTransfer(action: .awaitingSnapshot, token: token)
    var lastError: Error = CoreError.invalidResult
    for _ in 0..<25 {
      do {
        if try await sendGeodataCommand(check, to: session) == .ready { return }
      } catch {
        lastError = error
      }
      try await Task.sleep(for: .milliseconds(200))
    }
    throw lastError
  }

  private func sendGeodataCommand(_ command: GeodataTransfer, to session: NETunnelProviderSession) async throws -> GeodataTransfer.Reply {
    let encoder = PropertyListEncoder()
    encoder.outputFormat = .binary
    let response = try await session.hyRouteMessage(encoder.encode(command))
    guard response.count == 1, let byte = response.first,
          let reply = GeodataTransfer.Reply(rawValue: byte) else { throw CoreError.invalidResult }
    return reply
  }

  private func saveVPNPreferences(_ manager: NETunnelProviderManager) async throws {
    try await manager.saveToPreferences()
    try await manager.loadFromPreferences()
  }

  var canEditVPNRecovery: Bool {
    !vpnBusy && !stoppingVPN && (vpnStatus == .invalid || vpnStatus == .disconnected)
  }

  func setAutoReconnect(_ enabled: Bool) async {
    guard canEditVPNRecovery else { return }
    vpnBusy = true
    defer { vpnBusy = false }
    if enabled && !VPNStorage.canRecover {
      error = "Нет доступа к App Groups. Сохраните разрешение VPN-расширения при подписи IPA."
      return
    }
    if !enabled {
      do { try await disarmRecovery() }
      catch {
        self.error = "Не удалось отключить автовосстановление VPN. Повторите попытку."
        return
      }
    }
    autoReconnect = enabled
    UserDefaults.standard.set(enabled, forKey: "vpnAutoReconnect")
  }

  func setBlockOnDrop(_ enabled: Bool) {
    guard canEditVPNRecovery, autoReconnect else { return }
    blockOnDrop = enabled
    UserDefaults.standard.set(enabled, forKey: "vpnBlockOnDrop")
  }

  private func disarmRecovery() async throws {
    let current = try await vpnManager()
    if current.isOnDemandEnabled {
      current.isOnDemandEnabled = false
      current.onDemandRules = []
      try await saveVPNPreferences(current)
    }
    manager = current
    do { try await core.clearRecovery() }
    catch { await core.record("vpn_recovery_storage_error") }
  }

  func journal() async throws -> [String] {
    let events = try await core.journal()
    if [.connected, .reasserting].contains(vpnStatus),
       let session = manager?.connection as? NETunnelProviderSession,
       let command = try? JSONEncoder().encode(TrafficCommand(action: .vpnJournal)),
       let raw = try? await session.hyRouteMessage(command),
       let provider = try? JSONDecoder().decode([VPNJournalEvent].self, from: raw) {
      privateTunnelJournal = provider
    }
    var seen = Set<VPNJournalEvent>()
    let recent = (events + privateTunnelJournal).sorted { $0.at > $1.at }
      .filter { seen.insert($0).inserted }.prefix(160)
    return VPNJournalEvent.lines(Array(recent))
  }

  func setTrafficLogging(_ enabled: Bool) async throws {
    if vpnStatus == .connected {
      try await updateTraffic(TrafficCommand(action: .trafficSet, enabled: enabled))
    } else if [.connecting, .reasserting, .disconnecting].contains(vpnStatus) {
      throw ClientMessage(text: "Дождитесь завершения подключения.")
    }
    trafficLogging = enabled
    UserDefaults.standard.set(enabled, forKey: "vpnTrafficLogging")
  }

  func clearTrafficLog() async throws {
    try await updateTraffic(TrafficCommand(action: .trafficClear))
    trafficEvents = []
  }

  func refreshTrafficLog() async throws {
    try await updateTraffic(TrafficCommand(action: .trafficStatus))
  }

  private func updateTraffic(_ command: TrafficCommand) async throws {
    guard vpnStatus == .connected, let session = manager?.connection as? NETunnelProviderSession else { return }
    let response = try await session.hyRouteMessage(JSONEncoder().encode(command))
    guard !Task.isCancelled, vpnStatus == .connected, session === manager?.connection else { return }
    trafficEvents = try JSONDecoder().decode([TrafficEvent].self, from: response)
  }

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
    if status == .connected, let fingerprint = startingFingerprint {
      startingFingerprint = nil
      UserDefaults.standard.set(fingerprint, forKey: "vpnAppliedFingerprint")
      UserDefaults.standard.removeObject(forKey: "vpnGeodataPending")
      Task { await checkAppliedSettings() }
    } else if status == .connected && vpnStatus != .connected && trafficLogging {
      Task { try? await updateTraffic(TrafficCommand(action: .trafficSet, enabled: true)) }
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
  func loadRoutingFixture() async -> Bool {
    guard let fixture = try? await core.loadRoutingFixture() else { return false }
    state = fixture
    ready = true
    return true
  }

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
    let failure = "Не удалось обновить подписку. Сохранён предыдущий список."
    let updated = await change(failure) {
      try await self.core.refresh(id)
    }
    if updated && state.subscriptions.first(where: { $0.id == id })?.refreshFailed == true {
      error = failure
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

  func saveChain(exit: String, entry: String?) async throws {
    guard !busy else { throw ClientMessage(text: "Дождитесь окончания сохранения.") }
    busy = true
    defer { busy = false }
    var settings = state.settings
    settings.routing.viaProfiles[exit] = entry
    settings.selected = state.selected?.id
    do {
      let updated = try await core.save(settings)
      await applySettingsChange(updated)
    } catch let message as ClientMessage {
      throw message
    } catch {
      throw ClientMessage(text: "Не удалось записать цепочку в хранилище HyRoute.")
    }
  }

  func saveSplitDNS(_ settings: SplitDNS?) async -> Bool {
    var next = state.settings
    next.splitDNS = settings
    return await save(next, reportError: false)
  }

  func changeServerGroup(id: String, group: ServerGroup?) async throws {
    guard !busy else { throw ClientMessage(text: "Дождитесь окончания сохранения.") }
    busy = true
    defer { busy = false }
    let updated = try await core.changeServerGroup(id: id, group: group)
    await applySettingsChange(updated)
  }

  func changeRoutingProfile(_ operation: String, id: String = "", name: String = "") async throws {
    guard !busy else { throw ClientMessage(text: "Дождитесь окончания сохранения.") }
    busy = true
    defer { busy = false }
    let updated = try await core.changeRoutingProfile(operation, id: id, name: name)
    await applySettingsChange(updated)
  }

  func checkRoute(_ address: String, ip: String, transport: String) async throws -> CheckedRoute {
    try await core.checkRoute(address, ip: ip, transport: transport)
  }

  func geoTags(update: Bool) async throws -> [String] {
    let snapshot = update ? try await core.vpnState() : ""
    let previous = update ? (try? await core.geodataVersions()) : nil
    let tags = try await Task.detached(priority: .utility) {
      if update && !HyRouteUpdateGeoForState(snapshot) { throw CoreError.invalidResult }
      guard let tags = HyRouteGeoTags() else { throw CoreError.invalidResult }
      return try JSONDecoder().decode([String].self, from: Data(tags.utf8))
    }.value
    if update, previous != (try? await core.geodataVersions()) { markGeodataChanged(snapshot) }
    return tags
  }

  func geoSources() async throws -> [String: String] {
    try await Task.detached(priority: .utility) {
      guard let raw = HyRouteGeoSettings() else { throw CoreError.invalidResult }
      return try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
    }.value
  }

  func saveGeoSource(_ kind: String, address: String) async -> Bool {
    await Task.detached(priority: .utility) { HyRouteSetGeoSource(kind, address) }.value
  }

  func importGeoFile(_ kind: String, file: URL) async -> Bool {
    guard let snapshot = try? await core.vpnState() else { return false }
    let installed = await Task.detached(priority: .utility) {
      let scoped = file.startAccessingSecurityScopedResource()
      defer { if scoped { file.stopAccessingSecurityScopedResource() } }
      var coordinationError: NSError?
      var installed = false
      NSFileCoordinator().coordinate(readingItemAt: file, options: [], error: &coordinationError) { item in
        installed = HyRouteImportGeoFileForState(kind, item.path, snapshot)
      }
      return coordinationError == nil && installed
    }.value
    if installed { markGeodataChanged(snapshot) }
    return installed
  }

  func refreshAutomatically() async {
    guard ready, !updatingAutomatically, !busy else { return }
    updatingAutomatically = true
    defer { updatingAutomatically = false }
    let revision = stateRevision
    if let snapshot = try? await core.autoRefresh(), !busy, stateRevision == revision {
      await applySettingsChange(snapshot)
    }
    if !Task.isCancelled, let snapshot = try? await core.vpnState() {
      let previous = try? await core.geodataVersions()
      let updated = await Task.detached(priority: .utility) { HyRouteAutoUpdateGeoForState(snapshot) }.value
      if updated, previous != (try? await core.geodataVersions()) { markGeodataChanged(snapshot) }
    }
  }

  private func markGeodataChanged(_ snapshot: String) {
    guard [.connected, .reasserting, .connecting].contains(vpnStatus),
          !HyRouteVPNGeodataKinds(snapshot).isEmpty else { return }
    UserDefaults.standard.set(true, forKey: "vpnGeodataPending")
    preferencesPending = true
  }

  private func applySettingsChange(_ updated: ClientState) async {
    state = updated
    stateRevision += 1
    await checkAppliedSettings()
  }

  private func checkAppliedSettings() async {
    let revision = stateRevision
    guard let raw = try? await core.vpnState(), revision == stateRevision else { return }
    let saved = startingFingerprint ?? UserDefaults.standard.data(forKey: "vpnAppliedFingerprint")
    preferencesPending = UserDefaults.standard.bool(forKey: "vpnGeodataPending") ||
      (saved != nil && vpnFingerprint(raw) != saved)
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
      let updated = try await operation()
      await applySettingsChange(updated)
      return true
    } catch {
      if reportError { self.error = failure }
      return false
    }
  }
}
