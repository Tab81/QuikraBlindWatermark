#include "bwm_diagnostics.h"

#include "dct.h"
#include "dwt.h"
#include "svd.h"
#include "watermark.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define BWM_DIAG_SEED_DOMAIN_BLOCK UINT64_C(0x424C4F434B000001)
#define BWM_DIAG_SEED_DOMAIN_HEADER UINT64_C(0x4845414445520001)
#define BWM_DIAG_SEED_DOMAIN_PAYLOAD UINT64_C(0x5041594C4F414401)

static uint64_t derive_seed(const char *password, uint64_t domain) {
    bwm_splitmix64 rng;
    bwm_splitmix64_init(&rng, bwm_password_seed(password) ^ domain);
    return bwm_splitmix64_next(&rng);
}

static void pad_plane_zero(const float *src, int width, int height, float *dst,
                           int padded_width, int padded_height) {
    memset(dst, 0, (size_t)padded_width * (size_t)padded_height * sizeof(float));
    for (int row = 0; row < height; ++row) {
        memcpy(dst + (size_t)row * (size_t)padded_width,
               src + (size_t)row * (size_t)width, (size_t)width * sizeof(float));
    }
}

static void permute_inverse(const uint8_t *src, uint8_t *dst, const uint32_t *perm,
                            size_t count) {
    for (size_t i = 0; i < count; ++i) {
        dst[perm[i]] = src[i];
    }
}

static void repeated_bits_to_bytes(const uint8_t *bits, size_t byte_count, uint8_t *out) {
    size_t index = 0;
    for (size_t i = 0; i < byte_count; ++i) {
        uint8_t value = 0;
        for (int bit = 7; bit >= 0; --bit) {
            const unsigned int votes = (unsigned int)bits[index] +
                                       (unsigned int)bits[index + 1] +
                                       (unsigned int)bits[index + 2];
            index += 3;
            value = (uint8_t)((value << 1) | (votes >= 2u ? 1u : 0u));
        }
        out[i] = value;
    }
}

static uint8_t read_bit(const float *ll, int ll_width, int blocks_width,
                        uint32_t block_index, float d1) {
    const int block_row = (int)(block_index / (uint32_t)blocks_width);
    const int block_col = (int)(block_index % (uint32_t)blocks_width);
    const int base_row = block_row * BWM_BLOCK_SIZE;
    const int base_col = block_col * BWM_BLOCK_SIZE;

    float block[4][4];
    float frequency[4][4];
    float u[4][4];
    float s[4];
    float vt[4][4];

    for (int row = 0; row < 4; ++row) {
        for (int col = 0; col < 4; ++col) {
            block[row][col] =
                ll[(size_t)(base_row + row) * (size_t)ll_width + (size_t)(base_col + col)];
        }
    }

    bwm_dct4x4(block, frequency);
    bwm_svd4x4(frequency, u, s, vt);
    return (uint8_t)bwm_quantize_read(s[0], d1).bit;
}

static int read_payload_bits(const float *ll, int ll_width, int blocks_width,
                             const uint32_t *block_order, const char *password,
                             float d1, int payload_len, uint8_t *out_payload,
                             int payload_capacity) {
    if (payload_len <= 0 || payload_capacity < payload_len || out_payload == NULL) {
        return BWM_ERROR_INVALID_PARAMS;
    }

    const size_t payload_bit_count = (size_t)payload_len * 8u;
    const size_t payload_sequence_count = payload_bit_count * BWM_REDUNDANCY;
    uint8_t *payload_scrambled = (uint8_t *)malloc(payload_sequence_count);
    uint8_t *payload_bits = (uint8_t *)malloc(payload_sequence_count);
    uint32_t *payload_perm = (uint32_t *)malloc(payload_sequence_count * sizeof(uint32_t));
    uint8_t *payload_bytes = (uint8_t *)malloc((size_t)payload_len);
    int result = BWM_ERROR_OUT_OF_MEMORY;
    if (payload_scrambled == NULL || payload_bits == NULL || payload_perm == NULL ||
        payload_bytes == NULL) {
        goto cleanup;
    }

    for (size_t i = 0; i < payload_sequence_count; ++i) {
        payload_scrambled[i] =
            read_bit(ll, ll_width, blocks_width, block_order[BWM_HEADER_BLOCKS + i], d1);
    }
    bwm_shuffle_blocks(payload_perm, payload_sequence_count,
                       derive_seed(password, BWM_DIAG_SEED_DOMAIN_PAYLOAD));
    permute_inverse(payload_scrambled, payload_bits, payload_perm, payload_sequence_count);
    repeated_bits_to_bytes(payload_bits, (size_t)payload_len, payload_bytes);
    memcpy(out_payload, payload_bytes, (size_t)payload_len);
    result = BWM_OK;

cleanup:
    free(payload_scrambled);
    free(payload_bits);
    free(payload_perm);
    free(payload_bytes);
    return result;
}

