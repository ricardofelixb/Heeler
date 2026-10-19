import test from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { createConnection } from "node:net";
import { join } from "node:path";
import { PiMirrorBridge, endpoint, conversationRows, sessionUsage, thinkingLevels } from "./bridge.mjs";

async function fixture(t) {
  const home = await mkdtemp(join(tmpdir(), "heeler-pi-test-"));
  const env = { HERDR_SOCKET_PATH: "/tmp/test-herdr.sock", HERDR_PANE_ID: "opaque:pane/1" };
  let aborted = 0;
  let sessionID = "session-a";
  let idle = true;
  let branch = [{ type: "message", id: "u1", message: { role: "user", content: "Hello" } }];
  const sonnet = { provider: "anthropic", id: "sonnet", name: "Sonnet", reasoning: true };
  const mini = { provider: "openai", id: "mini", name: "Mini", reasoning: false };
  let thinking = "medium";
  const ctx = { isIdle: () => idle, abort: () => { aborted += 1; }, model: sonnet,
    scopedModels: [{ model: sonnet }, { model: mini }],
    getContextUsage: () => ({ tokens: 5_000, contextWindow: 200_000, percent: 2.5 }),
    sessionManager: { getBranch: () => branch, getEntries: () => branch, getSessionId: () => sessionID } };
  const api = {
    getCommands: () => [{ name: "live", description: "Talk", source: "extension" }, { name: "skill:x", source: "skill" }],
    setModel: async (model) => { ctx.model = model; return true; },
    getThinkingLevel: () => thinking,
    setThinkingLevel: (level) => { thinking = level; },
    emit: (channel, data) => { emitted.push([channel, data]); },
  };
  const emitted = [];
  const bridge = new PiMirrorBridge({ env, home, heartbeatMs: 20, api });
  await bridge.start(ctx);
  const address = endpoint(home, env.HERDR_SOCKET_PATH, env.HERDR_PANE_ID);
  t.after(async () => { await bridge.stop(); await rm(address.directory, { recursive: true, force: true });
    await rm(home, { recursive: true, force: true }); });
  async function client({ heartbeats = false } = {}) {
    const socket = createConnection(address.socket);
    let buffer = "";
    const frames = [];
    const waiters = [];
    socket.on("data", (chunk) => {
      buffer += chunk.toString();
      let end;
      while ((end = buffer.indexOf("\n")) >= 0) {
        const frame = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
        if (frame.type === "heartbeat" && !heartbeats) continue;
        if (waiters.length) waiters.shift()(frame); else frames.push(frame);
      }
    });
    const next = () => frames.length ? Promise.resolve(frames.shift()) : new Promise((resolve) => waiters.push(resolve));
    socket.on("error", () => {});
    await once(socket, "connect");
    t.after(() => socket.destroy());
    return { socket, next };
  }
  return { bridge, ctx, client, address, emitted, aborted: () => aborted,
    setBranch: (value) => { branch = value; }, setSession: (value) => { sessionID = value; },
    setIdle: (value) => { idle = value; } };
}

const options = { timeout: 5_000 };

test("endpoint is deterministic, short, and contains no pane shell syntax", () => {
  assert.equal(endpoint("/home/test", "/tmp/herdr.sock", "opaque:pane").socket,
    "/tmp/heeler-pi-928cd28cdeb14f38/2fac444f425c85ff601211138fa11f05.sock");
});

test("private socket supplies an authoritative branch to multiple clients", options, async (t) => {
  const f = await fixture(t);
  assert.equal((await stat(f.address.directory)).mode & 0o777, 0o700);
  assert.equal((await stat(f.address.socket)).mode & 0o777, 0o600);
  const a = await f.client(); const b = await f.client();
  for (const client of [a, b]) {
    const snapshot = await client.next();
    assert.equal(snapshot.type, "snapshot"); assert.equal(snapshot.sessionID, "session-a:0");
    assert.deepEqual(snapshot.rows, [{ id: "u1", role: "user", text: "Hello" }]);
  }
});

