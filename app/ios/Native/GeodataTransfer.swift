import CryptoKit
import Foundation

enum GeodataKind: String, Codable {
  case geoip, geosite

  var filename: String { rawValue + ".dat" }
}

struct GeodataTransfer: Codable {
  enum Action: String, Codable { case begin, append, finish, clear, cancel }

  static let chunkSize = 48 * 1024
  static let maximumSize = 300 * 1024 * 1024

  let action: Action
  let token: UUID
  var kind: GeodataKind?
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

  static func send(_ kind: GeodataKind, from directory: URL,
                   exchange: (Self) async throws -> Reply) async throws {
    let token = UUID()
    let source = directory.appendingPathComponent(kind.filename)
    let reader: FileHandle
    do { reader = try FileHandle(forReadingFrom: source) }
    catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
      _ = try await exchange(Self(action: .clear, token: token, kind: kind))
      return
    }
    defer { try? reader.close() }
    let fingerprint = try Fingerprint.read(reader)
    guard fingerprint.isValid else { throw CocoaError(.fileReadCorruptFile) }
    let reply = try await exchange(Self(action: .begin, token: token, kind: kind, fingerprint: fingerprint))
    if reply == .current { return }
    do {
      while let chunk = try reader.read(upToCount: chunkSize), !chunk.isEmpty {
        try Task.checkCancellation()
        _ = try await exchange(Self(action: .append, token: token, chunk: chunk))
      }
      _ = try await exchange(Self(action: .finish, token: token))
    } catch {
      _ = try? await exchange(Self(action: .cancel, token: token))
      throw error
    }
  }
}

// Each file is verified before replacing its existing copy in the tunnel sandbox.
// The provider calls this receiver only on its serial worker queue.
final class GeodataReceiver {
  private struct Pending {
    let token: UUID
    let kind: GeodataKind
    let expected: GeodataTransfer.Fingerprint
    let file: FileHandle
    var size = 0
    var hash = SHA256()
  }

  let directory: URL
  private let staging: URL
  private var pending: Pending?

  init(directory: URL) {
    self.directory = directory
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
    case .begin:
      guard let kind = request.kind, let expected = request.fingerprint, expected.isValid else { return nil }
      abort()
      var folder = directory
      try files.createDirectory(at: folder, withIntermediateDirectories: true)
      var attributes = URLResourceValues()
      attributes.isExcludedFromBackup = true
      try folder.setResourceValues(attributes)
      let existing = folder.appendingPathComponent(kind.filename)
      if let reader = try? FileHandle(forReadingFrom: existing) {
        defer { try? reader.close() }
        if (try? GeodataTransfer.Fingerprint.read(reader)) == expected { return .current }
      }
      #if os(iOS)
      try Data().write(to: staging, options: .completeFileProtectionUntilFirstUserAuthentication)
      #else
      try Data().write(to: staging)
      #endif
      pending = Pending(token: request.token, kind: kind, expected: expected,
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
      let destination = directory.appendingPathComponent(transfer.kind.filename)
      if files.fileExists(atPath: destination.path) {
        _ = try files.replaceItemAt(destination, withItemAt: staging)
      } else {
        try files.moveItem(at: staging, to: destination)
      }
      pending = nil
    case .clear:
      guard let kind = request.kind else { return nil }
      abort()
      let destination = directory.appendingPathComponent(kind.filename)
      if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
    case .cancel:
      guard pending?.token == request.token else { return nil }
      abort()
    }
    return .ready
  }

  private func abort() {
    try? pending?.file.close()
    pending = nil
    try? FileManager.default.removeItem(at: staging)
  }
}
