import ObjectiveC
import UIKit

/// Draws a circle under every touch, for screen recordings (the simulator's
/// recorder doesn't show taps). On only when launched with -demo or -showTouches.
/// Touches are read by swizzling UIWindow.sendEvent and drawn in a separate
/// pass-through window above everything, including sheets.
enum TouchIndicator {
	private static var overlay: UIWindow?
	private static var dots: [ObjectIdentifier: UIView] = [:]

	static func enableIfRequested() {
		let args = ProcessInfo.processInfo.arguments
		guard args.contains("-demo") || args.contains("-showTouches"),
		      let original = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.sendEvent(_:))),
		      let replacement = class_getInstanceMethod(UIWindow.self, #selector(UIWindow.damon_sendEvent(_:)))
		else { return }
		method_exchangeImplementations(original, replacement)
	}

	fileprivate static func handle(_ event: UIEvent, in window: UIWindow) {
		guard event.type == .touches, window !== overlay, let touches = event.allTouches,
		      let scene = window.windowScene else { return }
		if overlay == nil || overlay?.windowScene !== scene {
			let w = UIWindow(windowScene: scene)
			w.windowLevel = .alert + 1
			w.isUserInteractionEnabled = false
			w.backgroundColor = .clear
			w.isHidden = false
			overlay = w
		}
		guard let overlay else { return }
		for touch in touches {
			let key = ObjectIdentifier(touch)
			let point = touch.location(in: overlay)
			switch touch.phase {
			case .began:
				let dot = UIView(frame: CGRect(x: 0, y: 0, width: 46, height: 46))
				dot.layer.cornerRadius = 23
				dot.backgroundColor = UIColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 0.35)
				dot.layer.borderColor = UIColor(red: 0.851, green: 0.467, blue: 0.341, alpha: 0.9).cgColor
				dot.layer.borderWidth = 2
				dot.center = point
				dot.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
				overlay.addSubview(dot)
				UIView.animate(withDuration: 0.12) { dot.transform = .identity }
				dots[key] = dot
			case .moved, .stationary:
				dots[key]?.center = point
			case .ended, .cancelled:
				if let dot = dots.removeValue(forKey: key) {
					UIView.animate(withDuration: 0.35, animations: {
						dot.alpha = 0
						dot.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
					}, completion: { _ in dot.removeFromSuperview() })
				}
			default:
				break
			}
		}
	}
}

extension UIWindow {
	/// After swizzling, this name points at UIKit's original sendEvent.
	@objc fileprivate func damon_sendEvent(_ event: UIEvent) {
		damon_sendEvent(event)
		TouchIndicator.handle(event, in: self)
	}
}
