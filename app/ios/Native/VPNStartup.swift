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
  case configuration = 1, preparation, networkSettings, engine, cancelled

  static let errorDomain = "io.hyroute.packet-tunnel"
  var errorCode: Int { rawValue }

  var journalEvent: String {
    switch self {
    case .configuration: return "vpn_plan_error"
    case .preparation: return "vpn_prepare_error"
    case .networkSettings: return "vpn_tun_error"
    case .engine: return "vpn_engine_error"
    case .cancelled: return "vpn_cancelled"
    }
  }

  var userMessage: String {
    switch self {
    case .configuration: return "VPN-расширение отклонило настройки. Проверьте выбранный профиль и правила."
    case .preparation: return "Не удалось подготовить VPN. Проверьте доступность сервера и настройки профиля."
    case .networkSettings: return "iOS не смогла настроить интерфейс VPN."
    case .engine: return "VPN-расширение запустилось, но сетевое ядро не смогло подключить интерфейс."
    case .cancelled: return "Запуск VPN отменён."
    }
  }
}
