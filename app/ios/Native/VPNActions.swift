import AppIntents
import Foundation

struct VPNServerEntity: AppEntity {
  static let typeDisplayRepresentation: TypeDisplayRepresentation = "Сервер VPN"
  static let defaultQuery = VPNServerQuery()

  let id: String
  let name: String
  var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct VPNServerQuery: EntityStringQuery {
  func entities(for identifiers: [String]) async throws -> [VPNServerEntity] {
    let available = try await suggestedEntities()
    return identifiers.compactMap { id in available.first { $0.id == id } }
  }

  func entities(matching string: String) async throws -> [VPNServerEntity] {
    let available = try await suggestedEntities()
    return string.isEmpty ? available : available.filter { $0.name.localizedStandardContains(string) }
  }

  func suggestedEntities() async throws -> [VPNServerEntity] {
    let state = try await NativeCore.shared.load()
    return state.profiles.map { VPNServerEntity(id: $0.id, name: $0.title) }
  }
}

struct EnableVPNIntent: AppIntent {
  static let title: LocalizedStringResource = "Включить VPN"

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    _ = try await Client.shared.runCommand(.enable)
    return .result(dialog: "VPN включён.")
  }
}

struct DisableVPNIntent: AppIntent {
  static let title: LocalizedStringResource = "Выключить VPN"

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    _ = try await Client.shared.runCommand(.disable)
    return .result(dialog: "VPN выключен.")
  }
}

struct ChangeVPNServerIntent: AppIntent {
  static let title: LocalizedStringResource = "Сменить сервер"

  @Parameter(title: "Сервер VPN") var server: VPNServerEntity

  static var parameterSummary: some ParameterSummary {
    Summary("Выбрать \(\.$server)")
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    let result = try await Client.shared.runCommand(.changeServer(server.id))
    let dialog: IntentDialog = result == .switched ? "VPN подключён через \(server.name)." : "Выбран сервер \(server.name)."
    return .result(dialog: dialog)
  }
}

struct ReconnectVPNIntent: AppIntent {
  static let title: LocalizedStringResource = "Переподключиться"

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    _ = try await Client.shared.runCommand(.reconnect)
    return .result(dialog: "VPN подключён.")
  }
}

struct HyRouteShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(intent: EnableVPNIntent(), phrases: ["Включить VPN в \(.applicationName)"],
                shortTitle: "Включить VPN", systemImageName: "power")
    AppShortcut(intent: DisableVPNIntent(), phrases: ["Выключить VPN в \(.applicationName)"],
                shortTitle: "Выключить VPN", systemImageName: "poweroff")
    AppShortcut(intent: ChangeVPNServerIntent(), phrases: ["Сменить сервер в \(.applicationName)"],
                shortTitle: "Сменить сервер", systemImageName: "server.rack")
    AppShortcut(intent: ReconnectVPNIntent(), phrases: ["Переподключить VPN в \(.applicationName)"],
                shortTitle: "Переподключиться", systemImageName: "arrow.clockwise")
  }
}
