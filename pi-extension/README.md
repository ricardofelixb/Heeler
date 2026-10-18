# Pi session mirroring (personal fork preview)

A read-only transcript of the **existing Pi process**, not another agent or a transcript scraper.
Heeler opens its private Unix socket over the Host's authenticated SSH connection.
No HTTP listener, cloud service, model credentials, or terminal parsing is involved.

## Opt in on a Host

Requires macOS/Linux, Node, the current Pi extension API (tested with
`@earendil-works/pi-coding-agent` **1.3.0**), and Pi running inside a herdr pane.
The pane must expose `HERDR_SOCKET_PATH` and `HERDR_PANE_ID`.

Copy this entire directory to the Host; keep `index.ts` beside `bridge.mjs`.
For a **new** normal Pi TUI session, explicitly load it:

```sh
pi --extension /absolute/path/to/pi-extension/index.ts
```

For an **already-running** Pi session, put the directory in Pi's discovered
extensions (for example `~/.pi/agent/extensions/heeler-mirror/`) and run `/reload`
in that same TUI. This does not replace the agent process or reset its conversation.
Do not load two copies. No extension is installed by building or running Heeler.
Pi's normal extension/project-trust rules still apply.

In Heeler, open that pane from Agents. Pi's transcript covers its live terminal on
the normal Agent screen; the header's Show Terminal / Show Conversation button only
changes what you read, and Heeler remembers the choice. The terminal stays attached
underneath, so switching is instant. Other agent kinds keep their terminal UI.

If the extension isn't loaded (or SSH forbids streamlocal forwarding), you simply see
the terminal while Heeler keeps retrying in the background. It never launches a second
Pi, installs software remotely, changes SSH configuration, or falls back to an HTTP
port. Windows mirroring is not implemented.

## Current behavior and limits

- Text messages and expandable tool activity, all tool calls of one reply in one
  row; assistant text has inline Markdown. Thinking blocks aren't transmitted.
  Images appear as placeholders.
- **Read-only.** Everything you type goes through the screen's normal composer and
  keys into Pi's own terminal, so slash commands, attachments, skills and snippets
  work, and Enter while Pi is busy steers, as on the desktop. A client that writes
  to the socket is disconnected.
- While Pi shows a dialog (an extension `ui_prompt_*`), and whenever the mirror is
  disconnected, the transcript steps aside and the live terminal shows; answer with
  the composer's keys. Direct Input also shows the terminal.
- Each connection starts with an authoritative snapshot of the current branch, then
  receives pushed updates. Persisted message IDs replace temporary streaming rows.
  The branch is re-read after Pi has persisted `message_end`, not before.
- Native history is bounded to **120 recent rows**, with text/tool previews capped
  around **6,000 characters**. The serialized snapshot also fits a 1 MiB wire budget.
  The full original history/output remains in Pi/Terminal; it is not deleted.
- The bridge sends a heartbeat every **15 seconds**; Heeler treats **45 seconds** of
  silence as a stalled channel. Every failure, including before the first snapshot,
  retries with backoff (1–30 seconds), and a Host reconnect restarts it at once.
  Slow clients are disconnected rather than silently losing events.
- Multiple Heeler windows share one stream for the same Host/Pane. At most four
  socket clients connect to each Pi bridge. Pi, not any phone, owns agent lifetime.

## Security and protocol

The socket directory is `/tmp/heeler-pi-<first 16 hex SHA256(home)>/`, mode **0700**,
owned by Pi's user. Socket names are the first 32 hex SHA256 of
`HERDR_SOCKET_PATH + NUL + HERDR_PANE_ID`, suffixed `.sock`, mode **0600**.
Only a dead, owned socket may be removed at startup. Active sockets and symlinks are
never replaced. Unix-socket permissions and SSH login are the trust boundary: another
process running as the same OS user can access the same session. Never forward this
socket to an untrusted user/service.

NDJSON v1, bridge to app only: `snapshot` (epoch, opaque conversation/session token,
revision, rows, busy/blocked), `message` upsert, `status`, and `heartbeat`.
Desktop tree navigation changes the conversation token even within one session file.
Swift enforces frame bounds, version, unique snapshot row IDs, and revision continuity.
SSH library types remain inside the Transport adapter.

## Development

```sh
node --test pi-extension/bridge.test.mjs
# Optional: installed Pi; uses a temporary configuration and local mock model only.
node --test pi-extension/smoke.test.mjs
make test-app TEST_SELECTOR=HeelerTests/PiConversationTests
```

For UI-only work, launch the simulator app with
`--demo-screenshots --demo-pi-conversation`. This opens a clearly marked, in-memory
conversation fixture over the demo terminal. It makes no SSH/model calls.

See [ADR 0024](../docs/adr/0024-pi-session-conversation-mirror.md) for the fork decision.
