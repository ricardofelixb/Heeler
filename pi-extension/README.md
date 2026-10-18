# Pi session mirroring (personal fork preview)

A native face for the **existing Pi process**, not another agent or a transcript scraper.
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

In Heeler, open that pane from Agents. Pi opens in Conversation by default. Tap
Terminal in the top bar for the **same existing pane**, and Conversation to return.
Other agent kinds keep their existing terminal UI. The native view does not invoke
`agent.focus`, so merely viewing it doesn't switch the desktop's active tab.

If the extension isn't loaded (or SSH forbids streamlocal forwarding), the native
view explains the failure and offers Retry/Terminal. It never launches a second Pi,
installs software remotely, changes SSH configuration, or falls back to an HTTP port.
Windows mirroring is not implemented.

## Current behavior and limits

- Text messages from either device and expandable tool activity; assistant text has
  inline Markdown. Thinking blocks aren't transmitted. Images appear as placeholders.
- Send calls Pi's `sendUserMessage` with `deliverAs: "steer"`: while busy,
  Pi handles native steering; while idle, it starts a normal prompt.
  A receipt means **submitted to Pi**, not completed or necessarily accepted by a
  model/extension input handler. Pi remains responsible for execution and history.
- Stop invokes Pi's existing abort operation. Leaving the view/disconnecting does not.
- Slash commands, attachments, custom dialogs, and extension-specific controls remain
  in Terminal. Blocking extension dialogs show a native prompt to open Terminal.
- Each connection starts with an authoritative snapshot of the current branch, then
  receives pushed updates. Persisted message IDs replace temporary streaming rows.
  The branch is re-read after Pi has persisted `message_end`, not before.
- Native history is bounded to **120 recent rows**, with text/tool previews capped
  around **6,000 characters**. The serialized snapshot also fits a 1 MiB wire budget.
  The full original history/output remains in Pi/Terminal; it is not deleted.
- Lost receipts can be retried using the same command ID within the same bridge and
  conversation. Receipt IDs are retained in memory (10,000-command bound), not evicted.
  After Pi restarts/reloads, switches sessions, or navigates its tree, unconfirmed
  requests are **not** automatically re-submitted. The draft stays for review.
- Slow clients are disconnected rather than silently losing events. Once connected,
  interrupted streams reconnect with backoff (2–30 seconds); snapshots restore current
  state, not every intermediate token. A missing extension requires explicit Retry.
- Multiple Heeler windows share a local stream/draft for the same Host/Pane. At most
  four socket clients connect to each Pi bridge. Pi, not any phone, owns agent lifetime.

## Security and protocol

The socket directory is `/tmp/heeler-pi-<first 16 hex SHA256(home)>/`, mode **0700**,
owned by Pi's user. Socket names are the first 32 hex SHA256 of
`HERDR_SOCKET_PATH + NUL + HERDR_PANE_ID`, suffixed `.sock`, mode **0600**.
Only a dead, owned socket may be removed at startup. Active sockets and symlinks are
never replaced. Unix-socket permissions and SSH login are the trust boundary: another
process running as the same OS user can access the same session. Never forward this
socket to an untrusted user/service.

NDJSON v1: `snapshot` (epoch, opaque conversation/session token, revision, rows,
busy/blocked), `message` upsert, `status`, and `ack` receipts. Commands contain a
unique ID, epoch and conversation token, plus `prompt`/text or `stop`. IDs are
idempotent within the live bridge; reusing an ID with other content rejects it.
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
conversation fixture. It makes no SSH/model calls; its composer returns a fixture reply.

See [ADR 0024](../docs/adr/0024-pi-session-conversation-mirror.md) for the fork decision.
