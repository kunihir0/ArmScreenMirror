# SMIR wire protocol

Every byte exchanged between the iPhone tweak and the Mac server flows over a single TCP connection on port **4878**. The Mac advertises itself with Bonjour service type `_smirror._tcp.` so the iOS control app can discover it without the user typing an IP.

The wire has three layers:

1. A **HELLO** exchange in plaintext that establishes a forward-secure session key.
2. **Length-prefixed AES-256-GCM frames** on top of the TCP stream.
3. The **plaintext message format** carried inside each frame.

All multi-byte integers on the wire are **big-endian** unless the field is explicitly described as raw bytes / IEEE-754 floats.

```
TCP stream
│
├─ 56-byte HELLO        (plaintext, exactly once per direction)
│
├─ Encrypted record     ┐
│   ├─ uint32 length    │
│   ├─ ciphertext       │
│   └─ 16-byte GCM tag  │  many records, both directions
├─ Encrypted record     │
├─ ...                  ┘
```

---

## 1. HELLO handshake

Both endpoints send a 56-byte HELLO immediately after the TCP connection comes up. The iPhone always sends first; the Mac replies with its own HELLO once it has parsed the iPhone's.

```
offset  size  field
------  ----  -----------------------------------------------------------
  0      4    magic = 0x53 0x4D 0x49 0x48   ('SMIH')
  4      1    version = 0x02
  5      1    flags  (bit 0 = legacy, bit 1 = forward secrecy + password)
  6      2    reserved (zero)
  8     16    nonce  (random; client_nonce on iOS→Mac, server_nonce on Mac→iOS)
 24     32    X25519 ephemeral public key
------------------------------------------------------------------------
total   56
```

- **`SMIH`** is intentionally distinct from the in-record `SMIR` magic so a confused parser can't mistake one for the other.
- The version byte gates protocol upgrades; today's only valid value is `2` (the version that introduced X25519 + 32-byte pubkey field).
- The nonce is fresh entropy from `SecRandomCopyBytes` / `arc4random_buf` per connection.
- The X25519 public key is the **raw 32-byte little-endian encoding** that both CryptoKit (`Curve25519.KeyAgreement.PublicKey.rawRepresentation`) and TweetNaCl (`crypto_scalarmult_base`) produce.

After both HELLOs have been exchanged, every subsequent byte on the connection is encrypted.

### Key derivation

Both sides compute the same 256-bit session key without sending another byte:

```
shared    = X25519(local_priv, remote_pub)         # 32 bytes raw scalarmult output
salt      = client_nonce ‖ server_nonce             # 32 bytes
pwdKDF    = PBKDF2-HMAC-SHA512(password, salt,
                               iterations = 600 000,
                               output_len = 32)
ikm       = shared ‖ pwdKDF                         # 64 bytes
sessionKey = HKDF-SHA256(ikm,
                         salt = salt,
                         info = "SMIR-session-key-v2",
                         length = 32)
```

Notes:

- The X25519 private keys are wiped right after `shared` is computed → forward secrecy.
- The password is required: an active attacker who only sees the HELLO can't compute `pwdKDF` and therefore not the session key. `pwdKDF` is mixed into `ikm` rather than used as the HKDF salt so that PBKDF2 is on the actual key material, not on the salt.
- `iterations = 600 000` is the OWASP 2023 recommendation for PBKDF2-SHA512.
- The **`info`** string is bumped (`v2`) whenever the derivation scheme changes, so a re-deployed peer with the old scheme will fail authentication instead of silently producing a different key.

### Failure modes

- `HELLO magic mismatch` → first 4 bytes weren't `'SMIH'`. Connection closed.
- `Protocol version mismatch` → byte 4 wasn't `0x02`. Connection closed.
- `Invalid X25519 pubkey` → the raw 32 bytes don't decode (CryptoKit's constructor throws). Connection closed.
- `decrypt failed` on the first record → both sides successfully derived a key but they aren't equal, almost always because the passwords differ. Connection closed.

---

## 2. Encrypted record format

After HELLO, the stream is a sequence of records:

```
+---------------------+----------------------+------------+
| uint32 length (BE)  |   AES-GCM ciphertext |  16-byte   |
|  = ciphertext+tag   |                      |  GCM tag   |
+---------------------+----------------------+------------+
```

- **`length`** counts ciphertext bytes **plus** the trailing 16-byte GCM tag.
- **Cipher**: AES-256-GCM. CryptoKit on macOS, `CCCryptorGCMOneshotEncrypt/Decrypt` on iOS where available, falling back to the legacy `CCCryptorGCMSetIV` / `CCCryptorGCMUpdate` / `CCCryptorGCMFinalize` set on older releases. The crypto module probes which symbols are present at load time.
- **IV (12 bytes)**: `0x00 0x00 0x00 0x00 ‖ counter_be64` where `counter_be64` is the **send-side counter** for outgoing records and the **receive-side counter** for incoming records. Each side keeps two `uint64` counters that start at 0 and are incremented after every successful encrypt/decrypt. The IV is not transmitted — TCP guarantees in-order delivery so both ends increment in lockstep.
- **No AAD** is used. The 4-byte length prefix is not authenticated; if it gets corrupted, the GCM tag check on the next record will fail and the connection drops.
- **No re-keying**: a session key is used until the connection closes. Counters are 64-bit so birthday-bound collisions only matter at ≥ 2³² records (~4 billion video frames — well beyond any realistic session).

