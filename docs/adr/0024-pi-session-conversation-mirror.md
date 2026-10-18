# ADR 0024: Pi-first conversation mirroring in the personal fork

- Status: Accepted (personal fork preview)
- Date: 2026-10-17

## Context

This fork favors one existing Pi session across desktop and phone, rather than
launching a separate headless agent for each interface. herdr has no structured
conversation API ([ADR 0012](0012-monitor-non-realtime-agent-surface.md)); terminal
text is not a reliable message/tool protocol. ACP adapters are useful for managed
agents, but do not establish attachment to an already-running Pi TUI.

## Decision

Add an **opt-in Pi extension** inside the existing process. It projects Pi's
current SessionManager branch and live message/tool/UI events onto a private
user-owned Unix socket. The app reaches it through direct-streamlocal on the
existing authenticated SSH Transport. Socket discovery hashes the user's home,
herdr socket, and opaque pane ID; it uses no shell interpolation or network listener.

Pi panes open a native Conversation with text, expandable tools, composer, and
Stop. The same-pane Terminal remains available for slash commands, attachments,
and custom extension dialogs. Other agents remain terminal-based. The app never
starts a new agent or changes desktop focus just to display the native view.

Pi remains authoritative for credentials, tools, history, execution and lifetime.
The app owns presentation and a local draft; a connection holds only a forwarding
channel. Snapshot plus versioned/revisioned pushed updates supports reconnect and
branch reconciliation without terminal parsing or optimistic transcript duplication.
Snapshots run after message persistence and replace temporary streaming identities.

A command receipt means submitted to Pi's extension API, not model acceptance or
completion. Retries retain their ID only within the same bridge epoch and
conversation token. Pi restarts/reloads/session switches/tree navigation invalidate
unconfirmed requests rather than risking duplicate execution. Unsent/unconfirmed
text stays available for review. No cross-process exactly-once claim is made.

## Consequences

- This is deliberately Pi-specific, not a new multi-agent abstraction or a change
  to herdr's generated wire protocol. Claude, Codex, voice, and new navigation
  are outside this first pass.
- Requires a separately installed extension and the current Pi extension API,
  tested against `@earendil-works/pi-coding-agent` 1.3.0. Existing Hosts without it
  retain terminal access; loading it never happens silently from the phone.
- macOS/Linux only initially. Native Windows doesn't support this socket path.
- Bounded native history/tool previews protect a mobile stream; full source
  history remains in Pi. Images, thinking, custom UI, and rich Markdown blocks
  aren't replicated in this version. The native UI indicates truncation.
- User-owned 0700 directory/0600 socket and the SSH login are the trust boundary.
  Same-OS-user processes are trusted, as with the session files themselves.
- [ADR 0012](0012-monitor-non-realtime-agent-surface.md) and
  [ADR 0013](0013-live-terminal-with-local-composer.md) remain the default contracts
  for other agent kinds and the terminal fallback; their rejection of inferred
  chat remains valid. This surface instead uses explicit Pi runtime events.
- Setup, bounded wire contract and focused verification live in
  [pi-extension/README.md](../../pi-extension/README.md).
