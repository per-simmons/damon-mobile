"use strict";

const $ = (id) => document.getElementById(id);
const state = {
	tree: null,
	filter: localGet("filter") || "all",
	open: new Set(JSON.parse(localGet("openAgents") || "[]")),
	statuses: {},
	pane: null, // { paneId, workspaceId, title, agent }
	items: [],
	before: null,
	end: 0,
	pending: [], // optimistic user messages
	attachments: [], // { file, url } picked but not sent yet
	ws: null,
};

function localGet(k) { try { return localStorage.getItem(k); } catch { return null; } }
function localSet(k, v) { try { localStorage.setItem(k, v); } catch {} }

// ------------------------------------------------------------- helpers

function el(tag, attrs = {}, ...kids) {
	const node = document.createElement(tag);
	for (const [k, v] of Object.entries(attrs)) {
		if (v == null || v === false) continue;
		if (k === "class") node.className = v;
		else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
		else node.setAttribute(k, v === true ? "" : v);
	}
	for (const kid of kids.flat()) if (kid != null) node.append(kid.nodeType ? kid : document.createTextNode(String(kid)));
	return node;
}

function svg(path) {
	const s = document.createElementNS("http://www.w3.org/2000/svg", "svg");
	s.setAttribute("viewBox", "0 0 24 24");
	s.innerHTML = path;
	return s;
}

function avatar(agent, cls = "avatar") {
	if (agent?.icon) return el("img", { class: cls, src: `/icons/${agent.icon}.png`, alt: "" });
	const letter = el("div", { class: `${cls} letter` }, (agent?.name || "?").replace(/[^A-Za-z]/g, "").slice(0, 1).toUpperCase() || "•");
	letter.style.background = agent?.color || "#a3a29c";
	return letter;
}

function ago(ms) {
	if (!ms) return "";
	const s = (Date.now() - ms) / 1000;
	if (s < 60) return "now";
	if (s < 3600) return `${Math.floor(s / 60)}m`;
	if (s < 86400) return `${Math.floor(s / 3600)}h`;
	if (s < 7 * 86400) return `${Math.floor(s / 86400)}d`;
	return new Date(ms).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

const STATUS_LABEL = { working: "Working", review: "Done", permission: "Needs you" };

function toast(text) {
	const t = $("toast");
	t.textContent = text;
	t.hidden = false;
	clearTimeout(toast.timer);
	toast.timer = setTimeout(() => (t.hidden = true), 2600);
}

async function api(path, body) {
	const res = await fetch(path, body ? { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) } : {});
	if (!res.ok) throw new Error((await res.json().catch(() => ({}))).error || res.statusText);
	return res.json();
}

function renderMarkdown(text) {
	const div = el("div", { class: "prose" });
	if (window.marked && window.DOMPurify) {
		div.innerHTML = DOMPurify.sanitize(marked.parse(text, { breaks: false, gfm: true }));
		for (const a of div.querySelectorAll("a")) { a.target = "_blank"; a.rel = "noopener"; }
	} else {
		div.style.whiteSpace = "pre-wrap";
		div.textContent = text;
	}
	return div;
}

// ------------------------------------------------------------- sidebar

function allChats() {
	const out = [];
	for (const rail of state.tree?.rails || [])
		for (const agent of rail.agents)
			for (const chat of agent.chats) out.push({ rail, agent: { ...agent, color: rail.color }, chat });
	return out;
}

function chatStatus(chat) {
	return chat.paneId ? (state.statuses[chat.paneId] ?? chat.status) : null;
}

function chatRow(entry, showAgent = false) {
	const { chat, agent } = entry;
	const status = chatStatus(chat);
	const row = el(
		"button",
		{
			class: `chat-row${state.pane?.paneId === chat.paneId ? " selected" : ""}${chat.hasTranscript ? "" : " dim"}`,
			onclick: () => openChat(entry),
		},
		el("span", { class: `dot ${status || ""}` }),
		el("span", { class: "t" }, showAgent ? el("span", { class: "agent-name" }, `${agent.name} · `) : null, chat.title || "Untitled"),
		el("span", { class: "when" }, ago(chat.lastActivity)),
	);
	return row;
}

