# Design Canvas wire protocol

Version 1. This is the normative description of everything that crosses the
link between the Design Canvas Mac app and the Design Canvas iPad (or iPhone)
app. Code that disagrees with it is wrong. The constants live in
`Shared/CanvasMessages.swift` (`CanvasWire`), the framing in
`Shared/WireFrame.swift` and `Shared/VideoPacket.swift`, and the link
messages in `Shared/LinkMessages.swift`.

Both apps are built from this folder and ship together, so the protocol has
no negotiation and no compatibility promise across versions: a peer that
speaks another version is told so and turned away (section 5.1).

## 1. Roles and transport

- The **iPad listens** on TCP port **9100** and advertises Bonjour type
  **`_designcanvas._tcp`** with TXT keys `id` (its install id) and `v` (its
  wire version).
- The **Mac dials**: over USB through macOS's usbmuxd (which can only open
  connections toward the device), over WiFi to the Bonjour service. The
  same bytes run on both.
- One iPad shows one Mac. A Mac may serve several iPads, each on its own
  connection.
- Both directions use TCP with `TCP_NODELAY`.

## 2. Frames

Every byte on the connection belongs to a frame:

```
[u32 BE length][u8 kind][length - 1 bytes of body]
```

`length` counts the kind byte and the body. It MUST be at least 1 and at most
33554432 (32 MiB). A receiver that reads a length outside that range MUST
close the connection: the next frame's boundary is unknown.

| kind | name | body |
|---|---|---|
| 1 | message | section 3 |
| 2 | video | section 4, Mac to iPad only |

A frame of any other kind MUST be skipped. (A kind byte of `0x7B`, `{`, is
what the protocol Design Canvas used before this one looks like: JSON
straight after the length. Implementations MAY use it to tell the user the
other app is out of date.)

## 3. Messages

```
[u32 BE json length][json length bytes of UTF-8 JSON][attachment]
```

The JSON is an object with a string `type`, at most 1 MiB. The attachment
is whatever bytes remain in the frame, possibly none; only `annotation` uses
one. An unknown `type` MUST be ignored, and so MUST an unknown field of a
known type.

## 4. Video

Mac to iPad, H.264, real time, no frame reordering, a keyframe only when one
is needed (a new connection, a `keyframe` request, a change of stream size).

```
[u64 BE frame number][u8 flags]
[if flags & 0x02: u8 count, then count × (u16 BE length, parameter set)]
[sample]
```

- `flags & 0x01`: the frame is a sync sample (a keyframe).
- `flags & 0x02`: parameter sets follow — for H.264 the SPS then the PPS.
  Every keyframe carries them.
- `sample`: the encoder's own output, a run of NAL units each prefixed with
  its 4-byte big-endian length (AVCC), handed to the decoder unchanged.
- The **frame number** is the Mac's capture counter. It increases on a
  connection but is not contiguous (frames the link had no room for are never
  encoded). It is what `freeze` names (section 6).

A receiver that has no parameter sets yet, or cannot decode a frame, sends
`keyframe` (at most once a second).

## 5. Link messages

### 5.1 `hello` (both ways)

The Mac sends it as soon as its connection is up. The iPad treats every new
connection as a candidate until its `hello` arrives, then adopts it (replacing
any other session) and answers with its own.

| field | type | |
|---|---|---|
| `v` | number | the sender's wire version |
| `role` | `"mac"` or `"ipad"` | |
| `name` | string, optional, ≤ 60 characters | the sender's name, for display |
| `id` | string | iPad only: its install id |
| `device` | `"iPad"` or `"iPhone"` | iPad only |

If `v` differs from its own, the receiving side sends `bye` with reason
`version` and closes. Over WiFi the Mac streams only to an iPad whose `id`
is the one its Bonjour service advertised. A `hello` over WiFi does not by itself replace a session that
runs over USB: the iPad holds it, sends `asking` (section 5.6) and asks its
user whether to switch. Nothing on the link is authenticated, and a cable is
the one thing a LAN neighbour cannot fake. The Mac starts streaming when the iPad's `hello`
arrives. A candidate that sends no `hello` within 6 s is dropped.

### 5.2 `ping`, `pong` (both ways)

Each side sends `ping {t}` every 2 s, `t` being its clock in milliseconds;
the other answers `pong` with the same `t`. A side that has received no byte
at all for 6 s closes the connection. Every chunk read counts, so a large
upload in progress never looks like silence.

### 5.3 `keyframe` (iPad to Mac)

No fields. The next video frame is a keyframe; if the screen has not
changed, the Mac re-encodes the newest frame it has.

### 5.4 `bye` (both ways)

Sent just before closing on purpose. `reason`: `sleep` (the iPad locked; it
comes back on wake), `quit` (the app is quitting or the user disconnected),
`version` (section 5.1), `replaced` (the iPad adopted a newer connection),
`inUse` (the iPad's user kept its cabled Mac, or another request was already
open; section 5.6). An unknown reason
reads as `quit`. A Mac told `replaced` or `inUse` stops dialing that iPad
until something changes (it is replugged, re-advertised, or the user connects
it), so two Macs never take one iPad back and forth.

