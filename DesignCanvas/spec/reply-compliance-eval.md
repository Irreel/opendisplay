# Reply-compliance eval

Design Canvas has no reply timeout by owner decision (D21, `technical_doc.md`
section 5.4): a round Claude Code never replies to just stays `sent`
forever. There are two known-silent failure modes behind that decision
(`technical_doc.md` section 11, "Failure modes"): the channel notification
never reached Claude Code (dropped, or the channel wasn't loaded), or
Claude Code saw it but the model never called `design_canvas_reply` (never
got to it, or got stuck behind a permission prompt, per G19). Neither
produces an error anywhere — the only way to know how often either
happens is to run real rounds and count.

This is that measurement. It is also the only evidence behind the PRD
success metric "Rounds that receive a reply: near 100%".

## Protocol

Prerequisites: a real Design Canvas session — a real iPad (or, failing
that, the harness in `DesignCanvas/server/scripts/channel-harness.mjs`
standing in for the iPad's HTTP calls) driving a **real** Claude Code
session attached via the channel, working in a real project. This is not
a test of the daemon or the channel process (those are covered by
`pnpm --dir DesignCanvas/server test`, `test:channel`, and `test:e2e`); it
is a test of whether the *model*, in a real session, reliably calls the
reply tool.

1. Draw and send 10 rounds, each a real, small, applicable request (e.g.
   "make this button bigger", "this label is misspelled", "add a border
   here") against a project Claude Code can actually act on. Space them
   out enough that you can tell which reply belongs to which round —
   sending a second round before the first is answered is a valid and
   useful thing to test (see the note on G10 below), but keep track of
   which annotation ID is which.
2. For each round, start a timer when the round shows `sent` and stop it
   when a reply is recorded (visible on the iPad, or via
   `GET /v1/rounds?device=<id>` on the daemon).
3. Give each round up to **10 minutes** of wall-clock time before counting
   it as non-compliant. (This eval's own bookkeeping window — not a
   product feature. The product itself never times a round out.)
4. Fill in the results table below, one row per round.
5. Compliance = replies received / 10. **Threshold: 9/10 (90%).**

A run at or above the threshold means the reply gap is rare enough that
D21 (no product-level timeout) remains an acceptable trade for the MVP. A
run below it means investigate before shipping further on this
assumption:

- Check the daemon log for `channel.notification.sent` and
  `channel.subscriber.handle_error` lines for the missing round's
  annotation ID — a `sent` notification with no reply as the model
  starting cold; a *missing* `channel.notification.sent` line means the
  notification never left the channel process (a delivery bug, not a
  model behavior).
- Check the Claude Code session transcript for the missing round: did the
  model see the notification at all (queued behind other work per G10),
  did it act on the change but forget to call the tool, or was it stuck
  behind a permission prompt (G19, D20's terminal-visibility mitigation)?
- File what you find as a TODOS.md entry or an issue; do not just re-run
  the eval until it passes.

## Results

Run date: **\_\_\_\_**  ·  Tester: **\_\_\_\_**  ·  Build/commit: **\_\_\_\_**  ·  Project: **\_\_\_\_**

| Round | Sketch / request | Sent at | Replied? | Time to reply | Status | PR link? | Notes |
|---|---|---|---|---|---|---|---|
| 1 | | | | | | | |
| 2 | | | | | | | |
| 3 | | | | | | | |
| 4 | | | | | | | |
| 5 | | | | | | | |
| 6 | | | | | | | |
| 7 | | | | | | | |
| 8 | | | | | | | |
| 9 | | | | | | | |
| 10 | | | | | | | |

**Compliance: \_\_\_ / 10 — PASS / FAIL (threshold 9/10)**

Summary of any failures and what was found investigating them:

---

## Related, not this eval

- **G10 (batched turns).** Whether two sketches sent while Claude Code is
  mid-turn both come out correctly applied is a related but separate
  question (`TODOS.md`, "Measure batched sketches in one Claude Code
  turn"). This eval doesn't have to avoid triggering it, but a batched
  round that comes back wrong is a G10 finding, not a reply-compliance
  failure, and should be logged separately.
- **Device hardware bugs.** Use `device-checklist.md` for anything about
  the wire, the freeze, or the drawing surface itself. This eval assumes
  those already work and is purely about whether replies come back.