function renderTree() {
	const tree = $("tree");
	tree.replaceChildren();
	if (!state.tree) return;
	if (state.filter === "active") {
		const rank = { permission: 0, working: 1, review: 2 };
		const active = allChats()
			.filter((e) => rank[chatStatus(e.chat)] !== undefined)
			.sort((a, b) => rank[chatStatus(a.chat)] - rank[chatStatus(b.chat)] || (b.chat.lastActivity ?? 0) - (a.chat.lastActivity ?? 0));
		if (!active.length) {
			tree.append(el("div", { class: "empty-side" }, "Nothing running right now."));
			return;
		}
		tree.append(el("div", { class: "rail active-list" }, active.map((e) => chatRow(e, true))));
		return;
	}
	for (const rail of state.tree.rails) {
		const head = el("div", { class: "rail-head" });
		if (rail.icon) head.append(el("img", { src: `/icons/${rail.icon}.png`, alt: "" }));
		else {
			const sw = el("span", { class: "swatch" });
			if (rail.color) sw.style.background = rail.color;
			head.append(sw);
		}
		head.append(el("span", {}, rail.name));
		// A repo with one unnamed workspace is its own agent; skip the duplicate header.
		const solo = rail.agents.length === 1 && rail.agents[0].name === rail.name;
		const section = el("section", { class: "rail" }, solo ? null : head);
		for (const agent of rail.agents) {
			const key = agent.id;
			const isOpen = state.open.has(key);
			const live = agent.chats.filter((c) => ["working", "permission", "review"].includes(chatStatus(c)));
			const box = el("div", { class: `agent${isOpen ? " open" : ""}` });
			const newBtn = el("span", {
				class: "new",
				role: "button",
				"aria-label": `New chat with ${agent.name}`,
				onclick: (ev) => { ev.stopPropagation(); newChat(rail, agent); },
			}, svg('<path d="M12 5v14M5 12h14"/>'));
			const rowKids = [
				avatar({ ...agent, color: rail.color }),
				el("span", { class: "name" }, agent.name),
			];
			if (live.length) rowKids.push(el("span", { class: `dot ${chatStatus(live[0])}` }));
			rowKids.push(el("span", { class: "count" }, agent.chats.length || ""), newBtn, svg('<path d="M9 6l6 6-6 6"/>'));
			rowKids[rowKids.length - 1].classList.add("chev");
			const row = el("button", {
				class: "agent-row",
				onclick: () => {
					state.open.has(key) ? state.open.delete(key) : state.open.add(key);
					localSet("openAgents", JSON.stringify([...state.open]));
					box.classList.toggle("open");
				},
			}, rowKids);
			box.append(row, el("div", { class: "chats" }, agent.chats.map((chat) => chatRow({ rail, agent: { ...agent, color: rail.color }, chat }))));
			section.append(box);
		}
		tree.append(section);
	}
}

const prettyName = (name) => String(name).replace(/[_-]\d{1,2}\.\d{1,2}\.\d{2}$/, "");

async function loadTree() {
	try {
		const tree = await api("/api/tree");
		for (const rail of tree.rails) {
			const solo = rail.agents.length === 1 && rail.agents[0].name === rail.name;
			rail.name = prettyName(rail.name);
			for (const agent of rail.agents) agent.name = solo ? rail.name : prettyName(agent.name);
		}
		state.tree = tree;
		renderTree();
		if (state.pane) updateHeader();
	} catch (e) {
		toast(`Couldn't load Damon: ${e.message}`);
	}
}

