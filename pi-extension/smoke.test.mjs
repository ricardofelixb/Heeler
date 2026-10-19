// Optional integration smoke: requires Pi 1.3+ on PATH. Only a local mock model is used.
import test from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { createServer } from "node:http";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { createConnection } from "node:net";
import { createInterface } from "node:readline";
import { endpoint } from "./bridge.mjs";

class Inbox {
  frames = [];
  waiters = [];
  constructor(input) {
    this.lines = createInterface({ input });
    this.lines.on("line", (line) => {
      let frame;
      try { frame = JSON.parse(line); } catch { return; }
      const index = this.waiters.findIndex((waiter) => waiter.match(frame));
      if (index >= 0) this.waiters.splice(index, 1)[0].resolve(frame);
      else this.frames.push(frame);
    });
  }
  next(match) {
    const index = this.frames.findIndex(match);
    if (index >= 0) return Promise.resolve(this.frames.splice(index, 1)[0]);
    return new Promise((resolve) => this.waiters.push({ match, resolve }));
  }
}

test("real Pi core mirrors the running session, takes only settings from the phone, and restores on reconnect", { timeout: 30_000 }, async (t) => {
  const directory = await mkdtemp(join(tmpdir(), "heeler-pi-smoke-"));
  const env = { ...process.env, PI_CODING_AGENT_DIR: join(directory, "agent"), PI_OFFLINE: "1",
    HERDR_SOCKET_PATH: "/tmp/heeler-smoke-herdr.sock", HERDR_PANE_ID: `smoke-${process.pid}` };
  const requests = [];
  const model = createServer(async (request, response) => {
    let body = "";
    for await (const chunk of request) body += chunk;
    requests.push(JSON.parse(body));
    response.writeHead(200, { "Content-Type": "text/event-stream" });
    const chunk = (delta, finish_reason = null) => `data: ${JSON.stringify({ id: "mock", object: "chat.completion.chunk",
      created: 0, model: "mock", choices: [{ index: 0, delta, finish_reason }] })}\n\n`;
    response.end(chunk({ role: "assistant", content: "" }) + chunk({ content: "Hello from the same Pi process." }) +
      chunk({}, "stop") + "data: [DONE]\n\n");
  });
  model.listen(0, "127.0.0.1"); await once(model, "listening");
  const provider = join(directory, "provider.ts");
  await writeFile(provider, `export default function(pi) { pi.registerProvider("heeler-mock", {
    baseUrl: "http://127.0.0.1:${model.address().port}/v1", apiKey: "local-test-only", api: "openai-completions",
    models: [{id:"mock", name:"Local mock", reasoning:false, input:["text"],
      cost:{input:0,output:0,cacheRead:0,cacheWrite:0}, contextWindow:8192, maxTokens:128}]
  }); }`);
  const child = spawn("pi", ["--offline", "--mode", "rpc", "--no-session", "--no-extensions", "--no-mcp",
    "--no-skills", "--no-prompt-templates", "--no-themes", "--no-context-files", "--no-tools",
    "--extension", resolve("pi-extension/index.ts"), "--extension", provider,
    "--model", "heeler-mock/mock"], { env, cwd: directory, stdio: ["pipe", "pipe", "pipe"] });
  const exited = once(child, "exit");
  // Don't forward stderr: no user credentials or machine configuration enter test output.
  child.stderr.resume();
  t.after(async () => {
    child.kill("SIGTERM"); await exited;
    model.closeAllConnections(); await new Promise((done) => model.close(done));
    // A force-killed test process can leave its own dead socket, never another pane's.
    await rm(endpoint(homedir(), env.HERDR_SOCKET_PATH, env.HERDR_PANE_ID).socket, { force: true });
    await rm(directory, { recursive: true, force: true });
  });
  const rpc = new Inbox(child.stdout);
  const command = async (type, id, extra = {}) => {
    child.stdin.write(`${JSON.stringify({ type, id, ...extra })}\n`);
    const reply = await rpc.next((frame) => frame.type === "response" && frame.id === id);
    assert.equal(reply.success, true, `${type} failed`);
    return reply;
  };
  await command("get_state", "ready");
  async function phone() {
    const socket = createConnection(endpoint(homedir(), env.HERDR_SOCKET_PATH, env.HERDR_PANE_ID).socket);
    const inbox = new Inbox(socket);
    t.after(() => socket.destroy());
    await once(socket, "connect");
    return { socket, inbox, snapshot: await inbox.next((frame) => frame.type === "snapshot") };
  }
  const first = await phone();
  await command("prompt", "desktop", { message: "Desktop prompt" });
  const final = await first.inbox.next((frame) => frame.type === "snapshot" && !frame.busy &&
    frame.rows.some((row) => row.role === "assistant"));
  assert.equal(final.rows.filter((row) => row.role === "user" && row.text === "Desktop prompt").length, 1);
  assert.equal(first.snapshot.settings.model.id, "mock");
  // Messages never come through the mirror; only model and thinking settings do.
  first.socket.write(`${JSON.stringify({ type: "prompt", id: "phone", text: "Ignored" })}\n`);
  first.socket.write(`${JSON.stringify({ type: "setModel", provider: "heeler-mock", id: "mock" })}\n`);
  const settings = await first.inbox.next((frame) => frame.type === "settings");
  assert.equal(settings.settings.model.id, "mock");
  assert.deepEqual(settings.settings.model.thinkingLevels, ["off"]);
  const second = await phone();
  assert.deepEqual(second.snapshot.rows.map((row) => row.role), ["user", "assistant"]);
  const messages = await command("get_messages", "messages");
  assert.equal(messages.data.messages.filter((message) => message.role === "user").length, 1);
  assert.equal(requests.length, 1);
});