### 5.5 `status` (Mac to iPad)

The Mac's side of the Claude Code hop. Sent after the iPad's `hello` and again
whenever it changes, never on a timer.

| field | type | |
|---|---|---|
| `channel` | `attached`, `detached`, `existing`, `none` | an unknown value reads as `none` |
| `project` | string, optional | the target session's folder; absent when there is no target |

### 5.6 `asking` (iPad to Mac)

No fields. The iPad is mirroring a Mac over its cable, and this Mac's
`hello` arrived over WiFi: the iPad is asking its user whether to switch.
Until it answers, the iPad keeps the connection as a candidate and answers
its `ping`s, and the Mac stops timing its handshake out after 6 s and waits
up to 45 s. The answer is the iPad's `hello` (switch: the cabled Mac is sent
`bye` reason `replaced`) or `bye` reason `inUse` (keep the cable). With no
answer from the user within 30 s the iPad keeps the cable. One request is
open at a time; another Mac asking meanwhile is sent `bye` reason `inUse` at
once, and so is any Mac asking within 60 s of a request that ended without a
switch (the user kept the cable, it timed out, or the asking Mac left). The iPad shows the asking Mac's `name` only as a
claim, with control and formatting characters removed.

## 6. Canvas messages

| `type` | direction | fields | attachment |
|---|---|---|---|
| `freeze` | iPad to Mac | `frame`, `t` | — |
| `frozen` | Mac to iPad | `frame`, `ok` | — |
| `annotation` | iPad to Mac | `viewport`, `note`?, `base`?, `session`?, `t` | the sketch PNG |
| `agentReply` | Mac to iPad | `annotationId`, `status`, `message`?, `prUrl`?, `t` | — |
| `rounds` | Mac to iPad | `rounds[]` | — |
| `sessions` | Mac to iPad | `sessions[]`, `target`? | — |
| `selectSession` | iPad to Mac | `id`, `t` | — |

`t` is always milliseconds since the Unix epoch on the sender's clock, as a
number.

- **`freeze`**: enter Draw Mode on the frame on screen. `frame` is that
  frame's number (section 4). The iPad stops showing new frames at once.
- **`frozen`**: `ok` is true when the Mac still holds the clean, pre-encode
  original of `frame`, false when it does not. `frame` repeats the request's,
  and an iPad ignores a `frozen` for any frame but the one it asked about.
- **`annotation`**: the finished sketch. The attachment is a PNG of the
  strokes only, transparent, at most 25165824 bytes (24 MiB); the iPad refuses
  a bigger one before sending, where the strokes can still be erased.
  `viewport` (`{w, h, scale}`) describes the surface the PNG covers: `w` and
  `h` are its size in points — the whole picture as fitted to the screen,
  whatever the zoom was while drawing — and `scale` the screen scale it was
  rendered at. `note` is the user's typed note. `session` is the
  `sessions.target` the iPad was showing at Done; the round goes to that
  session even if the target changes afterwards. With `base` absent (or a
  value the Mac does not know) the Mac composites the sketch over the frame
  the last `freeze` held, stretched over the whole frame. With `base:
  "blank"` there is no frame: no `freeze` precedes it, and the Mac
  composites over an opaque white image of `w × scale` by `h × scale` pixels.
  There is no acknowledgement: "sent" means the socket write completed. An
  iPad that loses the link before then re-sends the identical message after
  the next `hello`, and the Mac drops one whose `t` it has already accepted
  from that iPad.
- **`agentReply`**: one round's live status. `status` is one of `queued`,
  `sent`, `applied`, `failed`, `needs_input`; `message` is at most 2048 UTF-8
  bytes, cut on a character boundary.
- **`rounds`**: the newest 20 rounds for this iPad, newest first, sent after
  every `hello` and whenever the Mac's daemon stream reconnects. Each entry:
  `annotationId`, `createdAt` (ISO 8601), `status`, and optionally `message`
  (≤ 2048 bytes), `prUrl`, `note`. An entry that cannot be read is skipped. An
  iPad never moves a round it knows backwards: a snapshot can predate an
  `agentReply` it already showed.
- **`sessions`**: the Claude Code sessions the Mac is connected to, at most
  20, each `id`, `folder` (≤ 60 characters), `title`? (≤ 80), `branch`?
  (≤ 80), `startedAt`, `lastReplyAt`?, `state` (`idle`, `busy`, `waiting`; an
  unknown value reads as `busy`), and `target`, the `id` the next sketch goes
  to. Sent after every `hello` and whenever the list or the target changes.
  With several sessions and no `target`, the iPad does not send an
  `annotation` until the user picks one.
- **`selectSession`**: make `id` the target. The Mac answers with a fresh
  `sessions`, which is the only confirmation.

## 7. No input

Nothing on this link moves the Mac's pointer or types on it. The iPad's
pinch and pan zoom its own picture and are never sent anywhere, and the Mac
app never asks for Accessibility.
