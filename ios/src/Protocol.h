#ifndef SMIR_PROTOCOL_H
#define SMIR_PROTOCOL_H

#include <stdint.h>

#define SMIR_MAGIC 0x534D4952u  // 'SMIR'

typedef enum : uint8_t {
    SMIR_HANDSHAKE    = 0x01,
    SMIR_VIDEO_CONFIG = 0x02,
    SMIR_VIDEO_FRAME  = 0x03,
    SMIR_ORIENTATION  = 0x04,
    SMIR_QUALITY      = 0x05,   // Mac → iOS: 1 byte preset (0=low,1=medium,2=high)
    SMIR_TOUCH_DOWN   = 0x10,
    SMIR_TOUCH_MOVE   = 0x11,
    SMIR_TOUCH_UP     = 0x12,
    SMIR_SWIPE        = 0x13,   // gesto sintetizado por el iPhone con timing real
    SMIR_KEY_EVENT    = 0x20,
    SMIR_TEXT_INPUT   = 0x21,
    SMIR_BUTTON_EVENT = 0x30,
    SMIR_PING         = 0x40,
    SMIR_PONG         = 0x41,
} SMIRType;

#pragma pack(push, 1)
typedef struct {
    uint32_t magic;
    uint8_t  type;
    uint8_t  reserved[3];
    uint32_t length;
} SMIRHeader;

typedef struct {
    uint32_t width;
    uint32_t height;
    float    scale;
    uint8_t  ios_major;
    uint8_t  ios_minor;
    uint8_t  orientation;
    uint8_t  reserved;
    char     device_name[64];
} SMIRHandshake;

typedef struct {
    uint8_t  finger_id;
    uint8_t  reserved[3];
    float    x_norm;
    float    y_norm;
} SMIRTouch;

typedef struct {
    float    x1;
    float    y1;
    float    x2;
    float    y2;
    uint32_t duration_ms;
} SMIRSwipe;

typedef struct {
    uint16_t hid_keycode;
    uint8_t  down;
    uint8_t  reserved;
} SMIRKey;

typedef struct {
    uint8_t button_id;
    uint8_t down;
    uint8_t reserved[2];
} SMIRButton;
#pragma pack(pop)

#define SMIR_BTN_HOME       1
#define SMIR_BTN_LOCK       2
#define SMIR_BTN_VOL_UP     3
#define SMIR_BTN_VOL_DOWN   4
#define SMIR_BTN_MUTE       5
#define SMIR_BTN_SIRI       6

#endif
