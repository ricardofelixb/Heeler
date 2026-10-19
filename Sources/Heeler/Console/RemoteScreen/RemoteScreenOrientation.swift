import SwiftUI
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

/// Full control of a Host's screen, in a window of its own above the app.
/// Turned sideways, only this window's content matters: the app underneath
/// is covered, and back upright before the window goes, so its sheets and
/// layout never show mid-turn.
@MainActor
enum RemoteScreenPresenter {
    private static var window: UIWindow?

    static func present(
        title: String,
        makeSession: @escaping () -> RemoteScreenSession,
        onClose: @escaping () -> Void
    ) {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
        else { return }
        let previousKey = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.backgroundColor = .black
        window.rootViewController = UIHostingController(rootView: RemoteScreenFullView(
            title: title, makeSession: makeSession,
            onClose: { close(restoring: previousKey, then: onClose) }))
        self.window = window
        window.makeKeyAndVisible()
        RemoteScreenOrientation.allowsLandscape = true
    }

    private static func close(restoring previousKey: UIWindow?, then onClose: @escaping () -> Void) {
        guard let window else { return }
        let wasSideways = window.windowScene?.effectiveGeometry.interfaceOrientation.isLandscape == true
        RemoteScreenOrientation.allowsLandscape = false
        Task {
            // Covers the app while it turns back upright.
            if wasSideways { try? await Task.sleep(for: .milliseconds(450)) }
            window.isHidden = true
            Self.window = nil
            previousKey?.makeKey()
            onClose()
        }
    }
}
