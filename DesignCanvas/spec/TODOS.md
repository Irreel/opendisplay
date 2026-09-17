# TODOS

## Design Canvas

### Encrypted WiFi transport with a pairing code (OpenDisplay #16)

**What:** TLS on the OpenDisplay wire with a self-signed certificate exchanged at first pairing, so WiFi sessions cannot be spoofed or sniffed.

**Why:** The MVP accepts OpenDisplay's trust-on-first-use, which leaves a LAN injection path: anyone who advertises the iPad's cleartext Bonjour id gets dialed and can push a sketch into the user's Claude Code session. The Claude Code Channels reference also requires an authenticated sender before the permission relay can be declared, so this blocks permission prompts on the iPad.

**Context:** OpenDisplay upstream tracks this as roadmap issue #16 (github.com/peetzweg/opendisplay/issues/16). Design Canvas consumes it once upstream or this fork ships it. Start at PROTOCOL.md sections 2.1 and 10 (two-phase migration rules); it is a protocol-version change on both apps. Eng review 2026-09-16, decision 3A.

**Effort:** XL
**Priority:** P1
**Depends on:** None. Blocks: permission relay on the iPad.

### MCP tool returning the composite as an image block

**What:** `design_canvas_get_image(annotation_id)` on the channel server, returning the composite as an MCP image content block, as a second delivery path beside the file path.

**Why:** The file-path form gives the daemon no signal that the model actually looked at the sketch; a tool call is logged. It also works in a sandboxed or remote Claude Code session where the path does not exist, and it is the interface a future embedded-agent backend would use.

**Context:** Decided against for the MVP in technical_doc.md section 5.5 on contract stability and vendor precedent (fakechat sends a path). Build when replies show the model acting without reading the sketch, or when the embedded backend lands. Start in packages/server/src/channel/index.ts beside the reply tool; downscale server-side to about 1568 px before encoding.

**Effort:** S
**Priority:** P3
**Depends on:** Reply tool shipped.

### Measure batched sketches in one Claude Code turn (G10)

**What:** A dogfooding protocol: send a second round while the first is being applied, ten times, and record whether the batched turn produces correct edits for both.

**Why:** The Channels reference says events arriving mid-task are delivered together on the next turn. Whether two sketches in one turn yield good edits is unknown and decides whether the iPad should discourage sending while a round is unanswered.

**Context:** G10 in technical_doc.md section 10. Run with the E2E harness and a real session once the MVP round works end to end.

**Effort:** S
**Priority:** P3
**Depends on:** MVP round working end to end.

### Pending-round TTL

**What:** Mark `pending` rounds older than about 30 minutes as `expired` in the daemon sweep and never emit them; show `expired` in the rounds snapshot.

**Why:** At-least-once delivery plus backlog replay plus Claude Code batching means sketches drawn on a UI that no longer exists replay after a Claude Code restart and get applied to moved-on source. With Stack cut, the iPad has no way to cancel a queued round.

**Context:** Outside-voice finding 8 in the 2026-09-16 eng review; deferred by owner. The daemon already has a lease sweep (packages/server, claim lease 30 s) to extend. Revisit together with Stack.

**Effort:** S
**Priority:** P3
**Depends on:** None.

## Completed
