# Design Canvas wire protocol

Version 2. This is the normative description of everything that crosses the
link between the Design Canvas Mac app and the Design Canvas iPad (or iPhone)
app. Code that disagrees with it is wrong. The constants live in
`Shared/CanvasMessages.swift` (`CanvasWire`), the framing in
`Shared/WireFrame.swift` and `Shared/VideoPacket.swift`, the link messages
in `Shared/LinkMessages.swift`, and pairing and sealing in
`Shared/Pairing.swift`. Version 2 (2026-11-03) added pairing and sealed
every session; version 1 had neither.

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
| 3 | sealed | a kind-1 or kind-2 frame, encrypted (section 5.7) |

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

### 5.1 `hello` (both ways), and how a session starts

Everything up to the end of the handshake travels in the clear; everything
after it is sealed (section 5.7). In order:

1. The Mac sends `hello` as soon as its connection is up. The iPad treats
   every new connection as a candidate until this arrives.
2. The iPad answers with its own `hello`. If it has this Mac paired, the
   hello carries its signature (`sig`) over the verify transcript.
3. If the Mac has the iPad paired and the signature checks against the key
   it pinned, it sends `verify` with its own signature, and both directions
   are sealed from there. Otherwise the two pair (section 5.7), after which
   both directions are sealed too.
4. The iPad, now sure which Mac this is, either takes it as its session and
   sends `ready`, or first asks its user (section 5.6). The Mac streams from
   `ready`.

| field | type | |
|---|---|---|
| `v` | number | the sender's wire version |
| `role` | `"mac"` or `"ipad"` | |
| `name` | string, optional, ≤ 60 characters | the sender's name, for display only: a claim, never proof |
| `id` | string | iPad only: its install id |
| `device` | `"iPad"` or `"iPhone"` | iPad only |
| `key` | base64, 32 bytes | the sender's long-term Ed25519 public key |
| `eph` | base64, 32 bytes | the sender's X25519 key for this connection only |
| `sig` | base64, 64 bytes, optional | iPad only, when it has the Mac paired: its signature over the verify transcript |

If `v` differs from its own, the receiving side sends `bye` with reason
`version` and closes. Over WiFi the Mac goes on only with an iPad whose `id`
is the one its Bonjour service advertised. A candidate that sends no `hello`
within 6 s is dropped, and so is one that has not finished its handshake by
then, unless it is pairing or waiting on the user.

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
`inUse` (the iPad's user kept the Mac it mirrors, or another request was
already open; section 5.6), `notPaired` (pairing was declined, cancelled,
timed out or turned away, or the Mac was forgotten), `authFailed` (a
signature did not check against the pinned key). An unknown reason reads as
`quit`. A Mac told `notPaired` or `authFailed` does not redial that iPad
until the user connects it again. A Mac told `replaced` or `inUse` stops dialing that iPad until something
changes (it is replugged, re-advertised, or the user connects it), so two
Macs never take one iPad back and forth.

### 5.5 `status` (Mac to iPad)

The Mac's side of the Claude Code hop. Sent when the session starts and again
whenever it changes, never on a timer.

| field | type | |
|---|---|---|
| `channel` | `attached`, `detached`, `existing`, `none` | an unknown value reads as `none` |
| `project` | string, optional | the target session's folder; absent when there is no target |

### 5.6 Another Mac while one is mirrored, and `asking` (iPad to Mac)

While the iPad mirrors a Mac, a newcomer that has proven itself (section
5.7) is handled like this:

- one that just paired: adopted at once (the user chose it on this iPad);
- over USB: adopted at once (a cable is physical; plugging one in is intent);
- with the key of the Mac being mirrored: adopted at once (that Mac coming
  back on a new connection);
- otherwise (another paired Mac, over WiFi): held, and the iPad asks its
  user whether to switch, saying whether the current Mac is on the cable.

