import Foundation

struct VPNJournalEvent: Decodable, Hashable {
  let at: Int64
  let message: String

  static func lines(_ data: Data, timeZone: TimeZone = .autoupdatingCurrent) throws -> [String] {
    lines(try JSONDecoder().decode([Self].self, from: data), timeZone: timeZone)
  }

  static func lines(_ events: [Self], timeZone: TimeZone = .autoupdatingCurrent) -> [String] {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "dd.MM HH:mm:ss"
    return events.map { event in
      let date = Date(timeIntervalSince1970: Double(event.at) / 1000)
      return formatter.string(from: date) + "  " + event.message
    }
  }
}

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

  var help: String {
    switch self {
    case .tunnel: return "Отправлять через выбранный VPN-профиль."
    case .direct: return "Подключаться без VPN."
    case .block: return "Запрещать подключение."
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

func ruleDestinations(_ input: String) -> [String] {
  var seen = Set<String>()
  return input.components(separatedBy: .newlines).compactMap { line in
    let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
    let url = URLComponents(string: text)
    var value = text
    if let scheme = url?.scheme?.lowercased(), ["http", "https"].contains(scheme),
       let host = url?.host, !host.isEmpty {
      value = host.hasPrefix("[") && host.hasSuffix("]")
        ? String(host.dropFirst().dropLast()) : host
    }
    return !value.isEmpty && seen.insert(value).inserted ? value : nil
  }
}

enum RuleDomainCondition: CaseIterable, Hashable {
  case suffix, contains

  var label: String { self == .suffix ? "Домен заканчивается на" : "В домене есть" }
  var example: String { self == .suffix ? ".ru" : "video" }
  var exampleMatch: String { self == .suffix ? "Например, .ru подходит для mail.yandex.ru." : "Например, video подходит для cdn-video.example.org." }

  func value(from pattern: String) -> String? {
    switch self {
    case .suffix: return pattern.hasPrefix(".") && pattern.count > 1 ? pattern : nil
    case .contains:
      let prefix = "keyword:"
      guard pattern.lowercased().hasPrefix(prefix), pattern.count > prefix.count else { return nil }
      return String(pattern.dropFirst(prefix.count))
    }
  }

  func patterns(_ input: String) -> [String]? {
    var output: [String] = []
    let invalid = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "/:*?#"))
    for item in ruleDestinations(input) {
      var text = value(from: item) ?? item
      if self == .suffix {
        if text.hasPrefix("*.") { text.removeFirst(2) }
        if text.hasPrefix(".") { text.removeFirst() }
      }
      guard !text.isEmpty, text.rangeOfCharacter(from: invalid) == nil,
            self != .suffix || (!text.hasPrefix(".") && !text.contains("..")) else { return nil }
      output.append((self == .suffix ? "." : "keyword:") + text)
    }
    return output
  }

  static func summary(_ pattern: String) -> String {
    if let suffix = Self.suffix.value(from: pattern) { return "Окончание \(suffix)" }
    if let word = Self.contains.value(from: pattern) { return "Содержит «\(word)»" }
    return pattern
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
    if `protocol` == "group" { return "Группа серверов" }
    if balance == true { return "VLESS · \(balanceStrategy ?? "leastLoad")" }
    return `protocol` == "vless" ? "VLESS" : "Hysteria 2"
  }
}

struct ServerGroup: Codable, Identifiable {
  var id: String = ""
  var name: String
  var primary: [String]
  var reserve: String
}

struct SplitDNS: Codable {
  var tunnel: String
  var direct: String
  var domains: [String]
}

struct Subscription: Decodable, Identifiable {
  let id: String
  let title: String?
  let servers: [VPNProfile]
  let canRefresh: Bool?
  let usedBytes: Int64?
  let limitBytes: Int64?
  let expiresAt: Int64?
  let refreshedAt: Int64?
  let attemptedAt: Int64?
  let refreshFailed: Bool?

  var name: String {
    guard let title, !title.isEmpty else { return "Импортированные серверы" }
    return title
  }
}

struct RoutingProfile: Decodable, Identifiable {
  let id: String
  let name: String
  let ruleCount: Int
}

struct CheckedRoute: Decodable {
  let target: String
  let action: RouteAction
  let rule: String
  let chain: [String]?
  let notes: [String]?
}

struct RouteRule: Codable {
  var action: RouteAction = .tunnel
  var domains: [String]?
  var ports: String?
  var `protocol`: String?
  var profile: String?
  var enabled: Bool?

  func hasUnavailableProfile(available: Set<String>) -> Bool {
    guard enabled != false, action == .tunnel, let profile, !profile.isEmpty else { return false }
    return !available.contains(profile)
  }

  var title: String {
    var parts = (domains ?? []).map(RuleDomainCondition.summary)
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

  func unavailableChainExits(available: Set<String>) -> [String] {
    viaProfiles.keys.filter { exit in
      guard let entry = viaProfiles[exit] else { return false }
      return !available.contains(exit) || !available.contains(entry)
    }.sorted()
  }

  func unavailableRuleIndices(available: Set<String>) -> [Int] {
    rules.indices.filter { rules[$0].hasUnavailableProfile(available: available) }
  }

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
  var splitDNS: SplitDNS?

  init() {}

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    selected = try values.decodeIfPresent(String.self, forKey: .selected)
    routing = try values.decodeIfPresent(Routing.self, forKey: .routing) ?? Routing()
    appScope = try values.decodeIfPresent(String.self, forKey: .appScope)
    appPackages = try values.decodeIfPresent([String].self, forKey: .appPackages)
    splitDNS = try values.decodeIfPresent(SplitDNS.self, forKey: .splitDNS)
  }
}

struct ClientState: Decodable {
  var subscriptions: [Subscription] = []
  var settings = ClientSettings()
  var activeRoutingProfile: String?
  var routingProfiles: [RoutingProfile]?
  var serverGroups: [ServerGroup]?
  var groupServers: [VPNProfile]?

  var ruleSets: [RoutingProfile] {
    routingProfiles ?? [RoutingProfile(id: "default", name: "Основной", ruleCount: settings.routing.rules.count)]
  }

  var activeRuleSet: RoutingProfile? {
    ruleSets.first { $0.id == (activeRoutingProfile ?? "default") }
  }

  var profiles: [VPNProfile] {
    let active = subscriptions.flatMap(\.servers).filter { $0.missing != true }
    return active.filter { $0.balance == true } + active.filter { $0.balance != true }
  }

  var selected: VPNProfile? {
    let available = profiles
    return available.first { $0.id == settings.selected } ?? available.first
  }

  var chainProfiles: [VPNProfile] { profiles.filter { $0.protocol != "group" } }

  func profileTitle(_ id: String) -> String {
    let profile = subscriptions.lazy.flatMap(\.servers).first { $0.id == id }
    guard let profile else { return "Удалённый профиль" }
    return profile.missing == true ? "\(profile.title) · недоступен" : profile.title
  }
}
