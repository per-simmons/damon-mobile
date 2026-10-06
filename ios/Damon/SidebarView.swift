import SwiftUI

struct Route: Hashable {
	let rail: Rail
	let agent: Agent
	let chat: Chat
}

struct SidebarView: View {
	@EnvironmentObject var store: Store
	@Binding var path: [Route]
	@AppStorage("filter") private var filter = "all"
	@AppStorage("openAgents") private var openRaw = ""
	@State private var editingServer = false
	@State private var serverDraft = ""
	@State private var renaming: Chat?
	@State private var choosing: (rail: Rail, agent: Agent)?
	@State private var renameDraft = ""

	private var open: Set<String> { Set(openRaw.split(separator: ",").map(String.init)) }

	var body: some View {
		List {
			Section {
				Picker("Filter", selection: $filter) {
					Text("All").tag("all")
					Text("Active").tag("active")
				}
				.pickerStyle(.segmented)
				.listRowBackground(Color.clear)
				.listRowSeparator(.hidden)
			}
			if let error = store.loadError, store.rails.isEmpty {
				VStack(alignment: .leading, spacing: 10) {
					Text(error).foregroundStyle(Theme.muted)
					Button("Retry") { Task { store.reconnect(); await store.loadTree() } }
						.font(.system(size: 15, weight: .semibold))
						.foregroundStyle(Theme.accent)
				}
				.padding(.vertical, 8)
				.listRowBackground(Color.clear)
			}
			if filter == "active" { activeSection } else { railSections }
		}
		.listStyle(.plain)
		.scrollContentBackground(.hidden)
		.background(Theme.side)
		.navigationTitle("Damon")
		.toolbar {
			ToolbarItem(placement: .topBarTrailing) {
				Menu {
					Button("Server address…") { serverDraft = store.server; editingServer = true }
					Button("Reconnect") { store.reconnect(); Task { await store.loadTree() } }
				} label: {
					Circle().fill(store.connected ? Theme.review : Theme.faint).frame(width: 9, height: 9)
						.padding(8)
				}
			}
		}
		.refreshable(isEnabled: !ProcessInfo.processInfo.arguments.contains("-demo")) { await store.loadTree() }
		.sheet(isPresented: Binding(get: { choosing != nil }, set: { if !$0 { choosing = nil } })) {
			if let pick = choosing {
				NewChatSheet(agentName: pick.agent.name) { tool in
					Task { await newChat(pick.rail, pick.agent, with: tool) }
				}
			}
		}
		.alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
			TextField("Name", text: $renameDraft)
			Button("Rename") {
				if let chat = renaming { Task { _ = await store.rename(tabId: chat.tabId, to: renameDraft) } }
				renaming = nil
			}
			Button("Cancel", role: .cancel) { renaming = nil }
		} message: {
			Text("Renames the tab in Damon on your desktop too.")
		}
		.alert("Server address", isPresented: $editingServer) {
			TextField("http://100.x.y.z:8787", text: $serverDraft)
				.textInputAutocapitalization(.never)
				.keyboardType(.URL)
			Button("Save") { store.server = serverDraft; Task { await store.loadTree() } }
			Button("Cancel", role: .cancel) {}
		}
	}

	@ViewBuilder
	private var railSections: some View {
		ForEach(store.rails) { rail in
			let solo = rail.agents.count == 1 && rail.agents[0].name == rail.name
			Section {
				ForEach(rail.agents) { agent in agentGroup(rail, agent) }
			} header: {
				if !solo { railHeader(rail) }
			}
		}
	}

	private func railHeader(_ rail: Rail) -> some View {
		HStack(spacing: 8) {
			if let url = store.iconURL(rail.icon) {
				CachedImage(url: url) { Theme.line }
					.frame(width: 16, height: 16)
					.clipShape(RoundedRectangle(cornerRadius: 4))
			} else {
				RoundedRectangle(cornerRadius: 2).fill(rail.color.map { Color(hex: $0) } ?? Theme.faint)
					.frame(width: 8, height: 8)
			}
			Text(rail.name.uppercased()).font(.system(size: 12, weight: .semibold)).kerning(0.6)
				.foregroundStyle(Theme.muted)
			Spacer(minLength: 0)
		}
		.padding(.top, 10)
		.padding(.bottom, 4)
		.padding(.horizontal, 20)
		.frame(maxWidth: .infinity, alignment: .leading)
		// Plain-list headers pin to the top while scrolling; a solid backing
		// keeps them from drawing over the rows sliding underneath.
		.background(Theme.side)
		.listRowInsets(EdgeInsets())
	}

	private func agentGroup(_ rail: Rail, _ agent: Agent) -> some View {
		let isOpen = Binding(
			get: { open.contains(agent.id) },
			set: { on in
				var set = open
				if on { set.insert(agent.id) } else { set.remove(agent.id) }
				openRaw = set.joined(separator: ",")
			}
		)
		let live = agent.chats.compactMap { store.status(of: $0) }.first { ["permission", "working", "review"].contains($0) }
		return DisclosureGroup(isExpanded: isOpen) {
			ForEach(agent.chats) { chat in
				Button { open(rail, agent, chat) } label: { ChatRow(chat: chat) }
					.contextMenu { renameButton(chat) }
					.accessibilityIdentifier("chat-\(chat.id)")
					.listRowBackground(Theme.side)
			}
		} label: {
			HStack(spacing: 12) {
				Avatar(name: agent.name, icon: agent.icon, color: rail.color, size: 34)
				Text(agent.name).font(.system(size: 17, weight: .medium)).lineLimit(1)
				Spacer(minLength: 4)
				if let live { StatusDot(status: live) }
				Text(agent.chats.isEmpty ? "" : "\(agent.chats.count)").font(.system(size: 13)).foregroundStyle(Theme.faint)
				Button { choosing = (rail, agent) } label: {
					Image(systemName: "plus").font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.muted)
						.frame(width: 30, height: 30)
				}
				.buttonStyle(.borderless)
				.accessibilityLabel("New chat with \(agent.name)")
			}
		}
		.accessibilityIdentifier("agent-\(agent.name)")
		.tint(Theme.faint)
		.listRowBackground(Theme.side)
	}

	@ViewBuilder
	private var activeSection: some View {
		let rank = ["permission": 0, "working": 1, "review": 2]
		let entries = store.rails.flatMap { rail in
			rail.agents.flatMap { agent in agent.chats.map { (rail, agent, $0) } }
		}
		.filter { rank[store.status(of: $0.2) ?? ""] != nil }
		.sorted { a, b in
			let ra = rank[store.status(of: a.2) ?? ""]!, rb = rank[store.status(of: b.2) ?? ""]!
			return ra != rb ? ra < rb : (a.2.lastActivity ?? 0) > (b.2.lastActivity ?? 0)
		}
		if entries.isEmpty {
			Text("Nothing running right now.").foregroundStyle(Theme.muted).listRowBackground(Color.clear)
		}
		ForEach(entries, id: \.2.id) { rail, agent, chat in
			Button { open(rail, agent, chat) } label: {
				HStack(spacing: 12) {
					Avatar(name: agent.name, icon: agent.icon, color: rail.color, size: 30)
					ChatRow(chat: chat, agentName: agent.name)
				}
			}
			.contextMenu { renameButton(chat) }
			.listRowBackground(Theme.side)
		}
	}

	private func renameButton(_ chat: Chat) -> some View {
		Button {
			renameDraft = chat.title ?? ""
			renaming = chat
		} label: {
			Label("Rename", systemImage: "pencil")
		}
	}

	private func open(_ rail: Rail, _ agent: Agent, _ chat: Chat) {
		guard chat.paneId != nil else {
			store.loadError = "That tab isn't a terminal chat. Open it on the desktop."
			return
		}
		path.append(Route(rail: rail, agent: agent, chat: chat))
	}

	private func newChat(_ rail: Rail, _ agent: Agent, with tool: String) async {
		do {
			let res = try await store.post("/api/new-chat", ["workspaceId": agent.id, "agent": tool])
			guard let pane = res["paneId"] as? String, let tab = res["tabId"] as? String else {
				throw AppError((res["error"] as? String) ?? "Damon didn't open a tab")
			}
			await store.loadTree()
			let chat = Chat(paneId: pane, tabId: tab, title: (res["name"] as? String) ?? "New chat", paneName: nil,
			                status: nil, hasTranscript: false, lastActivity: nil, nonTerminal: nil, agent: tool)
			path.append(Route(rail: rail, agent: agent, chat: chat))
		} catch {
			store.loadError = "Couldn't open a chat: \(error.localizedDescription)"
		}
	}
}

