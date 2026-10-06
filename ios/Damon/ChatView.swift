import PhotosUI
import SwiftUI

struct ChatView: View {
	@EnvironmentObject var store: Store
	@StateObject private var model: ChatModel
	let route: Route
	@State private var draft = ""
	@State private var showKeys = false
	@State private var atBottom = true
	@State private var starting = false
	@StateObject private var dictation = Dictation()
	@State private var dictationBase = ""
	@State private var title: String
	@State private var photoPicks: [PhotosPickerItem] = []
	@State private var attachments: [UIImage] = []
	@State private var renaming = false
	@State private var renameDraft = ""
	@FocusState private var focused: Bool

	init(route: Route, store: Store) {
		self.route = route
		_model = StateObject(wrappedValue: ChatModel(paneId: route.chat.paneId ?? "", store: store))
		_title = State(initialValue: route.chat.title ?? "Chat")
	}

	private var status: String? { store.statuses[model.paneId] ?? model.initialStatus }
	private var agent: Agent { route.agent }

	var body: some View {
		ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(alignment: .leading, spacing: 20) {
					if model.before != nil {
						Button("Load earlier messages") { Task { await model.loadOlder() } }
							.font(.system(size: 13))
							.foregroundStyle(Theme.muted)
							.padding(.horizontal, 14).padding(.vertical, 7)
							.overlay(Capsule().stroke(Theme.line))
							.frame(maxWidth: .infinity)
					}
					if let note = model.note, model.items.isEmpty, model.pending.isEmpty {
						Text(note).font(.system(size: 15)).foregroundStyle(Theme.muted)
							.multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 40)
					}
					ForEach(model.items + model.pending) { item in
						MessageRow(item: item, agent: agent, railColor: route.rail.color).id(item.id)
					}
					Color.clear.frame(height: 1).id("bottom")
				}
				.padding(.horizontal, 16)
				.padding(.vertical, 14)
			}
			.defaultScrollAnchor(.bottom)
			.scrollDismissesKeyboard(.interactively)
			.onScrollGeometryChange(for: Bool.self) { geo in
				geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height < 160
			} action: { _, near in atBottom = near }
			.onChange(of: model.lastAppend) {
				if atBottom { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
			}
			.onChange(of: model.loading) {
				if !model.loading { proxy.scrollTo("bottom", anchor: .bottom) }
			}
		}
		.background(Theme.bg)
		.safeAreaInset(edge: .bottom) { dock }
		.navigationBarTitleDisplayMode(.inline)
		.toolbar {
			ToolbarItem(placement: .principal) {
				Button {
					renameDraft = title
					renaming = true
				} label: {
				HStack(spacing: 8) {
					Avatar(name: agent.name, icon: agent.icon, color: route.rail.color, size: 26)
					VStack(alignment: .leading, spacing: 0) {
						Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
						Text(route.rail.name == agent.name ? agent.name : "\(agent.name) · \(route.rail.name)")
							.font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
					}
				}
				}
				.buttonStyle(.plain)
				.accessibilityHint("Rename this chat")
			}
			ToolbarItem(placement: .topBarTrailing) {
				if let label = Theme.label(status) {
					Text(label)
						.font(.system(size: 12, weight: .medium))
						.padding(.horizontal, 10).padding(.vertical, 4)
						.foregroundStyle(status == "permission" ? .white : (Theme.status(status) ?? Theme.muted))
						.background(status == "permission" ? Theme.permission : Theme.bubble, in: Capsule())
				}
			}
		}
		.task {
			await model.load()
			if route.chat.hasTranscript == false && model.items.isEmpty && route.chat.lastActivity == nil {
				// Fresh tab: typing before Claude or Codex has started would land in the plain shell.
				starting = true
				model.note = "Starting \(route.chat.agent == "codex" ? "Codex" : "Claude") in a new Damon tab…"
				try? await Task.sleep(for: .seconds(9))
				starting = false
				if model.items.isEmpty { model.note = "New chat. Say something." }
			}
		}
		.alert("Rename chat", isPresented: $renaming) {
			TextField("Name", text: $renameDraft)
			Button("Rename") {
				let name = renameDraft
				Task {
					if await store.rename(tabId: route.chat.tabId, to: name) {
						title = name.trimmingCharacters(in: .whitespacesAndNewlines)
					}
				}
			}
			Button("Cancel", role: .cancel) {}
		} message: {
			Text("Renames the tab in Damon on your desktop too.")
		}
		.onDisappear { dictation.cancel(); store.unsubscribe(model) }
		.onChange(of: dictation.error) { _, message in
			if let message { store.loadError = message; dictation.error = nil }
		}
	}

	// MARK: Dock

	private var dock: some View {
		VStack(spacing: 8) {
			actionBar
			if showKeys { keysRow }
			if !attachments.isEmpty { attachmentStrip }
			composer
		}
		.padding(.horizontal, 12)
		.padding(.top, 6)
		.padding(.bottom, 8)
		.background(Theme.bg)
	}

	@ViewBuilder
	private var actionBar: some View {
		if status == "permission" {
			let tool = model.currentTool
			VStack(alignment: .leading, spacing: 10) {
				(Text("Needs your OK").foregroundStyle(Theme.muted)
					+ Text(tool.map { ": \($0.name)" } ?? "").bold()
					+ Text(tool.map { $0.summary.isEmpty ? "" : " · \($0.summary)" } ?? "").foregroundStyle(Theme.muted))
					.font(.system(size: 14))
				if let options = tool?.input?.questions?.first?.options, !options.isEmpty {
					FlowButtons(buttons: options.prefix(5).enumerated().map { i, o in ("\(i + 1). \(o.label)", "\(i + 1)", false) } + [("Cancel", "esc", false)]) { key in
						Task { await store.sendKey(key, pane: model.paneId) }
					}
				} else {
					FlowButtons(buttons: [("Allow", "1", true), ("Always allow", "2", false), ("Deny", "esc", false)]) { key in
						Task { await store.sendKey(key, pane: model.paneId) }
					}
				}
			}
			.padding(14)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(Theme.panel, in: RoundedRectangle(cornerRadius: 16))
			.overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
		} else if status == "working" {
			HStack(spacing: 10) {
				ProgressView().controlSize(.small).tint(Theme.accent)
				Text(model.currentTool.map { "Working · \($0.name) \($0.summary)" } ?? "Working…")
					.font(.system(size: 14)).foregroundStyle(Theme.muted).lineLimit(1)
				Spacer()
			}
			.padding(.horizontal, 6)
		}
	}

	private var keysRow: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 6) {
				ForEach([("Esc", "esc"), ("↑", "up"), ("↓", "down"), ("Enter", "enter"), ("1", "1"), ("2", "2"), ("3", "3"), ("⇧Tab", "shift-tab")], id: \.1) { label, key in
					Button(label) { Task { await store.sendKey(key, pane: model.paneId) } }
						.font(.system(size: 14, design: .monospaced))
						.padding(.horizontal, 12).padding(.vertical, 8)
						.background(Theme.panel, in: RoundedRectangle(cornerRadius: 9))
						.overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.line))
						.foregroundStyle(Theme.text)
				}
			}
		}
	}

	private var attachmentStrip: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				ForEach(Array(attachments.enumerated()), id: \.offset) { index, image in
					Image(uiImage: image).resizable().scaledToFill()
						.frame(width: 60, height: 60)
						.clipShape(RoundedRectangle(cornerRadius: 10))
						.overlay(alignment: .topTrailing) {
							Button { attachments.remove(at: index) } label: {
								Image(systemName: "xmark.circle.fill").font(.system(size: 18))
									.symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
							}
							.offset(x: 6, y: -6)
							.accessibilityLabel("Remove image")
						}
				}
			}
			.padding(.top, 6).padding(.horizontal, 4)
		}
	}

	private var hasDraft: Bool {
		!draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
	}

	private var composer: some View {
		HStack(alignment: .bottom, spacing: 6) {
			Button { showKeys.toggle() } label: {
				Image(systemName: "keyboard").font(.system(size: 17)).frame(width: 36, height: 36)
					.foregroundStyle(showKeys ? Theme.accent : Theme.muted)
			}
			PhotosPicker(selection: $photoPicks, maxSelectionCount: 4, matching: .images) {
				Image(systemName: "photo").font(.system(size: 17)).frame(width: 32, height: 36)
					.foregroundStyle(attachments.isEmpty ? Theme.muted : Theme.accent)
			}
			.accessibilityLabel("Attach images")
			.onChange(of: photoPicks) { _, picks in
				guard !picks.isEmpty else { return }
				Task {
					for pick in picks {
						if let data = try? await pick.loadTransferable(type: Data.self), let image = UIImage(data: data) {
							attachments.append(image)
						}
					}
					photoPicks = []
				}
			}
			TextField(starting ? "Starting \(route.chat.agent == "codex" ? "Codex" : "Claude")…" : "Reply to \(agent.name)…", text: $draft, axis: .vertical)
				.lineLimit(1...6)
				.font(.system(size: 16))
				.focused($focused)
				.accessibilityIdentifier("composer")
				.disabled(starting)
				.padding(.vertical, 8)
			MicButton(dictation: dictation) {
				if dictation.isRecording {
					dictation.stop()
				} else {
					// Dictation adds to whatever is already typed.
					dictationBase = draft.trimmingCharacters(in: .whitespacesAndNewlines)
					Task {
						await dictation.start { spoken in
							draft = dictationBase.isEmpty ? spoken : "\(dictationBase) \(spoken)"
						}
					}
				}
			}
			.disabled(starting)
			if status == "working" && !hasDraft && !dictation.isRecording {
				Button { Task { await store.sendKey("esc", pane: model.paneId) } } label: {
					Image(systemName: "stop.fill").font(.system(size: 13)).frame(width: 36, height: 36)
						.foregroundStyle(Theme.bg).background(Theme.text, in: Circle())
				}
			} else {
				Button {
					dictation.cancel()
					let text = draft
					let images = attachments
					draft = ""
					attachments = []
					Task { await model.send(text, images: images) }
				} label: {
					Image(systemName: "arrow.up").font(.system(size: 16, weight: .semibold)).frame(width: 36, height: 36)
						.foregroundStyle(.white).background(Theme.accent, in: Circle())
				}
				.accessibilityLabel("Send")
				.disabled(!hasDraft || starting)
				.opacity(hasDraft ? 1 : 0.35)
			}
		}
		.padding(6)
		.background(Theme.panel, in: RoundedRectangle(cornerRadius: 22))
		.overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.line))
		.shadow(color: .black.opacity(0.06), radius: 8, y: 2)
	}
}

