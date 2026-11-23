import Foundation
import NetworkExtension

@MainActor
protocol VPNCommandTarget {
  var vpnStatus: NEVPNStatus { get }
  var commandProfileID: String? { get }
  func startForCommand() async throws
  func stopForCommand() async throws
  func selectForCommand(_ id: String) async throws
  func waitForCommandStatus(connected: Bool) async throws
}

extension NEVPNStatus {
  var isActiveTunnel: Bool { self == .connected || self == .connecting || self == .reasserting }
}

enum VPNCommand: Equatable {
  case enable, disable, changeServer(String), reconnect

  enum Result: Equatable {
    case connected, disconnected, selected, switched
  }

  @MainActor
  func perform(on target: any VPNCommandTarget) async throws -> Result {
    switch self {
    case .enable:
      try await connect(target)
      return .connected
    case .disable:
      try await disconnect(target)
      return .disconnected
    case .changeServer(let id):
      let changed = id != target.commandProfileID
      try await target.selectForCommand(id)
      if changed && target.vpnStatus.isActiveTunnel {
        try await disconnect(target)
        try await connect(target)
        return .switched
      }
      return .selected
    case .reconnect:
      if target.vpnStatus.isActiveTunnel { try await disconnect(target) }
      try await connect(target)
      return .connected
    }
  }

  @MainActor
  private func connect(_ target: any VPNCommandTarget) async throws {
    if target.vpnStatus == .disconnecting { try await target.waitForCommandStatus(connected: false) }
    if !target.vpnStatus.isActiveTunnel { try await target.startForCommand() }
    try await target.waitForCommandStatus(connected: true)
  }

  @MainActor
  private func disconnect(_ target: any VPNCommandTarget) async throws {
    // Stop also disarms On Demand when iOS has already lost the connection.
    try await target.stopForCommand()
    try await target.waitForCommandStatus(connected: false)
  }
}
