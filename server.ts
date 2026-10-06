/**
 * Damon Mobile — a Claude-style chat client for the agents running in Damon.
 *
 * Reads Damon's own state (never writes to it):
 *   ~/.damon/local.db                         rails (projects) and agents (workspaces)
 *   GET /control/list (Damon control API)     live tabs, panes, working/idle status
 *   ~/.damon/terminal-history/<ws>/<pane>/meta.json   pane -> Claude session id
 *   ~/.claude/projects/<slug>/<session>.jsonl  the conversation itself
 * Sends by typing into the real pane through POST /control/send-text, exactly as
 * if you typed at the desk.
 *
 * Serves on this Mac's Tailscale address and loopback only. Every Tailscale
 * request must come from a device logged in as ALLOWED_LOGIN (tailscale whois).
 */

import { Database } from "bun:sqlite";
import { existsSync, mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { open } from "node:fs/promises";
import { homedir } from "node:os";
import { join, basename } from "node:path";
import type { ServerWebSocket } from "bun";

const HOME = homedir();
const DAMON = join(HOME, ".damon");
const PROJECTS = join(HOME, ".claude", "projects");
const PUBLIC = join(import.meta.dir, "public");
const PORT = Number(process.env.DAMON_MOBILE_PORT ?? 8787);
// Required: this Mac's Tailscale IP (`tailscale ip -4`) and the Tailscale login allowed in
// (`tailscale whois <your phone's tailnet IP>` shows it). No defaults on purpose.
const TAILSCALE_IP = process.env.DAMON_MOBILE_TS_IP ?? "";
const ALLOWED_LOGIN = process.env.DAMON_MOBILE_LOGIN ?? "";
if (!TAILSCALE_IP || !ALLOWED_LOGIN) {
	console.error("[damon-mobile] set DAMON_MOBILE_TS_IP and DAMON_MOBILE_LOGIN (see README)");
	process.exit(1);
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const SAFE_ID = /^[A-Za-z0-9_-]{1,200}$/;
const CHUNK = 256 * 1024;
const MAX_SCAN = 24 * 1024 * 1024;
const PAGE = 60;
const PLUMBING = ["<command-name>", "<local-command-", "<command-message>", "<user-memory-input>"];
const SYSTEM_REMINDER = /<system-reminder>[\s\S]*?<\/system-reminder>\s*/g;
const CODEX_SESSIONS = join(HOME, ".codex", "sessions");
// Images sent from the phone (kept out of any synced or repo folder).
const UPLOADS = join(HOME, ".damon-mobile", "uploads");
const UPLOAD_NAME = /^[0-9]{8}-[0-9a-f-]{36}\.(jpg|png|heic)$/;
const MAX_UPLOAD = 25 * 1024 * 1024;
const STATE_DIR = join(import.meta.dir, "state");
const CODEX_PANES_FILE = join(STATE_DIR, "codex-panes.json");
const LAUNCH = {
	claude: "claude --dangerously-skip-permissions",
	codex: "codex --dangerously-bypass-approvals-and-sandbox -c check_for_update_on_startup=false",
} as const;
const CODEX_INJECTED = ["# AGENTS.md instructions", "<codex_internal_context", "<environment_context", "<INSTRUCTIONS>", "<user_instructions>", "<turn_aborted>"];

// ------------------------------------------------------------------ auth

const whoisCache = new Map<string, { ok: boolean; at: number }>();

async function isAllowed(ip: string | undefined): Promise<boolean> {
	if (!ip) return false;
	const addr = ip.replace(/^::ffff:/, "");
	if (addr === "127.0.0.1" || addr === "::1") return true;
	const cached = whoisCache.get(addr);
	if (cached && Date.now() - cached.at < 10 * 60_000) return cached.ok;
	let ok = false;
	try {
		const proc = Bun.spawn(["tailscale", "whois", "--json", addr], { stdout: "pipe", stderr: "ignore" });
		const out = await new Response(proc.stdout).text();
		ok = JSON.parse(out)?.UserProfile?.LoginName === ALLOWED_LOGIN;
	} catch {
		ok = false;
	}
	whoisCache.set(addr, { ok, at: Date.now() });
	return ok;
}

// ------------------------------------------------------------ damon state

function controlApi() {
	const token = readFileSync(join(DAMON, "control-api.token"), "utf8").trim();
	const port = readFileSync(join(DAMON, "control-api.port"), "utf8").trim();
	return { base: `http://127.0.0.1:${port}`, headers: { Authorization: `Bearer ${token}` } };
}

interface LivePane { id: string; tabId: string; type: string; name?: string; status?: string }
interface LiveTab { id: string; workspaceId: string; name: string; isActive: boolean; panes: LivePane[] }

async function liveTabs(): Promise<{ tabs: LiveTab[]; source: string }> {
	const { base, headers } = controlApi();
	const res = await fetch(`${base}/control/list`, { headers, signal: AbortSignal.timeout(8000) });
	const body = (await res.json()) as { ok: boolean; tabs: LiveTab[]; source: string };
	if (!body.ok) throw new Error("control list failed");
	return { tabs: body.tabs, source: body.source };
}

async function control(path: string, payload: Record<string, unknown>) {
	const { base, headers } = controlApi();
	const res = await fetch(`${base}${path}`, {
		method: "POST",
		headers: { ...headers, "Content-Type": "application/json" },
		body: JSON.stringify(payload),
		signal: AbortSignal.timeout(12000),
	});
	return (await res.json()) as Record<string, unknown>;
}

function iconId(url: string | null): string | null {
	const m = url?.match(/^superset-icon:\/\/projects\/([0-9a-f-]{36})$/i);
	return m ? m[1] : null;
}

function loadRailsAndAgents() {
	const db = new Database(join(DAMON, "local.db"), { readonly: true });
	try {
		return db
			.query(
				`select p.id pid, p.name pname, p.color, p.icon_url picon, p.tab_order porder,
				        w.id wid, w.name wname, w.icon_url wicon, w.tab_order worder, p.main_repo_path repo
				   from workspaces w join projects p on p.id = w.project_id
				  where w.deleting_at is null
				  order by coalesce(p.tab_order, 999), w.tab_order`,
			)
			.all() as Record<string, string | number | null>[];
	} finally {
		db.close();
	}
}

function paneSession(workspaceId: string, paneId: string): { sessionId: string | null; cwd: string | null } {
	if (!SAFE_ID.test(workspaceId) || !SAFE_ID.test(paneId)) return { sessionId: null, cwd: null };
	try {
		const meta = JSON.parse(readFileSync(join(DAMON, "terminal-history", workspaceId, paneId, "meta.json"), "utf8"));
		const sid = typeof meta.claudeSessionId === "string" && UUID.test(meta.claudeSessionId) ? meta.claudeSessionId : null;
		return { sessionId: sid, cwd: typeof meta.cwd === "string" ? meta.cwd : null };
	} catch {
		return { sessionId: null, cwd: null };
	}
}

const pathCache = new Map<string, string>();

function transcriptPath(sessionId: string | null, cwd: string | null): string | null {
	if (!sessionId || !UUID.test(sessionId)) return null;
	const hit = pathCache.get(sessionId);
	if (hit && existsSync(hit)) return hit;
	const slugs = cwd ? [cwd.replace(/[/._]/g, "-")] : [];
	try {
		slugs.push(...readdirSync(PROJECTS));
	} catch {
		return null;
	}
	for (const slug of slugs) {
		const p = join(PROJECTS, slug, `${sessionId}.jsonl`);
		if (existsSync(p)) {
			pathCache.set(sessionId, p);
			return p;
		}
	}
	return null;
}

async function buildTree() {
	const rows = loadRailsAndAgents();
	const { tabs } = await liveTabs();
	const rails: any[] = [];
	const railById = new Map<string, any>();
	const agentById = new Map<string, any>();
	for (const r of rows) {
		let rail = railById.get(r.pid as string);
		if (!rail) {
			rail = { id: r.pid, name: r.pname, color: r.color === "default" ? null : r.color, icon: iconId(r.picon as string), agents: [] };
			railById.set(r.pid as string, rail);
			rails.push(rail);
		}
		const agent = {
			id: r.wid,
			name: r.wname === "default" ? String(r.pname) : r.wname,
			icon: iconId(r.wicon as string) ?? rail.icon,
			chats: [] as any[],
		};
		agentById.set(r.wid as string, agent);
		rail.agents.push(agent);
	}
	for (const tab of tabs) {
		const agent = agentById.get(tab.workspaceId);
		if (!agent) continue;
		const terminals = tab.panes.filter((p) => p.type === "terminal");
		terminals.forEach((pane, i) => {
			const { path, kind } = paneTranscript(tab.workspaceId, pane.id);
			let lastActivity: number | null = null;
			if (path) {
				try {
					lastActivity = statSync(path).mtimeMs;
				} catch {}
			}
			agent.chats.push({
				paneId: pane.id,
				tabId: tab.id,
				title: terminals.length > 1 ? `${tab.name} · ${i + 1}` : tab.name,
				paneName: pane.name ?? null,
				status: pane.status ?? null,
				hasTranscript: Boolean(path),
				agent: kind,
				lastActivity,
			});
		});
		const others = tab.panes.length - terminals.length;
		if (others > 0 && terminals.length === 0) {
			agent.chats.push({ paneId: null, tabId: tab.id, title: tab.name, status: null, hasTranscript: false, lastActivity: null, nonTerminal: true });
		}
	}
	for (const rail of rails) for (const agent of rail.agents) agent.chats.sort((a: any, b: any) => (b.lastActivity ?? 0) - (a.lastActivity ?? 0));
	return { rails, at: Date.now() };
}

async function findPane(paneId: string) {
	const { tabs } = await liveTabs();
	for (const tab of tabs) {
		const pane = tab.panes.find((p) => p.id === paneId);
		if (pane) return { tab, pane };
	}
	return null;
}

// ----------------------------------------------------------- codex panes

/**
 * Damon records no pane -> Codex session link, so panes the phone opens with
 * Codex are remembered here and matched to the rollout file Codex creates
 * (same cwd, started just after the tab opened).
 */
interface CodexPane { cwd: string; startedAt: number; rollout?: string }
let codexPanes: Record<string, CodexPane> = {};
try {
	codexPanes = JSON.parse(readFileSync(CODEX_PANES_FILE, "utf8"));
} catch {}

function saveCodexPanes() {
	mkdirSync(STATE_DIR, { recursive: true });
	writeFileSync(CODEX_PANES_FILE, JSON.stringify(codexPanes, null, 1));
}

function codexRollout(paneId: string): string | null {
	const entry = codexPanes[paneId];
	if (!entry) return null;
	if (entry.rollout && existsSync(entry.rollout)) return entry.rollout;
	const claimed = new Set(Object.values(codexPanes).map((e) => e.rollout).filter(Boolean));
	const dirs = new Set<string>();
	for (const offset of [-1, 0, 1]) {
		const d = new Date(entry.startedAt + offset * 86400_000);
		const pad = (n: number) => String(n).padStart(2, "0");
		dirs.add(join(CODEX_SESSIONS, String(d.getFullYear()), pad(d.getMonth() + 1), pad(d.getDate())));
	}
	let best: { path: string; at: number } | null = null;
	for (const dir of dirs) {
		let names: string[] = [];
		try { names = readdirSync(dir); } catch { continue; }
		for (const name of names) {
			if (!name.startsWith("rollout-") || !name.endsWith(".jsonl")) continue;
			const path = join(dir, name);
			if (claimed.has(path)) continue;
			try {
				const meta = JSON.parse(readFileSync(path, "utf8").split("\n", 1)[0]);
				const at = Date.parse(meta?.payload?.timestamp ?? meta?.timestamp);
				if (meta?.type !== "session_meta" || meta.payload?.cwd !== entry.cwd) continue;
				if (!(at >= entry.startedAt - 10_000) || (best && at >= best.at)) continue;
				best = { path, at };
			} catch {}
		}
	}
	if (best) {
		entry.rollout = best.path;
		saveCodexPanes();
		return best.path;
	}
	return null;
}

/**
 * Finds every running Codex in a Damon pane: the process inherits the pane's
 * SUPERSET_PANE_ID, and Codex keeps its current rollout file open. That gives an
 * exact pane -> conversation link for Codex started anywhere, desktop included.
 */
function scanCodexProcesses() {
	try {
		const ps = Bun.spawnSync(["/bin/ps", "-axo", "pid=,ppid=,command="]).stdout.toString();
		const rows = ps.split("\n").map((l) => l.match(/^\s*(\d+)\s+(\d+)\s+(.*)$/)).filter(Boolean) as RegExpMatchArray[];
		const codex = rows.filter((r) => /codex/.test(r[3]) && !/mcp|grep|ps -/.test(r[3])).map((r) => r[1]);
		if (!codex.length) return;
		const lsof = Bun.spawnSync(["/usr/sbin/lsof", "-Fpn", "-p", codex.join(",")]).stdout.toString();
		const open = new Map<string, string>();
		let pid = "";
		for (const line of lsof.split("\n")) {
			if (line.startsWith("p")) pid = line.slice(1);
			else if (line.startsWith("n") && /\/\.codex\/sessions\/.*rollout-.*\.jsonl$/.test(line)) open.set(pid, line.slice(1));
		}
		if (!open.size) return;
		const parent = new Map(rows.map((r) => [r[1], r[2]]));
		const envOf = (p: string) =>
			Bun.spawnSync(["/bin/ps", "eww", "-o", "command=", "-p", p]).stdout.toString().match(/SUPERSET_PANE_ID=([A-Za-z0-9_-]+)/)?.[1];
		let changed = false;
		for (const [p, rollout] of open) {
			const pane = envOf(p) ?? envOf(parent.get(p) ?? "");
			if (!pane || !SAFE_ID.test(pane)) continue;
			const entry = codexPanes[pane] ?? { cwd: "", startedAt: Date.now() };
			if (entry.rollout !== rollout) {
				codexPanes[pane] = { ...entry, rollout };
				changed = true;
			}
		}
		if (changed) saveCodexPanes();
	} catch {}
}
scanCodexProcesses();
setInterval(scanCodexProcesses, 15_000);

function mtime(path: string | null): number {
	try { return path ? statSync(path).mtimeMs : 0; } catch { return 0; }
}

/** The transcript behind a pane, Claude or Codex: whichever was written to last. */
function paneTranscript(workspaceId: string, paneId: string): { path: string | null; sessionId: string | null; kind: "claude" | "codex" } {
	const { sessionId, cwd } = paneSession(workspaceId, paneId);
	const claude = transcriptPath(sessionId, cwd);
	const codex = codexPanes[paneId] ? codexRollout(paneId) : null;
	if (codex && mtime(codex) >= mtime(claude)) return { path: codex, sessionId: "codex", kind: "codex" };
	return { path: claude, sessionId, kind: "claude" };
}

// ------------------------------------------------------------ transcript

type Item =
	| { id: string; kind: "user" | "agent_message" | "notification" | "recap" | "compaction" | "compact_summary"; ts: string | null; text: string }
	| { id: string; kind: "assistant"; ts: string | null; text: string; tools: Tool[]; msgId: string | null };
interface Tool { id: string; name: string; summary: string; error?: boolean; input?: unknown }

function textOf(content: unknown): string {
	if (typeof content === "string") return content;
	if (!Array.isArray(content)) return "";
	return content
		.filter((b: any) => b && b.type === "text" && typeof b.text === "string")
		.map((b: any) => b.text)
		.join("\n");
}

function short(s: unknown, n = 90): string {
	const t = String(s ?? "").replace(/\s+/g, " ").trim();
	return t.length > n ? `${t.slice(0, n - 1)}…` : t;
}

function toolSummary(name: string, input: any): string {
	const i = input ?? {};
	switch (name) {
		case "Bash": return short(i.description || i.command);
		case "Read": case "Write": case "Edit": case "MultiEdit": case "NotebookEdit":
			return basename(String(i.file_path ?? i.notebook_path ?? ""));
		case "Grep": case "Glob": return short(i.pattern);
		case "WebFetch": return short(i.url);
		case "WebSearch": return short(i.query);
		case "Agent": case "Task": return short(i.description || i.prompt);
		case "Skill": return short(i.skill);
		case "TodoWrite": return "Updated the plan";
		case "AskUserQuestion": return short(i.questions?.[0]?.question);
		default: return short(Object.values(i).find((v) => typeof v === "string") ?? "");
	}
}

function toolLabel(name: string): string {
	if (name.startsWith("mcp__")) return name.split("__").slice(2).join(" ").replace(/_/g, " ");
	return name;
}

function codexToolSummary(name: string, p: any): string {
	const raw = String(p.input ?? p.arguments ?? "");
	const cmd = raw.match(/cmd\s*[:=]\s*"((?:[^"\\]|\\.)*)"/)?.[1] ?? raw.match(/"command"\s*:\s*\[?"([^"]+)/)?.[1];
	if (cmd) return short(cmd.replace(/\\"/g, '"'));
	const file = raw.match(/\*\*\* (?:Update|Add|Delete) File: (\S+)/)?.[1];
	if (file) return basename(file);
	return short(raw);
}

/** Codex rollout records -> the same UI items. All of one turn folds into one reply. */
function parseCodexRecord(rec: any): Item[] {
	const p = rec?.payload;
	if (rec?.type !== "response_item" || !p) return [];
	const ts = typeof rec.timestamp === "string" ? rec.timestamp : null;
	const id = String(p.id ?? p.call_id ?? crypto.randomUUID());
	if (p.type === "message" && p.role === "user") {
		const text = (p.content ?? []).filter((c: any) => c?.type === "input_text").map((c: any) => c.text).join("\n").trim();
		if (!text || CODEX_INJECTED.some((x) => text.startsWith(x))) return [];
		return [{ id, kind: "user", ts, text }];
	}
	if (p.type === "message" && p.role === "assistant") {
		const text = (p.content ?? []).filter((c: any) => c?.type === "output_text").map((c: any) => c.text).join("\n").trim();
		return text ? [{ id, kind: "assistant", ts, text, tools: [], msgId: "codex-turn" }] : [];
	}
	if (p.type === "function_call" || p.type === "custom_tool_call" || p.type === "local_shell_call") {
		const name = String(p.name ?? "shell");
		return [{ id, kind: "assistant", ts, text: "", tools: [{ id: String(p.call_id ?? id), name, summary: codexToolSummary(name, p) }], msgId: "codex-turn" }];
	}
	return [];
}

/** One JSONL record -> UI items. Tool results update the tools they answer. */
function parseRecord(rec: any, sessionId: string, results: Map<string, boolean>): Item[] {
	if (sessionId === "codex") return parseCodexRecord(rec);
	if (!rec || rec.isSidechain || (rec.sessionId && rec.sessionId !== sessionId)) return [];
	const id = typeof rec.uuid === "string" ? rec.uuid : crypto.randomUUID();
	const ts = typeof rec.timestamp === "string" ? rec.timestamp : null;
	if (rec.type === "system") {
		if (rec.subtype === "away_summary" && typeof rec.content === "string")
			return [{ id, kind: "recap", ts, text: rec.content.replace(" (disable recaps in /config)", "") }];
		if (rec.subtype === "compact_boundary") return [{ id, kind: "compaction", ts, text: "Conversation compacted" }];
		return [];
	}
	const msg = rec.message;
	if (!msg || typeof msg !== "object") return [];
	if (rec.type === "user") {
		if (Array.isArray(msg.content)) {
			for (const b of msg.content) if (b?.type === "tool_result" && b.tool_use_id) results.set(b.tool_use_id, Boolean(b.is_error));
			if (msg.content.some((b: any) => b?.type === "tool_result")) return [];
		}
		if (rec.isCompactSummary) return [{ id, kind: "compact_summary", ts, text: textOf(msg.content) }];
		if (rec.isMeta) return [];
		const text = textOf(msg.content).replace(SYSTEM_REMINDER, "").trim();
		if (!text || PLUMBING.some((p) => text.startsWith(p))) return [];
		if (text.startsWith("Another Claude session sent a message")) return [{ id, kind: "agent_message", ts, text }];
		if (text.startsWith("<task-notification")) {
			const summary = text.match(/<summary>([\s\S]*?)<\/summary>/)?.[1] ?? "Background task finished";
			return [{ id, kind: "notification", ts, text: summary.trim() }];
		}
		return [{ id, kind: "user", ts, text }];
	}
	if (rec.type === "assistant" && Array.isArray(msg.content)) {
		const text = textOf(msg.content);
		const tools: Tool[] = msg.content
			.filter((b: any) => b?.type === "tool_use")
			.map((b: any) => ({
				id: b.id,
				name: toolLabel(String(b.name)),
				summary: toolSummary(String(b.name), b.input),
				...(b.name === "AskUserQuestion" ? { input: b.input } : {}),
			}));
		if (!text.trim() && !tools.length) return [];
		return [{ id, kind: "assistant", ts, text, tools, msgId: msg.id ?? null }];
	}
	return [];
}

/** Fold consecutive blocks of the same assistant reply; stamp tool errors. */
function finalize(items: Item[], results: Map<string, boolean>): Item[] {
	const out: Item[] = [];
	for (const item of items) {
		const prev = out[out.length - 1];
		if (item.kind === "assistant" && prev?.kind === "assistant" && item.msgId && prev.msgId === item.msgId) {
			prev.text = [prev.text, item.text].filter((t) => t.trim()).join("\n\n");
			prev.tools.push(...item.tools);
			continue;
		}
		out.push(item.kind === "assistant" ? { ...item, tools: [...item.tools] } : item);
	}
	for (const item of out)
		if (item.kind === "assistant") for (const t of item.tools) if (results.get(t.id)) t.error = true;
	return out;
}

/** Read backward from `end` until `limit` items are collected. */
async function readPage(path: string, sessionId: string, end: number | null, limit: number) {
	const fh = await open(path, "r");
	try {
		const size = (await fh.stat()).size;
		let pos = end === null ? size : Math.min(end, size);
		let fileEnd = pos;
		let carry = Buffer.alloc(0);
		let scanned = 0;
		let counted = 0;
		const records: { rec: any; start: number }[] = [];
		const scratch = new Map<string, boolean>();
		const take = (line: Buffer, start: number) => {
			if (!line.length) return;
			try {
				const rec = JSON.parse(line.toString("utf8"));
				records.push({ rec, start });
				counted += parseRecord(rec, sessionId, scratch).length;
			} catch {}
		};
		while (pos > 0 && scanned < MAX_SCAN && counted < limit) {
			const step = Math.min(CHUNK, pos);
			pos -= step;
			const buf = Buffer.alloc(step);
			await fh.read(buf, 0, step, pos);
			scanned += step;
			const block = Buffer.concat([buf, carry]);
			let lineEnd = block.length;
			if (scanned === step && end === null && block[block.length - 1] !== 10) {
				// The newest record is still being written; the live feed delivers it.
				lineEnd = block.lastIndexOf(10) + 1;
				fileEnd = pos + lineEnd;
			}
			for (let i = lineEnd - 1; i >= 0 && counted < limit; i--) {
				if (block[i] !== 10) continue;
				take(block.subarray(i + 1, lineEnd), pos + i + 1);
				lineEnd = i;
			}
			carry = block.subarray(0, lineEnd);
			if (counted >= limit) break;
		}
		if (pos === 0 && counted < limit && carry.length) {
			take(carry, 0);
			carry = Buffer.alloc(0);
		}
		records.reverse();
		const results = new Map<string, boolean>();
		const items: Item[] = [];
		for (const { rec } of records) items.push(...parseRecord(rec, sessionId, results));
		const earliest = records.length ? records[0].start : pos;
		return {
			items: finalize(items, results),
			before: earliest > 0 ? earliest : null,
			end: fileEnd,
			size,
		};
	} finally {
		await fh.close();
	}
}

async function readAppended(path: string, sessionId: string, from: number) {
	const fh = await open(path, "r");
	try {
		const size = (await fh.stat()).size;
		if (size <= from) return { items: [] as Item[], next: size < from ? size : from };
		const buf = Buffer.alloc(Math.min(size - from, 8 * 1024 * 1024));
		await fh.read(buf, 0, buf.length, from);
		const lastNl = buf.lastIndexOf(10);
		if (lastNl < 0) return { items: [] as Item[], next: from };
		const results = new Map<string, boolean>();
		const items: Item[] = [];
		for (const line of buf.subarray(0, lastNl).toString("utf8").split("\n")) {
			if (!line) continue;
			try {
				items.push(...parseRecord(JSON.parse(line), sessionId, results));
			} catch {}
		}
		return { items: finalize(items, results), results: [...results], next: from + lastNl + 1 };
	} finally {
		await fh.close();
	}
}

// ------------------------------------------------------------- live feed

interface Client { paneId: string | null; path: string | null; sessionId: string | null; offset: number }
const clients = new Set<ServerWebSocket<Client>>();
let lastStatus = "";

async function tick() {
	if (!clients.size) return;
	try {
		const { tabs } = await liveTabs();
		const statuses: Record<string, string | null> = {};
		for (const t of tabs) for (const p of t.panes) statuses[p.id] = p.status ?? null;
		const json = JSON.stringify(statuses);
		if (json !== lastStatus) {
			lastStatus = json;
			for (const ws of clients) ws.send(JSON.stringify({ type: "status", statuses }));
		}
	} catch {}
	for (const ws of clients) {
		const c = ws.data;
		if (!c.paneId) continue;
		if (!c.path) {
			const found = await findPane(c.paneId).catch(() => null);
			if (!found) continue;
			const { path, sessionId } = paneTranscript(found.tab.workspaceId, c.paneId);
			if (!path || !sessionId) continue;
			c.path = path;
			c.sessionId = sessionId;
			c.offset = 0;
			ws.send(JSON.stringify({ type: "reload" }));
			continue;
		}
		try {
			const { items, results, next } = await readAppended(c.path, c.sessionId!, c.offset);
			c.offset = next;
			if (items.length || results?.length) ws.send(JSON.stringify({ type: "append", items, results }));
		} catch {}
	}
}
setInterval(tick, 1200);

// --------------------------------------------------------------- routes

const KEYS: Record<string, string> = {
	esc: "\x1b", enter: "\r", up: "\x1b[A", down: "\x1b[B", tab: "\t", "shift-tab": "\x1b[Z",
	"ctrl-c": "\x03", "1": "1", "2": "2", "3": "3", "4": "4", "5": "5",
};

function json(body: unknown, status = 200) {
	return new Response(JSON.stringify(body), {
		status,
		headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
	});
}

async function route(req: Request, server: any): Promise<Response | undefined> {
	const url = new URL(req.url);
	const p = url.pathname;

	if (p === "/api/live") {
		const ok = server.upgrade(req, { data: { paneId: null, path: null, sessionId: null, offset: 0 } as Client });
		return ok ? undefined : json({ error: "upgrade_failed" }, 400);
	}
	if (p === "/health") return json({ ok: true });
	if (p === "/api/tree") return json(await buildTree());

	if (p === "/api/chat") {
		const paneId = url.searchParams.get("pane") ?? "";
		if (!SAFE_ID.test(paneId)) return json({ error: "invalid_pane" }, 400);
		const found = await findPane(paneId);
		if (!found) return json({ error: "pane_not_found" }, 404);
		const { path, sessionId, kind } = paneTranscript(found.tab.workspaceId, paneId);
		const context = { paneId, tabId: found.tab.id, workspaceId: found.tab.workspaceId, title: found.tab.name, status: found.pane.status ?? null, sessionId, agent: kind };
		if (!path || !sessionId) return json({ context, items: [], before: null, end: 0, noTranscript: true });
		const beforeRaw = url.searchParams.get("before");
		const before = beforeRaw && /^\d{1,15}$/.test(beforeRaw) ? Number(beforeRaw) : null;
		const page = await readPage(path, sessionId, before, PAGE);
		return json({ context, ...page });
	}

	if (req.method === "POST" && p === "/api/upload") {
		const type = req.headers.get("content-type") ?? "";
		const ext = type.includes("png") ? "png" : type.includes("heic") ? "heic" : type.includes("jpeg") || type.includes("jpg") ? "jpg" : null;
		if (!ext) return json({ error: "send image/jpeg, image/png or image/heic" }, 415);
		const bytes = new Uint8Array(await req.arrayBuffer());
		if (!bytes.length || bytes.length > MAX_UPLOAD) return json({ error: "image empty or over 25 MB" }, 413);
		mkdirSync(UPLOADS, { recursive: true });
		const d = new Date();
		const stamp = `${d.getFullYear()}${String(d.getMonth() + 1).padStart(2, "0")}${String(d.getDate()).padStart(2, "0")}`;
		const name = `${stamp}-${crypto.randomUUID()}.${ext}`;
		await Bun.write(join(UPLOADS, name), bytes);
		return json({ ok: true, name, path: join(UPLOADS, name) });
	}

	const upload = p.match(/^\/uploads\/([^/]+)$/);
	if (upload && UPLOAD_NAME.test(upload[1])) {
		const file = Bun.file(join(UPLOADS, upload[1]));
		return (await file.exists())
			? new Response(file, { headers: { "Cache-Control": "max-age=86400" } })
			: new Response("", { status: 404 });
	}

	if (req.method === "POST" && p === "/api/send") {
		const body = (await req.json()) as { paneId?: string; text?: string; images?: string[] };
		const images = (Array.isArray(body.images) ? body.images : []).filter((n) => typeof n === "string" && UPLOAD_NAME.test(n) && existsSync(join(UPLOADS, n))).slice(0, 8);
		if (!body.paneId || !SAFE_ID.test(body.paneId) || typeof body.text !== "string" || (!body.text.trim() && !images.length))
			return json({ error: "invalid" }, 400);
		if (!(await findPane(body.paneId))) return json({ error: "pane_not_found" }, 404);
		// The agent gets each image as a local file path; Claude Code and Codex both open
		// local images (Claude Code attaches a typed image path as an image).
		const attached = images.map((n) => join(UPLOADS, n));
		const note = attached.length
			? ` (Image${attached.length > 1 ? "s" : ""} attached from my phone, please look: ${attached.join(" ")} )`
			: "";
		// Collapse newlines: in Claude Code a raw newline submits early.
		const text = (body.text.trim() + note).replace(/\r?\n/g, " ").trim().slice(0, 20000);
		// Text and Enter in one write look like a paste to Claude Code, which strips
		// the CR as an "invisible character" and holds the prompt for review. Type
		// the text, let the TUI settle, then press Enter on its own.
		const typed = await control("/control/send-text", { paneId: body.paneId, data: text, submit: false });
		if (!typed.ok) return json(typed, 502);
		await Bun.sleep(350);
		return json(await control("/control/send-text", { paneId: body.paneId, data: "\r", submit: false }));
	}

	if (req.method === "POST" && p === "/api/key") {
		const body = (await req.json()) as { paneId?: string; key?: string };
		const data = body.key ? KEYS[body.key] : undefined;
		if (!body.paneId || !SAFE_ID.test(body.paneId) || !data) return json({ error: "invalid" }, 400);
		return json(await control("/control/send-text", { paneId: body.paneId, data, submit: false }));
	}

	if (req.method === "POST" && p === "/api/rename") {
		const body = (await req.json()) as { tabId?: string; name?: string };
		const name = typeof body.name === "string" ? body.name.trim().slice(0, 200) : "";
		if (!body.tabId || !SAFE_ID.test(body.tabId) || !name) return json({ error: "invalid" }, 400);
		const result = await control("/control/rename-tab", { tabId: body.tabId, name });
		if (!result.ok) {
			const old = String(result.error ?? "").startsWith("Unknown route");
			return json({ error: old ? "Renaming needs a Damon build with /control/rename-tab" : String(result.error ?? "rename failed") }, old ? 501 : 502);
		}
		return json(result);
	}

	if (req.method === "POST" && p === "/api/new-chat") {
		const body = (await req.json()) as { workspaceId?: string; agent?: string };
		if (!body.workspaceId || !SAFE_ID.test(body.workspaceId)) return json({ error: "invalid" }, 400);
		const agent = body.agent === "codex" ? "codex" : "claude";
		const startedAt = Date.now();
		const res = await control("/control/open-tab", {
			workspaceId: body.workspaceId,
			command: LAUNCH[agent],
			name: agent === "codex" ? "Codex chat" : "Claude chat",
		});
		if (agent === "codex" && typeof res.paneId === "string" && typeof res.workspacePath === "string") {
			codexPanes[res.paneId] = { cwd: res.workspacePath, startedAt };
			saveCodexPanes();
		}
		return json({ ...res, agent });
	}

	const icon = p.match(/^\/icons\/([0-9a-f-]{36})\.png$/i);
	if (icon) {
		const file = join(DAMON, "project-icons", `${icon[1]}.png`);
		return existsSync(file)
			? new Response(Bun.file(file), { headers: { "Cache-Control": "max-age=3600" } })
			: new Response("", { status: 404 });
	}

	const name = p === "/" ? "index.html" : p.slice(1);
	if (/^[a-z0-9._-]+$/i.test(name)) {
		const file = Bun.file(join(PUBLIC, name));
		if (await file.exists()) return new Response(file, { headers: { "Cache-Control": "no-cache" } });
	}
	return new Response("Not found", { status: 404 });
}

function serve(hostname: string) {
	return Bun.serve<Client>({
		hostname,
		port: PORT,
		async fetch(req, server) {
			if (!(await isAllowed(server.requestIP(req)?.address))) return new Response("Forbidden", { status: 403 });
			// A web page on one of your devices could otherwise open the live socket or
			// call the API cross-site (browsers allow cross-origin WebSockets). Only this
			// server's own page (same origin) and the native app (no Origin) get in.
			const origin = req.headers.get("origin");
			if (origin && origin !== new URL(req.url).origin) return new Response("Forbidden", { status: 403 });
			try {
				return await route(req, server);
			} catch (error) {
				console.error("[damon-mobile]", error);
				return json({ error: "server_error" }, 500);
			}
		},
		websocket: {
			open(ws) {
				clients.add(ws);
				lastStatus = "";
			},
			close(ws) {
				clients.delete(ws);
			},
			async message(ws, raw) {
				try {
					const msg = JSON.parse(String(raw)) as { type: string; paneId?: string; end?: number };
					if (msg.type === "subscribe") {
						ws.data.paneId = msg.paneId && SAFE_ID.test(msg.paneId) ? msg.paneId : null;
						ws.data.path = null;
						ws.data.sessionId = null;
						if (ws.data.paneId) {
							const found = await findPane(ws.data.paneId);
							if (found) {
								const { path, sessionId } = paneTranscript(found.tab.workspaceId, ws.data.paneId);
								if (path && sessionId) {
									ws.data.path = path;
									ws.data.sessionId = sessionId;
									ws.data.offset = typeof msg.end === "number" ? msg.end : statSync(path).size;
								}
							}
						}
					}
				} catch {}
			},
		},
	});
}

serve("127.0.0.1");
try {
	serve(TAILSCALE_IP);
	console.log(`[damon-mobile] http://${TAILSCALE_IP}:${PORT} (tailnet, ${ALLOWED_LOGIN} only) + http://127.0.0.1:${PORT}`);
} catch (error) {
	// Usually Tailscale isn't up yet (just after login or a reboot). Exit so
	// launchd restarts us in 10 s, rather than serving loopback only forever.
	console.log(`[damon-mobile] tailnet bind failed (${String(error)}); exiting so launchd retries`);
	process.exit(1);
}

// If Tailscale restarts, the listener on its address can go deaf while the
// process looks healthy. Probe it once a minute; three misses -> restart.
let misses = 0;
setInterval(async () => {
	try {
		const res = await fetch(`http://${TAILSCALE_IP}:${PORT}/health`, { signal: AbortSignal.timeout(5000) });
		misses = res.ok ? 0 : misses + 1;
	} catch {
		misses++;
	}
	if (misses >= 3) {
		console.log("[damon-mobile] tailnet listener unreachable 3x; exiting so launchd restarts it");
		process.exit(1);
	}
}, 60_000);
