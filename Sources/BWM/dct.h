#ifndef BWM_DCT_H
#define BWM_DCT_H

#ifdef __cplusplus
extern "C" {
#endif

void bwm_dct4x4(const float in[4][4], float out[4][4]);
void bwm_idct4x4(const float in[4][4], float out[4][4]);

#ifdef __cplusplus
}
#endif

#endif