test("heartbeats keep idle clients alive without advancing revisions", options, async (t) => {
  const f = await fixture(t); const a = await f.client({ heartbeats: true });
  const snapshot = await a.next();
  assert.deepEqual(await a.next(), { type: "heartbeat", version: 1 });
  f.bridge.event({ type: "ui_prompt_start", title: "Approve in Terminal" }, f.ctx);
  let status = await a.next();
  while (status.type === "heartbeat") status = await a.next();
  assert.equal(status.revision, snapshot.revision + 1);
  assert.equal(status.blocked, "Approve in Terminal");
});

test("snapshots carry model, thinking, usage and non-skill commands", options, async (t) => {
  const f = await fixture(t); const a = await f.client();
  const { settings } = await a.next();
  assert.deepEqual(settings.model, { provider: "anthropic", id: "sonnet", name: "Sonnet",
    thinkingLevels: ["off", "minimal", "low", "medium", "high"] });
  assert.equal(settings.thinking, "medium");
  assert.deepEqual(settings.models.map((model) => model.id), ["sonnet", "mini"]);
  assert.equal(settings.usage.contextPercent, 2.5);
  assert.ok(settings.commands.some((command) => command.name === "compact"));
  assert.ok(settings.commands.some((command) => command.name === "live"));
  assert.ok(!settings.commands.some((command) => command.name === "skill:x"));
});

test("the phone can switch model and thinking, but nothing else", options, async (t) => {
  const f = await fixture(t); const a = await f.client(); await a.next();
  a.socket.write(`${JSON.stringify({ type: "setModel", provider: "openai", id: "mini" })}\n`);
  assert.equal((await a.next()).settings.model.id, "mini");
  a.socket.write(`${JSON.stringify({ type: "setModel", provider: "evil", id: "unscoped" })}\n`);
  a.socket.write(`${JSON.stringify({ type: "stop" })}\n`);
  a.socket.write(`${JSON.stringify({ type: "setThinking", level: "high" })}\n`);
  const settings = (await a.next()).settings;
  assert.equal(settings.model.id, "mini");
  assert.equal((await a.next()).settings.thinking, "high");
  assert.equal(f.aborted(), 0);
});

test("malformed or oversized phone input closes only that client and never aborts Pi", options, async (t) => {
  const f = await fixture(t); const a = await f.client(); await a.next();
  const closed = once(a.socket, "close");
  a.socket.write("not json\n"); await closed;
  const b = await f.client(); await b.next();
  const oversized = once(b.socket, "close");
  b.socket.write("x".repeat(17_000)); await oversized;
  const c = await f.client(); assert.equal((await c.next()).type, "snapshot");
  c.socket.destroy(); await f.bridge.stop(); assert.equal(f.aborted(), 0);
});

test("thinking levels and usage follow pi-ai's rules", () => {
  assert.deepEqual(thinkingLevels({ reasoning: false }), ["off"]);
  assert.deepEqual(thinkingLevels({ reasoning: true, thinkingLevelMap: { minimal: null, xhigh: "xhigh" } }),
    ["off", "low", "medium", "high", "xhigh"]);
  assert.deepEqual(sessionUsage([
    { type: "message", message: { role: "assistant", usage: { input: 10, output: 5, cacheRead: 2, cacheWrite: 1, cost: { total: 0.5 } } } },
    { type: "message", message: { role: "user", content: "x" } },
  ]), { inputTokens: 10, outputTokens: 5, cacheTokens: 3, cost: 0.5 });
});

test("desktop tree navigation replaces the transcript even within the same session file", options, async (t) => {
  const f = await fixture(t); const a = await f.client(); const before = await a.next();
  f.bridge.event({ type: "session_tree" }, f.ctx);
  const snapshot = await a.next();
  assert.equal(snapshot.type, "snapshot"); assert.notEqual(snapshot.sessionID, before.sessionID);
});

test("message_end waits for Pi persistence before publishing stable IDs", options, async (t) => {
  const f = await fixture(t); const a = await f.client(); await a.next();
  const message = { role: "assistant", content: [{ type: "text", text: "Final" }] };
  f.bridge.event({ type: "message_end", message }, f.ctx);
  f.setBranch([{ type: "message", id: "a1", message }]);
  assert.deepEqual((await a.next()).rows, [{ id: "a1", role: "assistant", text: "Final" }]);
});

