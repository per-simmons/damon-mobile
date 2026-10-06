import Foundation
import SwiftUI
import UIKit

/// Talks to the Damon Mobile server on your Mac (server.ts): the rail/agent
/// tree over HTTP, live status and new messages over one WebSocket.
@MainActor
final class Store: ObservableObject {
	@Published var rails: [Rail] = []
	@Published var statuses: [String: String] = [:]
	@Published var connected = false
	@Published var loadError: String?
	@Published var server: String {
		didSet { UserDefaults.standard.set(server, forKey: "server"); reconnect() }
	}

	weak var activeChat: ChatModel?
	private var socket: URLSessionWebSocketTask?
	private var retry: Task<Void, Never>?

	init() {
		server = UserDefaults.standard.string(forKey: "server") ?? ""
	}

	var base: URL { URL(string: server) ?? URL(string: "http://127.0.0.1:8787")! }

	func iconURL(_ id: String?) -> URL? {
		guard let id else { return nil }
		return base.appendingPathComponent("icons/\(id).png")
	}

	func status(of chat: Chat) -> String? {
		guard let pane = chat.paneId else { return nil }
		return statuses[pane] ?? chat.status
	}

	// MARK: HTTP

	func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
		var req = URLRequest(url: URL(string: path, relativeTo: base)!)
		req.cachePolicy = .reloadIgnoringLocalCacheData
		req.timeoutInterval = 8
		let (data, response) = try await fetch(req)
		try check(response, data)
		return try JSONDecoder().decode(T.self, from: data)
	}

	@discardableResult
	func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
		var req = URLRequest(url: URL(string: path, relativeTo: base)!)
		req.httpMethod = "POST"
		req.setValue("application/json", forHTTPHeaderField: "Content-Type")
		req.httpBody = try JSONSerialization.data(withJSONObject: body)
		req.timeoutInterval = 12
		let (data, response) = try await fetch(req)
		try check(response, data)
		return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
	}

	/// Network failures almost always mean the phone can't reach your Mac over
	/// Tailscale; say that instead of "The request timed out."
	private func fetch(_ req: URLRequest) async throws -> (Data, URLResponse) {
		do {
			return try await URLSession.shared.data(for: req)
		} catch let error as URLError where [.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet].contains(error.code) {
			throw AppError("Can't reach your Mac. Check that Tailscale is connected on this phone.")
		}
	}

	private func check(_ response: URLResponse, _ data: Data) throws {
		guard let http = response as? HTTPURLResponse else { return }
		if http.statusCode == 403 { throw AppError("This device isn't allowed. Is Tailscale on and signed in as you?") }
		if !(200..<300).contains(http.statusCode) {
			let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
			throw AppError(message ?? "Server error \(http.statusCode)")
		}
	}

	/// Uploads one image (JPEG) to your Mac; returns the server's file name.
	func upload(_ image: UIImage) async throws -> String {
		let maxSide: CGFloat = 2048
		let scale = min(1, maxSide / max(image.size.width, image.size.height))
		let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
		let resized = UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
		guard let data = resized.jpegData(compressionQuality: 0.82) else { throw AppError("Couldn't encode the image") }
		var req = URLRequest(url: URL(string: "/api/upload", relativeTo: base)!, timeoutInterval: 60)
		req.httpMethod = "POST"
		req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
		req.httpBody = data
		let (body, response) = try await fetch(req)
		try check(response, body)
		guard let name = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["name"] as? String else {
			throw AppError("Upload failed")
		}
		return name
	}

	func uploadURL(_ name: String) -> URL { base.appendingPathComponent("uploads/\(name)") }

	func loadTree() async {
		guard !server.isEmpty else {
			loadError = "Set your Mac's address: tap the dot (top right) → Server address, e.g. http://100.x.y.z:8787"
			return
		}
		do {
			var tree = try await get("/api/tree", as: Tree.self)
			for r in tree.rails.indices {
				let solo = tree.rails[r].agents.count == 1 && tree.rails[r].agents[0].name == tree.rails[r].name
				tree.rails[r].name = prettyName(tree.rails[r].name)
				for a in tree.rails[r].agents.indices {
					tree.rails[r].agents[a].name = solo ? tree.rails[r].name : prettyName(tree.rails[r].agents[a].name)
				}
			}
			// Demo mode (screen recordings): agent rails only, and under them only the demo chat.
			let args = ProcessInfo.processInfo.arguments
			if args.contains("-demo") {
				let demoPane = args.firstIndex(of: "-demoPane").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
				tree.rails = tree.rails.filter { $0.icon != nil }
				for r in tree.rails.indices {
					for a in tree.rails[r].agents.indices {
						tree.rails[r].agents[a].chats = tree.rails[r].agents[a].chats.filter { $0.paneId == demoPane }
					}
				}
			}
			rails = tree.rails
			loadError = nil
		} catch {
			loadError = error.localizedDescription
		}
	}

	/// Renames the Damon tab (its userTitle), the same as renaming it on the desktop.
	func rename(tabId: String, to name: String) async -> Bool {
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return false }
		do {
			try await post("/api/rename", ["tabId": tabId, "name": trimmed])
			UINotificationFeedbackGenerator().notificationOccurred(.success)
			await loadTree()
			return true
		} catch {
			loadError = error.localizedDescription
			return false
		}
	}

	func sendKey(_ key: String, pane: String) async {
		do {
			try await post("/api/key", ["paneId": pane, "key": key])
			UIImpactFeedbackGenerator(style: .light).impactOccurred()
		} catch {
			loadError = error.localizedDescription
		}
	}

	// MARK: Live socket

	func connect() {
		guard socket == nil else { return }
		var comps = URLComponents(url: base.appendingPathComponent("api/live"), resolvingAgainstBaseURL: false)!
		comps.scheme = base.scheme == "https" ? "wss" : "ws"
		guard let url = comps.url else { return }
		let task = URLSession.shared.webSocketTask(with: url)
		socket = task
		task.resume()
		connected = true
		receive(task)
		if let chat = activeChat { subscribe(chat) }
	}

	func reconnect() {
		socket?.cancel(with: .goingAway, reason: nil)
		socket = nil
		connected = false
		connect()
	}

	func subscribe(_ chat: ChatModel) {
		activeChat = chat
		var msg: [String: Any] = ["type": "subscribe", "paneId": chat.paneId]
		if let end = chat.end { msg["end"] = end }
		send(msg)
	}

	func unsubscribe(_ chat: ChatModel) {
		guard activeChat === chat else { return }
		activeChat = nil
		send(["type": "subscribe"])
	}

	private func send(_ msg: [String: Any]) {
		guard let socket, let data = try? JSONSerialization.data(withJSONObject: msg),
		      let text = String(data: data, encoding: .utf8) else { return }
		socket.send(.string(text)) { _ in }
	}

	private func receive(_ task: URLSessionWebSocketTask) {
		task.receive { [weak self] result in
			Task { @MainActor in
				guard let self, self.socket === task else { return }
				switch result {
				case .failure:
					self.socket = nil
					self.connected = false
					self.retry?.cancel()
					self.retry = Task { try? await Task.sleep(for: .seconds(1.5)); self.connect() }
				case let .success(message):
					if case let .string(text) = message { self.handle(text) }
					self.receive(task)
				}
			}
		}
	}

	private func handle(_ text: String) {
		guard let data = text.data(using: .utf8),
		      let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
		      let type = msg["type"] as? String else { return }
		switch type {
		case "status":
			if let map = msg["statuses"] as? [String: Any] {
				statuses = map.compactMapValues { $0 as? String }
			}
		case "append":
			let items: [Item] = (msg["items"] as? [Any])
				.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
				.flatMap { try? JSONDecoder().decode([Item].self, from: $0) } ?? []
			let failed = Set(((msg["results"] as? [[Any]]) ?? []).compactMap { pair -> String? in
				pair.count == 2 && (pair[1] as? Bool) == true ? pair[0] as? String : nil
			})
			activeChat?.append(items, failedTools: failed)
		case "reload":
			if let chat = activeChat { Task { await chat.load() } }
		default:
			break
		}
	}
}

