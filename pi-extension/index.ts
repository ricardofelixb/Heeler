import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { ASK_USER_BLOCKED_EVENT, ASK_USER_PROMPT_EVENT, PiMirrorBridge } from "./bridge.mjs";

/** Opt-in companion for Heeler. Uses the already-running TUI's session. */
export default function (pi: ExtensionAPI) {
  const bridge = new PiMirrorBridge({ api: {
    getCommands: () => pi.getCommands(),
    setModel: (model: Parameters<ExtensionAPI["setModel"]>[0]) => pi.setModel(model),
    getThinkingLevel: () => pi.getThinkingLevel(),
    setThinkingLevel: (level: Parameters<ExtensionAPI["setThinkingLevel"]>[0]) => pi.setThinkingLevel(level),
    emit: (channel: string, data: unknown) => pi.events.emit(channel, data),
  } });
  // ask_user_question's questions, so the phone can answer them natively.
  pi.events.on(ASK_USER_PROMPT_EVENT, (data) => bridge.askUser(data));
  pi.events.on(ASK_USER_BLOCKED_EVENT, (data) => bridge.askUserBlocked(data));
  pi.on("session_start", async (_event, ctx) => {
    try { await bridge.start(ctx); }
    catch (error) { ctx.ui.notify(`Heeler mirror: ${String(error)}`, "error"); }
  });
  pi.on("session_shutdown", () => bridge.stop());
  // Observes only: the input still goes to Pi as typed.
  pi.on("input", (event, ctx) => { bridge.queue(event, ctx); return { action: "continue" }; });
  pi.on("message_start", (event, ctx) => bridge.event(event, ctx));
  pi.on("message_update", (event, ctx) => bridge.event(event, ctx));
  pi.on("message_end", (event, ctx) => bridge.event(event, ctx));
  pi.on("tool_execution_start", (event, ctx) => bridge.event(event, ctx));
  pi.on("tool_execution_update", (event, ctx) => bridge.event(event, ctx));
  pi.on("tool_execution_end", (event, ctx) => bridge.event(event, ctx));
  pi.on("agent_start", (event, ctx) => bridge.event(event, ctx));
  pi.on("agent_settled", (event, ctx) => bridge.event(event, ctx));
  pi.on("ui_prompt_start", (event, ctx) => bridge.event(event, ctx));
  pi.on("ui_prompt_end", (event, ctx) => bridge.event(event, ctx));
  pi.on("session_tree", (event, ctx) => bridge.event(event, ctx));
  pi.on("session_compact", (event, ctx) => bridge.event(event, ctx));
  pi.on("model_select", (event, ctx) => bridge.event(event, ctx));
  pi.on("thinking_level_select", (event, ctx) => bridge.event(event, ctx));
}