test("streaming tool output and changed branches restore on reconnect", options, async (t) => {
  const f = await fixture(t); const a = await f.client(); await a.next();
  f.bridge.event({ type: "tool_execution_update", toolCallId: "call1", toolName: "bash",
    args: { command: "pwd" }, partialResult: { content: [{ type: "text", text: "/repo" }] } }, f.ctx);
  assert.equal((await a.next()).row.state, "running");
  const b = await f.client(); const snapshot = await b.next();
  assert.match(snapshot.rows.at(-1).detail, /\/repo/);
  f.setSession("new-session"); f.setBranch([]); f.bridge.event({ type: "session_tree" }, f.ctx);
  const changed = await a.next(); assert.equal(changed.sessionID, "new-session:1"); assert.deepEqual(changed.rows, []);
});

test("history combines tool calls/results, excludes thinking, and bounds text/rows", () => {
  const entries = [{ type: "message", id: "a", message: { role: "assistant", content: [
    { type: "thinking", thinking: "private thought" }, { type: "toolCall", id: "c", name: "read", arguments: { path: "a" } }] } },
  { type: "message", id: "r", message: { role: "toolResult", toolCallId: "c", content: [{ type: "text", text: "Done" }] } }];
  const result = conversationRows(entries);
  assert.equal(result.rows.length, 1); assert.equal(result.rows[0].state, "done");
  assert.match(result.rows[0].detail, /Done/); assert.doesNotMatch(JSON.stringify(result), /private thought/);
  const large = conversationRows(Array.from({ length: 200 }, (_, i) => ({ type: "message", id: String(i),
    message: { role: "user", content: "x".repeat(20_000) } })));
  assert.equal(large.rows.length, 120); assert.equal(large.truncated, true); assert.ok(large.rows[0].text.length < 6_100);
});

test("snapshot fits its serialized budget even with heavily escaped text", options, async (t) => {
  const f = await fixture(t);
  f.setBranch(Array.from({ length: 120 }, (_, index) => ({ type: "message", id: String(index),
    message: { role: "user", content: "\u0000".repeat(6_000) } })));
  const snapshot = f.bridge.snapshot();
  assert.ok(Buffer.byteLength(JSON.stringify(snapshot)) + 1 <= 1_048_576);
  assert.equal(snapshot.truncated, true);
  assert.equal(snapshot.rows.at(-1).id, "119");
});

test("an active socket is never replaced by another mirror", options, async (t) => {
  const f = await fixture(t);
  const other = new PiMirrorBridge(f.bridge.options);
  await assert.rejects(other.start(f.ctx), /already active/);
});

test("messages sent while Pi works show as queued until Pi takes them", options, async (t) => {
  const f = await fixture(t); const a = await f.client(); await a.next();
  f.setIdle(false);
  f.bridge.queue({ type: "input", text: "ignored while idle" }, f.ctx);
  f.bridge.queue({ type: "input", text: " Use the other API ", streamingBehavior: "steer" }, f.ctx);
  const queued = (await a.next()).rows.at(-1);
  assert.deepEqual(queued, { id: "queued:1", role: "user", text: "Use the other API", state: "queued" });
  f.bridge.event({ type: "message_start", message: { role: "user", content: "Use the other API" } }, f.ctx);
  assert.equal((await a.next()).rows.some((row) => row.state === "queued"), false);
  f.bridge.queue({ type: "input", text: "later", streamingBehavior: "followUp" }, f.ctx);
  assert.equal((await a.next()).rows.at(-1).state, "queued");
  f.ctx.hasPendingMessages = () => false;
  f.bridge.event({ type: "agent_settled" }, f.ctx);
  assert.equal((await a.next()).rows.some((row) => row.state === "queued"), false);
});

/** Pi's dialog object as the TUI provides it: each dialog waits for a terminal answer or its signal. */
function terminalDialogs() {
  const open = [];
  const show = (kind, title, opts, cancel) => new Promise((resolve) => {
    const entry = { kind, title, answer: resolve, signal: opts?.signal };
    open.push(entry);
    opts?.signal?.addEventListener("abort", () => { entry.dismissed = true; resolve(cancel); });
  });
  return { open, ui: {
    select: (title, _options, opts) => show("select", title, opts, undefined),
    confirm: (title, _message, opts) => show("confirm", title, opts, false),
    input: (title, _placeholder, opts) => show("input", title, opts, undefined),
    notify: () => {},
  } };
}

