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

The mirror is **read-only**. On a Pi pane's normal Agent screen, a transcript
(text, tools grouped per reply) covers the live terminal; a header toggle chooses
which one to read. The screen's own Composer, tools keyboard and Direct Input stay
the only input path, typing into Pi's terminal, so slash commands, attachments,
dialogs and Pi's native busy steering all behave as on the desktop. While Pi shows
a dialog or the mirror is down, the terminal shows through. Other agents remain
terminal-based. The app never starts a new agent or changes desktop focus.

Pi remains authoritative for credentials, tools, history, execution and lifetime;
a connection holds only a forwarding channel. Snapshot plus versioned/revisioned
pushed updates supports reconnect and branch reconciliation without terminal
parsing. Snapshots run after message persistence and replace temporary streaming
identities. A 15-second heartbeat lets the app detect a stalled channel.

Amended 2026-10-18: the first preview had its own composer, Stop and an
acknowledged prompt protocol. Two input paths drifted (no attachments, slash
commands or dialogs; follow-up rather than steering), so the mirror lost its
write path in favor of the existing Composer.

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
- Native dialog controls would need Pi to expose a dialog's choices; until then
  the live terminal answers them.
- User-owned 0700 directory/0600 socket and the SSH login are the trust boundary.
  Same-OS-user processes are trusted, as with the session files themselves.
- [ADR 0012](0012-monitor-non-realtime-agent-surface.md) and
  [ADR 0013](0013-live-terminal-with-local-composer.md) remain the default contracts
  for other agent kinds and the terminal fallback; their rejection of inferred
  chat remains valid. This surface instead uses explicit Pi runtime events.
- Setup, bounded wire contract and focused verification live in
  [pi-extension/README.md](../../pi-extension/README.md).