`asking` has no fields and tells the held Mac it is waiting on that
question. Until the answer, the iPad keeps the connection as a candidate and
answers its `ping`s, and the Mac waits up to 45 s. The answer is `ready`
(switch: the Mac it replaces is sent `bye` reason `replaced`) or `bye` reason
`inUse` (don't switch). With no answer from the user within 30 s the iPad
keeps the current Mac. One request is open at a time; another Mac asking
meanwhile is sent `bye` reason `inUse` at once, and so is any Mac asking
within 60 s of a request that ended without a switch (the user said no, it
timed out, or the asking Mac left). The iPad shows the asking Mac's `name`
quoted, with control and formatting characters removed, and says so when it
copies the current Mac's name.

### 5.7 Pairing, proof and sealing

The pattern is HomeKit's and AirPlay 2's. Each device has a long-term
Ed25519 identity, kept in its Keychain. Pairing pins the other device's
public key once: the Mac files iPads by install id, the iPad files Macs by
the first 16 bytes of the SHA-256 of their key. Every connection proves both
identities over a fresh X25519 exchange, so what one connection's keys would
reveal says nothing about another, and seals every frame.

**Transcripts.** Each signature and the code cover
`"designcanvas-v2 {label}"` followed by, each as `[u32 BE length][bytes]`,
the Mac's key, the Mac's `eph`, the iPad's key, the iPad's `eph`, and an
extra field (empty unless stated). Labels: `verify-ipad`, `verify-mac`,
`pair`, `pair-ipad` and `pair-mac` (both with the extra field the Mac's
nonce followed by the iPad's).

**Proof (paired).** The iPad's `hello.sig` signs the `verify-ipad`
transcript; the Mac's `verify {sig}` signs `verify-mac`. Each side checks
the other's against the key it pinned; a mismatch is `bye` reason
`authFailed`. A side that has no pin for the other's key, or a different
one, pairs instead.

**Pairing (numeric comparison).** Both screens show the same six digits and
the user confirms on both.

1. Mac: `pair {}`.
2. iPad: `pairCommit {c}`, `c` = SHA-256 of `"designcanvas-v2 commit"`, its
   32-byte random nonce and the `pair` transcript. It commits before it can
   see the Mac's nonce, so a device in the middle cannot pick values that
   make the two screens agree: it gets one guess in a million.
3. Mac: `pairNonce {n}`, its 32-byte random nonce.
4. iPad: `pairNonce {n}`, its nonce; the Mac checks it against `c`.
5. Both show the code: the first four bytes of the SHA-256 of
   `"designcanvas-v2 code"`, the `pair` transcript and both nonces, as a
   big-endian number modulo 1 000 000, six digits written `123 456`.
6. When its user taps Pair, each side sends `pairConfirm {sig}` (the iPad
   signing `pair-ipad`, the Mac `pair-mac`) and seals everything it sends
   after it. Each side seals what it reads once the other's `pairConfirm`
   has checked. With both done, each pins the other's key; the iPad then
   sends `ready`. Cancel on either side is `bye` reason `notPaired`.

Pairing waits up to 90 s for its users. A Mac starts it only over the cable
or after its user clicked Connect for that iPad: a WiFi reconnect whose proof
fails ends with `notPaired`, not with a question. After a pairing ends
without being confirmed, the iPad turns WiFi pairing requests away unasked
for 60 s. Forgetting a paired device on either side removes its pin; a
session with it ends with `bye` reason `notPaired`.

**Sealing.** The two directions' keys come from HKDF-SHA256 over the X25519
secret, salted with the SHA-256 of the `verify-ipad` transcript, with info
`designcanvas-v2 mac->ipad` and `designcanvas-v2 ipad->mac`. A sealed frame is
`[u32 BE length][3][ChaCha20-Poly1305 ciphertext][16-byte tag]`, the
plaintext being the inner frame's kind byte and body, the nonce four zero
bytes and a 64-bit big-endian counter per direction from 0. Once a direction
is sealed, a frame that is not kind 3, that does not open, or that arrives out
of order ends the connection. A direction switches right after the frame that
starts it: `verify` (both directions, in the proof), or each side's own
`pairConfirm`.

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
  the next session starts, and the Mac drops one whose `t` it has already accepted
  from that iPad.
- **`agentReply`**: one round's live status. `status` is one of `queued`,
  `sent`, `applied`, `failed`, `needs_input`; `message` is at most 2048 UTF-8
  bytes, cut on a character boundary.
- **`rounds`**: the newest 20 rounds for this iPad, newest first, sent after
  every session start and whenever the Mac's daemon stream reconnects. Each entry:
  `annotationId`, `createdAt` (ISO 8601), `status`, and optionally `message`
  (≤ 2048 bytes), `prUrl`, `note`. An entry that cannot be read is skipped. An
  iPad never moves a round it knows backwards: a snapshot can predate an
  `agentReply` it already showed.
- **`sessions`**: the Claude Code sessions the Mac is connected to, at most
  20, each `id`, `folder` (≤ 60 characters), `title`? (≤ 80), `branch`?
  (≤ 80), `startedAt`, `lastReplyAt`?, `state` (`idle`, `busy`, `waiting`; an
  unknown value reads as `busy`), and `target`, the `id` the next sketch goes
  to. Sent when every session starts and whenever the list or the target changes.
  With several sessions and no `target`, the iPad does not send an
  `annotation` until the user picks one.
- **`selectSession`**: make `id` the target. The Mac answers with a fresh
  `sessions`, which is the only confirmation.

## 7. No input

Nothing on this link moves the Mac's pointer or types on it. The iPad's
pinch and pan zoom its own picture and are never sent anywhere, and the Mac
app never asks for Accessibility.
