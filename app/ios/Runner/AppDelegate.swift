import Flutter
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
        case "importSubscription", "refreshSubscription":
          let state = try store.read()
          let updated: String?
          if call.method == "refreshSubscription" {
            updated = (args["id"] as? String).flatMap { HyRouteRefreshSubscription(state, $0) }
          } else {
            updated = (args["input"] as? String).flatMap {
              HyRouteAddSubscription(state, $0, args["fromUrl"] as? Bool ?? false)
            }
          }
          guard let updated, let view = HyRouteStateView(updated) else {
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
