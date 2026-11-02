#ifndef BWM_ALGORITHM_H
#define BWM_ALGORITHM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    BWM_ALGO_V1 = 1,
    BWM_ALGO_V2 = 2
} bwm_algorithm_t;

#define BWM_V1_HEADER_VERSION 0x02u
#define BWM_V2_HEADER_VERSION 0x03u

#ifdef __cplusplus
}
#endif

#endif
