import { createHash, randomUUID } from "node:crypto";
import { readFileSync } from "node:fs";
import { mkdir, lstat, chmod, unlink } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { createServer, createConnection } from "node:net";
import { basename, join } from "node:path";

const hash = (text) => createHash("sha256").update(text).digest("hex");
export const MAX_LINE_BYTES = 1_048_576;
// Heeler treats 45 s of silence as a stalled channel and reconnects.
export const HEARTBEAT_MS = 15_000;
const MAX_TEXT = 6_000;
const MAX_ROWS = 120;
const MAX_QUEUED = 8;
const clip = (text) => {
  const value = String(text ?? "");
  return value.length > MAX_TEXT ? `${value.slice(0, MAX_TEXT)}\n[…more in Terminal]` : value;
};
const contentText = (content) => typeof content === "string" ? content :
  (content ?? []).map((part) => part.type === "text" ? part.text :
    part.type === "image" ? "[Image — open Terminal to view]" : "").filter(Boolean).join("\n");

// Pi 1.3.0's built-in slash commands; extensions can't read Pi's own list.
const BUILTIN_COMMANDS = [
  ["model", "Select model"], ["thinking", "Set thinking level"], ["compact", "Manually compact the session context"],
  ["new", "Start a new session"], ["resume", "Resume a different session"], ["reload", "Reload extensions, skills, prompts and context files"],
  ["session", "Show session info and stats"], ["tree", "Navigate session tree"], ["fork", "Fork from a previous user message"],
  ["clone", "Duplicate the current session"], ["name", "Set session display name"], ["copy", "Copy last agent message"],
  ["export", "Export session"], ["share", "Share session"], ["scoped-models", "Enable/disable models for cycling"],
  ["settings", "Open settings menu"], ["hotkeys", "Show keyboard shortcuts"], ["changelog", "Show changelog entries"],
  ["login", "Configure provider authentication"], ["logout", "Remove provider authentication"], ["trust", "Save project trust decision"],
  ["import", "Import a session from JSONL"], ["bug", "Report a bug"], ["quit", "Quit pi"],
].map(([name, description]) => ({ name, description }));
const MAX_COMMANDS = 300;
const MAX_MODELS = 200;
const MAX_COMMAND_BYTES = 16_384;
const MAX_DIALOG_OPTIONS = 50;
const MAX_OPTION_TEXT = 500;

// rpiv-ask-user-question's public event channels (2.13.9+ answers from outside).
export const ASK_USER_PROMPT_EVENT = "rpiv:ask-user:prompt";
export const ASK_USER_BLOCKED_EVENT = "rpiv:ask-user:blocked";
export const ASK_USER_ANSWER_EVENT = "rpiv:ask-user:answer";
// Pi shares one dialog object among extensions; this marks our wrapper on it.
const DIALOGS = Symbol.for("heeler.mirror.dialogs");
const short = (text) => String(text ?? "").slice(0, MAX_OPTION_TEXT);
const withSignal = (opts, signal) =>
  ({ ...opts, signal: opts?.signal ? AbortSignal.any([opts.signal, signal]) : signal });

// Mirrors pi-ai's getSupportedThinkingLevels, which extensions can't import.
export const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"];
export function thinkingLevels(model) {
  if (!model?.reasoning) return ["off"];
  return THINKING_LEVELS.filter((level) => {
    const mapped = model.thinkingLevelMap?.[level];
    if (mapped === null) return false;
    return level === "xhigh" || level === "max" ? mapped !== undefined : true;
  });
}

const modelInfo = (model) => model ? { provider: String(model.provider), id: String(model.id),
  name: String(model.name || model.id), thinkingLevels: thinkingLevels(model) } : null;

// Weekly limits as the usage-status extension saves them for every Pi on the machine.
const LIMIT_PROVIDERS = [["claude-bridge", "Claude"], ["openai-codex", "Codex"]];

/** Each provider's weekly remaining share, read from usage-status's shared files; no requests of our own. */
export function weeklyLimits(directory = tmpdir(), env = process.env) {
  return LIMIT_PROVIDERS.flatMap(([provider, label]) => {
    const account = provider === "claude-bridge" && env.CLAUDE_CONFIG_DIR ? basename(env.CLAUDE_CONFIG_DIR) : undefined;
    try {
      const file = join(directory, `pi-usage-status-${provider}${account ? `-${account}` : ""}.json`);
      const value = JSON.parse(readFileSync(file, "utf8"))?.value;
      if (typeof value?.left !== "number" || typeof value?.resetsAt !== "number") return [];
      return [{ label: account ? `${label} (${account})` : label, left: value.left, resetsAt: value.resetsAt }];
    } catch {
      return [];
    }
  });
}

