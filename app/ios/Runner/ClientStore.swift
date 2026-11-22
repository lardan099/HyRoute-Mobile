import CryptoKit
import Foundation
import Security

struct ClientStore {
  private let keychainItem: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "io.hyroute.client-state",
    kSecAttrAccount as String: "v1",
  ]

  private func key(create: Bool) throws -> SymmetricKey {
    var query = keychainItem
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    var found: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &found)
    if status == errSecSuccess {
      guard let data = found as? Data, data.count == 32 else {
        throw CocoaError(.fileReadCorruptFile)
      }
      return SymmetricKey(data: data)
    }
    guard create, status == errSecItemNotFound else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
    }
    let key = SymmetricKey(size: .bits256)
    var item = keychainItem
    item[kSecValueData as String] = key.withUnsafeBytes { Data($0) }
    item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let added = SecItemAdd(item as CFDictionary, nil)
    guard added == errSecSuccess else {
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(added))
    }
    return key
  }

  private func directory() throws -> URL {
    try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false
    ).appendingPathComponent("HyRoute", isDirectory: true)
  }

  func read() throws -> String {
    let url = try directory().appendingPathComponent("client-state.v1")
    let content: Data
    do {
      content = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return ""
    }
    let box = try AES.GCM.SealedBox(combined: content)
    let decrypted = try AES.GCM.open(box, using: key(create: false))
    guard let state = String(data: decrypted, encoding: .utf8) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return state
  }

  func prepareDirectory() throws -> URL {
    var folder = try directory()
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var properties = URLResourceValues()
    properties.isExcludedFromBackup = true
    try folder.setResourceValues(properties)
    return folder
  }

  func write(_ state: String) throws {
    let folder = try prepareDirectory()
    let url = folder.appendingPathComponent("client-state.v1")
    let box = try AES.GCM.seal(Data(state.utf8), using: key(create: true))
    guard let content = box.combined else { throw CocoaError(.fileWriteUnknown) }
    try content.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
}
