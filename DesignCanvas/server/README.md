# @design-canvas/server

The local laptop process for Design Canvas. Two runtime modes (mutually exclusive):

- `designtool --http` — the **daemon**. Owns the FS store and serves the HTTP API on `127.0.0.1:47100` only (`SERVER_PORT` overrides the port; the bind address is not configurable). Long-lived; runs while Claude Code is or is not running. Does **not** speak MCP. Periodically sweeps stale claims back to pending.
- `designtool --channel` — the **channel subscriber**, spawned by Claude Code via `.mcp.json`. Speaks MCP over stdio and declares the `claude/channel` capability, and is a loopback client of the daemon: it subscribes to the daemon's SSE stream, and for each pending annotation it claims → emits the `claude/channel` notification → marks served. Binds **no** HTTP. Lifetime tied to Claude Code.

Delivery is **at-least-once**: a claim takes a lease, and the daemon's reconcile sweep returns a claim abandoned by a crashed subscriber to pending. A client may therefore occasionally see a duplicate notification.

Spec: `DesignCanvas/spec/technical_doc.md`.

## Loopback only

Every endpoint answers `403 {"error":"forbidden"}` to a non-loopback peer (`127.0.0.1` / `::1` / `::ffff:127.0.0.1` only). There is no LAN-bind mode, no CORS, and no pairing: Design Canvas's iPad app never talks to this daemon directly (it goes through the OpenDisplay wire to the Mac app, which is the only loopback client).

## Module structure

```
src/
├── index.ts            # entry, mode dispatch
├── shared.ts            # wire types and constants
├── http/                # HTTP routes, multipart parsing, SSE plumbing
├── channel/             # claude/channel adapter boundary — the only place that imports the MCP SDK
├── store/               # FS annotation + capture store, rounds projection, uuidv7
└── log.ts               # structured JSON-lines logging
```

## Hard rules

1. The `channel/` directory is the only place that imports `@modelcontextprotocol/sdk` or names the wire protocol. Other directories see typed events plus a public `notifyAnnotation(annotation)`.
2. The HTTP layer and the channel layer share state through the store, never by direct calls.
3. No code in this package writes anywhere except `~/.claude/channels/design-canvas/` and `~/Library/Logs/DesignCanvas/`.
4. No LLM calls. Period.
5. Every state change in the store emits a structured log line.

## Local dev

```bash
pnpm --dir DesignCanvas/server install
pnpm --dir DesignCanvas/server build
pnpm --dir DesignCanvas/server test
pnpm --dir DesignCanvas/server typecheck
node DesignCanvas/server/dist/index.js --http    # runs the daemon on 127.0.0.1:47100
```

For isolated runs, set `DESIGN_CANVAS_STORE_DIR` and `DESIGN_CANVAS_LOG_PATH` to temporary paths. Otherwise the server writes to:

- `~/.claude/channels/design-canvas/`
- `~/Library/Logs/DesignCanvas/server.log`
