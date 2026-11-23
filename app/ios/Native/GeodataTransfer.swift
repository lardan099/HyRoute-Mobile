import CryptoKit
import Foundation

struct GeodataTransfer: Codable {
  enum Action: String, Codable { case begin, append, finish, cancel, checkRecovery, awaitingSnapshot }

  static let chunkSize = 48 * 1024
  static let inlineLimit = 24 * 1024
  static let startupTimeout: TimeInterval = 30
  static let maximumSize = 64 * 1024 * 1024

  let action: Action
  let token: UUID
  var fingerprint: Fingerprint?
  var chunk: Data?

  enum Reply: UInt8 {
    case ready = 1, current

    var data: Data { Data([rawValue]) }
  }

  struct Fingerprint: Codable, Equatable {
    let size: Int
    let digest: Data

    var isValid: Bool { (1...GeodataTransfer.maximumSize).contains(size) && digest.count == 32 }

    static func read(_ file: FileHandle) throws -> Self {
      try file.seek(toOffset: 0)
      var size = 0
      var hash = SHA256()
      while let chunk = try file.read(upToCount: GeodataTransfer.chunkSize), !chunk.isEmpty {
        size += chunk.count
        guard size <= GeodataTransfer.maximumSize else { throw CocoaError(.fileReadTooLarge) }
        hash.update(data: chunk)
      }
      try file.seek(toOffset: 0)
      return Self(size: size, digest: Data(hash.finalize()))
    }
  }

  static func sendSnapshot(_ data: Data, token: UUID, exchange: (Self) async throws -> Reply) async throws {
    let fingerprint = Fingerprint(size: data.count, digest: Data(SHA256.hash(data: data)))
    guard fingerprint.isValid else { throw CocoaError(.fileReadTooLarge) }
    let reply = try await exchange(Self(action: .begin, token: token, fingerprint: fingerprint))
    if reply == .current { return }
    do {
      for offset in stride(from: 0, to: data.count, by: chunkSize) {
        try Task.checkCancellation()
        let chunk = data.subdata(in: offset..<min(offset + chunkSize, data.count))
        _ = try await exchange(Self(action: .append, token: token, chunk: chunk))
      }
      _ = try await exchange(Self(action: .finish, token: token))
    } catch {
      _ = try? await exchange(Self(action: .cancel, token: token))
      throw error
    }
  }
}

// The archive is verified before replacing its existing copy in the tunnel sandbox.
// The provider calls this receiver only on its serial worker queue.
final class GeodataReceiver {
  private struct Pending {
    let token: UUID
    let expected: GeodataTransfer.Fingerprint
    let file: FileHandle
    var size = 0
    var hash = SHA256()
  }

  private let directory: URL
  let archive: URL
  private let staging: URL
  private var pending: Pending?

  init(directory: URL) {
    self.directory = directory
    archive = directory.appendingPathComponent("snapshot.zip")
    staging = directory.appendingPathComponent(".incoming")
  }

  func receive(_ request: GeodataTransfer) -> GeodataTransfer.Reply? {
    do { return try process(request) }
    catch {
      abort()
      return nil
    }
  }

  private func process(_ request: GeodataTransfer) throws -> GeodataTransfer.Reply? {
    let files = FileManager.default
    switch request.action {
    case .checkRecovery, .awaitingSnapshot:
      return nil
    case .begin:
      guard let expected = request.fingerprint, expected.isValid else { return nil }
      abort()
      var folder = directory
      try files.createDirectory(at: folder, withIntermediateDirectories: true)
      var attributes = URLResourceValues()
      attributes.isExcludedFromBackup = true
      try folder.setResourceValues(attributes)
      if let reader = try? FileHandle(forReadingFrom: archive) {
        defer { try? reader.close() }
        if (try? GeodataTransfer.Fingerprint.read(reader)) == expected { return .current }
      }
      #if os(iOS)
      try Data().write(to: staging, options: .completeFileProtectionUntilFirstUserAuthentication)
      #else
      try Data().write(to: staging)
      #endif
      pending = Pending(token: request.token, expected: expected,
                        file: try FileHandle(forWritingTo: staging))
    case .append:
      guard var transfer = pending, transfer.token == request.token else { return nil }
      guard let chunk = request.chunk, !chunk.isEmpty, chunk.count <= GeodataTransfer.chunkSize,
            chunk.count <= transfer.expected.size - transfer.size else {
        abort()
        return nil
      }
      try transfer.file.write(contentsOf: chunk)
      transfer.hash.update(data: chunk)
      transfer.size += chunk.count
      pending = transfer
    case .finish:
      guard let transfer = pending, transfer.token == request.token else { return nil }
      guard transfer.size == transfer.expected.size,
            Data(transfer.hash.finalize()) == transfer.expected.digest else {
        abort()
        return nil
      }
      try transfer.file.close()
      if files.fileExists(atPath: archive.path) {
        _ = try files.replaceItemAt(archive, withItemAt: staging)
      } else {
        try files.moveItem(at: staging, to: archive)
      }
      pending = nil
    case .cancel:
      guard pending?.token == request.token else { return nil }
      abort()
    }
    return .ready
  }

  func abort() {
    try? pending?.file.close()
    pending = nil
    try? FileManager.default.removeItem(at: staging)
  }
}
