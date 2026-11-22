import CryptoKit
import Flutter
import Security
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()
    let channel = FlutterMethodChannel(
      name: "io.hyroute/core",
      binaryMessenger: messenger,
      codec: FlutterStandardMethodCodec.sharedInstance(),
      taskQueue: messenger.makeBackgroundTaskQueue?()
    )
    channel.setMethodCallHandler { call, result in
      let args = call.arguments as? [String: Any] ?? [:]
      let failure = FlutterError(code: "core", message: nil, details: nil)
      do {
        let store = ClientStore()
        switch call.method {
        case "loadState":
          let folder = try store.prepareDirectory()
          HyRouteConfigureGeo(folder.appendingPathComponent("geo", isDirectory: true).path)
          if let view = HyRouteStateView(try store.read()) {
            result(view)
          } else {
            result(failure)
          }
        case "importSubscription":
          guard let input = args["input"] as? String,
            let updated = HyRouteAddSubscription(try store.read(), input, args["fromUrl"] as? Bool ?? false),
            let view = HyRouteStateView(updated)
          else {
            result(failure)
            return
          }
          try store.write(updated)
          result(view)
        case "saveSettings":
          guard let settings = args["settings"] as? String,
            let updated = HyRouteSaveSettings(try store.read(), settings)
          else {
            result(failure)
            return
          }
          try store.write(updated)
          result(nil)
        case "geoTags":
          if let tags = HyRouteGeoTags() {
            result(tags)
          } else {
            result(failure)
          }
        case "updateGeo":
          result(HyRouteUpdateGeo() ? nil : failure)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: "storage", message: nil, details: nil))
      }
    }
  }
}

private struct ClientStore {
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