struct AppError: LocalizedError {
	let message: String
	init(_ message: String) { self.message = message }
	var errorDescription: String? { message }
}

/// One open conversation: its messages, paging, and sending.
@MainActor
final class ChatModel: ObservableObject {
	let paneId: String
	let store: Store
	@Published var items: [Item] = []
	@Published var pending: [Item] = []
	@Published var before: Int?
	@Published var end: Int?
	@Published var loading = true
	@Published var note: String?
	@Published var initialStatus: String?
	@Published var lastAppend = Date()

	init(paneId: String, store: Store) {
		self.paneId = paneId
		self.store = store
	}

	func load() async {
		loading = true
		do {
			let page = try await store.get("/api/chat?pane=\(paneId)", as: ChatPage.self)
			items = page.items
			// A fresh chat's first messages arrive by reload, not the live feed;
			// drop "sending" bubbles that are now in the transcript.
			let sent = Set(page.items.filter { $0.kind == "user" }.map { Attachments.split($0.text).text })
			pending.removeAll { sent.contains($0.text.trimmingCharacters(in: .whitespacesAndNewlines)) }
			before = page.before
			end = page.end
			initialStatus = page.context?.status
			note = page.noTranscript == true
				? "No conversation in this tab yet. Send a message and it will show up here."
				: nil
			store.subscribe(self)
		} catch {
			note = "Couldn't load this chat. \(error.localizedDescription)"
		}
		loading = false
	}