// Must match PiConversationEndpoint in Swift. No remote shell interpolation.
export function endpoint(home, herdrSocket, paneID) {
  const directory = `/tmp/heeler-pi-${hash(home).slice(0, 16)}`;
  return { directory, socket: join(directory, `${hash(`${herdrSocket}\0${paneID}`).slice(0, 32)}.sock`) };
}

export function conversationRows(entries) {
  const rows = [];
  const tools = new Map();
  for (const entry of entries) {
    if (entry.type === "message") {
      const message = entry.message;
      if (message.role === "user" || message.role === "assistant") {
        const text = clip(contentText(message.content) || message.errorMessage);
        if (text) rows.push({ id: entry.id, role: message.role, text });
        for (const part of Array.isArray(message.content) ? message.content : []) {
          if (part.type !== "toolCall") continue;
          const row = { id: `tool:${part.id}`, role: "tool", text: part.name,
            detail: clip(JSON.stringify(part.arguments, null, 2)), state: "running" };
          rows.push(row);
          tools.set(part.id, row);
        }
      } else if (message.role === "toolResult") {
        const row = tools.get(message.toolCallId);
        if (row) {
          row.detail = clip(`${row.detail}\n\n${contentText(message.content)}`);
          row.state = message.isError ? "error" : "done";
        } else {
          rows.push({ id: `tool:${message.toolCallId}`, role: "tool", text: message.toolName,
            detail: clip(contentText(message.content)), state: message.isError ? "error" : "done" });
        }
      }
    } else if (entry.type === "custom_message" && entry.display) {
      rows.push({ id: entry.id, role: "notice", text: clip(contentText(entry.content)) });
    } else if (entry.type === "compaction" || entry.type === "branch_summary") {
      rows.push({ id: entry.id, role: "notice", text: clip(entry.summary) });
    }
  }
  return { rows: rows.slice(-MAX_ROWS), truncated: rows.length > MAX_ROWS };
}

/** Runs inside the existing Pi process. A lost phone never owns agent lifetime. */
export class PiMirrorBridge {
  constructor(options = {}) {
    this.options = options;
    this.epoch = randomUUID();
    this.clients = new Set();
    this.revision = 0;
    this.branchRevision = 0;
    this.toolRows = new Map();
    this.queued = [];
    this.queuedCount = 0;
    this.live = undefined;
    this.blocked = undefined;
    this.dialogs = [];
    this.dialogCount = 0;
  }

