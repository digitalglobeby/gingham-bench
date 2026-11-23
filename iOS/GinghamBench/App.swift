import UIKit

// Gingham Bench for iPhone and iPad: the same live rows in Gingham,
// UITableView and UICollectionView (typical and tuned), SwiftUI Table and
// SwiftUI List, each scrolled down and up (steady, fast, flicks) while values
// change, and the frames each one gets. A UIKit app (no SwiftUI around the UIKit engines);
// the SwiftUI engines are hosted in their own UIHostingController.
//
// Launch arguments run the tests by themselves (see BenchResults.swift).
// Measure a Release build on a device: the simulator draws with the Mac.

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        // The bench's key: every row shown (see Shared/BenchKey.swift).
        BenchKey.register()
        return true
    }

    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = UINavigationController(rootViewController: BenchViewController())
        window.makeKeyAndVisible()
        self.window = window
    }
}
