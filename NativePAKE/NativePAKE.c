#include "NativePAKE.h"
#include <openssl/curve25519.h>
#include <stdlib.h>

struct na_spake { SPAKE2_CTX *ctx; };

na_spake *na_spake_start(int role, const uint8_t *code, size_t code_len, uint8_t message[32]) {
    if ((role != 0 && role != 1) || !code || code_len != 6 || !message) return NULL;
    na_spake *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    static const uint8_t mac[] = "NearbyAudio Mac v2";
    static const uint8_t pad[] = "NearbyAudio iPad v2";
    state->ctx = SPAKE2_CTX_new(role == 0 ? spake2_role_alice : spake2_role_bob,
        role == 0 ? mac : pad, role == 0 ? sizeof(mac) - 1 : sizeof(pad) - 1,
        role == 0 ? pad : mac, role == 0 ? sizeof(pad) - 1 : sizeof(mac) - 1);
    size_t length = 0;
    if (!state->ctx || !SPAKE2_generate_msg(state->ctx, message, &length, 32, code, code_len) || length != 32) {
        na_spake_free(state);
        return NULL;
    }
    return state;
}

int na_spake_finish(na_spake *state, const uint8_t peer_message[32], uint8_t key[64]) {
    if (!state || !state->ctx || !peer_message || !key) return 0;
    size_t length = 0;
    int success = SPAKE2_process_msg(state->ctx, key, &length, 64, peer_message, 32);
    return success && length == 64;
}

void na_spake_free(na_spake *state) {
    if (!state) return;
    SPAKE2_CTX_free(state->ctx);
    free(state);
}
