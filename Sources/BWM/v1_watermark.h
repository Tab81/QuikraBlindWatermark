#ifndef BWM_V1_WATERMARK_H
#define BWM_V1_WATERMARK_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

int v1_watermark_embed(const uint8_t *src_pixels, int width, int height, int channels,
                       const uint8_t *payload, int payload_len, int is_text,
                       const char *password, uint8_t **out_pixels, int *out_size);

int v1_watermark_peek_version(const uint8_t *src_pixels, int width, int height,
                              int channels, const char *password, int *out_version);

int v1_watermark_extract(const uint8_t *src_pixels, int width, int height, int channels,
                         const char *password, uint8_t **out_payload,
                         int *out_payload_len, int *out_is_text);

#ifdef __cplusplus
}
#endif

#endif
