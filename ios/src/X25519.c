// X25519 (Curve25519 Diffie-Hellman) — implementación de referencia compacta.
// Basada en TweetNaCl (D. J. Bernstein et al., dominio público).
//
// Operaciones de campo en GF(2^255 - 19), aritmética con limbs int64_t[16],
// escalar-multiplicación con la "Montgomery ladder". Tiempo constante.
//
// API exportada (smir_x25519_*) en X25519.h.

#include "X25519.h"
#include <Security/Security.h>
#include <string.h>

typedef int64_t gf[16];
static const gf _121665 = {0xDB41, 1};

static void car25519(gf o) {
    int64_t c;
    for (int i = 0; i < 16; i++) {
        o[i] += (1LL << 16);
        c = o[i] >> 16;
        o[(i + 1) * (i < 15)] += c - 1 + 37 * (c - 1) * (i == 15);
        o[i] -= c << 16;
    }
}

static void sel25519(gf p, gf q, int b) {
    int64_t t, c = ~(b - 1);
    for (int i = 0; i < 16; i++) {
        t = c & (p[i] ^ q[i]);
        p[i] ^= t;
        q[i] ^= t;
    }
}

static void pack25519(uint8_t *o, const gf n) {
    int b;
    gf m, t;
    for (int i = 0; i < 16; i++) t[i] = n[i];
    car25519(t); car25519(t); car25519(t);
    for (int j = 0; j < 2; j++) {
        m[0] = t[0] - 0xFFED;
        for (int i = 1; i < 15; i++) {
            m[i] = t[i] - 0xFFFF - ((m[i - 1] >> 16) & 1);
            m[i - 1] &= 0xFFFF;
        }
        m[15] = t[15] - 0x7FFF - ((m[14] >> 16) & 1);
        b = (m[15] >> 16) & 1;
        m[14] &= 0xFFFF;
        sel25519(t, m, 1 - b);
    }
    for (int i = 0; i < 16; i++) {
        o[2 * i]     = (uint8_t)(t[i] & 0xFF);
        o[2 * i + 1] = (uint8_t)((t[i] >> 8) & 0xFF);
    }
}

static void unpack25519(gf o, const uint8_t *n) {
    for (int i = 0; i < 16; i++) {
        o[i] = (int64_t)n[2 * i] + ((int64_t)n[2 * i + 1] << 8);
    }
    o[15] &= 0x7FFF;
}

static void A(gf o, const gf a, const gf b) {
    for (int i = 0; i < 16; i++) o[i] = a[i] + b[i];
}

static void Z(gf o, const gf a, const gf b) {
    for (int i = 0; i < 16; i++) o[i] = a[i] - b[i];
}

static void M(gf o, const gf a, const gf b) {
    int64_t t[31];
    for (int i = 0; i < 31; i++) t[i] = 0;
    for (int i = 0; i < 16; i++)
        for (int j = 0; j < 16; j++) t[i + j] += a[i] * b[j];
    for (int i = 0; i < 15; i++) t[i] += 38 * t[i + 16];
    for (int i = 0; i < 16; i++) o[i] = t[i];
    car25519(o); car25519(o);
}

static void S(gf o, const gf a) { M(o, a, a); }

static void inv25519(gf o, const gf i) {
    gf c;
    for (int a = 0; a < 16; a++) c[a] = i[a];
    for (int a = 253; a >= 0; a--) {
        S(c, c);
        if (a != 2 && a != 4) M(c, c, i);
    }
    for (int a = 0; a < 16; a++) o[a] = c[a];
}

int smir_x25519_scalarmult(uint8_t out[32], const uint8_t priv[32], const uint8_t pub[32]) {
    uint8_t z[32];
    int64_t r;
    gf x, a, b, c, d, e, f;
    for (int i = 0; i < 31; i++) z[i] = priv[i];
    z[31] = (priv[31] & 127) | 64;
    z[0] &= 248;
    unpack25519(x, pub);
    for (int i = 0; i < 16; i++) {
        b[i] = x[i];
        d[i] = a[i] = c[i] = 0;
    }
    a[0] = d[0] = 1;
    for (int i = 254; i >= 0; i--) {
        r = (z[i >> 3] >> (i & 7)) & 1;
        sel25519(a, b, (int)r);
        sel25519(c, d, (int)r);
        A(e, a, c);
        Z(a, a, c);
        A(c, b, d);
        Z(b, b, d);
        S(d, e);
        S(f, a);
        M(a, c, a);
        M(c, b, e);
        A(e, a, c);
        Z(a, a, c);
        S(b, a);
        Z(c, d, f);
        M(a, c, _121665);
        A(a, a, d);
        M(c, c, a);
        M(a, d, f);
        M(d, b, x);
        S(b, e);
        sel25519(a, b, (int)r);
        sel25519(c, d, (int)r);
    }
    inv25519(c, c);
    M(a, a, c);
    pack25519(out, a);

    // Detectar punto de orden bajo: el resultado es todo ceros.
    uint8_t acc = 0;
    for (int i = 0; i < 32; i++) acc |= out[i];
    return acc != 0;
}

void smir_x25519_make_priv(uint8_t priv[32]) {
    (void)SecRandomCopyBytes(kSecRandomDefault, 32, priv);
    // Clamping de RFC 7748:
    priv[0]  &= 248;
    priv[31] &= 127;
    priv[31] |= 64;
}

void smir_x25519_pub_from_priv(uint8_t pub_out[32], const uint8_t priv[32]) {
    static const uint8_t base[32] = { 9, 0 };  // generador estándar de Curve25519
    smir_x25519_scalarmult(pub_out, priv, base);
}
