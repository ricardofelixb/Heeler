import { createHash, randomUUID } from "node:crypto";
import { mkdir, lstat, chmod, unlink } from "node:fs/promises";
import { homedir } from "node:os";
import { createServer, createConnection } from "node:net";
import { join } from "node:path";

const hash = (text) => createHash("sha256").update(text).digest("hex");
export const MAX_LINE_BYTES = 1_048_576;
// Heeler treats 45 s of silence as a stalled channel and reconnects.
export const HEARTBEAT_MS = 15_000;
const MAX_TEXT = 6_000;
const MAX_ROWS = 120;
const clip = (text) => {
  const value = String(text ?? "");
  return value.length > MAX_TEXT ? `${value.slice(0, MAX_TEXT)}\n[…more in Terminal]` : value;
};
const contentText = (content) => typeof content === "string" ? content :
  (content ?? []).map((part) => part.type === "text" ? part.text :
    part.type === "image" ? "[Image — open Terminal to view]" : "").filter(Boolean).join("\n");

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
    this.live = undefined;
    this.blocked = undefined;
  }

  async start(ctx) {
    this.ctx = ctx;
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
    const truncated = history.truncated || rows.length > MAX_ROWS;
    rows = rows.slice(-MAX_ROWS);
    const frame = { type: "snapshot", version: 1, epoch: this.epoch, revision: this.revision,
      sessionID: this.conversationID(), rows, truncated,
      busy: !this.ctx.isIdle(), blocked: this.blocked ?? null };
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

  refresh(ctx) {
    this.ctx = ctx;
    const sessionID = ctx.sessionManager.getSessionId();
    if (this.sessionID !== sessionID) {
      this.toolRows.clear();
      this.blocked = undefined;
      this.sessionID = sessionID;
    }
    this.live = undefined;
    clearTimeout(this.flushTimer);
    this.flushTimer = undefined;
    this.broadcast(this.snapshot());
  }

  event(event, ctx) {
    this.ctx = ctx;
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

  /** Read-only: input reaches Pi through its terminal, which handles busy steering natively. */
  connect(socket) {
    if (this.clients.size >= 4) { socket.destroy(); return; }
    this.clients.add(socket);
    socket.on("error", () => {});
    socket.on("close", () => this.clients.delete(socket));
    socket.once("data", () => socket.destroy());
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
