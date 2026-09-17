#!/usr/bin/env node
// Design Canvas server entry. Mode dispatch lives here; domain logic stays in modules.

import { CAPTURE_SWEEP_MS, CLAIM_LEASE_MS } from './shared.js';
import { createMcpChannel } from './channel/index.js';
import { runChannelSubscriber } from './channel/subscriber.js';
import { AnnotationEventBus } from './http/event-stream.js';
import { startHttpServer } from './http/server.js';
import { createLogger } from './log.js';
import { DesignCanvasStore } from './store/store.js';

const args = new Set(process.argv.slice(2));
const isChannel = args.has('--channel');
const isHttp = args.has('--http');

if (isChannel && isHttp) {
  console.error('--channel and --http are mutually exclusive');
  process.exit(2);
}

if (!isChannel && !isHttp) {
  console.error('designtool: pass --channel (spawned by Claude Code) or --http (local dev)');
  process.exit(2);
}

const logger = createLogger();

if (isChannel) {
  // Thin loopback client: claim pending annotations from the daemon and push
  // them onto the channel. No HTTP server here.
  const channel = createMcpChannel(logger);
  // Establish the MCP stdio transport up front so the host's `initialize`
  // handshake is answered immediately, not only when the first annotation
  // arrives. Then subscribe to the daemon's loopback stream.
  await channel.connect();
  await runChannelSubscriber({ channel, logger });
} else {
  // Daemon: owns the FS store and serves the HTTP API.
  const store = new DesignCanvasStore(logger);
  const bus = new AnnotationEventBus();
  await store.ensure();
  await startHttpServer({
    version: process.env['npm_package_version'] ?? '0.0.0',
    store,
    bus,
    logger,
  });
  // Periodic sweep: return stale `serving` records (from a crashed subscriber)
  // to pending. unref() so this timer never holds the process open.
  const timer = setInterval(() => {
    void store.reconcileStaleClaims();
  }, CLAIM_LEASE_MS / 2);
  timer.unref();
  // Captures a Draw Mode entry posted and no sketch ever claimed: swept at startup
  // and hourly, so a full-resolution frame per entry does not accumulate (I5).
  void store.pruneCaptures();
  const captureSweep = setInterval(() => {
    void store.pruneCaptures();
  }, CAPTURE_SWEEP_MS);
  captureSweep.unref();
}