for (const chip of document.querySelectorAll(".chip")) {
	chip.classList.toggle("on", chip.dataset.filter === state.filter);
	chip.addEventListener("click", () => {
		state.filter = chip.dataset.filter;
		localSet("filter", state.filter);
		for (const c of document.querySelectorAll(".chip")) c.classList.toggle("on", c === chip);
		renderTree();
	});
}

// ------------------------------------------------------------- chat view

function findEntry(paneId) {
	return allChats().find((e) => e.chat.paneId === paneId);
}

function updateHeader() {
	const entry = state.pane && findEntry(state.pane.paneId);
	const agent = entry?.agent ?? state.pane?.agent;
	$("chat-name").textContent = entry?.chat.title ?? state.pane?.title ?? "";
	$("chat-sub").textContent = agent
		? entry && entry.rail.name !== agent.name ? `${agent.name} · ${entry.rail.name}` : agent.name
		: "";
	const img = $("chat-avatar");
	if (agent?.icon) { img.src = `/icons/${agent.icon}.png`; img.style.display = ""; }
	else img.style.display = "none";
	const status = state.pane ? state.statuses[state.pane.paneId] ?? entry?.chat.status : null;
	const pill = $("chat-status");
	pill.className = `status-pill ${status || ""}`;
	pill.textContent = STATUS_LABEL[status] || "";
	renderActionBar(status);
}

async function openChat(entry) {
	const { chat, agent } = entry;
	if (!chat.paneId) { toast("That tab isn't a terminal chat. Open it on the desktop."); return; }
	state.pane = { paneId: chat.paneId, title: chat.title, agent, workspaceId: agent.id };
	state.items = [];
	state.pending = [];
	state.before = null;
	localSet("lastPane", chat.paneId);
	$("chat").classList.remove("empty");
	document.body.classList.add("in-chat");
	$("messages").replaceChildren();
	$("empty-note").textContent = "Loading…";
	updateHeader();
	renderTree();
	try {
		const data = await api(`/api/chat?pane=${encodeURIComponent(chat.paneId)}`);
		if (state.pane?.paneId !== chat.paneId) return;
		state.items = data.items;
		state.before = data.before;
		state.end = data.end;
		if (data.context?.status) state.statuses[chat.paneId] = data.context.status;
		$("empty-note").textContent = data.noTranscript
			? "No Claude conversation found for this tab yet. If it's new, send a message and it will appear here."
			: "";
		renderMessages(true);
		updateHeader();
		subscribe();
	} catch (e) {
		$("empty-note").textContent = `Couldn't load this chat (${e.message}).`;
	}
}

async function loadOlder() {
	if (!state.pane || state.before == null) return;
	const scroller = $("scroller");
	const prevHeight = scroller.scrollHeight;
	const btn = $("older");
	btn.textContent = "Loading…";
	try {
		const data = await api(`/api/chat?pane=${encodeURIComponent(state.pane.paneId)}&before=${state.before}`);
		state.items = [...data.items, ...state.items];
		state.before = data.before;
		renderMessages(false);
		scroller.scrollTop = scroller.scrollHeight - prevHeight;
	} catch (e) {
		toast(e.message);
	}
	btn.textContent = "Load earlier messages";
}
$("older").addEventListener("click", loadOlder);

function stepsBlock(tools) {
	const box = el("div", { class: "steps" });
	const errors = tools.filter((t) => t.error).length;
	const label = `${tools.length} step${tools.length === 1 ? "" : "s"}${errors ? ` · ${errors} failed` : ""}`;
	box.append(
		el("button", { class: "steps-toggle", onclick: () => box.classList.toggle("open") }, svg('<path d="M9 6l6 6-6 6"/>'), label),
		el("div", { class: "steps-list" }, tools.map((t) => el("div", { class: `step${t.error ? " error" : ""}` }, el("b", {}, t.name), el("span", {}, t.summary)))),
	);
	return box;
}

