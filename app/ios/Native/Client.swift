import Foundation
import NetworkExtension
import SwiftUI

private enum CoreError: Error { case invalidResult }

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
  private var startingVPN = false
  @Published private(set) var state = ClientState()
  @Published private(set) var ready = false
  @Published private(set) var busy = false
  @Published private(set) var vpnBusy = false
  @Published private(set) var vpnStatus: NEVPNStatus = .invalid
  @Published var error: String?

  func load() async {
    if await change("Не удалось открыть хранилище HyRoute.", { try await self.core.load() }) {
      ready = true
      manager = try? await vpnManager()
      syncVPNStatus()
    }
  }

  func toggleVPN() async {
    guard !vpnBusy else { return }
    if vpnStatus == .connected || vpnStatus == .connecting || vpnStatus == .reasserting {
      startingVPN = false
      (manager?.connection as? NETunnelProviderSession)?.stopTunnel()
      await core.record("vpn_stop")
      syncVPNStatus()
      return
    }
    guard state.selected != nil, vpnStatus != .disconnecting else { return }
    vpnBusy = true
    defer { vpnBusy = false }
    await core.record("vpn_request")
    do {
      let current = try await vpnManager()
      if !current.isEnabled {
        await core.record("vpn_permission")
        current.isEnabled = true
        try await current.saveToPreferences()
        try await current.loadFromPreferences()
      }
      manager = current
      guard let session = current.connection as? NETunnelProviderSession else { throw CoreError.invalidResult }
      startingVPN = true
      let snapshot = try await core.vpnState()
      try session.startTunnel(options: ["state": snapshot as NSString])
      syncVPNStatus()
    } catch {
      startingVPN = false
      await core.record("vpn_system_error")
      self.error = "Не удалось запустить VPN. Проверьте разрешение iOS и выбранный профиль."
      syncVPNStatus()
    }
  }

  func journal() async throws -> [String] { try await core.journal() }

  func probeHandle(scope: String, id: String) async throws -> ProbeHandle {
    let snapshot = try await core.vpnState()
    let journal = try await core.journalPath()
    let session = vpnStatus == .connected ? manager?.connection as? NETunnelProviderSession : nil
    return ProbeHandle(snapshot: snapshot, scope: scope, id: id, journal: journal, session: session)
  }

  func syncVPNStatus() {
    guard let status = manager?.connection.status else { return }
    if status == .connected {
      startingVPN = false
    } else if startingVPN && vpnStatus == .connecting && (status == .disconnected || status == .invalid) {
      startingVPN = false
      error = "VPN не подключился. Проверьте профиль и установленные базы правил."
    }
    vpnStatus = status
  }

  private func vpnManager() async throws -> NETunnelProviderManager {
    guard let bundleID = Bundle.main.bundleIdentifier else { throw CoreError.invalidResult }
    let providerID = bundleID + ".PacketTunnel"
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
    if let installed = managers.first(where: {
      ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == providerID
    }) { return installed }
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
