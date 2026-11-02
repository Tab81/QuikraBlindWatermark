#include "watermark.h"

#include <math.h>
#include <stdint.h>
#include <string.h>

static int valid_pixel_dimensions(int width, int height, int channels) {
    return width > 0 && height > 0 && (channels == 1 || channels == 3 || channels == 4);
}

static uint8_t clamp_round_to_u8(double value) {
    if (value <= 0.0) {
        return 0;
    }
    if (value >= 255.0) {
        return 255;
    }
    return (uint8_t)(value + 0.5);
}

uint64_t bwm_password_seed(const char *password) {
    uint64_t hash = UINT64_C(14695981039346656037);
    if (password == NULL) {
        return hash;
    }

    const unsigned char *bytes = (const unsigned char *)password;
    while (*bytes != 0) {
        hash ^= (uint64_t)*bytes;
        hash *= UINT64_C(1099511628211);
        ++bytes;
    }
    return hash;
}

void bwm_splitmix64_init(bwm_splitmix64 *rng, uint64_t seed) {
    if (rng != NULL) {
        rng->state = seed;
    }
}

uint64_t bwm_splitmix64_next(bwm_splitmix64 *rng) {
    if (rng == NULL) {
        return 0;
    }

    rng->state += UINT64_C(0x9E3779B97F4A7C15);
    uint64_t value = rng->state;
    value = (value ^ (value >> 30)) * UINT64_C(0xBF58476D1CE4E5B9);
    value = (value ^ (value >> 27)) * UINT64_C(0x94D049BB133111EB);
    return value ^ (value >> 31);
}

void bwm_shuffle_blocks(uint32_t *order, size_t count, uint64_t seed) {
    if (order == NULL || count > (size_t)UINT32_MAX) {
        return;
    }

    for (size_t i = 0; i < count; ++i) {
        order[i] = (uint32_t)i;
    }

    bwm_splitmix64 rng;
    bwm_splitmix64_init(&rng, seed);
    for (size_t i = count; i > 1; --i) {
        const size_t j = (size_t)(bwm_splitmix64_next(&rng) % i);
        const uint32_t tmp = order[i - 1];
        order[i - 1] = order[j];
        order[j] = tmp;
    }
}

void bwm_build_block_order(uint32_t *order, size_t count, const char *password) {
    bwm_shuffle_blocks(order, count, bwm_password_seed(password));
}

static bwm_quantized_value qim_parts(float value, float step) {
    bwm_quantized_value result = {0.0, 0.0, 0};
    if (!(step > 0.0f)) {
        return result;
    }

    const double scaled = (double)value / (double)step;
    result.cell = floor(scaled);
    result.fraction = scaled - result.cell;
    result.bit = (result.fraction >= 0.5) ? 1 : 0;
    return result;
}

bwm_quantized_value bwm_quantize_read(float value, float step) {
    return qim_parts(value, step);
}

float bwm_quantize_write(float value, float step, int bit) {
    const bwm_quantized_value current = qim_parts(value, step);
    if (!(step > 0.0f)) {
        return 0.0f;
    }

    const double offset = (bit != 0) ? 0.75 : 0.25;
    return (float)((current.cell + offset) * (double)step);
}

uint16_t bwm_crc16_ccitt(const uint8_t *data, size_t length) {
    uint16_t crc = 0xFFFFu;
    if (data == NULL && length != 0) {
        return 0;
    }

    for (size_t i = 0; i < length; ++i) {
        crc ^= (uint16_t)data[i] << 8;
        for (int bit = 0; bit < 8; ++bit) {
            if ((crc & 0x8000u) != 0) {
                crc = (uint16_t)((crc << 1) ^ 0x1021u);
            } else {
                crc = (uint16_t)(crc << 1);
            }
        }
    }
    return crc;
}

int bwm_validate_password(const char *password) {
    return (password != NULL && password[0] != '\0') ? BWM_OK
                                                     : BWM_ERROR_PASSWORD_REQUIRED;
}