// Phone/web uploads ride in the message as "(Image attached from my phone, please look: <paths>)".
const ATTACH_NOTE = /\s*\(Images? attached from my phone, please look: ([^)]*)\)\s*$/;
function splitAttachments(text) {
	const m = text.match(ATTACH_NOTE);
	if (!m) return { text: text.trim(), images: [] };
	const images = m[1].trim().split(/\s+/).map((p) => p.split("/").pop()).filter(Boolean);
	return { text: text.slice(0, m.index).trim(), images };
}

function imagesNode(urls) {
	return el("div", { class: `msg-images${urls.length === 1 ? " one" : ""}` }, urls.map((src) => el("img", { src, alt: "" })));
}

function messageNode(item, agent) {
	switch (item.kind) {
		case "user": {
			const parts = splitAttachments(item.text);
			const urls = item.localUrls?.length ? item.localUrls : parts.images.map((n) => `/uploads/${n}`);
			return el("div", { class: `msg user${item.pending ? " pending" : ""}` },
				urls.length ? imagesNode(urls) : null,
				parts.text ? el("div", { class: "bubble" }, parts.text) : null);
		}
		case "assistant": {
			const body = el("div", { class: "body" });
			if (item.text?.trim()) body.append(renderMarkdown(item.text));
			if (item.tools?.length) body.append(stepsBlock(item.tools));
			return el("div", { class: "msg assistant" }, avatar(agent, "avatar"), body);
		}
		case "recap":
			return el("div", { class: "card" }, el("span", { class: "label" }, "While you were away"), item.text);
		case "agent_message": {
			const text = item.text.replace(/^Another Claude session sent a message:\s*/, "").replace(/<\/?teammate-message[^>]*>/g, "").trim();
			const card = el("div", { class: "card collapsed", onclick: () => card.classList.toggle("collapsed") },
				el("span", { class: "label" }, "Message from another session"), el("div", { class: "card-text" }, text));
			return card;
		}
		case "compact_summary": {
			const card = el("div", { class: "card collapsed", onclick: () => card.classList.toggle("collapsed") },
				el("span", { class: "label" }, "Summary of earlier conversation"), el("div", { class: "card-text" }, item.text));
			return card;
		}
		case "compaction":
			return el("div", { class: "divider" }, "Context compacted");
		case "notification":
			return el("div", { class: "note" }, item.text);
		default:
			return null;
	}
}

function nearBottom() {
	const s = $("scroller");
	return s.scrollHeight - s.scrollTop - s.clientHeight < 160;
}

function scrollToBottom() {
	const s = $("scroller");
	s.scrollTop = s.scrollHeight;
}

function renderMessages(stick) {
	const wasNear = stick || nearBottom();
	const agent = state.pane?.agent;
	const box = $("messages");
	box.replaceChildren(...[...state.items, ...state.pending].map((i) => messageNode(i, agent)).filter(Boolean));
	$("older").hidden = state.before == null;
	if (wasNear) requestAnimationFrame(scrollToBottom);
}

function appendItems(items, results) {
	for (const item of items) {
		if (item.kind === "user") {
			const i = state.pending.findIndex((p) => p.text.trim() === splitAttachments(item.text).text);
			if (i >= 0) state.pending.splice(i, 1);
		}
		const prev = state.items[state.items.length - 1];
		if (item.kind === "assistant" && prev?.kind === "assistant" && item.msgId && prev.msgId === item.msgId) {
			prev.text = [prev.text, item.text].filter((t) => t?.trim()).join("\n\n");
			prev.tools = [...prev.tools, ...item.tools];
		} else state.items.push(item);
	}
	if (results?.length) {
		const failed = new Set(results.filter(([, err]) => err).map(([id]) => id));
		for (const it of state.items) if (it.kind === "assistant") for (const t of it.tools) if (failed.has(t.id)) t.error = true;
	}
	$("empty-note").textContent = "";
	renderMessages(false);
}

// ------------------------------------------------------------- actions

