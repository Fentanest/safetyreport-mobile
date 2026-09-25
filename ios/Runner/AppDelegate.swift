import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private static let communityAuthChannel = "com.fentanest.mysafetyreport/community_auth"
  private static let communityAuthScheme = "com.fentanest.mysafetyreport"
  private static let communityAuthHost = "auth"
  private static let communityAuthPath = "/callback"

  /// Dart 가 `takePendingLink`·`getInitialLink` 를 부르기 전에 도착한 링크 보관함.
  private var pendingCommunityAuthLink: String?
  private var communityAuthChannelRef: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 콜드 스타트 딥링크: Android 의 보관함과 같은 역할. Dart 가 준비되면 `getInitialLink` 로 가져간다.
    if let url = launchOptions?[.url] as? URL, Self.isCommunityAuthLink(url) {
      pendingCommunityAuthLink = url.absoluteString
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.binaryMessenger
    let channel = FlutterMethodChannel(
      name: Self.communityAuthChannel,
      binaryMessenger: messenger
    )
    communityAuthChannelRef = channel
    channel.setMethodCallHandler { [weak self] call, result in
      switch call.method {
      case "takePendingLink", "getInitialLink":
        let link = self?.pendingCommunityAuthLink
        self?.pendingCommunityAuthLink = nil
        result(link)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  override func application(
    _ app: UIApplication,
    open url: URL,
    options: [UIApplication.OpenURLOptionsKey: Any] = [:]
  ) -> Bool {
    // Android `MainActivity.captureCommunityAuthLink` 와 같은 판정: scheme/host/path 정확히 일치만 받는다.
    if Self.isCommunityAuthLink(url) {
      pendingCommunityAuthLink = url.absoluteString
      communityAuthChannelRef?.invokeMethod("onCommunityAuthLink", arguments: nil)
      return true
    }
    return super.application(app, open: url, options: options)
  }

  private static func isCommunityAuthLink(_ url: URL) -> Bool {
    return url.scheme == communityAuthScheme
      && url.host == communityAuthHost
      && url.path == communityAuthPath
  }
}
