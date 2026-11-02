#include "dct.h"

static const float kDctMatrix[4][4] = {
    {0.5f, 0.5f, 0.5f, 0.5f},
    {0.6532814824f, 0.2705980501f, -0.2705980501f, -0.6532814824f},
    {0.5f, -0.5f, -0.5f, 0.5f},
    {0.2705980501f, -0.6532814824f, 0.6532814824f, -0.2705980501f},
};

void bwm_dct4x4(const float in[4][4], float out[4][4]) {
    float row_transformed[4][4];

    for (int row = 0; row < 4; ++row) {
        for (int v = 0; v < 4; ++v) {
            row_transformed[row][v] = in[row][0] * kDctMatrix[v][0] +
                                      in[row][1] * kDctMatrix[v][1] +
                                      in[row][2] * kDctMatrix[v][2] +
                                      in[row][3] * kDctMatrix[v][3];
        }
    }

    for (int v = 0; v < 4; ++v) {
        for (int u = 0; u < 4; ++u) {
            out[u][v] = row_transformed[0][v] * kDctMatrix[u][0] +
                        row_transformed[1][v] * kDctMatrix[u][1] +
                        row_transformed[2][v] * kDctMatrix[u][2] +
                        row_transformed[3][v] * kDctMatrix[u][3];
        }
    }
}

void bwm_idct4x4(const float in[4][4], float out[4][4]) {
    float column_restored[4][4];

    for (int v = 0; v < 4; ++v) {
        for (int row = 0; row < 4; ++row) {
            column_restored[row][v] = in[0][v] * kDctMatrix[0][row] +
                                      in[1][v] * kDctMatrix[1][row] +
                                      in[2][v] * kDctMatrix[2][row] +
                                      in[3][v] * kDctMatrix[3][row];
        }
    }

    for (int row = 0; row < 4; ++row) {
        for (int col = 0; col < 4; ++col) {
            out[row][col] = column_restored[row][0] * kDctMatrix[0][col] +
                            column_restored[row][1] * kDctMatrix[1][col] +
                            column_restored[row][2] * kDctMatrix[2][col] +
                            column_restored[row][3] * kDctMatrix[3][col];
        }
    }
}
