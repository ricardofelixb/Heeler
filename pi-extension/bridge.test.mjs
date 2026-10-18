import test from "node:test";
import assert from "node:assert/strict";
import { once } from "node:events";
import { mkdtemp, rm, stat } from "node:fs/promises";
import { tmpdir } from "node:os";
import { createConnection } from "node:net";
import { join } from "node:path";
import { PiMirrorBridge, endpoint, conversationRows } from "./bridge.mjs";

async function fixture(t) {
  const home = await mkdtemp(join(tmpdir(), "heeler-pi-test-"));
  const env = { HERDR_SOCKET_PATH: "/tmp/test-herdr.sock", HERDR_PANE_ID: "opaque:pane/1" };
  const prompts = [];
  let aborted = 0;
  let sessionID = "session-a";
  let branch = [{ type: "message", id: "u1", message: { role: "user", content: "Hello" } }];
  const ctx = { isIdle: () => true, abort: () => { aborted += 1; },
    sessionManager: { getBranch: () => branch, getSessionId: () => sessionID } };
  const bridge = new PiMirrorBridge({ sendUserMessage: (...args) => prompts.push(args) }, { env, home });
  await bridge.start(ctx);
  const address = endpoint(home, env.HERDR_SOCKET_PATH, env.HERDR_PANE_ID);
  t.after(async () => { await bridge.stop(); await rm(address.directory, { recursive: true, force: true });
    await rm(home, { recursive: true, force: true }); });
  async function client() {
    const socket = createConnection(address.socket);
    let buffer = "";
    const frames = [];
    const waiters = [];
    socket.on("data", (chunk) => {
      buffer += chunk.toString();
      let end;
      while ((end = buffer.indexOf("\n")) >= 0) {
        const frame = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
        if (waiters.length) waiters.shift()(frame); else frames.push(frame);
      }
    });
    const next = () => frames.length ? Promise.resolve(frames.shift()) : new Promise((resolve) => waiters.push(resolve));
    socket.on("error", () => {});
    await once(socket, "connect");
    t.after(() => socket.destroy());
    return { socket, next, write: (command) => socket.write(`${JSON.stringify(command)}\n`),
      command: (type, extra = {}) => ({ id: "request-1", epoch: bridge.epoch, sessionID: bridge.conversationID(), type, ...extra }) };
  }
  return { bridge, ctx, client, prompts, address, aborted: () => aborted,
    setBranch: (value) => { branch = value; }, setSession: (value) => { sessionID = value; } };
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

test("lost acknowledgment retry after reconnect submits exactly one prompt", options, async (t) => {
  const f = await fixture(t); const a = await f.client(); await a.next();
  const command = a.command("prompt", { text: "Continue" });
  a.write(command); assert.equal((await a.next()).type, "ack");
  a.socket.destroy();
  const b = await f.client(); await b.next(); b.write(command);
  assert.equal((await b.next()).error, undefined);
  assert.deepEqual(f.prompts, [["Continue", { deliverAs: "followUp" }]]);
});

test("stale session, stale bridge, reused ID, slash commands, and UI blocking reject", options, async (t) => {
  const f = await fixture(t); const a = await f.client(); await a.next();
  for (const extra of [{ sessionID: "other" }, { epoch: "old" }, { text: "/live" }]) {
    a.write(a.command("prompt", { text: "No", ...extra })); assert.ok((await a.next()).error);
  }
  a.write(a.command("prompt", { text: "Yes" })); await a.next();
  a.write(a.command("prompt", { text: "Changed" })); assert.ok((await a.next()).error);
  f.bridge.event({ type: "ui_prompt_start", title: "Approve in Terminal" }, f.ctx);
  assert.equal((await a.next()).blocked, "Approve in Terminal");
  a.write(a.command("prompt", { id: "request-2", text: "No" })); assert.ok((await a.next()).error);
  assert.equal(f.prompts.length, 1);
});

test("stop is deduplicated and disconnect does not abort Pi", options, async (t) => {
  const f = await fixture(t); const a = await f.client(); await a.next();
  const stop = a.command("stop"); a.write(stop); await a.next(); a.write(stop); await a.next();
  assert.equal(f.aborted(), 1); a.socket.destroy(); await f.bridge.stop(); assert.equal(f.aborted(), 1);
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

test("malformed or oversized commands close only that client", options, async (t) => {
  const f = await fixture(t); const a = await f.client(); await a.next();
  const closed = once(a.socket, "close"); a.socket.write("x".repeat(65_537)); await closed;
  const b = await f.client(); assert.equal((await b.next()).type, "snapshot");
  b.write(b.command("prompt", { text: "Still works" })); await b.next(); assert.equal(f.prompts.length, 1);
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

test("desktop tree navigation invalidates commands even within the same session file", options, async (t) => {
  const f = await fixture(t); const a = await f.client(); await a.next();
  const old = a.command("prompt", { text: "Old branch" });
  f.bridge.event({ type: "session_tree" }, f.ctx); const snapshot = await a.next();
  assert.notEqual(snapshot.sessionID, old.sessionID);
  a.write(old); assert.ok((await a.next()).error); assert.equal(f.prompts.length, 0);
});

test("an active socket is never replaced by another mirror", options, async (t) => {
  const f = await fixture(t);
  const other = new PiMirrorBridge({}, f.bridge.options);
  await assert.rejects(other.start(f.ctx), /already active/);
});
