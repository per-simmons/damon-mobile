import SwiftUI
import UIKit

extension Color {
	init(hex: String) {
		let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
		var v: UInt64 = 0
		Scanner(string: s).scanHexInt64(&v)
		self.init(
			red: Double((v >> 16) & 0xFF) / 255,
			green: Double((v >> 8) & 0xFF) / 255,
			blue: Double(v & 0xFF) / 255
		)
	}

	static func dynamic(_ light: String, _ dark: String) -> Color {
		Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(Color(hex: dark)) : UIColor(Color(hex: light)) })
	}
}

/// Claude's palette: warm cream, soft greys, the coral accent.
enum Theme {
	static let bg = Color.dynamic("#FAF9F5", "#262624")
	static let side = Color.dynamic("#F5F4EF", "#1F1E1D")
	static let panel = Color.dynamic("#FFFFFF", "#30302E")
	static let text = Color.dynamic("#1F1E1D", "#F5F4EF")
	static let muted = Color.dynamic("#73726C", "#A6A39B")
	static let faint = Color.dynamic("#A3A29C", "#75736C")
	static let line = Color.dynamic("#E8E6DC", "#3A3936")
	static let bubble = Color.dynamic("#F0EEE6", "#393937")
	static let code = Color.dynamic("#F3F1EA", "#1F1E1D")
	static let accent = Color(hex: "#D97757")
	static let working = Color(hex: "#D4A03C")
	static let review = Color(hex: "#4F9D69")
	static let permission = Color(hex: "#D0544A")

	static func status(_ s: String?) -> Color? {
		switch s {
		case "working": working
		case "review": review
		case "permission": permission
		default: nil
		}
	}

	static func label(_ s: String?) -> String? {
		switch s {
		case "working": "Working"
		case "review": "Done"
		case "permission": "Needs you"
		default: nil
		}
	}

	static let serif = Font.system(size: 17, design: .serif)
}

struct StatusDot: View {
	let status: String?
	@State private var dim = false

	var body: some View {
		Circle()
			.fill(Theme.status(status) ?? .clear)
			.frame(width: 8, height: 8)
			.opacity(status == "working" && dim ? 0.3 : 1)
			.onAppear {
				guard status == "working" else { return }
				withAnimation(.easeInOut(duration: 0.7).repeatForever()) { dim = true }
			}
	}
}

struct Avatar: View {
	@EnvironmentObject var store: Store
	let name: String
	let icon: String?
	var color: String?
	var size: CGFloat = 32

	var body: some View {
		Group {
			if let url = store.iconURL(icon) {
				CachedImage(url: url) { letter }
			} else {
				letter
			}
		}
		.frame(width: size, height: size)
		.clipShape(Circle())
	}

	private var letter: some View {
		ZStack {
			Circle().fill(color.map { Color(hex: $0) } ?? Theme.faint)
			Text(String(name.first(where: \.isLetter) ?? "•").uppercased())
				.font(.system(size: size * 0.42, weight: .semibold))
				.foregroundStyle(.white)
		}
	}
}
