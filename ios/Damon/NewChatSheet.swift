import SwiftUI

/// Picker for a new chat: Claude Code on the Claude sub, or Codex on the ChatGPT sub.
struct NewChatSheet: View {
	let agentName: String
	let pick: (String) -> Void
	@Environment(\.dismiss) private var dismiss

	var body: some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("New chat with \(agentName)")
				.font(.system(size: 17, weight: .semibold))
				.padding(.top, 22)
			option("claude", logo: "ClaudeLogo", title: "Claude", detail: "Claude sub · skips permissions")
			option("codex", logo: "OpenAILogo", title: "Codex", detail: "ChatGPT sub · skips approvals")
			Spacer(minLength: 0)
		}
		.padding(.horizontal, 20)
		.background(Theme.bg)
		.presentationDetents([.height(250)])
		.presentationDragIndicator(.visible)
	}

	private func option(_ id: String, logo: String, title: String, detail: String) -> some View {
		Button {
			dismiss()
			pick(id)
		} label: {
			HStack(spacing: 14) {
				Image(logo)
					.resizable()
					.scaledToFit()
					.foregroundStyle(Theme.text)
					.frame(width: 30, height: 30)
					.frame(width: 48, height: 48)
					.background(Theme.bubble, in: RoundedRectangle(cornerRadius: 12))
				VStack(alignment: .leading, spacing: 2) {
					Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
					Text(detail).font(.system(size: 13)).foregroundStyle(Theme.muted)
				}
				Spacer()
				Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.faint)
			}
			.padding(12)
			.background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
			.overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
		}
		.buttonStyle(.plain)
		.accessibilityLabel(title)
	}
}