struct FlowButtons: View {
	let buttons: [(String, String, Bool)]
	let tap: (String) -> Void

	var body: some View {
		ScrollView(.horizontal, showsIndicators: false) {
			HStack(spacing: 8) {
				ForEach(buttons, id: \.0) { label, key, primary in
					Button(label) { tap(key) }
						.font(.system(size: 14, weight: primary ? .semibold : .regular))
						.padding(.horizontal, 14).padding(.vertical, 9)
						.foregroundStyle(primary ? .white : Theme.text)
						.background(primary ? Theme.accent : Theme.bg, in: RoundedRectangle(cornerRadius: 10))
						.overlay(RoundedRectangle(cornerRadius: 10).stroke(primary ? Theme.accent : Theme.line))
				}
			}
		}
	}
}

struct MessageRow: View {
	@EnvironmentObject var store: Store
	let item: Item
	let agent: Agent
	let railColor: String?
	@State private var expanded = false

	var body: some View {
		switch item.kind {
		case "user":
			let parts = Attachments.split(item.text)
			VStack(alignment: .trailing, spacing: 6) {
				if let local = item.localImages, !local.isEmpty {
					imageRow(local.map { AnyView(Image(uiImage: $0).resizable().scaledToFill()) })
				} else if !parts.images.isEmpty {
					imageRow(parts.images.map { name in
						AnyView(CachedImage(url: store.uploadURL(name)) { Theme.bubble })
					})
				}
				if !parts.text.isEmpty {
					HStack {
						Spacer(minLength: 48)
						Text(parts.text)
							.font(.system(size: 16))
							.padding(.horizontal, 14).padding(.vertical, 10)
							.background(Theme.bubble, in: RoundedRectangle(cornerRadius: 18))
							.textSelection(.enabled)
					}
				}
			}
			.frame(maxWidth: .infinity, alignment: .trailing)
			.opacity(item.pending == true ? 0.55 : 1)
		case "assistant":
			HStack(alignment: .top, spacing: 12) {
				Avatar(name: agent.name, icon: agent.icon, color: railColor, size: 26).padding(.top, 2)
				VStack(alignment: .leading, spacing: 8) {
					if !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { MarkdownView(item.text) }
					if let tools = item.tools, !tools.isEmpty { StepsView(tools: tools) }
				}
				.frame(maxWidth: .infinity, alignment: .leading)
			}
		case "recap":
			card("While you were away", item.text, collapsible: false)
		case "agent_message":
			card("Message from another session",
			     item.text.replacingOccurrences(of: #"^Another Claude session sent a message:\s*"#, with: "", options: .regularExpression)
			     	.replacingOccurrences(of: #"</?teammate-message[^>]*>"#, with: "", options: .regularExpression)
			     	.trimmingCharacters(in: .whitespacesAndNewlines),
			     collapsible: true)
		case "compact_summary":
			card("Summary of earlier conversation", item.text, collapsible: true)
		case "compaction":
			HStack(spacing: 10) {
				Rectangle().fill(Theme.line).frame(height: 1)
				Text("Context compacted").font(.system(size: 12)).foregroundStyle(Theme.faint).fixedSize()
				Rectangle().fill(Theme.line).frame(height: 1)
			}
		case "notification":
			Text(item.text).font(.system(size: 12)).foregroundStyle(Theme.faint)
				.multilineTextAlignment(.center).frame(maxWidth: .infinity)
		default:
			EmptyView()
		}
	}

	private func imageRow(_ views: [AnyView]) -> some View {
		HStack(spacing: 6) {
			ForEach(Array(views.enumerated()), id: \.offset) { _, view in
				view.frame(width: views.count == 1 ? 200 : 110, height: views.count == 1 ? 200 : 110)
					.clipShape(RoundedRectangle(cornerRadius: 14))
			}
		}
	}

	private func card(_ label: String, _ text: String, collapsible: Bool) -> some View {
		VStack(alignment: .leading, spacing: 4) {
			Text(label.uppercased()).font(.system(size: 11, weight: .semibold)).kerning(0.6).foregroundStyle(Theme.faint)
			Text(text).font(.system(size: 14)).foregroundStyle(Theme.muted)
				.lineLimit(collapsible && !expanded ? 4 : nil)
		}
		.padding(.horizontal, 14).padding(.vertical, 10)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
		.overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
		.onTapGesture { if collapsible { withAnimation { expanded.toggle() } } }
	}
}

struct StepsView: View {
	let tools: [Tool]
	@State private var open = false

	var body: some View {
		let failed = tools.filter { $0.error == true }.count
		VStack(alignment: .leading, spacing: 4) {
			Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
				HStack(spacing: 6) {
					Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
						.rotationEffect(.degrees(open ? 90 : 0))
					Text("\(tools.count) step\(tools.count == 1 ? "" : "s")\(failed > 0 ? " · \(failed) failed" : "")")
						.font(.system(size: 13))
				}
				.foregroundStyle(Theme.muted)
			}
			.buttonStyle(.plain)
			if open {
				VStack(alignment: .leading, spacing: 6) {
					ForEach(tools) { tool in
						HStack(alignment: .firstTextBaseline, spacing: 8) {
							Text(tool.name).font(.system(size: 13, weight: .semibold))
								.foregroundStyle(tool.error == true ? Theme.permission : Theme.text)
							Text(tool.summary).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
						}
					}
				}
				.padding(.leading, 12)
				.overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 2) }
			}
		}
	}
}
