#ifndef BWM_SVD_H
#define BWM_SVD_H

#ifdef __cplusplus
extern "C" {
#endif

void bwm_svd4x4(const float in[4][4], float U[4][4], float S[4], float VT[4][4]);

void bwm_svd4x4_reconstruct(const float U[4][4], const float S[4], const float VT[4][4],
                            float out[4][4]);

#ifdef __cplusplus
}
#endif

#endif