function pendingTool() {
	for (let i = state.items.length - 1; i >= 0; i--) {
		const it = state.items[i];
		if (it.kind === "user") return null;
		if (it.kind === "assistant" && it.tools?.length) return it.tools[it.tools.length - 1];
	}
	return null;
}

function renderActionBar(status) {
	const bar = $("action-bar");
	bar.replaceChildren();
	const working = status === "working";
	$("stop").hidden = !working;
	$("send").hidden = working && !$("input").value.trim();
	if (status === "permission") {
		const tool = pendingTool();
		bar.append(el("div", { class: "what" }, "Needs your OK", tool ? el("span", {}, ": ", el("b", {}, tool.name), tool.summary ? ` · ${tool.summary}` : "") : ""));
		const q = tool?.input?.questions?.[0];
		const row = el("div", { class: "row" });
		if (q?.options?.length) {
			q.options.slice(0, 5).forEach((o, i) => row.append(el("button", { onclick: () => sendKey(String(i + 1)) }, `${i + 1}. ${o.label}`)));
			row.append(el("button", { onclick: () => sendKey("esc") }, "Cancel"));
		} else {
			row.append(
				el("button", { class: "primary", onclick: () => sendKey("1") }, "Allow"),
				el("button", { onclick: () => sendKey("2") }, "Always allow"),
				el("button", { onclick: () => sendKey("esc") }, "Deny"),
			);
		}
		bar.append(row, el("div", { class: "what" }, "Something else on screen? Use the keys button for arrows and Enter."));
		bar.hidden = false;
		return;
	}
	if (working) {
		const tool = pendingTool();
		bar.append(el("div", { class: "working-line" }, el("span", { class: "spinner" }), tool ? `Working · ${tool.name}${tool.summary ? ` ${tool.summary}` : ""}` : "Working…"));
		bar.hidden = false;
		return;
	}
	bar.hidden = true;
}

async function sendKey(key) {
	if (!state.pane) return;
	try {
		await api("/api/key", { paneId: state.pane.paneId, key });
		if (navigator.vibrate) navigator.vibrate(10);
	} catch (e) {
		toast(`Key failed: ${e.message}`);
	}
}

for (const b of document.querySelectorAll("#keys button")) b.addEventListener("click", () => sendKey(b.dataset.key));
$("keys-toggle").addEventListener("click", () => {
	$("keys").hidden = !$("keys").hidden;
	$("keys-toggle").classList.toggle("on", !$("keys").hidden);
});
$("stop").addEventListener("click", () => sendKey("esc"));

const input = $("input");
function syncComposer() {
	input.style.height = "auto";
	input.style.height = `${Math.min(input.scrollHeight, window.innerHeight * 0.4)}px`;
	$("send").disabled = !input.value.trim() && !state.attachments.length;
	const status = state.pane ? state.statuses[state.pane.paneId] : null;
	$("send").hidden = status === "working" && !input.value.trim();
}
input.addEventListener("input", syncComposer);
input.addEventListener("keydown", (e) => {
	if (e.key === "Enter" && !e.shiftKey && !e.isComposing && window.matchMedia("(min-width: 821px)").matches) {
		e.preventDefault();
		$("composer").requestSubmit();
	}
});

function renderThumbs() {
	const box = $("thumbs");
	box.hidden = !state.attachments.length;
	box.replaceChildren(...state.attachments.map((a, i) =>
		el("div", { class: "thumb" }, el("img", { src: a.url, alt: "" }),
			el("button", { type: "button", "aria-label": "Remove image", onclick: () => { state.attachments.splice(i, 1); renderThumbs(); syncComposer(); } }, "×"))));
}
$("file").addEventListener("change", (e) => {
	for (const file of [...e.target.files].slice(0, 4)) state.attachments.push({ file, url: URL.createObjectURL(file) });
	e.target.value = "";
	renderThumbs();
	syncComposer();
});

