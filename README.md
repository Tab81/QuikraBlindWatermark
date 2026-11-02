# BlindWaterMark

## 它能做什么

macOS/iOS 盲水印框架，适合防止截图转发和常规压缩后的盗用。

v1 使用 1 级 Haar DWT、4×4 正交 DCT、SVD 最大奇异值 `S[0]` 量化和 8 字节自描述头；提取不需要原图。

### 实测数据

512×512 合成测试集，32 字节载荷，默认 `d1 = 36`、`d2 = 0`。表中为 CRC 成功提取率，不是视觉相似度，也不代表所有真实图片都能达到。

| 项目 | 实测结果 |
|---|---:|
| JPEG q95 / q90 / q80 / q70 | 100% |
| 缩放 1.5× 往返 | 100% |
| 缩放 0.75× 往返 | 100% |
| 缩放 0.5× 往返 | 75% |
| 高斯噪声 σ=2 | 100% |
| 高斯噪声 σ=5 | 66.7% |
| 嵌入 PSNR（512×512） | 约 49.6 dB |

### 安装

要求 Swift 5.9+。`Package.swift` 支持 macOS 13.0、iOS 16.4、tvOS 16.4、watchOS 9.4、visionOS 1.0。C 核心可跨 macOS/iOS 使用；Swift 封装当前使用 AppKit `NSImage`，iOS 端需改用 `CGImage`/RGBA8 缓冲或按平台适配。

SwiftPM 依赖：

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/your-org/BlindWaterMark.git", from: "1.0.0")
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "BlindWatermarkKit", package: "BlindWaterMark")
        ]
    )
]
```

Xcode 添加包依赖：

1. 打开 **File > Add Package Dependencies...**。
2. 输入仓库 URL，选择 `1.0.0` 或对应的版本范围。
3. 将 `BlindWatermarkKit` 添加到 App target；只使用 C 核心时改为添加 `BWM`。

将示例中的 `your-org` 和仓库名替换为最终 GitHub 地址。本地开发也可使用 `.package(path: "../BlindWaterMark")`。

### 用法

Swift 嵌入：

```swift
import AppKit
import BlindWatermarkKit

@MainActor
func embedWatermark(in image: NSImage) throws -> NSImage {
    try BlindWatermarkService().embed(
        in: image,
        payload: Data("secret".utf8),
        isText: true,
        password: "change-me"
    )
}
```

Swift 提取：

```swift
import AppKit
import BlindWatermarkKit

@MainActor
func extractWatermark(from image: NSImage) throws -> BlindWatermarkResult {
    try BlindWatermarkService().extract(from: image, password: "change-me")
}
```

结果为 `.detected(payload: Data, isText: Bool)` 或 `.notDetected`。

C 最小示例：

```c
#include <stdint.h>
#include <stdlib.h>
#include <BWM/quikra_bwm.h>

int embed_rgba(const uint8_t *rgba, int width, int height,
               const uint8_t *payload, int payload_len,
               const char *password, uint8_t **out_rgba, int *out_size) {
    return quikra_bwm_embed(
        rgba, width, height, 4,
        payload, payload_len,
        1,
        BWM_ALGO_V1,
        password,
        out_rgba, out_size
    );
}

int extract_rgba(const uint8_t *rgba, int width, int height,
                 const char *password, uint8_t **out_payload,
                 int *out_len, int *out_is_text) {
    int rc = quikra_bwm_extract(
        rgba, width, height, 4,
        password,
        out_payload, out_len, out_is_text
    );
    if (rc == BWM_OK && *out_payload == NULL) {
        /* 未检测到水印，或密码错误。 */
    }
    return rc;
}
```

`out_rgba` 和 `out_payload` 由 C 层 `malloc`，调用方必须 `free`。错误信息可通过 `bwm_get_error_message(rc)` 获取，返回静态字符串，无需释放。

## 它不保证什么

- **不保证抵抗调色（亮度/对比度 ±10% 实测 0%）。** 原因是 `S[0]` 绝对量化对整体亮度缩放不具不变性；v2 规划中。对会统一调整亮度或对比度的链路，当前应在业务侧避免依赖该水印，或等待 v2。
- **不保证抵抗旋转、裁剪。** v1 不做几何同步，旋转或裁剪后的图像不能可靠恢复头部和载荷；7e 框架校正原型已验证，旋转只有 12.5%、裁剪为 0%，不纳入 v1。需要覆盖几何变换时，应改用带同步信号的方案并重新验证。
- **不保证抵抗 AI 生成式重绘。** 这是像素级水印的架构天花板，不在 v1 威胁模型内；生成式重绘后应视为目标图像已被替换。
- **密码只控制块顺序和打乱序列，不构成加密。** 密码不是加密密钥；需要保密载荷时，请在调用方先加密，再嵌入密文。
- **错误密码与“无水印”不可区分，统一返回 `.notDetected` / `BWM_OK + NULL`。** 这是无原图盲提取的固有限制，不是实现缺陷；调用方不应把 `NULL` 当作异常。

## 使用约束与版本说明

- 最小图像尺寸：必须容纳 `192` 个头块和载荷的三份重复；不足时返回 `BWM_ERROR_IMAGE_TOO_SMALL`。
- 测试集说明：上述数据来自 512×512 合成测试集；真实照片、极端压缩参数、跨平台色彩转换可能影响成功率，建议在自己的目标场景下验证。
- v2 尚未实现；修改 `d1` 会改变格式兼容性，旧图需要旧的量化参数。
- 当前发布版本为 v1.0.0，算法版本 `0x02`，量化参数为 `d1 = 36`、`d2 = 0`。
- 许可证：BSD-3-Clause，见 `LICENSE`。

欢迎在使用时注明 Powered by Quikra (https://quikra.top)，但并非许可要求。
