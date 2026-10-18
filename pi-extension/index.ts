import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { PiMirrorBridge } from "./bridge.mjs";

/** Opt-in companion for Heeler. Uses the already-running TUI's session. */
export default function (pi: ExtensionAPI) {
  const bridge = new PiMirrorBridge();
  pi.on("session_start", async (_event, ctx) => {
    try { await bridge.start(ctx); }
    catch (error) { ctx.ui.notify(`Heeler mirror: ${String(error)}`, "error"); }
  });
  pi.on("session_shutdown", () => bridge.stop());
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
}
