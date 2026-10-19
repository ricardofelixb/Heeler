import UIKit

/// Only a Host's screen in full control turns sideways with the phone; the
/// rest of the app stays upright on iPhone.
@MainActor
enum RemoteScreenOrientation {
    static var allowsLandscape = false {
        didSet { if allowsLandscape != oldValue { apply() } }
    }

    static var mask: UIInterfaceOrientationMask {
        if UIDevice.current.userInterfaceIdiom == .pad { return .all }
        return allowsLandscape ? .allButUpsideDown : .portrait
    }

    private static func apply() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            if !allowsLandscape, UIDevice.current.userInterfaceIdiom != .pad {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
            }
        }
    }
}

extension PushRegistrationDelegate {
    func application(
        _ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        RemoteScreenOrientation.mask
    }
}