struct ChatRow: View {
	@EnvironmentObject var store: Store
	let chat: Chat
	var agentName: String?

	var body: some View {
		HStack(spacing: 10) {
			StatusDot(status: store.status(of: chat))
			VStack(alignment: .leading, spacing: 1) {
				if let agentName { Text(agentName).font(.system(size: 12)).foregroundStyle(Theme.muted) }
				HStack(spacing: 5) {
					if chat.agent == "codex" {
						Image("OpenAILogo").resizable().scaledToFit().frame(width: 12, height: 12).foregroundStyle(Theme.muted)
					}
					Text(chat.title ?? "Untitled").font(.system(size: 15))
					.foregroundStyle(chat.hasTranscript == false ? Theme.faint : Theme.text)
					.lineLimit(1)
				}
			}
			Spacer(minLength: 6)
			Text(relativeTime(chat.lastActivity)).font(.system(size: 12)).foregroundStyle(Theme.faint)
		}
		.contentShape(Rectangle())
	}
}


extension View {
	/// Pull-to-refresh, switched off for screen recordings where a scroll back to
	/// the top would overshoot into a refresh spinner.
	@ViewBuilder
	func refreshable(isEnabled: Bool, action: @escaping @Sendable () async -> Void) -> some View {
		if isEnabled { refreshable(action: action) } else { self }
	}
}