	func loadOlder() async {
		guard let before else { return }
		do {
			let page = try await store.get("/api/chat?pane=\(paneId)&before=\(before)", as: ChatPage.self)
			items = page.items + items
			self.before = page.before
		} catch {
			store.loadError = error.localizedDescription
		}
	}

	func append(_ new: [Item], failedTools: Set<String>) {
		for item in new {
			if item.kind == "user", let i = pending.firstIndex(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == Attachments.split(item.text).text }) {
				pending.remove(at: i)
			}
			if item.kind == "assistant", let last = items.last, last.kind == "assistant",
			   let id = item.msgId, id == last.msgId {
				var merged = last
				merged.text = [last.text, item.text].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n\n")
				merged.tools = (last.tools ?? []) + (item.tools ?? [])
				items[items.count - 1] = merged
			} else {
				items.append(item)
			}
		}
		if !failedTools.isEmpty {
			for i in items.indices where items[i].kind == "assistant" {
				guard var tools = items[i].tools else { continue }
				for t in tools.indices where failedTools.contains(tools[t].id) { tools[t].error = true }
				items[i].tools = tools
			}
		}
		if !new.isEmpty { note = nil; lastAppend = Date() }
	}

	func send(_ text: String, images: [UIImage] = []) async {
		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty || !images.isEmpty else { return }
		var bubble = Item(pendingText: trimmed)
		bubble.localImages = images
		pending.append(bubble)
		lastAppend = Date()
		UIImpactFeedbackGenerator(style: .medium).impactOccurred()
		do {
			var names: [String] = []
			for image in images { names.append(try await store.upload(image)) }
			try await store.post("/api/send", ["paneId": paneId, "text": trimmed, "images": names])
		} catch {
			pending.removeAll { $0.id == bubble.id }
			store.loadError = "Not sent: \(error.localizedDescription)"
		}
	}

	/// The tool the agent is on (or asking permission for): the last one since you spoke.
	var currentTool: Tool? {
		for item in items.reversed() {
			if item.kind == "user" { return nil }
			if item.kind == "assistant", let tool = item.tools?.last { return tool }
		}
		return nil
	}
}
