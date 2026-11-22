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
      switch call.method {
      case "importSubscription":
        guard let input = args["input"] as? String,
          let preview = HyRoutePreview(input, args["fromUrl"] as? Bool ?? false)
        else {
          result(failure)
          return
        }
        result(preview)
      case "validateRouting":
        guard let configuration = args["configuration"] as? String,
          HyRouteValidate(configuration, args["selectedServer"] as? String ?? "")
        else {
          result(failure)
          return
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
