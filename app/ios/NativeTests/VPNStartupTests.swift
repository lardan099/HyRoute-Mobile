import Foundation
import NetworkExtension

@main
struct VPNStartupTests {
  static func main() {
    var rejectedBeforeTransition = VPNStartup()
    precondition(rejectedBeforeTransition.observe(.disconnected, elapsed: .zero) == .waiting)
    precondition(rejectedBeforeTransition.observe(.disconnected, elapsed: .seconds(8)) == .rejected)

    var rejectedAfterTransition = VPNStartup()
    precondition(rejectedAfterTransition.observe(.connecting, elapsed: .seconds(1)) == .waiting)
    precondition(rejectedAfterTransition.observe(.disconnected, elapsed: .seconds(2)) == .rejected)

    var slowStartup = VPNStartup()
    precondition(slowStartup.observe(.connecting, elapsed: .seconds(15)) == .waiting)
    precondition(slowStartup.observe(.connecting, elapsed: .seconds(35)) == .timedOut)

    var connected = VPNStartup()
    precondition(connected.observe(.disconnected, elapsed: .seconds(2)) == .waiting)
    precondition(connected.observe(.connected, elapsed: .seconds(3)) == .connected)

    let error = TunnelStartError.preparation as NSError
    precondition(error.domain == TunnelStartError.errorDomain)
    precondition(TunnelStartError(rawValue: error.code) == .preparation)
    precondition(TunnelStartError.planFailure("geo") == .geodata)
    precondition(TunnelStartError.planFailure("reference") == .missingReference)
    precondition((TunnelStartError.geodata as NSError).code == 10)
    precondition((TunnelStartError.missingReference as NSError).code == 11)
    precondition(TunnelStartError.planFailure("geo", sharedGeodataAvailable: false) == .geodataSharedStorage)
    precondition((TunnelStartError.geodataSharedStorage as NSError).code == 13)

    var recovery = ChainRecoveryPolicy()
    var now = DispatchTime(uptimeNanoseconds: 1)
    for cooldown in [15, 30, 60, 120, 120] {
      precondition(!recovery.canRestart(networkAvailable: false, now: now))
      precondition(recovery.canRestart(networkAvailable: true, now: now))
      precondition(recovery.didRestart(now: now) == cooldown)
      precondition(!recovery.canRestart(networkAvailable: true, now: now + .seconds(cooldown - 1)))
      now = now + .seconds(cooldown)
    }
    recovery = ChainRecoveryPolicy()
    precondition(recovery.didRestart(now: now) == 15)
    print("VPN startup and chain cooldown cases passed")
  }
}
