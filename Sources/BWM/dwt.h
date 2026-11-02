#ifndef BWM_DWT_H
#define BWM_DWT_H

#ifdef __cplusplus
extern "C" {
#endif

#define BWM_DWT_OK 0
#define BWM_DWT_ERROR_INVALID_DIMENSIONS 1
#define BWM_DWT_ERROR_NULL_POINTER 2
#define BWM_DWT_ERROR_SIZE_MISMATCH 3

/*
 * 1-level orthonormal Haar DWT2 for a single-channel row-major plane.
 *
 * Width and height must be positive even numbers. No padding is performed.
 *
 * out_ll: ll_w * ll_h floats, row-major, where ll_w = width / 2 and
 *         ll_h = height / 2.
 *
 * out_h:  3 * ll_w * ll_h floats. The buffer contains three contiguous,
 *         row-major subbands of size ll_w * ll_h each:
 *           [0, N)       LH
 *           [N, 2N)      HL
 *           [2N, 3N)     HH
 *         where N = ll_w * ll_h.
 */
int bwm_haar_dwt2(const float *in, int width, int height, float *out_ll, float *out_h,
                  int *out_ll_w, int *out_ll_h);

/*
 * Inverse of bwm_haar_dwt2. in_h has the same three-region layout described
 * above. width and height are the original even plane dimensions.
 */
int bwm_haar_idwt2(const float *in_ll, const float *in_h, int ll_w, int ll_h, float *out,
                   int width, int height);

#ifdef __cplusplus
}
#endif

#endif
