#ifndef BWM_DIAGNOSTICS_H
#define BWM_DIAGNOSTICS_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int header_magic_ok;
    int version;
    int crc_ok;
    int is_text;
    int payload_len;
} bwm_diag_info;

/*
 * Test-only extraction path. It mirrors the shipping layout but exposes the
 * header and CRC outcomes separately, plus the raw payload bytes before the
 * CRC gate, so BER can be measured even when CRC fails.
 */
int bwm_diag_extract(const uint8_t *src_pixels, int width, int height, int channels,
                     const char *password, float d1, int expected_payload_len,
                     bwm_diag_info *out_info, uint8_t *out_payload,
                     int payload_capacity);

#ifdef __cplusplus
}
#endif

#endif