test("Pi's dialogs reach the phone, and whichever side answers first wins", options, async (t) => {
  const { bridge, ctx, client } = await fixture(t);
  const terminal = terminalDialogs();
  Object.assign(ctx, { hasUI: true, mode: "tui", ui: terminal.ui });
  bridge.adopt(ctx);
  const phone = await client();
  assert.equal((await phone.next()).dialog, null);
  const send = (command) => phone.socket.write(`${JSON.stringify({ type: "answerDialog", ...command })}\n`);

  // Answered on the phone: Pi gets the phone's pick and the terminal dialog closes.
  const pick = ctx.ui.select("Which computer are you at?", ["Mac mini", "Omarchy"]);
  const shown = (await phone.next()).dialog;
  assert.deepEqual(shown, { id: shown.id, kind: "select", title: "Which computer are you at?", options: ["Mac mini", "Omarchy"] });
  send({ id: shown.id, option: 7 });
  send({ id: shown.id, option: 1 });
  assert.equal(await pick, "Omarchy");
  assert.equal(terminal.open[0].dismissed, true);
  assert.equal((await phone.next()).dialog, null);

  // Answered in the terminal: the phone's sheet closes and a late phone answer changes nothing.
  const confirmed = ctx.ui.confirm("Redeem?", "Use one banked reset");
  const question = (await phone.next()).dialog;
  assert.equal(question.message, "Use one banked reset");
  terminal.open[1].answer(true);
  assert.equal(await confirmed, true);
  assert.equal((await phone.next()).dialog, null);
  send({ id: question.id, confirmed: false });

  // Cancelling from the phone gives Pi the dialog's own cancel value.
  const typed = ctx.ui.input("Name", "session");
  send({ id: (await phone.next()).dialog.id, cancel: true });
  assert.equal(await typed, undefined);
  assert.equal(terminal.open[2].dismissed, true);
});

test("a reload re-points the shared dialog wrapper instead of wrapping twice", options, async (t) => {
  const first = await fixture(t);
  const second = await fixture(t);
  const terminal = terminalDialogs();
  const original = terminal.ui.select;
  for (const { bridge, ctx } of [first, second]) {
    Object.assign(ctx, { hasUI: true, mode: "tui", ui: terminal.ui });
    bridge.adopt(ctx);
  }
  assert.notEqual(terminal.ui.select, original);
  const phone = await second.client();
  await phone.next();
  const pick = terminal.ui.select("Pick", ["a"]);
  const shown = (await phone.next()).dialog;
  phone.socket.write(`${JSON.stringify({ type: "answerDialog", id: shown.id, option: 0 })}\n`);
  assert.equal(await pick, "a");
  assert.equal(terminal.open.length, 1);
  assert.equal(first.bridge.dialog(), null);
});

test("ask_user_question is answered through its own answer channel", options, async (t) => {
  const { bridge, client, emitted } = await fixture(t);
  const phone = await client();
  await phone.next();
  bridge.askUser({ questions: [{ question: "Old", header: "x", multiSelect: false, options: [] }] });
  bridge.askUser({ toolCallId: "call-1", questions: [{ question: "Which layout?", header: "Layout", multiSelect: false,
    options: [{ label: "Compact", description: "Less space", hasPreview: true }] }] });
  const shown = (await phone.next()).dialog;
  assert.deepEqual(shown, { id: "ask:call-1", kind: "questions", questions: [{ question: "Which layout?", header: "Layout",
    multiSelect: false, options: [{ label: "Compact", description: "Less space" }] }] });
  phone.socket.write(`${JSON.stringify({ type: "answerDialog", id: shown.id,
    answers: [{ questionIndex: 0, optionIndexes: [0] }] })}\n`);
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.deepEqual(emitted, [["rpiv:ask-user:answer", { toolCallId: "call-1", answers: [{ questionIndex: 0, optionIndexes: [0] }] }]]);
  bridge.askUserBlocked({ active: false, toolCallId: "call-1" });
  assert.equal((await phone.next()).dialog, null);
});
