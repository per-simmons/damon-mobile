import SwiftUI

/// Small block-level markdown renderer for Claude replies: paragraphs, headings,
/// lists, code blocks, tables, quotes and rules. Inline markup (bold, italics,
/// code, links) goes through AttributedString.
struct MarkdownView: View {
	let blocks: [Block]

	init(_ text: String) {
		blocks = Block.parse(text)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 10) {
			ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
				view(for: block)
			}
		}
		.textSelection(.enabled)
	}

	@ViewBuilder
	private func view(for block: Block) -> some View {
		switch block {
		case let .paragraph(text):
			Text(inline(text)).font(Theme.serif).lineSpacing(4).foregroundStyle(Theme.text)
		case let .heading(text):
			Text(inline(text)).font(.system(size: 17, weight: .semibold)).padding(.top, 4)
		case let .list(items, ordered):
			VStack(alignment: .leading, spacing: 6) {
				ForEach(Array(items.enumerated()), id: \.offset) { i, item in
					HStack(alignment: .firstTextBaseline, spacing: 8) {
						Text(ordered ? "\(i + 1)." : "•").font(Theme.serif).foregroundStyle(Theme.muted)
						Text(inline(item.text)).font(Theme.serif).lineSpacing(4)
					}
					.padding(.leading, CGFloat(item.indent) * 14)
				}
			}
		case let .code(text):
			ScrollView(.horizontal, showsIndicators: false) {
				Text(text).font(.system(size: 13, design: .monospaced)).padding(12)
			}
			.background(Theme.code, in: RoundedRectangle(cornerRadius: 10))
		case let .table(rows):
			ScrollView(.horizontal, showsIndicators: false) {
				Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
					ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
						GridRow {
							ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
								Text(inline(cell))
									.font(.system(size: 14, weight: r == 0 ? .semibold : .regular))
									.frame(maxWidth: 220, alignment: .leading)
									.padding(.horizontal, 9)
									.padding(.vertical, 6)
									.overlay(Rectangle().stroke(Theme.line, lineWidth: 0.5))
							}
						}
					}
				}
			}
		case let .quote(text):
			Text(inline(text)).font(Theme.serif).foregroundStyle(Theme.muted)
				.padding(.leading, 12)
				.overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 3) }
		case .rule:
			Rectangle().fill(Theme.line).frame(height: 1).padding(.vertical, 4)
		}
	}

	private func inline(_ text: String) -> AttributedString {
		(try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
			?? AttributedString(text)
	}
}

enum Block {
	struct ListItem { let text: String; let indent: Int }

	case paragraph(String)
	case heading(String)
	case list([ListItem], ordered: Bool)
	case code(String)
	case table([[String]])
	case quote(String)
	case rule

	static func parse(_ text: String) -> [Block] {
		var blocks: [Block] = []
		var paragraph: [String] = []
		var list: [ListItem] = []
		var ordered = false
		var table: [[String]] = []
		let lines = text.components(separatedBy: "\n")
		var i = 0

		func flush() {
			if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
			if !list.isEmpty { blocks.append(.list(list, ordered: ordered)); list = [] }
			if !table.isEmpty { blocks.append(.table(table)); table = [] }
		}

		while i < lines.count {
			let raw = lines[i]
			let line = raw.trimmingCharacters(in: .whitespaces)
			if line.hasPrefix("```") {
				flush()
				var code: [String] = []
				i += 1
				while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
					code.append(lines[i])
					i += 1
				}
				blocks.append(.code(code.joined(separator: "\n")))
			} else if line.isEmpty {
				flush()
			} else if line.hasPrefix("|") {
				if !paragraph.isEmpty || !list.isEmpty { flush() }
				let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
					.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
				if !cells.allSatisfy({ $0.allSatisfy { "-:".contains($0) } && !$0.isEmpty }) { table.append(cells) }
			} else if let m = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
				flush()
				blocks.append(.heading(String(m.2)))
			} else if line == "---" || line == "***" || line == "___" {
				flush()
				blocks.append(.rule)
			} else if line.hasPrefix(">") {
				flush()
				blocks.append(.quote(String(line.drop(while: { $0 == ">" || $0 == " " }))))
			} else if let m = raw.firstMatch(of: /^(\s*)([-*+]|\d+[.)])\s+(.*)$/) {
				if !paragraph.isEmpty || !table.isEmpty {
					let keep = list
					list = []
					flush()
					list = keep
				}
				if list.isEmpty { ordered = m.2.first?.isNumber == true }
				list.append(ListItem(text: String(m.3), indent: m.1.count / 2))
			} else if !list.isEmpty, raw.hasPrefix("  ") {
				let last = list.removeLast()
				list.append(ListItem(text: last.text + " " + line, indent: last.indent))
			} else {
				if !list.isEmpty || !table.isEmpty {
					let keep = paragraph
					paragraph = []
					flush()
					paragraph = keep
				}
				paragraph.append(line)
			}
			i += 1
		}
		flush()
		return blocks
	}
}
