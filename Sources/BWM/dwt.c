#include "dwt.h"

#include <stddef.h>

static int valid_even_dimensions(int width, int height) {
    return width > 0 && height > 0 && (width % 2) == 0 && (height % 2) == 0;
}

int bwm_haar_dwt2(const float *in, int width, int height, float *out_ll, float *out_h,
                  int *out_ll_w, int *out_ll_h) {
    if (in == NULL || out_ll == NULL || out_h == NULL || out_ll_w == NULL ||
        out_ll_h == NULL) {
        return BWM_DWT_ERROR_NULL_POINTER;
    }
    if (!valid_even_dimensions(width, height)) {
        return BWM_DWT_ERROR_INVALID_DIMENSIONS;
    }

    const int ll_w = width / 2;
    const int ll_h = height / 2;
    const size_t subband_size = (size_t)ll_w * (size_t)ll_h;

    float *lh = out_h;
    float *hl = out_h + subband_size;
    float *hh = out_h + 2 * subband_size;

    for (int y = 0; y < height; y += 2) {
        for (int x = 0; x < width; x += 2) {
            const float a = in[(size_t)y * (size_t)width + (size_t)x];
            const float b = in[(size_t)y * (size_t)width + (size_t)x + 1];
            const float c = in[(size_t)(y + 1) * (size_t)width + (size_t)x];
            const float d = in[(size_t)(y + 1) * (size_t)width + (size_t)x + 1];

            const size_t index = (size_t)(y / 2) * (size_t)ll_w + (size_t)(x / 2);
            out_ll[index] = (a + b + c + d) * 0.5f;
            lh[index] = (a + b - c - d) * 0.5f;
            hl[index] = (a - b + c - d) * 0.5f;
            hh[index] = (a - b - c + d) * 0.5f;
        }
    }

    *out_ll_w = ll_w;
    *out_ll_h = ll_h;
    return BWM_DWT_OK;
}

int bwm_haar_idwt2(const float *in_ll, const float *in_h, int ll_w, int ll_h, float *out,
                   int width, int height) {
    if (in_ll == NULL || in_h == NULL || out == NULL) {
        return BWM_DWT_ERROR_NULL_POINTER;
    }
    if (!valid_even_dimensions(width, height)) {
        return BWM_DWT_ERROR_INVALID_DIMENSIONS;
    }
    if (ll_w != width / 2 || ll_h != height / 2) {
        return BWM_DWT_ERROR_SIZE_MISMATCH;
    }

    const size_t subband_size = (size_t)ll_w * (size_t)ll_h;
    const float *lh = in_h;
    const float *hl = in_h + subband_size;
    const float *hh = in_h + 2 * subband_size;

    for (int y = 0; y < height; y += 2) {
        for (int x = 0; x < width; x += 2) {
            const size_t index = (size_t)(y / 2) * (size_t)ll_w + (size_t)(x / 2);
            const float ll = in_ll[index];
            const float l = lh[index];
            const float h = hl[index];
            const float d = hh[index];

            out[(size_t)y * (size_t)width + (size_t)x] = (ll + l + h + d) * 0.5f;
            out[(size_t)y * (size_t)width + (size_t)x + 1] = (ll + l - h - d) * 0.5f;
            out[(size_t)(y + 1) * (size_t)width + (size_t)x] = (ll - l + h - d) * 0.5f;
            out[(size_t)(y + 1) * (size_t)width + (size_t)x + 1] =
                (ll - l - h + d) * 0.5f;
        }
    }

    return BWM_DWT_OK;
}
