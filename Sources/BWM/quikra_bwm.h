#ifndef QUIKRA_BWM_H
#define QUIKRA_BWM_H

#include "bwm_algorithm.h"

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BWM_OK 0
#define BWM_ERROR_INVALID_HANDLE -1
#define BWM_ERROR_FILE_NOT_FOUND -2
#define BWM_ERROR_INVALID_IMAGE -3
#define BWM_ERROR_EMBED_FAILED -4
#define BWM_ERROR_EXTRACT_FAILED -5
#define BWM_ERROR_INVALID_PARAMS -6
#define BWM_ERROR_IMAGE_TOO_SMALL -7
#define BWM_ERROR_PASSWORD_REQUIRED -8
#define BWM_ERROR_NOT_IMPLEMENTED -9
#define BWM_ERROR_OUT_OF_MEMORY -10
#define BWM_ERROR_UNKNOWN -99

const char *bwm_get_error_message(int code);

/*
 * On success, *out_pixels is allocated with malloc() and *out_size is its byte
 * length. The caller must release it with free(). On failure, *out_pixels is
 * NULL and *out_size is 0. is_text is stored in the header flags bit 0; all
 * other header flag bits are written as zero.
 */
int quikra_bwm_embed(const uint8_t *src_pixels, int width, int height, int channels,
                     const uint8_t *payload, int payload_len, int is_text,
                     bwm_algorithm_t algorithm, const char *password,
                     uint8_t **out_pixels, int *out_size);

/*
 * On success, *out_payload is allocated with malloc() and *out_payload_len is
 * its byte length. The caller must release it with free().
 *
 * BWM_OK with *out_payload == NULL means "no detectable watermark". This
 * includes both an image with no watermark and a wrong password; blind
 * watermarking cannot distinguish them. It is not an error, and Swift callers
 * must not treat NULL as a failure or throw an exception. In this case
 * *out_is_text is also set to 0. A CRC mismatch also returns BWM_OK + NULL
 * with *out_is_text == 0.
 *
 * On success, *out_is_text receives header flags bit 0. Other flag bits are
 * ignored. If no watermark is detected, *out_is_text is 0.
 *
 * On other failures, both outputs are reset to NULL/0 as well, but the return
 * code is non-zero.
 */
int quikra_bwm_extract(const uint8_t *src_pixels, int width, int height, int channels,
                       const char *password, uint8_t **out_payload, int *out_payload_len,
                       int *out_is_text);

#ifdef __cplusplus
}
#endif

#endif
