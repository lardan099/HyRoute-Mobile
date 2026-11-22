import Darwin
import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private let worker = DispatchQueue(label: "io.hyroute.tunnel")
  private var packetBridge: PacketBridge?
  private var session: NSObject?
  private var generation = 0

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    worker.async {
      self.generation += 1
      let generation = self.generation
      let geodata = VPNStorage.sharedGeodata ?? FileManager.default.temporaryDirectory
        .appendingPathComponent("hyroute-geo-unavailable", isDirectory: true)
      guard let state = options?["state"] as? String,
            let prepared = HyRoutePrepareVPN(state, geodata.path) else {
        completionHandler(TunnelError.configuration)
        return
      }

      self.setTunnelNetworkSettings(Self.networkSettings()) { error in
        self.worker.async {
          guard generation == self.generation else {
            completionHandler(TunnelError.cancelled)
            return
          }
          do {
            if let error { throw error }
            let bridge = try PacketBridge(flow: self.packetFlow, queue: self.worker)
            guard let session = HyRouteStartVPN(prepared, bridge.coreFD) else {
              bridge.close()
              throw TunnelError.engine
            }
            self.packetBridge = bridge
            self.session = session
            bridge.start()
            completionHandler(nil)
          } catch {
            completionHandler(error)
          }
        }
      }
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    worker.async {
      self.generation += 1
      if let session = self.session { HyRouteStopVPN(session) }
      self.session = nil
      self.packetBridge?.close()
      self.packetBridge = nil
      completionHandler()
    }
  }

  private static func networkSettings() -> NEPacketTunnelNetworkSettings {
    let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.2")
    let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.252"])
    ipv4.includedRoutes = [NEIPv4Route.default()]
    settings.ipv4Settings = ipv4
    let ipv6 = NEIPv6Settings(addresses: ["fd72:cc0d:fe::1"], networkPrefixLengths: [64])
    ipv6.includedRoutes = [NEIPv6Route.default()]
    settings.ipv6Settings = ipv6
    settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1"])
    settings.mtu = 1400
    return settings
  }

  private enum TunnelError: Int, Error {
    case configuration, engine, cancelled
  }
}

// Xray reads datagrams with Darwin's four-byte utun address-family header.
// The socket pair stays inside the extension and uses no IP listener.
private final class PacketBridge {
  let coreFD: Int32
  private let fd: Int32
  private let flow: NEPacketTunnelFlow
  private let queue: DispatchQueue
  private var reader: DispatchSourceRead?
  private var closed = false

  init(flow: NEPacketTunnelFlow, queue: DispatchQueue) throws {
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    fd = descriptors[0]
    coreFD = descriptors[1]
    self.flow = flow
    self.queue = queue
  }

  func start() {
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.writeToInterface() }
    source.setCancelHandler { [fd] in _ = Darwin.close(fd) }
    reader = source
    source.resume()
    readInterface()
  }

  func close() {
    guard !closed else { return }
    closed = true
    if let reader { reader.cancel() } else { _ = Darwin.close(fd) }
    reader = nil
    _ = Darwin.close(coreFD)
  }

  private func readInterface() {
    flow.readPackets { [weak self] packets, families in
      guard let self else { return }
      self.queue.async {
        guard !self.closed else { return }
        for (packet, family) in zip(packets, families) {
          let version = family.int32Value
          guard version == AF_INET || version == AF_INET6 else { continue }
          var framed = Data([0, 0, 0, UInt8(version)])
          framed.append(packet)
          _ = framed.withUnsafeBytes { Darwin.send(self.fd, $0.baseAddress, $0.count, MSG_DONTWAIT) }
        }
        self.readInterface()
      }
    }
  }

  private func writeToInterface() {
    guard !closed else { return }
    var buffer = [UInt8](repeating: 0, count: 65_540)
    var packets: [Data] = []
    var families: [NSNumber] = []
    for _ in 0..<64 {
      let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, MSG_DONTWAIT) }
      guard count > 4 else { break }
      let family = Int32(buffer[3])
      guard family == AF_INET || family == AF_INET6 else { continue }
      packets.append(Data(buffer[4..<count]))
      families.append(NSNumber(value: family))
    }
    if !packets.isEmpty { _ = flow.writePackets(packets, withProtocols: families) }
  }
}
