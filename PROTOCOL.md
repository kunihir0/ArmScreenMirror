# Protocolo SMIR

Protocolo binario sobre TCP. Big-endian. Cada mensaje:

```
+----+----+----+----+----+----+----+----+----+----+----+----+
| 'S'| 'M'| 'I'| 'R'|TYPE|RES |RES |RES |   PAYLOAD LENGTH  |
+----+----+----+----+----+----+----+----+----+----+----+----+
| ... payload (PAYLOAD LENGTH bytes) ...                    |
+-----------------------------------------------------------+
```

- 4 bytes magic = `0x53 0x4D 0x49 0x52`
- 1 byte type
- 3 bytes reservados (cero)
- 4 bytes longitud del payload (uint32 BE)
- payload variable

## Tipos

| ID   | Nombre         | Dirección  | Payload |
|------|----------------|------------|---------|
| 0x01 | HANDSHAKE      | iOS → Mac  | u32 width, u32 height, f32 scale, u8 ios_major, u8 ios_minor, u8 orientation, u8 reserved, char[64] device_name |
| 0x02 | VIDEO_CONFIG   | iOS → Mac  | u32 sps_len, sps[], u32 pps_len, pps[] |
| 0x03 | VIDEO_FRAME    | iOS → Mac  | u8 keyframe, u8 reserved×3, u64 pts_us, NAL[] (Annex-B) |
| 0x04 | ORIENTATION    | iOS → Mac  | u8 orientation (1=portrait, 2=landscape-left, 3=landscape-right, 4=portrait-upside-down) |
| 0x10 | TOUCH_DOWN     | Mac → iOS  | u8 finger_id, u8 reserved×3, f32 x_norm, f32 y_norm |
| 0x11 | TOUCH_MOVE     | Mac → iOS  | u8 finger_id, u8 reserved×3, f32 x_norm, f32 y_norm |
| 0x12 | TOUCH_UP       | Mac → iOS  | u8 finger_id, u8 reserved×3, f32 x_norm, f32 y_norm |
| 0x20 | KEY_EVENT      | Mac → iOS  | u16 hid_keycode, u8 down, u8 reserved |
| 0x21 | TEXT_INPUT     | Mac → iOS  | u32 utf8_len, char[] utf8 |
| 0x30 | BUTTON_EVENT   | Mac → iOS  | u8 button_id, u8 down, u8 reserved×2 |
| 0x40 | PING           | bidi       | u64 timestamp_us |
| 0x41 | PONG           | bidi       | u64 timestamp_us (eco) |

### button_id
- 1 = Home
- 2 = Lock / Power
- 3 = Volume Up
- 4 = Volume Down
- 5 = Mute
- 6 = Siri

### orientation
La app del Mac usa este valor para rotar la vista. El video siempre llega con la
orientación nativa del framebuffer (típicamente portrait).

### Coordenadas
`x_norm` y `y_norm` están normalizadas a `[0, 1]` respecto al tamaño lógico de pantalla
del iPhone (puntos, no píxeles). El Mac calcula la normalización a partir de la posición
del cursor en su NSView.

## Handshake

1. Mac escucha en TCP 4878 y se anuncia por Bonjour `_smirror._tcp.`.
2. iOS abre conexión y envía `HANDSHAKE`.
3. iOS envía `VIDEO_CONFIG` (SPS+PPS de VideoToolbox).
4. iOS empieza a enviar `VIDEO_FRAME` a 30/60 fps.
5. Mac envía eventos de input cuando el usuario interactúa con la ventana.
6. `PING/PONG` cada 2s para keepalive.
