#include "v1_watermark.h"

#include "dct.h"
#include "dwt.h"
#include "svd.h"
#include "watermark.h"

#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define BWM_SEED_DOMAIN_BLOCK UINT64_C(0x424C4F434B000001)
#define BWM_SEED_DOMAIN_HEADER UINT64_C(0x4845414445520001)
#define BWM_SEED_DOMAIN_PAYLOAD UINT64_C(0x5041594C4F414401)
/*
 * v1 keeps d1 fixed to preserve the 0x02 format. This release does not expose
 * bwm_set_d1/bwm_get_d1; test-only d1 tuning belongs to diagnostics (for
 * example Tests/D1SweepSupport) and must not enter the public quikra_bwm.h API.
 */
#define BWM_V1_D1 36.0f

static uint64_t derive_seed(const char *password, uint64_t domain) {
    bwm_splitmix64 rng;
    bwm_splitmix64_init(&rng, bwm_password_seed(password) ^ domain);
    return bwm_splitmix64_next(&rng);
}

static int image_buffer_size(int width, int height, int channels, size_t *out_size) {
    if (width <= 0 || height <= 0 || (channels != 3 && channels != 4) || out_size == NULL) {
        return BWM_ERROR_INVALID_PARAMS;
    }

    const size_t pixels = (size_t)width * (size_t)height;
    if (pixels > SIZE_MAX / (size_t)channels) {
        return BWM_ERROR_INVALID_PARAMS;
    }

    const size_t bytes = pixels * (size_t)channels;
    if (bytes > (size_t)INT_MAX) {
        return BWM_ERROR_INVALID_PARAMS;
    }

    *out_size = bytes;
    return BWM_OK;
}

static void build_header(uint8_t header[BWM_HEADER_BYTES], const uint8_t *payload,
                         size_t payload_len, int is_text) {
    const uint16_t crc = bwm_crc16_ccitt(payload, payload_len);
    header[0] = (uint8_t)(BWM_HEADER_MAGIC >> 8);
    header[1] = (uint8_t)(BWM_HEADER_MAGIC & 0xFFu);
    header[2] = (uint8_t)BWM_V1_HEADER_VERSION;
    header[3] = is_text ? (uint8_t)BWM_HEADER_FLAG_TEXT : 0u;
    header[4] = (uint8_t)(payload_len >> 8);
    header[5] = (uint8_t)(payload_len & 0xFFu);
    header[6] = (uint8_t)(crc >> 8);
    header[7] = (uint8_t)(crc & 0xFFu);
}

