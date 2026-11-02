#include "quikra_bwm.h"

#include "v1_watermark.h"

const char *bwm_get_error_message(int code) {
    switch (code) {
        case BWM_OK:
            return "Success";
        case BWM_ERROR_INVALID_HANDLE:
            return "Invalid handle";
        case BWM_ERROR_FILE_NOT_FOUND:
            return "File not found";
        case BWM_ERROR_INVALID_IMAGE:
            return "Invalid image";
        case BWM_ERROR_EMBED_FAILED:
            return "Embed failed";
        case BWM_ERROR_EXTRACT_FAILED:
            return "Extract failed";
        case BWM_ERROR_INVALID_PARAMS:
            return "Invalid parameters";
        case BWM_ERROR_IMAGE_TOO_SMALL:
            return "Image too small for watermark payload";
        case BWM_ERROR_PASSWORD_REQUIRED:
            return "Password is required";
        case BWM_ERROR_NOT_IMPLEMENTED:
            return "Algorithm not implemented";
        case BWM_ERROR_OUT_OF_MEMORY:
            return "Out of memory";
        default:
            return "Unknown error";
    }
}

int quikra_bwm_embed(const uint8_t *src_pixels, int width, int height, int channels,
                     const uint8_t *payload, int payload_len, int is_text,
                     bwm_algorithm_t algorithm, const char *password,
                     uint8_t **out_pixels, int *out_size) {
    if (out_pixels == NULL || out_size == NULL) {
        return BWM_ERROR_INVALID_PARAMS;
    }
    *out_pixels = NULL;
    *out_size = 0;

    switch (algorithm) {
        case BWM_ALGO_V1:
            return v1_watermark_embed(src_pixels, width, height, channels, payload,
                                      payload_len, is_text, password, out_pixels, out_size);
        case BWM_ALGO_V2:
            return BWM_ERROR_NOT_IMPLEMENTED;
        default:
            return BWM_ERROR_INVALID_PARAMS;
    }
}

int quikra_bwm_extract(const uint8_t *src_pixels, int width, int height, int channels,
                       const char *password, uint8_t **out_payload, int *out_payload_len,
                       int *out_is_text) {
    if (out_payload == NULL || out_payload_len == NULL || out_is_text == NULL) {
        return BWM_ERROR_INVALID_PARAMS;
    }
    *out_payload = NULL;
    *out_payload_len = 0;
    *out_is_text = 0;

    int version = 0;
    int result = v1_watermark_peek_version(src_pixels, width, height, channels, password,
                                           &version);
    if (result != BWM_OK) {
        return result;
    }

    switch (version) {
        case BWM_V1_HEADER_VERSION:
            return v1_watermark_extract(src_pixels, width, height, channels, password,
                                        out_payload, out_payload_len, out_is_text);
        case BWM_V2_HEADER_VERSION:
            return BWM_ERROR_NOT_IMPLEMENTED;
        default:
            return BWM_OK;
    }
}
