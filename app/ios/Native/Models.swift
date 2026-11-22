import Foundation

enum RouteAction: String, Codable, CaseIterable, Identifiable {
  case tunnel, direct, block

  var id: Self { self }

  var label: String {
    switch self {
    case .tunnel: return "Через VPN"
    case .direct: return "Напрямую"
    case .block: return "Блокировать"
    }
  }

  var symbol: String {
    switch self {
    case .tunnel: return "lock.shield"
    case .direct: return "arrow.up.right"
    case .block: return "hand.raised"
    }
  }
}

struct VPNProfile: Decodable, Identifiable {
  let id: String
  let name: String
  let host: String?
  let `protocol`: String?
  let balance: Bool?
  let balanceStrategy: String?
  let missing: Bool?

  var title: String {
    if !name.isEmpty { return name }
    return host ?? "Профиль VPN"
  }

  var transport: String {
    if balance == true { return "VLESS · \(balanceStrategy ?? "leastLoad")" }
    return `protocol` == "vless" ? "VLESS" : "Hysteria 2"
  }
}

struct Subscription: Decodable, Identifiable {
  let id: String
  let title: String?
  let servers: [VPNProfile]
  let canRefresh: Bool?

  var name: String {
    guard let title, !title.isEmpty else { return "Импортированные серверы" }
    return title
  }
}

struct RouteRule: Codable {
  var action: RouteAction = .tunnel
  var domains: [String]?
  var ports: String?
  var `protocol`: String?
  var profile: String?

  var title: String {
    var parts = domains ?? []
    if let ports, !ports.isEmpty { parts.append("Порт \(ports)") }
    if let `protocol`, !`protocol`.isEmpty { parts.append(`protocol`.uppercased()) }
    return parts.isEmpty ? "Любое назначение" : parts.joined(separator: " · ")
  }
}

struct Routing: Codable {
  var defaultAction: RouteAction = .tunnel
  var rules: [RouteRule] = []
  var viaProfiles: [String: String] = [:]

  init() {}

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    defaultAction = try values.decodeIfPresent(RouteAction.self, forKey: .defaultAction) ?? .tunnel
    rules = try values.decodeIfPresent([RouteRule].self, forKey: .rules) ?? []
    viaProfiles = try values.decodeIfPresent([String: String].self, forKey: .viaProfiles) ?? [:]
  }
}

struct ClientSettings: Codable {
  var selected: String?
  var routing = Routing()
  var appScope: String?
  var appPackages: [String]?

  init() {}

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    selected = try values.decodeIfPresent(String.self, forKey: .selected)
    routing = try values.decodeIfPresent(Routing.self, forKey: .routing) ?? Routing()
    appScope = try values.decodeIfPresent(String.self, forKey: .appScope)
    appPackages = try values.decodeIfPresent([String].self, forKey: .appPackages)
  }
}

struct ClientState: Decodable {
  var subscriptions: [Subscription] = []
  var settings = ClientSettings()

  var profiles: [VPNProfile] {
    let active = subscriptions.flatMap(\.servers).filter { $0.missing != true }
    return active.filter { $0.balance == true } + active.filter { $0.balance != true }
  }

  var selected: VPNProfile? {
    let available = profiles
    return available.first { $0.id == settings.selected } ?? available.first
  }
}