int bwm_diag_extract(const uint8_t *src_pixels, int width, int height, int channels,
                     const char *password, float d1, int expected_payload_len,
                     bwm_diag_info *out_info, uint8_t *out_payload,
                     int payload_capacity) {
    if (out_info == NULL) {
        return BWM_ERROR_INVALID_PARAMS;
    }
    memset(out_info, 0, sizeof(*out_info));

    if (payload_capacity < 0 || (payload_capacity > 0 && out_payload == NULL)) {
        return BWM_ERROR_INVALID_PARAMS;
    }
    if (src_pixels == NULL || width <= 0 || height <= 0 ||
        (channels != 3 && channels != 4)) {
        return BWM_ERROR_INVALID_PARAMS;
    }
    if (!(d1 > 0.0f)) {
        return BWM_ERROR_INVALID_PARAMS;
    }
    const int password_result = bwm_validate_password(password);
    if (password_result != BWM_OK) {
        return password_result;
    }

    size_t block_count = 0;
    size_t required_blocks = 0;
    int result = bwm_check_capacity(width, height, 0, &block_count, &required_blocks);
    if (result != BWM_OK) {
        return result;
    }

    float *y_plane = NULL;
    float *u_plane = NULL;
    float *v_plane = NULL;
    float *padded_y = NULL;
    float *ll = NULL;
    float *h = NULL;
    uint32_t *block_order = NULL;
    uint8_t *payload_bits = NULL;
    uint8_t *payload_scrambled = NULL;
    uint32_t *payload_perm = NULL;
    uint8_t *payload_bytes = NULL;

    const size_t pixel_count = (size_t)width * (size_t)height;
    const int padded_width = width + (width & 1);
    const int padded_height = height + (height & 1);
    const size_t ll_width = (size_t)padded_width / 2u;
    const size_t ll_height = (size_t)padded_height / 2u;
    const size_t ll_pixel_count = ll_width * ll_height;

    result = BWM_ERROR_OUT_OF_MEMORY;
    y_plane = (float *)malloc(pixel_count * sizeof(float));
    u_plane = (float *)malloc(pixel_count * sizeof(float));
    v_plane = (float *)malloc(pixel_count * sizeof(float));
    padded_y = (float *)calloc((size_t)padded_width * (size_t)padded_height, sizeof(float));
    ll = (float *)malloc(ll_pixel_count * sizeof(float));
    h = (float *)malloc(3u * ll_pixel_count * sizeof(float));
    block_order = (uint32_t *)malloc(block_count * sizeof(uint32_t));
    if (y_plane == NULL || u_plane == NULL || v_plane == NULL || padded_y == NULL ||
        ll == NULL || h == NULL || block_order == NULL) {
        goto cleanup;
    }

    result = bwm_pixels_to_yuv(src_pixels, width, height, channels, y_plane, u_plane, v_plane);
    if (result != BWM_OK) {
        goto cleanup;
    }
    pad_plane_zero(y_plane, width, height, padded_y, padded_width, padded_height);

    int ll_w = 0;
    int ll_h = 0;
    if (bwm_haar_dwt2(padded_y, padded_width, padded_height, ll, h, &ll_w, &ll_h) !=
        BWM_DWT_OK) {
        result = BWM_ERROR_EXTRACT_FAILED;
        goto cleanup;
    }

    const int blocks_width = ll_w / BWM_BLOCK_SIZE;
    const int blocks_height = ll_h / BWM_BLOCK_SIZE;
    if (blocks_width <= 0 || blocks_height <= 0 ||
        (size_t)blocks_width * (size_t)blocks_height != block_count) {
        result = BWM_ERROR_EXTRACT_FAILED;
        goto cleanup;
    }
    bwm_shuffle_blocks(block_order, block_count,
                       derive_seed(password, BWM_DIAG_SEED_DOMAIN_BLOCK));

    uint8_t header_scrambled[BWM_HEADER_BLOCKS];
    uint8_t header_bits[BWM_HEADER_BLOCKS];
    uint8_t header[BWM_HEADER_BYTES];
    uint32_t header_perm[BWM_HEADER_BLOCKS];
    for (size_t i = 0; i < BWM_HEADER_BLOCKS; ++i) {
        header_scrambled[i] =
            read_bit(ll, ll_w, blocks_width, block_order[i], d1);
    }
    bwm_shuffle_blocks(header_perm, BWM_HEADER_BLOCKS,
                       derive_seed(password, BWM_DIAG_SEED_DOMAIN_HEADER));
    permute_inverse(header_scrambled, header_bits, header_perm, BWM_HEADER_BLOCKS);
    repeated_bits_to_bytes(header_bits, BWM_HEADER_BYTES, header);

    const uint16_t magic = (uint16_t)(((uint16_t)header[0] << 8) | (uint16_t)header[1]);
    out_info->version = header[2];
    if (magic != BWM_HEADER_MAGIC || header[2] != BWM_V1_HEADER_VERSION) {
        if (expected_payload_len > 0 &&
            bwm_check_capacity(width, height, expected_payload_len, &block_count,
                               &required_blocks) == BWM_OK &&
            read_payload_bits(ll, ll_w, blocks_width, block_order, password, d1,
                              expected_payload_len, out_payload,
                              payload_capacity) == BWM_OK) {
            out_info->payload_len = expected_payload_len;
        }
        result = BWM_OK;
        goto cleanup;
    }

    out_info->header_magic_ok = 1;
    out_info->is_text = (header[3] & BWM_HEADER_FLAG_TEXT) != 0;
    const uint16_t payload_len = (uint16_t)(((uint16_t)header[4] << 8) |
                                            (uint16_t)header[5]);
    const uint16_t header_crc = (uint16_t)(((uint16_t)header[6] << 8) |
                                           (uint16_t)header[7]);
    out_info->payload_len = (int)payload_len;
    if (payload_len == 0) {
        result = BWM_OK;
        goto cleanup;
    }

    result = bwm_check_capacity(width, height, (int)payload_len, &block_count,
                                &required_blocks);
    if (result != BWM_OK) {
        result = BWM_OK;
        goto cleanup;
    }

    const size_t payload_bit_count = (size_t)payload_len * 8u;
    const size_t payload_sequence_count = payload_bit_count * BWM_REDUNDANCY;
    payload_scrambled = (uint8_t *)malloc(payload_sequence_count);
    payload_bits = (uint8_t *)malloc(payload_sequence_count);
    payload_perm = (uint32_t *)malloc(payload_sequence_count * sizeof(uint32_t));
    payload_bytes = (uint8_t *)malloc((size_t)payload_len);
    if (payload_scrambled == NULL || payload_bits == NULL || payload_perm == NULL ||
        payload_bytes == NULL) {
        result = BWM_ERROR_OUT_OF_MEMORY;
        goto cleanup;
    }

    for (size_t i = 0; i < payload_sequence_count; ++i) {
        payload_scrambled[i] =
            read_bit(ll, ll_w, blocks_width, block_order[BWM_HEADER_BLOCKS + i], d1);
    }
    bwm_shuffle_blocks(payload_perm, payload_sequence_count,
                       derive_seed(password, BWM_DIAG_SEED_DOMAIN_PAYLOAD));
    permute_inverse(payload_scrambled, payload_bits, payload_perm, payload_sequence_count);
    repeated_bits_to_bytes(payload_bits, (size_t)payload_len, payload_bytes);

    out_info->crc_ok =
        bwm_crc16_ccitt(payload_bytes, (size_t)payload_len) == header_crc;
    if (payload_capacity >= (int)payload_len) {
        memcpy(out_payload, payload_bytes, (size_t)payload_len);
    }

    result = BWM_OK;

cleanup:
    free(y_plane);
    free(u_plane);
    free(v_plane);
    free(padded_y);
    free(ll);
    free(h);
    free(block_order);
    free(payload_bits);
    free(payload_scrambled);
    free(payload_perm);
    free(payload_bytes);
    return result;
}
