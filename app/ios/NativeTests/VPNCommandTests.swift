import NetworkExtension

@MainActor
private final class TestTunnel: VPNCommandTarget {
  enum Failure: Error { case selection, start, stop, wait }
  var vpnStatus: NEVPNStatus
  var commandProfileID: String? = "old"
  var failure: Failure?
  var actions: [String] = []

  init(_ status: NEVPNStatus) { vpnStatus = status }

  func startForCommand() async throws {
    actions.append("start:\(commandProfileID ?? "")")
    if failure == .start { throw Failure.start }
    vpnStatus = .connecting
  }

  func stopForCommand() async throws {
    actions.append("stop")
    if failure == .stop { throw Failure.stop }
    if vpnStatus.isActiveTunnel { vpnStatus = .disconnecting }
  }

  func selectForCommand(_ id: String) async throws {
    actions.append("select:\(id)")
    if failure == .selection { throw Failure.selection }
    commandProfileID = id
  }

  func waitForCommandStatus(connected: Bool) async throws {
    actions.append(connected ? "wait:up" : "wait:down")
    if failure == .wait { throw Failure.wait }
    vpnStatus = connected ? .connected : .disconnected
  }
}

@main
struct VPNCommandTests {
  @MainActor
  static func main() async throws {
    let cases: [(VPNCommand, NEVPNStatus, VPNCommand.Result, [String])] = [
      (.enable, .invalid, .connected, ["start:old", "wait:up"]),
      (.enable, .disconnected, .connected, ["start:old", "wait:up"]),
      (.enable, .connected, .connected, ["wait:up"]),
      (.enable, .connecting, .connected, ["wait:up"]),
      (.enable, .reasserting, .connected, ["wait:up"]),
      (.enable, .disconnecting, .connected, ["wait:down", "start:old", "wait:up"]),
      (.disable, .connected, .disconnected, ["stop", "wait:down"]),
      (.disable, .connecting, .disconnected, ["stop", "wait:down"]),
      (.disable, .reasserting, .disconnected, ["stop", "wait:down"]),
      (.disable, .disconnected, .disconnected, ["stop", "wait:down"]),
      (.disable, .disconnecting, .disconnected, ["stop", "wait:down"]),
      (.changeServer("new"), .disconnected, .selected, ["select:new"]),
      (.changeServer("new"), .disconnecting, .selected, ["select:new"]),
      (.changeServer("old"), .connected, .selected, ["select:old"]),
      (.changeServer("new"), .connected, .switched, ["select:new", "stop", "wait:down", "start:new", "wait:up"]),
      (.changeServer("new"), .reasserting, .switched, ["select:new", "stop", "wait:down", "start:new", "wait:up"]),
      (.reconnect, .connected, .connected, ["stop", "wait:down", "start:old", "wait:up"]),
      (.reconnect, .disconnected, .connected, ["start:old", "wait:up"]),
      (.reconnect, .disconnecting, .connected, ["wait:down", "start:old", "wait:up"]),
    ]
    for (command, status, expected, actions) in cases {
      let target = TestTunnel(status)
      let result = try await command.perform(on: target)
      precondition(result == expected && target.actions == actions, "\(command) \(status): \(target.actions)")
    }

    let failures: [(VPNCommand, NEVPNStatus, TestTunnel.Failure, [String])] = [
      (.changeServer("deleted"), .connected, .selection, ["select:deleted"]),
      (.changeServer("new"), .connected, .stop, ["select:new", "stop"]),
      (.reconnect, .connected, .wait, ["stop", "wait:down"]),
      (.enable, .disconnected, .start, ["start:old"]),
      (.enable, .disconnected, .wait, ["start:old", "wait:up"]),
    ]
    for (command, status, failure, actions) in failures {
      let target = TestTunnel(status)
      target.failure = failure
      do {
        _ = try await command.perform(on: target)
        preconditionFailure("Command claimed success after \(failure)")
      } catch let observed as TestTunnel.Failure {
        precondition(observed == failure && target.actions == actions)
      }
    }
    print("VPN command cases passed: \(cases.count + failures.count)")
  }
}
