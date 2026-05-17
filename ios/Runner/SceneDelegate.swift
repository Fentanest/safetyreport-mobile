import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  private let channelName = "com.fentanest.mysafetyreport/permissions"
  private let quickSyncType = "com.fentanest.mysafetyreport.quickSync"
  private let quickCrawlType = "com.fentanest.mysafetyreport.quickCrawl"
  private let syncEventType = "quick_sync"
  private let crawlEventType = "quick_crawl"
  private let prefsAppMode = "flutter.appMode"
  private let prefsBaseUrl = "flutter.baseUrl"
  private let prefsApiKey = "flutter.apiKey"
  private let prefsStandaloneUsername = "flutter.standaloneUsername"
  private let prefsStandaloneDemoMode = "flutter.standaloneDemoMode"
  private var pendingEventType: String?

  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UISceneConnectionOptions
  ) {
    if let shortcutType = connectionOptions.shortcutItem?.type {
      pendingEventType = eventType(for: shortcutType)
    }
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    refreshQuickActions()
  }

  override func sceneDidBecomeActive(_ scene: UIScene) {
    super.sceneDidBecomeActive(scene)
    refreshQuickActions()
    dispatchPendingQuickActionIfNeeded()
  }

  override func sceneWillResignActive(_ scene: UIScene) {
    refreshQuickActions()
    super.sceneWillResignActive(scene)
  }

  override func windowScene(
    _ windowScene: UIWindowScene,
    performActionFor shortcutItem: UIApplicationShortcutItem,
    completionHandler: @escaping (Bool) -> Void
  ) {
    pendingEventType = eventType(for: shortcutItem.type)
    dispatchPendingQuickActionIfNeeded(completionHandler: completionHandler)
  }

  private func refreshQuickActions() {
    let items = buildShortcutItems()
    DispatchQueue.main.async {
      UIApplication.shared.shortcutItems = items
    }
  }

  private func buildShortcutItems() -> [UIApplicationShortcutItem] {
    if isConfiguredStandalone() {
      return [
        UIApplicationShortcutItem(
          type: quickSyncType,
          localizedTitle: "동기화",
          localizedSubtitle: "데이터 동기화 실행",
          icon: UIApplicationShortcutIcon(systemImageName: "arrow.triangle.2.circlepath"),
          userInfo: nil
        ),
      ]
    }
    if isConfiguredServer() {
      return [
        UIApplicationShortcutItem(
          type: quickCrawlType,
          localizedTitle: "크롤링",
          localizedSubtitle: "서버 크롤링 시작",
          icon: UIApplicationShortcutIcon(systemImageName: "arrow.clockwise.circle"),
          userInfo: nil
        ),
      ]
    }
    return []
  }

  private func dispatchPendingQuickActionIfNeeded(
    completionHandler: ((Bool) -> Void)? = nil
  ) {
    guard let eventType = pendingEventType else {
      completionHandler?(false)
      return
    }
    pendingEventType = nil
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
      guard let controller = self.findFlutterViewController(from: self.window?.rootViewController)
      else {
        self.pendingEventType = eventType
        completionHandler?(false)
        return
      }
      let channel = FlutterMethodChannel(
        name: self.channelName,
        binaryMessenger: controller.binaryMessenger
      )
      channel.invokeMethod(
        "navigateToTab",
        arguments: [
          "tab": 6,
          "event_type": eventType,
        ]
      )
      completionHandler?(true)
    }
  }

  private func eventType(for shortcutType: String) -> String? {
    switch shortcutType {
    case quickSyncType:
      return syncEventType
    case quickCrawlType:
      return crawlEventType
    default:
      return nil
    }
  }

  private func isConfiguredStandalone() -> Bool {
    let defaults = UserDefaults.standard
    let appMode = defaults.string(forKey: prefsAppMode) ?? ""
    let username = defaults.string(forKey: prefsStandaloneUsername) ?? ""
    let demoMode = defaults.object(forKey: prefsStandaloneDemoMode) as? Bool ?? false
    return appMode == "standalone" && !username.isEmpty && !demoMode
  }

  private func isConfiguredServer() -> Bool {
    let defaults = UserDefaults.standard
    let appMode = defaults.string(forKey: prefsAppMode) ?? ""
    let baseUrl = defaults.string(forKey: prefsBaseUrl) ?? ""
    let apiKey = defaults.string(forKey: prefsApiKey) ?? ""
    return appMode != "standalone" && !baseUrl.isEmpty && !apiKey.isEmpty
  }

  private func findFlutterViewController(
    from controller: UIViewController?
  ) -> FlutterViewController? {
    if let flutterController = controller as? FlutterViewController {
      return flutterController
    }
    if let navigationController = controller as? UINavigationController {
      return findFlutterViewController(from: navigationController.visibleViewController)
    }
    if let tabBarController = controller as? UITabBarController {
      return findFlutterViewController(from: tabBarController.selectedViewController)
    }
    if let presented = controller?.presentedViewController {
      return findFlutterViewController(from: presented)
    }
    return nil
  }
}
