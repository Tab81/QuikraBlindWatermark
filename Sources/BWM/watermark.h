#ifndef BWM_WATERMARK_H
#define BWM_WATERMARK_H

#include <stddef.h>
#include <stdint.h>

#include "quikra_bwm.h"

#define BWM_BLOCK_SIZE 4
#define BWM_HEADER_BYTES 8
#define BWM_REDUNDANCY 3
#define BWM_HEADER_BITS (BWM_HEADER_BYTES * 8)
#define BWM_HEADER_BLOCKS (BWM_HEADER_BITS * BWM_REDUNDANCY)
#define BWM_HEADER_MAGIC 0xBA5Eu
#define BWM_HEADER_FLAG_TEXT 0x01u

typedef struct {
    uint64_t state;
} bwm_splitmix64;

typedef struct {
    double cell;
    double fraction;
    int bit;
} bwm_quantized_value;

uint64_t bwm_password_seed(const char *password);

void bwm_splitmix64_init(bwm_splitmix64 *rng, uint64_t seed);
uint64_t bwm_splitmix64_next(bwm_splitmix64 *rng);

void bwm_shuffle_blocks(uint32_t *order, size_t count, uint64_t seed);
void bwm_build_block_order(uint32_t *order, size_t count, const char *password);

bwm_quantized_value bwm_quantize_read(float value, float step);
float bwm_quantize_write(float value, float step, int bit);

uint16_t bwm_crc16_ccitt(const uint8_t *data, size_t length);

int bwm_validate_password(const char *password);

int bwm_pixels_to_yuv(const uint8_t *pixels, int width, int height, int channels,
                      float *y, float *u, float *v);
int bwm_yuv_to_pixels(const float *y, const float *u, const float *v,
                      const uint8_t *source_pixels, int width, int height, int channels,
                      uint8_t *out_pixels);

size_t bwm_capacity_blocks(int width, int height);
int bwm_check_capacity(int width, int height, int payload_len, size_t *out_blocks,
                       size_t *out_required_blocks);

#endif