  async start(ctx) {
    this.ctx = ctx;
    this.wrapDialogs(ctx);
    if (this.server) { this.refresh(ctx); return; }
    const env = this.options.env ?? process.env;
    if (!env.HERDR_SOCKET_PATH || !env.HERDR_PANE_ID) return;
    const home = this.options.home ?? homedir();
    const address = endpoint(home, env.HERDR_SOCKET_PATH, env.HERDR_PANE_ID);
    await mkdir(address.directory, { mode: 0o700, recursive: true });
    const dir = await lstat(address.directory);
    if (!dir.isDirectory() || dir.isSymbolicLink() || dir.uid !== process.getuid() || (dir.mode & 0o077)) {
      throw new Error("Pi mirror directory must be owned by you with permissions 0700");
    }
    // Remove only a dead, owned Unix socket, never an active bridge or symlink.
    try {
      const file = await lstat(address.socket);
      if (!file.isSocket() || file.uid !== process.getuid()) throw new Error("Unsafe Pi mirror socket");
      const alive = await new Promise((resolve, reject) => {
        const probe = createConnection(address.socket);
        probe.once("connect", () => { probe.destroy(); resolve(true); });
        probe.once("error", (error) => {
          probe.destroy();
          if (error.code === "ECONNREFUSED" || error.code === "ENOENT") resolve(false);
          else reject(error);
        });
      });
      if (alive) throw new Error("Another Pi mirror is already active in this pane");
      await unlink(address.socket);
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    const server = createServer((socket) => this.connect(socket));
    this.server = server;
    this.address = address;
    try {
      await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(address.socket, resolve);
      });
      await chmod(address.socket, 0o600);
      server.on("error", () => { for (const client of this.clients) client.destroy(); });
      this.heartbeat = setInterval(() => {
        for (const client of this.clients) this.write(client, { type: "heartbeat", version: 1 });
      }, this.options.heartbeatMs ?? HEARTBEAT_MS);
      this.heartbeat.unref();
    } catch (error) {
      this.server = undefined;
      server.close();
      throw error;
    }
  }

  conversationID() {
    return `${this.ctx.sessionManager.getSessionId()}:${this.branchRevision}`;
  }

  snapshot() {
    const history = conversationRows(this.ctx.sessionManager.getBranch());
    let rows = history.rows.map((row) => this.toolRows.get(row.id) ?? row);
    for (const row of this.toolRows.values()) {
      if (!rows.some((existing) => existing.id === row.id)) rows.push(row);
    }
    if (this.live) rows.push(this.live);
    // Sent while Pi works: waiting to steer, shown after everything else.
    rows.push(...this.queued.map((entry) => ({ id: entry.id, role: "user", text: entry.text, state: "queued" })));
    const truncated = history.truncated || rows.length > MAX_ROWS;
    rows = rows.slice(-MAX_ROWS);
    const frame = { type: "snapshot", version: 1, epoch: this.epoch, revision: this.revision,
      sessionID: this.conversationID(), rows, truncated,
      busy: !this.ctx.isIdle(), blocked: this.blocked ?? null, dialog: this.dialog(), settings: this.settings() };
    // Budget actual escaped bytes in one pass, retaining the most recent contiguous rows.
    let bytes = Buffer.byteLength(JSON.stringify({ ...frame, rows: [] }));
    let count = 0;
    for (let index = rows.length - 1; index >= 0; index -= 1) {
      const size = Buffer.byteLength(JSON.stringify(rows[index])) + (count ? 1 : 0);
      if (bytes + size > MAX_LINE_BYTES - 32) break;
      bytes += size; count += 1;
    }
    if (count < rows.length) {
      frame.rows = count ? rows.slice(-count) : [];
      frame.truncated = true;
    }
    return frame;
  }

  /** The models the phone may pick: the session's scoped set, else every available one. */
  models() {
    const scoped = this.ctx.scopedModels ?? [];
    const models = scoped.length ? scoped.map((entry) => entry.model) : (this.ctx.modelRegistry?.getAvailable?.() ?? []);
    return models.slice(0, MAX_MODELS);
  }

  /** Model, thinking, usage and slash commands for the phone's native controls. */
  settings() {
    const api = this.options.api ?? {};
    const context = this.ctx.getContextUsage?.();
    // Skills already come from Heeler's own skills list.
    const extra = (api.getCommands?.() ?? []).filter((command) => command.source !== "skill")
      .map((command) => ({ name: String(command.name), description: String(command.description ?? "").slice(0, 200) }));
    return {
      model: modelInfo(this.ctx.model),
      thinking: api.getThinkingLevel?.() ?? this.ctx.thinkingLevel ?? null,
      models: this.models().map(modelInfo),
      usage: { contextTokens: context?.tokens ?? null, contextWindow: context?.contextWindow ?? null,
        contextPercent: context?.percent ?? null, limits: weeklyLimits(this.options.tmpdir, this.options.env) },
      commands: [...BUILTIN_COMMANDS, ...extra].slice(0, MAX_COMMANDS),
    };
  }

  /** The question the phone answers: the newest one still open. */
  dialog() {
    return this.dialogs.at(-1)?.dialog ?? null;
  }

  /**
   * Pi's pick, yes/no and one-line text dialogs, wrapped once on the dialog object every
   * extension shares, so each one also reaches the phone. The wrapper always
   * asks the current bridge: a reload replaces the bridge, not the wrapper.
   */
  wrapDialogs(ctx) {
    if (!ctx.hasUI || (ctx.mode && ctx.mode !== "tui")) return;
    const ui = ctx.ui;
    if (typeof ui?.select !== "function") return;
    if (ui[DIALOGS]) { ui[DIALOGS].bridge = this; return; }
    const state = { bridge: this };
    Object.defineProperty(ui, DIALOGS, { value: state });
    // Pi's editor can't be closed from outside, so it stays in Terminal.
    const { select, confirm, input } = ui;
    const ask = (dialog, run, parse, cancel) => state.bridge ? state.bridge.ask(dialog, run, parse, cancel) : run();
    ui.select = (title, options, opts) => ask(
      { kind: "select", title: clip(title), options: (options ?? []).slice(0, MAX_DIALOG_OPTIONS).map(short) },
      (signal) => select.call(ui, title, options, signal ? withSignal(opts, signal) : opts),
      (reply) => Number.isInteger(reply?.option) && reply.option >= 0 && reply.option < Math.min(options.length, MAX_DIALOG_OPTIONS)
        ? { value: options[reply.option] } : undefined,
      undefined);
    ui.confirm = (title, message, opts) => ask(
      { kind: "confirm", title: clip(title), message: clip(message) },
      (signal) => confirm.call(ui, title, message, signal ? withSignal(opts, signal) : opts),
      (reply) => typeof reply?.confirmed === "boolean" ? { value: reply.confirmed } : undefined,
      false);
    ui.input = (title, placeholder, opts) => ask(
      { kind: "input", title: clip(title), placeholder: short(placeholder) },
      (signal) => input.call(ui, title, placeholder, signal ? withSignal(opts, signal) : opts),
      (reply) => typeof reply?.text === "string" ? { value: reply.text } : undefined, undefined);
  }

  /** Shows a dialog on the phone too; whichever side answers first wins and closes the other. */
  ask(dialog, run, parse, cancel) {
    if (!this.server) return run();
    const controller = new AbortController();
    const id = `dialog:${++this.dialogCount}`;
    return new Promise((resolve, reject) => {
      let settled = false;
      const finish = () => { settled = true; this.closeDialog(id); };
      this.openDialog({ id, ...dialog }, (reply) => {
        const outcome = reply?.cancel === true ? { value: cancel } : parse(reply);
        if (settled || !outcome) return;
        finish();
        resolve(outcome.value);
        controller.abort();
      });
      run(controller.signal).then(
        (value) => { if (!settled) { finish(); resolve(value); } },
        (error) => { if (!settled) { finish(); reject(error); } });
    });
  }

  /** ask_user_question's questionnaire, answered through its own answer channel. */
  askUser(payload) {
    const toolCallId = payload?.toolCallId;
    if (typeof toolCallId !== "string" || !Array.isArray(payload.questions) || !this.server) return;
    const questions = payload.questions.slice(0, 4).map((question) => ({
      question: clip(question?.question), header: short(question?.header),
      multiSelect: question?.multiSelect === true,
      options: (question?.options ?? []).slice(0, MAX_DIALOG_OPTIONS)
        .map((option) => ({ label: short(option?.label), description: short(option?.description) })),
    }));
    const emit = this.options.api?.emit;
    this.openDialog({ id: `ask:${toolCallId}`, kind: "questions", questions }, (reply) => {
      if (reply?.cancel === true) emit?.(ASK_USER_ANSWER_EVENT, { toolCallId, cancel: true });
      else if (Array.isArray(reply?.answers)) emit?.(ASK_USER_ANSWER_EVENT, { toolCallId, answers: reply.answers });
    });
  }

  askUserBlocked(payload) {
    if (payload?.active === false && typeof payload.toolCallId === "string") this.closeDialog(`ask:${payload.toolCallId}`);
  }

  openDialog(dialog, answer) {
    this.dialogs.push({ dialog, answer });
    this.broadcast({ type: "dialog", dialog });
  }

  closeDialog(id) {
    const count = this.dialogs.length;
    this.dialogs = this.dialogs.filter((entry) => entry.dialog.id !== id);
    if (this.dialogs.length !== count) this.broadcast({ type: "dialog", dialog: this.dialog() });
  }

  /** Model and thinking changes and dialog answers come from the phone; messages go through Pi's terminal. */
  async command(command) {
    if (!this.ctx) return;
    if (command?.type === "answerDialog") {
      this.dialogs.find((entry) => entry.dialog.id === command.id)?.answer(command);
      return;
    }
    const api = this.options.api ?? {};
    try {
      if (command?.type === "setModel") {
        const model = this.models().find((entry) => entry.provider === command.provider && entry.id === command.id);
        if (model) await api.setModel?.(model);
      } else if (command?.type === "setThinking" && THINKING_LEVELS.includes(command.level)) {
        api.setThinkingLevel?.(command.level);
      } else {
        return;
      }
    } catch {}
    // Pi clamps unsupported levels; report what it actually applied.
    this.broadcast({ type: "settings", settings: this.settings() });
  }

  write(socket, frame) {
    const line = `${JSON.stringify(frame)}\n`;
    if (Buffer.byteLength(line) > MAX_LINE_BYTES || socket.writableLength > MAX_LINE_BYTES) {
      socket.destroy(); // Slow consumers reconnect to an authoritative snapshot, never drop deltas.
      return;
    }
    socket.write(line);
  }

  broadcast(frame) {
    this.revision += 1;
    const value = { ...frame, version: 1, epoch: this.epoch, revision: this.revision,
      sessionID: this.conversationID() };
    for (const client of this.clients) this.write(client, value);
  }

  /** Another session starts clean: its tools, prompt and queue are not this one's. */
  adopt(ctx) {
    this.ctx = ctx;
    this.wrapDialogs(ctx);
    const sessionID = ctx.sessionManager.getSessionId();
    if (this.sessionID !== sessionID) {
      this.toolRows.clear();
      this.blocked = undefined;
      this.queued = [];
      this.sessionID = sessionID;
    }
  }

  refresh(ctx) {
    this.adopt(ctx);
    this.live = undefined;
    clearTimeout(this.flushTimer);
    this.flushTimer = undefined;
    this.broadcast(this.snapshot());
  }

  /** Pi took a message typed while it was busy; the phone shows it as queued until then. */
  queue(event, ctx) {
    this.adopt(ctx);
    if (!event.streamingBehavior) return;
    const text = clip(String(event.text ?? "").trim());
    if (!text) return;
    this.queuedCount += 1;
    this.queued.push({ id: `queued:${this.queuedCount}`, text });
    if (this.queued.length > MAX_QUEUED) this.queued.shift();
    this.refresh(ctx);
  }

  event(event, ctx) {
    this.ctx = ctx;
    if (event.type === "message_start" && event.message?.role === "user" && this.queued.length) {
      const text = clip(contentText(event.message.content).trim());
      const index = this.queued.findIndex((entry) => entry.text === text);
      this.queued.splice(index >= 0 ? index : 0, 1);
    }
    if (event.type === "agent_settled" && !ctx.hasPendingMessages?.()) this.queued = [];
    if (event.type === "message_end") {
      // Pi emits extension message_end BEFORE SessionManager.appendMessage.
      // Refresh on the next event-loop turn, after persistence has completed.
      clearImmediate(this.refreshImmediate);
      this.refreshImmediate = setImmediate(() => { this.refreshImmediate = undefined; this.refresh(this.ctx); });
    } else if (event.type === "message_update") {
      const text = clip(contentText(event.message.content));
      this.live = text ? { id: "streaming", role: "assistant", text, state: "running" } : undefined;
      // Coalesce token events; never await phone/network work on Pi's event path.
      if (!this.flushTimer) this.flushTimer = setTimeout(() => {
        this.flushTimer = undefined;
        if (this.live) this.broadcast({ type: "message", row: this.live });
      }, 80);
    } else if (event.type === "model_select" || event.type === "thinking_level_select") {
      this.broadcast({ type: "settings", settings: this.settings() });
    } else if (event.type === "ui_prompt_start") {
      this.blocked = clip(event.title || "Pi needs input in Terminal");
      this.broadcast({ type: "status", busy: !ctx.isIdle(), blocked: this.blocked });
    } else if (event.type === "ui_prompt_end") {
      this.blocked = undefined;
      this.broadcast({ type: "status", busy: !ctx.isIdle(), blocked: null });
    } else if (event.type.startsWith("tool_execution_")) {
      const row = { id: `tool:${event.toolCallId}`, role: "tool",
        text: clip(event.toolName), detail: clip(`${JSON.stringify(event.args, null, 2)}\n\n${
          contentText((event.result ?? event.partialResult)?.content)}`),
        state: event.type === "tool_execution_end" ? (event.isError ? "error" : "done") : "running" };
      this.toolRows.set(row.id, row);
      if (this.toolRows.size > MAX_ROWS) this.toolRows.delete(this.toolRows.keys().next().value);
      this.broadcast({ type: "message", row });
    } else {
      if (event.type === "session_tree") this.branchRevision += 1;
      if (event.type === "agent_settled" || event.type === "session_tree" || event.type === "session_compact") {
        this.toolRows.clear();
      }
      this.refresh(ctx);
    }
  }

  /** Messages reach Pi through its terminal, which handles busy steering natively. */
  connect(socket) {
    if (this.clients.size >= 4) { socket.destroy(); return; }
    this.clients.add(socket);
    socket.on("error", () => {});
    socket.on("close", () => this.clients.delete(socket));
    socket.setEncoding("utf8");
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      for (let end = buffer.indexOf("\n"); end >= 0; end = buffer.indexOf("\n")) {
        const line = buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
        let command;
        try { command = JSON.parse(line); } catch { socket.destroy(); return; }
        void this.command(command);
      }
      if (Buffer.byteLength(buffer) > MAX_COMMAND_BYTES) socket.destroy();
    });
    this.write(socket, this.snapshot());
  }

  async stop() {
    clearInterval(this.heartbeat);
    clearImmediate(this.refreshImmediate);
    clearTimeout(this.flushTimer);
    this.flushTimer = undefined;
    for (const client of this.clients) client.destroy();
    this.clients.clear();
    const server = this.server;
    this.server = undefined;
    if (server) {
      await new Promise((resolve) => server.close(resolve));
      // Node removes the socket when closing. Don't unlink a replacement bridge.
    }
  }
}
