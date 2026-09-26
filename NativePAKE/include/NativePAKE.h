#ifndef NEARBY_AUDIO_NATIVE_PAKE_H
#define NEARBY_AUDIO_NATIVE_PAKE_H

#include <stddef.h>
#include <stdint.h>

typedef struct na_spake na_spake;

// Each context is single-use. Role 0 is Mac (Alice); role 1 is iPad (Bob).
na_spake *na_spake_start(int role, const uint8_t *code, size_t code_len, uint8_t message[32]);
int na_spake_finish(na_spake *state, const uint8_t peer_message[32], uint8_t key[64]);
void na_spake_free(na_spake *state);

#endif
