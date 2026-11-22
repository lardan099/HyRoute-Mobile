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
  }
}
