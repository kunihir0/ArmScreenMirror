#ifndef SMIR_X25519_H
#define SMIR_X25519_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Genera una clave privada X25519 aleatoria (32 bytes) con SecRandomCopyBytes.
/// La clave queda con el "clamping" estándar de RFC 7748.
void smir_x25519_make_priv(uint8_t priv[32]);

/// Calcula la clave pública X25519 a partir de la privada (= scalar*G).
void smir_x25519_pub_from_priv(uint8_t pub_out[32], const uint8_t priv[32]);

/// Diffie-Hellman: out = X25519(priv, pub).
/// Devuelve 1 en éxito, 0 si la clave pública es inválida (orden bajo).
int  smir_x25519_scalarmult(uint8_t out[32], const uint8_t priv[32], const uint8_t pub[32]);

#ifdef __cplusplus
}
#endif

#endif
