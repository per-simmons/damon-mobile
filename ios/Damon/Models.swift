import Foundation
import UIKit

struct Tree: Decodable {
	var rails: [Rail]
}

struct Rail: Decodable, Identifiable, Hashable {
	let id: String
	var name: String
	let color: String?
	let icon: String?
	var agents: [Agent]
}

struct Agent: Decodable, Identifiable, Hashable {
	let id: String
	var name: String
	let icon: String?
	var chats: [Chat]
}

struct Chat: Decodable, Identifiable, Hashable {
	let paneId: String?
	let tabId: String
	let title: String?
	let paneName: String?
	let status: String?
	let hasTranscript: Bool?
	let lastActivity: Double?
	let nonTerminal: Bool?
	var agent: String? = nil

	var id: String { paneId ?? tabId }
}

struct ChatContext: Decodable {
	let paneId: String
	let title: String?
	let status: String?
}

struct ChatPage: Decodable {
	let context: ChatContext?
	let items: [Item]
	let before: Int?
	let end: Int?
	let noTranscript: Bool?
}

struct QuestionOption: Decodable, Hashable {
	let label: String
}

struct Question: Decodable, Hashable {
	let question: String?
	let options: [QuestionOption]?
}

struct ToolInput: Decodable, Hashable {
	let questions: [Question]?
}

struct Tool: Decodable, Identifiable, Hashable {
	let id: String
	let name: String
	let summary: String
	var error: Bool?
	let input: ToolInput?

	enum CodingKeys: String, CodingKey { case id, name, summary, error, input }

	init(from decoder: Decoder) throws {
		let c = try decoder.container(keyedBy: CodingKeys.self)
		id = try c.decode(String.self, forKey: .id)
		name = try c.decode(String.self, forKey: .name)
		summary = (try? c.decode(String.self, forKey: .summary)) ?? ""
		error = try? c.decodeIfPresent(Bool.self, forKey: .error)
		// Tool inputs are arbitrary JSON; only AskUserQuestion's shape matters here.
		input = try? c.decodeIfPresent(ToolInput.self, forKey: .input)
	}
}

struct Item: Decodable, Identifiable, Hashable {
	let id: String
	let kind: String
	let ts: String?
	var text: String
	var tools: [Tool]?
	let msgId: String?
	var pending: Bool?
	/// Images picked on the phone, shown on the "sending" bubble before the server has them.
	var localImages: [UIImage]? = nil

	enum CodingKeys: String, CodingKey { case id, kind, ts, text, tools, msgId, pending }

	init(pendingText: String) {
		id = "pending-\(UUID().uuidString)"
		kind = "user"
		ts = nil
		text = pendingText
		tools = nil
		msgId = nil
		pending = true
	}
}

/// Strips a trailing date suffix from folder names: "my-site_11.19.25" -> "my-site".
func prettyName(_ name: String) -> String {
	name.replacingOccurrences(of: #"[_-]\d{1,2}\.\d{1,2}\.\d{2}$"#, with: "", options: .regularExpression)
}

func relativeTime(_ ms: Double?) -> String {
	guard let ms else { return "" }
	let s = Date().timeIntervalSince1970 - ms / 1000
	if s < 60 { return "now" }
	if s < 3600 { return "\(Int(s / 60))m" }
	if s < 86400 { return "\(Int(s / 3600))h" }
	if s < 7 * 86400 { return "\(Int(s / 86400))d" }
	let f = DateFormatter()
	f.dateFormat = "MMM d"
	return f.string(from: Date(timeIntervalSince1970: ms / 1000))
}

/// Phone uploads ride along in the message as a note with file paths (that's what the
/// agent reads). Split them back out so the chat shows pictures, not paths.
enum Attachments {
	static let note = #/\s*\(Images? attached from my phone, please look: ([^)]*)\)\s*$/#

	static func split(_ text: String) -> (text: String, images: [String]) {
		guard let m = text.firstMatch(of: note) else { return (text.trimmingCharacters(in: .whitespacesAndNewlines), []) }
		let names = m.1.split(separator: " ").compactMap { $0.split(separator: "/").last.map(String.init) }
		return (String(text[..<m.range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines), names)
	}
}
