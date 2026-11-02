#include "svd.h"

#define ACCELERATE_NEW_LAPACK 1
#include <Accelerate/Accelerate.h>
#include <string.h>

#if __has_include(<Accelerate/LAPACK.h>)
#include <Accelerate/LAPACK.h>
#endif

void bwm_svd4x4(const float in[4][4], float U[4][4], float S[4], float VT[4][4]) {
    const int m = 4;
    const int n = 4;
    const int lda = 4;
    const int ldu = 4;
    const int ldvt = 4;
    const int lwork = 256;
    const char jobu = 'A';
    const char jobvt = 'A';

    float a_col_major[16];
    float u_col_major[16];
    float vt_col_major[16];
    float work[256];
    int info = 0;

    for (int row = 0; row < 4; ++row) {
        for (int col = 0; col < 4; ++col) {
            a_col_major[col * 4 + row] = in[row][col];
        }
    }

    sgesvd_(&jobu, &jobvt, &m, &n, a_col_major, &lda, S, u_col_major, &ldu,
            vt_col_major, &ldvt, work, &lwork, &info);

    if (info != 0) {
        memset(U, 0, 16 * sizeof(float));
        memset(S, 0, 4 * sizeof(float));
        memset(VT, 0, 16 * sizeof(float));
        return;
    }

    for (int row = 0; row < 4; ++row) {
        for (int col = 0; col < 4; ++col) {
            U[row][col] = u_col_major[col * 4 + row];
            VT[row][col] = vt_col_major[col * 4 + row];
        }
    }
}

void bwm_svd4x4_reconstruct(const float U[4][4], const float S[4], const float VT[4][4],
                            float out[4][4]) {
    for (int row = 0; row < 4; ++row) {
        for (int col = 0; col < 4; ++col) {
            float sum = 0.0f;
            for (int k = 0; k < 4; ++k) {
                sum += U[row][k] * S[k] * VT[k][col];
            }
            out[row][col] = sum;
        }
    }
}