async function uploadImage(file) {
	const type = /png/.test(file.type) ? "image/png" : /heic/.test(file.type) ? "image/heic" : "image/jpeg";
	const res = await fetch("/api/upload", { method: "POST", headers: { "Content-Type": type }, body: file });
	const body = await res.json();
	if (!res.ok) throw new Error(body.error || res.statusText);
	return body.name;
}

$("composer").addEventListener("submit", async (e) => {
	e.preventDefault();
	const text = input.value.trim();
	const attachments = state.attachments;
	if ((!text && !attachments.length) || !state.pane) return;
	input.value = "";
	state.attachments = [];
	renderThumbs();
	syncComposer();
	const pending = { kind: "user", text, pending: true, id: `pending-${Date.now()}`, localUrls: attachments.map((a) => a.url) };
	state.pending.push(pending);
	renderMessages(true);
	try {
		const images = [];
		for (const a of attachments) images.push(await uploadImage(a.file));
		await api("/api/send", { paneId: state.pane.paneId, text, images });
	} catch (err) {
		state.pending = state.pending.filter((p) => p !== pending);
		renderMessages(false);
		input.value = text;
		syncComposer();
		toast(`Not sent: ${err.message}`);
	}
});

async function newChat(rail, agent) {
	try {
		toast(`Opening a new chat with ${agent.name}…`);
		const res = await api("/api/new-chat", { workspaceId: agent.id });
		if (!res.paneId) throw new Error(res.error || "Damon didn't open a tab");
		await loadTree();
		await openChat({ rail, agent: { ...agent, color: rail.color }, chat: { paneId: res.paneId, title: res.name || "New chat", hasTranscript: false } });
		// Until Claude has started, typing would land in the plain shell.
		input.disabled = true;
		input.placeholder = "Starting Claude…";
		setTimeout(() => {
			input.disabled = false;
			input.placeholder = "Reply…";
			$("empty-note").textContent = "New chat. Say something.";
		}, 9000);
	} catch (e) {
		toast(`Couldn't open a chat: ${e.message}`);
	}
}

$("back").addEventListener("click", () => {
	document.body.classList.remove("in-chat");
	input.blur();
});

// ------------------------------------------------------------- live feed

function subscribe() {
	if (state.ws?.readyState === WebSocket.OPEN && state.pane)
		state.ws.send(JSON.stringify({ type: "subscribe", paneId: state.pane.paneId, end: state.end }));
}

function connect() {
	const ws = new WebSocket(`${location.protocol === "https:" ? "wss" : "ws"}://${location.host}/api/live`);
	state.ws = ws;
	ws.onopen = () => { $("conn").classList.add("on"); subscribe(); };
	ws.onclose = () => {
		$("conn").classList.remove("on");
		setTimeout(connect, 1500);
	};
	ws.onmessage = (ev) => {
		const msg = JSON.parse(ev.data);
		if (msg.type === "status") {
			state.statuses = msg.statuses;
			renderTree();
			updateHeader();
		} else if (msg.type === "append") {
			appendItems(msg.items || [], msg.results);
			if (state.pane) updateHeader();
		} else if (msg.type === "reload" && state.pane) {
			const entry = findEntry(state.pane.paneId);
			if (entry) openChat(entry);
		}
	};
}

document.addEventListener("visibilitychange", () => {
	if (document.visibilityState !== "visible") return;
	loadTree();
	if (state.ws?.readyState !== WebSocket.OPEN) connect();
	else if (state.pane) {
		// Phones suspend sockets; refetch the open chat so nothing is missed.
		const entry = findEntry(state.pane.paneId);
		if (entry) openChat(entry);
	}
});
setInterval(() => { if (document.visibilityState === "visible") loadTree(); }, 30_000);

(async () => {
	await loadTree();
	connect();
	const last = localGet("lastPane");
	const entry = last && findEntry(last);
	if (entry && window.matchMedia("(min-width: 821px)").matches) openChat(entry);
})();
