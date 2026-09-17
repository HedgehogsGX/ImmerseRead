import SwiftUI
import UIKit

/// One screen, several suites. Swift Testing runs suites concurrently, so two
/// tests that each show a window can cover each other: the covered window stops
/// getting SwiftUI updates and its test waits for layout that never comes. A
/// test holds the screen from the moment it shows a window until it dismisses it.
@MainActor
final class ReaderTestScreen {
    private static var isHeld = false
    private static var waiting: [CheckedContinuation<Void, Never>] = []

    private let window: UIWindow
    private let previousKeyWindow: UIWindow?

    private init(window: UIWindow, previousKeyWindow: UIWindow?) {
        self.window = window
        self.previousKeyWindow = previousKeyWindow
    }

    static func show(_ controller: UIViewController) async -> ReaderTestScreen {
        while isHeld {
            await withCheckedContinuation { waiting.append($0) }
        }
        isHeld = true

        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let previousKeyWindow = scenes.flatMap(\.windows).first(where: \.isKeyWindow)
        let window = scenes.first.map(UIWindow.init(windowScene:))
            ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        return ReaderTestScreen(window: window, previousKeyWindow: previousKeyWindow)
    }

    /// Swaps in another controller, for tests that reopen a document.
    func present(_ controller: UIViewController) {
        window.rootViewController = controller
    }

    func dismiss() {
        window.isHidden = true
        window.rootViewController = nil
        previousKeyWindow?.makeKey()

        Self.isHeld = false
        let resumed = Self.waiting
        Self.waiting.removeAll()
        resumed.forEach { $0.resume() }
    }
}
