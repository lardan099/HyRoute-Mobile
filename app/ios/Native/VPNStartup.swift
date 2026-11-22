import Foundation
import NetworkExtension

struct VPNStartup {
  enum Outcome: Equatable { case waiting, connected, rejected, timedOut }

  private var sawTransition = false

  mutating func observe(_ status: NEVPNStatus, elapsed: Duration) -> Outcome {
    switch status {
    case .connected:
      return .connected
    case .connecting, .reasserting, .disconnecting:
      sawTransition = true
    case .disconnected, .invalid:
      if sawTransition || elapsed >= .seconds(8) { return .rejected }
    @unknown default:
      break
    }
    return elapsed >= .seconds(35) ? .timedOut : .waiting
  }
}

enum TunnelStartError: Int, CustomNSError {
  case configuration = 1, preparation = 2, networkSettings = 3, engine = 4, cancelled = 5
  case missingOptions = 6, unreadableState = 7, noProfile = 8, rules = 9
  case geodata = 10, missingReference = 11, unsupportedProfile = 12, geodataSharedStorage = 13

  static let errorDomain = "io.hyroute.packet-tunnel"
  var errorCode: Int { rawValue }

  var journalEvent: String {
    switch self {
    case .configuration: return "vpn_plan_error"
    case .missingOptions: return "vpn_options_missing"
    case .unreadableState: return "vpn_state_error"
    case .noProfile: return "vpn_profile_missing"
    case .rules: return "vpn_rules_error"
    case .geodata: return "vpn_geo_error"
    case .geodataSharedStorage: return "vpn_geo_shared_error"
    case .missingReference: return "vpn_reference_missing"
    case .unsupportedProfile: return "vpn_profile_unsupported"
    case .preparation: return "vpn_prepare_error"
    case .networkSettings: return "vpn_tun_error"
    case .engine: return "vpn_engine_error"
    case .cancelled: return "vpn_cancelled"
    }
  }

  var userMessage: String {
    switch self {
    case .configuration: return "VPN-расширение отклонило настройки. Проверьте выбранный профиль и правила."
    case .missingOptions: return "iOS не передала настройки расширению. Откройте HyRoute и подключитесь на главном экране."
    case .unreadableState: return "Расширение не смогло прочитать настройки HyRoute."
    case .noProfile: return "Выберите доступный профиль VPN на главном экране."
    case .rules: return "Не удалось применить локальные правила. Откройте «Правила» и проверьте условия."
    case .geodata: return "Расширение не нашло базу или категорию GeoSite/GeoIP. Обновите базы в настройках правил."
    case .geodataSharedStorage: return "VPN-расширению недоступно общее хранилище GeoSite/GeoIP. При установке IPA приложению и расширению нужен один App Group."
    case .missingReference: return "Правило или цепочка использует недоступный профиль. Откройте «Правила» и замените его или удалите связь."
    case .unsupportedProfile: return "Профиль содержит неподдерживаемые параметры соединения."
    case .preparation: return "Не удалось подготовить VPN. Проверьте доступность сервера и настройки профиля."
    case .networkSettings: return "iOS не смогла настроить интерфейс VPN."
    case .engine: return "VPN-расширение запустилось, но сетевое ядро не смогло подключить интерфейс."
    case .cancelled: return "Запуск VPN отменён."
    }
  }

  static func planFailure(_ issue: String?, sharedGeodataAvailable: Bool = true) -> Self {
    switch issue {
    case "state": return .unreadableState
    case "profile": return .noProfile
    case "rules": return .rules
    case "geo": return sharedGeodataAvailable ? .geodata : .geodataSharedStorage
    case "reference": return .missingReference
    case "unsupported": return .unsupportedProfile
    default: return .configuration
    }
  }
}