static void bytes_to_repeated_bits(const uint8_t *bytes, size_t byte_count, uint8_t *out) {
    size_t index = 0;
    for (size_t i = 0; i < byte_count; ++i) {
        for (int bit = 7; bit >= 0; --bit) {
            const uint8_t value = (uint8_t)((bytes[i] >> bit) & 1u);
            out[index++] = value;
            out[index++] = value;
            out[index++] = value;
        }
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

static void permute_forward(const uint8_t *src, uint8_t *dst, const uint32_t *perm,
                            size_t count) {
    for (size_t i = 0; i < count; ++i) {
        dst[i] = src[perm[i]];
    }
}

static void permute_inverse(const uint8_t *src, uint8_t *dst, const uint32_t *perm,
                            size_t count) {
    for (size_t i = 0; i < count; ++i) {
        dst[perm[i]] = src[i];
    }
}

static void pad_plane_zero(const float *src, int width, int height, float *dst,
                           int padded_width, int padded_height) {
    memset(dst, 0, (size_t)padded_width * (size_t)padded_height * sizeof(float));
    for (int row = 0; row < height; ++row) {
        memcpy(dst + (size_t)row * (size_t)padded_width,
               src + (size_t)row * (size_t)width, (size_t)width * sizeof(float));
    }
}

static void crop_plane(const float *src, int src_width, int width, int height, float *dst) {
    for (int row = 0; row < height; ++row) {
        memcpy(dst + (size_t)row * (size_t)width,
               src + (size_t)row * (size_t)src_width, (size_t)width * sizeof(float));
    }
}

static void embed_bit(float *ll, int ll_width, int blocks_width, uint32_t block_index,
                      uint8_t bit) {
    const int block_row = (int)(block_index / (uint32_t)blocks_width);
    const int block_col = (int)(block_index % (uint32_t)blocks_width);
    const int base_row = block_row * BWM_BLOCK_SIZE;
    const int base_col = block_col * BWM_BLOCK_SIZE;

    float block[4][4];
    float frequency[4][4];
    float u[4][4];
    float s[4];
    float vt[4][4];
    float restored[4][4];

    for (int row = 0; row < 4; ++row) {
        for (int col = 0; col < 4; ++col) {
            block[row][col] =
                ll[(size_t)(base_row + row) * (size_t)ll_width + (size_t)(base_col + col)];
        }
    }

    bwm_dct4x4(block, frequency);
    bwm_svd4x4(frequency, u, s, vt);
    s[0] = bwm_quantize_write(s[0], BWM_V1_D1, bit);
    bwm_svd4x4_reconstruct(u, s, vt, frequency);
    bwm_idct4x4(frequency, restored);

    for (int row = 0; row < 4; ++row) {
        for (int col = 0; col < 4; ++col) {
            ll[(size_t)(base_row + row) * (size_t)ll_width + (size_t)(base_col + col)] =
                restored[row][col];
        }
    }
}

static uint8_t read_bit(const float *ll, int ll_width, int blocks_width,
                        uint32_t block_index) {
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
    return (uint8_t)bwm_quantize_read(s[0], BWM_V1_D1).bit;
}

int v1_watermark_embed(const uint8_t *src_pixels, int width, int height, int channels,
                       const uint8_t *payload, int payload_len, int is_text,
                       const char *password, uint8_t **out_pixels, int *out_size) {
    if (out_pixels == NULL || out_size == NULL) {
        return BWM_ERROR_INVALID_PARAMS;
    }
    *out_pixels = NULL;
    *out_size = 0;

    if (src_pixels == NULL || payload == NULL || payload_len <= 0 ||
        payload_len > 0xFFFF) {
        return BWM_ERROR_INVALID_PARAMS;
    }
    const int password_result = bwm_validate_password(password);
    if (password_result != BWM_OK) {
        return password_result;
    }

    size_t output_bytes = 0;
    int result = image_buffer_size(width, height, channels, &output_bytes);
    if (result != BWM_OK) {
        return result;
    }

    size_t block_count = 0;
    size_t required_blocks = 0;
    result = bwm_check_capacity(width, height, payload_len, &block_count, &required_blocks);
    if (result != BWM_OK) {
        return result;
    }

    uint8_t *output = NULL;
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

    const size_t pixel_count = (size_t)width * (size_t)height;
    const int padded_width = width + (width & 1);
    const int padded_height = height + (height & 1);
    const size_t ll_width = (size_t)padded_width / 2u;
    const size_t ll_height = (size_t)padded_height / 2u;
    const size_t ll_pixel_count = ll_width * ll_height;
    const size_t payload_bit_count = (size_t)payload_len * 8u;
    const size_t payload_sequence_count = payload_bit_count * BWM_REDUNDANCY;

    result = BWM_ERROR_OUT_OF_MEMORY;
    output = (uint8_t *)malloc(output_bytes);
    y_plane = (float *)malloc(pixel_count * sizeof(float));
    u_plane = (float *)malloc(pixel_count * sizeof(float));
    v_plane = (float *)malloc(pixel_count * sizeof(float));
    padded_y = (float *)calloc((size_t)padded_width * (size_t)padded_height, sizeof(float));
    ll = (float *)malloc(ll_pixel_count * sizeof(float));
    h = (float *)malloc(3u * ll_pixel_count * sizeof(float));
    block_order = (uint32_t *)malloc(block_count * sizeof(uint32_t));
    payload_bits = (uint8_t *)malloc(payload_sequence_count);
    payload_scrambled = (uint8_t *)malloc(payload_sequence_count);
    payload_perm = (uint32_t *)malloc(payload_sequence_count * sizeof(uint32_t));

    if (output == NULL || y_plane == NULL || u_plane == NULL || v_plane == NULL ||
        padded_y == NULL || ll == NULL || h == NULL || block_order == NULL ||
        payload_bits == NULL || payload_scrambled == NULL || payload_perm == NULL) {
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
        result = BWM_ERROR_EMBED_FAILED;
        goto cleanup;
    }

    const int blocks_width = ll_w / BWM_BLOCK_SIZE;
    const int blocks_height = ll_h / BWM_BLOCK_SIZE;
    if (blocks_width <= 0 || blocks_height <= 0 ||
        (size_t)blocks_width * (size_t)blocks_height != block_count) {
        result = BWM_ERROR_EMBED_FAILED;
        goto cleanup;
    }
    bwm_shuffle_blocks(block_order, block_count, derive_seed(password, BWM_SEED_DOMAIN_BLOCK));

    uint8_t header[BWM_HEADER_BYTES];
    uint8_t header_bits[BWM_HEADER_BLOCKS];
    uint8_t header_scrambled[BWM_HEADER_BLOCKS];
    uint32_t header_perm[BWM_HEADER_BLOCKS];
    build_header(header, payload, (size_t)payload_len, is_text);
    bytes_to_repeated_bits(header, BWM_HEADER_BYTES, header_bits);
    bwm_shuffle_blocks(header_perm, BWM_HEADER_BLOCKS,
                       derive_seed(password, BWM_SEED_DOMAIN_HEADER));
    permute_forward(header_bits, header_scrambled, header_perm, BWM_HEADER_BLOCKS);
    for (size_t i = 0; i < BWM_HEADER_BLOCKS; ++i) {
        embed_bit(ll, ll_w, blocks_width, block_order[i], header_scrambled[i]);
    }

    bytes_to_repeated_bits(payload, (size_t)payload_len, payload_bits);
    bwm_shuffle_blocks(payload_perm, payload_sequence_count,
                       derive_seed(password, BWM_SEED_DOMAIN_PAYLOAD));
    permute_forward(payload_bits, payload_scrambled, payload_perm, payload_sequence_count);
    for (size_t i = 0; i < payload_sequence_count; ++i) {
        embed_bit(ll, ll_w, blocks_width, block_order[BWM_HEADER_BLOCKS + i],
                  payload_scrambled[i]);
    }

    if (bwm_haar_idwt2(ll, h, ll_w, ll_h, padded_y, padded_width, padded_height) !=
        BWM_DWT_OK) {
        result = BWM_ERROR_EMBED_FAILED;
        goto cleanup;
    }
    crop_plane(padded_y, padded_width, width, height, y_plane);

    result = bwm_yuv_to_pixels(y_plane, u_plane, v_plane, src_pixels, width, height, channels,
                               output);
    if (result != BWM_OK) {
        goto cleanup;
    }

    *out_pixels = output;
    *out_size = (int)output_bytes;
    output = NULL;
    result = BWM_OK;

cleanup:
    free(output);
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
    return result;
}

static int v1_extract_impl(const uint8_t *src_pixels, int width, int height, int channels,
                           const char *password, uint8_t **out_payload,
                           int *out_payload_len, int *out_is_text, int header_only,
                           int *out_version) {
    if (out_version != NULL) {
        *out_version = 0;
    }
    if (!header_only) {
        if (out_payload == NULL || out_payload_len == NULL || out_is_text == NULL) {
            return BWM_ERROR_INVALID_PARAMS;
        }
        *out_payload = NULL;
        *out_payload_len = 0;
        *out_is_text = 0;
    }

    if (src_pixels == NULL) {
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
    bwm_shuffle_blocks(block_order, block_count, derive_seed(password, BWM_SEED_DOMAIN_BLOCK));

    uint8_t header_scrambled[BWM_HEADER_BLOCKS];
    uint8_t header_bits[BWM_HEADER_BLOCKS];
    uint8_t header[BWM_HEADER_BYTES];
    uint32_t header_perm[BWM_HEADER_BLOCKS];
    for (size_t i = 0; i < BWM_HEADER_BLOCKS; ++i) {
        header_scrambled[i] = read_bit(ll, ll_w, blocks_width, block_order[i]);
    }
    bwm_shuffle_blocks(header_perm, BWM_HEADER_BLOCKS,
                       derive_seed(password, BWM_SEED_DOMAIN_HEADER));
    permute_inverse(header_scrambled, header_bits, header_perm, BWM_HEADER_BLOCKS);
    repeated_bits_to_bytes(header_bits, BWM_HEADER_BYTES, header);

    const uint16_t magic = (uint16_t)(((uint16_t)header[0] << 8) | (uint16_t)header[1]);
    const uint8_t version = header[2];
    if (magic != BWM_HEADER_MAGIC) {
        result = BWM_OK;
        goto cleanup;
    }
    if (out_version != NULL) {
        *out_version = (int)version;
    }
    if (header_only || version != BWM_V1_HEADER_VERSION) {
        result = BWM_OK;
        goto cleanup;
    }
    const int is_text = (header[3] & BWM_HEADER_FLAG_TEXT) != 0;

    const uint16_t payload_len = (uint16_t)(((uint16_t)header[4] << 8) |
                                            (uint16_t)header[5]);
    const uint16_t header_crc = (uint16_t)(((uint16_t)header[6] << 8) |
                                           (uint16_t)header[7]);
    if (payload_len == 0) {
        result = BWM_OK;
        goto cleanup;
    }

    result = bwm_check_capacity(width, height, (int)payload_len, &block_count,
                                &required_blocks);
    if (result != BWM_OK) {
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
            read_bit(ll, ll_w, blocks_width, block_order[BWM_HEADER_BLOCKS + i]);
    }
    bwm_shuffle_blocks(payload_perm, payload_sequence_count,
                       derive_seed(password, BWM_SEED_DOMAIN_PAYLOAD));
    permute_inverse(payload_scrambled, payload_bits, payload_perm, payload_sequence_count);
    repeated_bits_to_bytes(payload_bits, (size_t)payload_len, payload_bytes);

    if (bwm_crc16_ccitt(payload_bytes, (size_t)payload_len) != header_crc) {
        result = BWM_OK;
        goto cleanup;
    }

    *out_payload = payload_bytes;
    *out_payload_len = (int)payload_len;
    *out_is_text = is_text;
    payload_bytes = NULL;
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

int v1_watermark_peek_version(const uint8_t *src_pixels, int width, int height,
                              int channels, const char *password, int *out_version) {
    if (out_version == NULL) {
        return BWM_ERROR_INVALID_PARAMS;
    }
    return v1_extract_impl(src_pixels, width, height, channels, password, NULL, NULL,
                           NULL, 1, out_version);
}

int v1_watermark_extract(const uint8_t *src_pixels, int width, int height, int channels,
                         const char *password, uint8_t **out_payload,
                         int *out_payload_len, int *out_is_text) {
    return v1_extract_impl(src_pixels, width, height, channels, password, out_payload,
                           out_payload_len, out_is_text, 0, NULL);
}