int bwm_pixels_to_yuv(const uint8_t *pixels, int width, int height, int channels,
                      float *y, float *u, float *v) {
    if (pixels == NULL || y == NULL || u == NULL || v == NULL) {
        return BWM_ERROR_INVALID_PARAMS;
    }
    if (!valid_pixel_dimensions(width, height, channels)) {
        return BWM_ERROR_INVALID_PARAMS;
    }

    const size_t pixel_count = (size_t)width * (size_t)height;
    for (size_t i = 0; i < pixel_count; ++i) {
        double r;
        double g;
        double b;

        if (channels == 1) {
            r = g = b = (double)pixels[i];
        } else {
            const size_t index = i * (size_t)channels;
            r = (double)pixels[index];
            g = (double)pixels[index + 1];
            b = (double)pixels[index + 2];
        }

        y[i] = (float)(0.299 * r + 0.587 * g + 0.114 * b);
        u[i] = (float)(-0.14713 * r - 0.28886 * g + 0.436 * b + 128.0);
        v[i] = (float)(0.615 * r - 0.51499 * g - 0.10001 * b + 128.0);
    }

    return BWM_OK;
}

int bwm_yuv_to_pixels(const float *y, const float *u, const float *v,
                      const uint8_t *source_pixels, int width, int height, int channels,
                      uint8_t *out_pixels) {
    if (y == NULL || u == NULL || v == NULL || out_pixels == NULL) {
        return BWM_ERROR_INVALID_PARAMS;
    }
    if (channels == 4 && source_pixels == NULL) {
        return BWM_ERROR_INVALID_PARAMS;
    }
    if (!valid_pixel_dimensions(width, height, channels)) {
        return BWM_ERROR_INVALID_PARAMS;
    }

    const size_t pixel_count = (size_t)width * (size_t)height;
    for (size_t i = 0; i < pixel_count; ++i) {
        if (channels == 1) {
            out_pixels[i] = clamp_round_to_u8((double)y[i]);
            continue;
        }

        const double u_value = (double)u[i] - 128.0;
        const double v_value = (double)v[i] - 128.0;
        const double r = (double)y[i] + 1.13983 * v_value;
        const double g = (double)y[i] - 0.39465 * u_value - 0.58060 * v_value;
        const double b = (double)y[i] + 2.03211 * u_value;

        const size_t index = i * (size_t)channels;
        out_pixels[index] = clamp_round_to_u8(r);
        out_pixels[index + 1] = clamp_round_to_u8(g);
        out_pixels[index + 2] = clamp_round_to_u8(b);
        if (channels == 4) {
            out_pixels[index + 3] = source_pixels[index + 3];
        }
    }

    return BWM_OK;
}

size_t bwm_capacity_blocks(int width, int height) {
    if (width <= 0 || height <= 0) {
        return 0;
    }

    const size_t ll_width = (size_t)((width + 1) / 2);
    const size_t ll_height = (size_t)((height + 1) / 2);
    return (ll_width / BWM_BLOCK_SIZE) * (ll_height / BWM_BLOCK_SIZE);
}

int bwm_check_capacity(int width, int height, int payload_len, size_t *out_blocks,
                       size_t *out_required_blocks) {
    if (width <= 0 || height <= 0 || payload_len < 0) {
        return BWM_ERROR_INVALID_PARAMS;
    }

    const size_t blocks = bwm_capacity_blocks(width, height);
    if (out_blocks != NULL) {
        *out_blocks = blocks;
    }

    if ((size_t)payload_len > SIZE_MAX / 8u) {
        return BWM_ERROR_INVALID_PARAMS;
    }
    const size_t payload_bits = (size_t)payload_len * 8u;
    if (payload_bits > (SIZE_MAX - BWM_HEADER_BLOCKS) / BWM_REDUNDANCY) {
        return BWM_ERROR_INVALID_PARAMS;
    }

    const size_t required_blocks = BWM_HEADER_BLOCKS + BWM_REDUNDANCY * payload_bits;
    if (out_required_blocks != NULL) {
        *out_required_blocks = required_blocks;
    }

    return (blocks >= required_blocks) ? BWM_OK : BWM_ERROR_IMAGE_TOO_SMALL;
}