A receiver that fails GCM authentication closes the connection immediately; resync after a single bad record is not attempted.

---

## 3. Plaintext message format

Each record's plaintext is a single SMIR message:

```
offset  size  field
------  ----  -----------------------------------------------------------
  0      4    magic = 0x53 0x4D 0x49 0x52   ('SMIR')
  4      1    type
  5      3    reserved (zero)
  8      4    payload length (uint32 BE)
 12     N    payload (N bytes)
------------------------------------------------------------------------
```

- The magic mismatches `'SMIH'` (HELLO) on purpose; if the parser ever sees `SMIH` after handshake it knows something is wrong.
- The 3 reserved bytes are not used today; receivers must ignore them.
- Payload length excludes the 12-byte header.

A single record carries exactly one message; messages are not split across records, and records do not contain partial messages.

---

## 4. Message types

| ID    | Name           | Direction  | Payload (bytes) |
|-------|----------------|------------|-----------------|
| 0x01  | `HANDSHAKE`     | iOS → Mac  | see [Handshake payload](#handshake-payload) |
| 0x02  | `VIDEO_CONFIG`  | iOS → Mac  | `u32 sps_len ‖ sps[] ‖ u32 pps_len ‖ pps[]` |
| 0x03  | `VIDEO_FRAME`   | iOS → Mac  | `u8 keyframe ‖ u8 reserved×3 ‖ u64 pts_us ‖ AnnexB[]` |
| 0x04  | `ORIENTATION`   | iOS → Mac  | `u8 orientation` (1=portrait, 2=landscape-left, 3=landscape-right, 4=portrait-upside-down) |
| 0x05  | `QUALITY`       | Mac → iOS  | `u8 preset` (0=low, 1=medium, 2=high) |
| 0x10  | `TOUCH_DOWN`    | Mac → iOS  | `u8 finger_id ‖ u8 reserved×3 ‖ f32 x_norm ‖ f32 y_norm` |
| 0x11  | `TOUCH_MOVE`    | Mac → iOS  | same |
| 0x12  | `TOUCH_UP`      | Mac → iOS  | same |
| 0x13  | `SWIPE`         | Mac → iOS  | `f32 x1 ‖ f32 y1 ‖ f32 x2 ‖ f32 y2 ‖ u32 duration_ms` |
| 0x20  | `KEY_EVENT`     | Mac → iOS  | `u16 hid_keycode ‖ u8 down ‖ u8 reserved` |
| 0x21  | `TEXT_INPUT`    | Mac → iOS  | `u32 utf8_len ‖ utf8[]` |
| 0x30  | `BUTTON_EVENT`  | Mac → iOS  | `u8 button_id ‖ u8 down ‖ u8 reserved×2` |
| 0x40  | `PING`          | bidi       | `u64 timestamp_us` |
| 0x41  | `PONG`          | bidi       | `u64 timestamp_us` (echo of ping) |

### Handshake payload

```
offset  size  field
------  ----  -----------------------------------------------------------
  0      4    width   (uint32 BE)
  4      4    height  (uint32 BE)
  8      4    scale   (IEEE-754 float32, big-endian byte order)
 12      1    ios_major
 13      1    ios_minor
 14      1    orientation (1..4, see ORIENTATION above)
 15      1    reserved
 16     64    device_name (UTF-8, null-padded, e.g. "iPhone10,4")
------------------------------------------------------------------------
total   80
```

- `width` / `height` carry the **logical (point) size** of the device's main screen, not pixel dimensions; `scale` is sent for compatibility but the iPhone currently always sets it to `1.0f`.
- `device_name` is the raw output of `uname(2)` on the iPhone (e.g. `iPhone10,4`, `iPad7,11`). The Mac's device-history layer keys off this string + iOS major/minor + width/height.

### Touch coordinates

`x_norm` and `y_norm` are normalised to `[0, 1]` over the device's logical screen rect. The iOS injector clamps them to that range before forwarding to `IOHIDDigitizerEventCreateAtAbsolutePosition`. The Mac computes the normalisation from the `NSEvent` location relative to the `DeviceView`'s bounds.

### Swipe

A `SWIPE` is a higher-level gesture: instead of streaming individual `TOUCH_DOWN/MOVE/UP` events from the Mac, the iPhone synthesises a 120 Hz path itself. The benefit is correct timing (low jitter on slow networks) and special handling of edge gestures.

If `from.y >= 0.96` and the gesture moves significantly upward (or `from.y <= 0.04` moving down), the iPhone classifies the swipe as an **edge gesture** and inserts:

- An 80 ms dwell at the start position before motion begins (so SpringBoard's edge gesture recognizer qualifies the touch).
- Linear easing between the two endpoints (instead of the easeOutQuad used for normal swipes).
- A 120 ms dwell at the end position before the touch is released.

This is what makes Notification Center reliably open from the Mac UI on Home-button iPhones.

### Buttons (`BUTTON_EVENT`)

| `button_id` | Meaning |
|-------------|---------|
| 1 | Home |
| 2 | Lock / Power |
| 3 | Volume Up |
| 4 | Volume Down |
| 5 | Mute |
| 6 | Siri |

For `id == 5` (Mute), the iPhone bypasses the HID consumer page (consumer Mute usage `0xE2` is not honoured by iOS for category mute) and instead toggles the Audio/Video category between volume 0 and the previously saved level via `AVSystemController setVolumeTo:forCategory:`. The volume HUD pops up automatically.

For other buttons the iPhone sends standard HID events on the consumer page (`0x0C`):

| Button | HID Usage |
|--------|-----------|
| Home   | `0x40` (Menu) |
| Lock   | `0x30` (Power) |
| Vol+   | `0xE9` |
| Vol-   | `0xEA` |
| Siri   | `0x221` (AC Search) |

### Quality preset

The `QUALITY` payload is a single byte: `0` (Low), `1` (Medium), `2` (High). Receiving this message restarts the iPhone capture + encoder pipeline with new parameters:

| Preset | Capture scale | FPS active / idle | H.264 bitrate cap | VT quality |
|--------|---------------|-------------------|-------------------|------------|
| Low    | 0.30 of native | 10 / 3            | 400 kbps          | 0.35       |
| Medium | 0.40           | 15 / 4            | 800 kbps          | 0.50       |
| High   | 0.65           | 24 / 8            | 2.5 Mbps          | 0.70       |

Idle FPS kicks in when 16 sample pixels at the centre of the frame haven't changed for ~5 frames (cheap motion gate).

### `TEXT_INPUT`

UTF-8, no null terminator, length-prefixed. The iPhone's `TouchInjector typeText:` walks each grapheme and emits HID keyboard events for ASCII; for non-ASCII it falls back to UIKit text injection where possible.

### `PING` / `PONG`

Either side may originate a `PING`; the receiver echoes the same 8-byte payload back as `PONG`. The Mac currently sends a ping every 2 s while connected to detect dead peers (TCP keepalive isn't always enough behind NATs).

---

## 5. Connection lifecycle

A typical session, top to bottom:

```
TCP open
  iOS  ──→  HELLO (SMIH ‖ ver=2 ‖ flags=2 ‖ client_nonce ‖ ephC.pub)
  Mac  ──→  HELLO (SMIH ‖ ver=2 ‖ flags=2 ‖ server_nonce ‖ ephS.pub)
  -- both sides derive sessionKey, key wipe of priv halves --
  iOS  ──→  HANDSHAKE
  iOS  ──→  VIDEO_CONFIG
  Mac  ──→  QUALITY (preset persisted on Mac side)
  iOS  ──→  VIDEO_FRAME × N (15–60 fps)
  Mac  ──→  TOUCH_*, SWIPE, KEY_EVENT, BUTTON_EVENT … as the user interacts
  Mac  ──→  PING                            every 2 s
  iOS  ──→  PONG                            in reply
  ...
TCP close
```

Either side closing the TCP connection terminates the session; the iPhone tweak's `_attemptConnect` retries every 5 s while the user-facing toggle in the control app is on.

---

## 6. Constants reference

| Constant            | Value         | Description |
|---------------------|---------------|-------------|
| `SMIR_HELLO_MAGIC`  | `0x534D4948`  | `'SMIH'` magic for the HELLO frame |
| `SMIR_MAGIC`        | `0x534D4952`  | `'SMIR'` magic for in-record messages |
| `SMIR_PROTO_VER`    | `0x02`        | Wire-format version |
| `SMIR_HELLO_LEN`    | `56`          | Bytes in a HELLO |
| `SMIR_NONCE_LEN`    | `16`          | HELLO nonce size |
| `SMIR_X25519_LEN`   | `32`          | Raw X25519 pubkey size |
| `SMIR_PBKDF2_ITERS` | `600 000`     | PBKDF2-SHA512 iteration count |
| HKDF info           | `"SMIR-session-key-v2"` | 19-byte ASCII string |
| GCM IV layout       | `0x00000000 ‖ counter_be64` | 12 bytes total |
| Listener port       | `4878`        | TCP |
| Bonjour type        | `_smirror._tcp.` | DNS-SD service name |

The constants live in `mac/Sources/ScreenMirrorServer/NetworkServer.swift` and `ios/src/NetworkClient.m` (kept in sync by hand). Bumping `SMIR_PROTO_VER` requires updating both — older peers will fail handshake with `Protocol version mismatch`.
