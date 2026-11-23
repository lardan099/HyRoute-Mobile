import Darwin
import Foundation
import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider {
  private struct StartRequest {
    let state: String
    let trafficLogging: Bool
    let generation: Int
    let completion: (Error?) -> Void
  }

  private let worker = DispatchQueue(label: "io.hyroute.tunnel")
  private var packetBridge: PacketBridge?
  private var session: NSObject?
  private var probe: NSObject?
  private var probeToken: UUID?
  private var generation = 0
  private var pendingGeodata: (token: UUID, request: StartRequest)?
  private lazy var geodataReceiver: GeodataReceiver? = {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first.map {
      GeodataReceiver(directory: $0.appendingPathComponent("hyroute-tunnel-geo", isDirectory: true))
    }
  }()

  override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
    worker.async {
      self.cancelGeodataStart(.cancelled)
      self.generation += 1
      let manualState = options?["state"] as? String
      let journal = VPNStorage.tunnelJournal
      HyRouteRecordVPNEvent(journal, "vpn_provider_start")
      let recoveryEnabled = (self.protocolConfiguration as? NETunnelProviderProtocol)?
        .providerConfiguration?["recovery"] as? Bool == true
      let snapshot = manualState ?? (recoveryEnabled ? VPNStorage.recoveryState() : nil)
      guard let state = snapshot, !state.isEmpty else {
        HyRouteRecordVPNEvent(journal, TunnelStartError.missingOptions.journalEvent)
        completionHandler(TunnelStartError.missingOptions)
        return
      }
      let request = StartRequest(state: state, trafficLogging: options?["trafficLogging"] as? Bool == true,
                                 generation: self.generation, completion: completionHandler)
      if manualState == nil {
        HyRouteRecordVPNEvent(journal, "vpn_system_restart")
        let shared = VPNStorage.sharedGeodata
        self.openTunnel(request, geodata: shared ?? Self.emptyGeodataDirectory,
                        sharedGeodataAvailable: shared.map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false)
      } else if let data = options?["geoSnapshot"] as? Data, data.count <= GeodataTransfer.inlineLimit {
        self.openWithGeodata(request) { HyRouteInstallVPNGeodataSnapshot(data, $0.path) }
      } else if let tokenText = options?["geoTransferToken"] as? String, let token = UUID(uuidString: tokenText) {
        self.pendingGeodata = (token, request)
        self.worker.asyncAfter(deadline: .now() + GeodataTransfer.startupTimeout) { [weak self] in
          guard let self, self.pendingGeodata?.token == token else { return }
          self.cancelGeodataStart(.geodataTransfer)
        }
      } else if HyRouteVPNGeodataKinds(state).isEmpty {
        self.openTunnel(request, geodata: Self.emptyGeodataDirectory)
      } else {
        self.failGeodataStart(request)
      }
    }
  }

  private static var emptyGeodataDirectory: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("hyroute-geo-unavailable", isDirectory: true)
  }

  private func openWithGeodata(_ request: StartRequest, install: (URL) -> Bool) {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("hyroute-vpn-geo-\(UUID().uuidString)", isDirectory: true)
    let files = FileManager.default
    defer { try? files.removeItem(at: directory) }
    do {
      try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      guard install(directory) else {
        failGeodataStart(request)
        return
      }
      openTunnel(request, geodata: directory)
    } catch {
      failGeodataStart(request)
    }
  }

  private func failGeodataStart(_ request: StartRequest) {
    let error = TunnelStartError.geodataTransfer
    HyRouteRecordVPNEvent(VPNStorage.tunnelJournal, error.journalEvent)
    request.completion(error)
  }

  private func cancelGeodataStart(_ error: TunnelStartError) {
    guard let pending = pendingGeodata else { return }
    pendingGeodata = nil
    geodataReceiver?.abort()
    HyRouteRecordVPNEvent(VPNStorage.tunnelJournal, error.journalEvent)
    pending.request.completion(error)
  }

  private func openTunnel(_ request: StartRequest, geodata: URL, sharedGeodataAvailable: Bool = true) {
    let journal = VPNStorage.tunnelJournal
    var issue: NSString?
    guard let plan = HyRoutePlanVPN(request.state, geodata.path, &issue) else {
      let failure = TunnelStartError.planFailure(issue as String?, sharedGeodataAvailable: sharedGeodataAvailable)
      HyRouteRecordVPNEvent(journal, failure.journalEvent)
      request.completion(failure)
      return
    }
    guard let prepared = HyRoutePrepareVPN(plan) else {
      HyRouteRecordVPNEvent(journal, TunnelStartError.preparation.journalEvent)
      request.completion(TunnelStartError.preparation)
      return
    }

    HyRouteRecordVPNEvent(journal, "vpn_interface")
    self.setTunnelNetworkSettings(Self.networkSettings()) { error in
      self.worker.async {
        guard request.generation == self.generation else {
          request.completion(TunnelStartError.cancelled)
          return
        }
        do {
          if let error { throw error }
          let bridge = try PacketBridge(flow: self.packetFlow, queue: self.worker)
          guard let session = HyRouteStartVPN(prepared, bridge.coreFD) else {
            bridge.close()
            throw TunnelStartError.engine
          }
          self.packetBridge = bridge
          self.session = session
          HyRouteSetTrafficLogging(session, request.trafficLogging)
          bridge.start()
          HyRouteRecordVPNEvent(journal, "vpn_running")
          request.completion(nil)
        } catch {
          let startError = error as? TunnelStartError ?? .networkSettings
          let detail = error as NSError
          let source = detail.domain == TunnelStartError.errorDomain ? "PacketTunnel" : detail.domain
          HyRouteRecordVPNError(journal, startError.journalEvent, source, Int32(clamping: detail.code))
          request.completion(startError)
        }
      }
    }
  }

  override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
    worker.async {
      self.generation += 1
      self.cancelGeodataStart(.cancelled)
      if let probe = self.probe { HyRouteCancelProbe(probe) }
      self.probe = nil
      self.probeToken = nil
      if let session = self.session { HyRouteStopVPN(session) }
      self.session = nil
      self.packetBridge?.close()
      self.packetBridge = nil
      HyRouteRecordVPNEvent(VPNStorage.tunnelJournal, "vpn_stopped")
      completionHandler()
    }
  }

  override func handleAppMessage(_ data: Data, completionHandler: ((Data?) -> Void)?) {
    worker.async {
      if data.count <= 256, let command = try? JSONDecoder().decode(TrafficCommand.self, from: data) {
        guard let session = self.session else {
          completionHandler?(nil)
          return
        }
        switch command.action {
        case .trafficStatus: break
        case .trafficSet:
          HyRouteSetTrafficLogging(session, command.enabled == true)
        case .trafficClear:
          HyRouteClearTrafficEvents(session)
        }
        completionHandler?(Data(HyRouteTrafficEvents(session).utf8))
        return
      }
      if data.count <= 64 * 1024, let transfer = try? PropertyListDecoder().decode(GeodataTransfer.self, from: data) {
        if transfer.action == .checkRecovery {
          completionHandler?(Self.recoveryStorageAvailable() ? GeodataTransfer.Reply.ready.data : nil)
          return
        }
        guard let pending = self.pendingGeodata, pending.token == transfer.token,
              let receiver = self.geodataReceiver else {
          completionHandler?(nil)
          return
        }
        if transfer.action == .awaitingSnapshot {
          completionHandler?(GeodataTransfer.Reply.ready.data)
          return
        }
        let reply = receiver.receive(transfer)
        completionHandler?(reply?.data)
        if (transfer.action == .begin && reply == .current) || (transfer.action == .finish && reply == .ready) {
          self.pendingGeodata = nil
          self.openWithGeodata(pending.request) { HyRouteInstallVPNGeodataSnapshotFile(receiver.archive.path, $0.path) }
        } else if transfer.action == .cancel {
          self.cancelGeodataStart(.geodataTransfer)
        }
        return
      }
      guard let command = try? JSONDecoder().decode(ProbeCommand.self, from: data) else {
        completionHandler?(nil)
        return
      }
      switch command.action {
      case .start:
        if let probe = self.probe { HyRouteCancelProbe(probe) }
        self.probeToken = command.token
        if let state = command.state, let scope = command.scope, let id = command.id {
          self.probe = HyRouteStartProbe(state, scope, id, VPNStorage.tunnelJournal)
        } else {
          self.probe = nil
        }
      case .status:
        guard self.probeToken == command.token else {
          completionHandler?(nil)
          return
        }
      case .cancel:
        if self.probeToken == command.token {
          if let probe = self.probe { HyRouteCancelProbe(probe) }
          self.probe = nil
          self.probeToken = nil
        }
        completionHandler?(Data())
        return
      }
      let snapshot = self.probe.flatMap { HyRouteProbeSnapshot($0) }
      completionHandler?(snapshot.map { Data($0.utf8) })
    }
  }

  private static func recoveryStorageAvailable() -> Bool {
    guard let state = VPNStorage.recoveryState(), !state.isEmpty else { return false }
    if HyRouteVPNGeodataKinds(state).isEmpty { return true }
    guard let directory = VPNStorage.sharedGeodata else { return false }
    return FileManager.default.isReadableFile(atPath: directory.path)
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
