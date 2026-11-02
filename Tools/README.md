# Development Tools

这些目录是开发、调参和回归分析工具，不属于稳定公共 API，也不作为 library product 发布；下游依赖方不会构建它们。

- `B1Prototype/`：离线 SVD 比值、亮度归一化和几何同步原型。通过 `swift Tools/B1Prototype/b1_prototype.swift <mode>` 运行。
- `D1Sweep/`：d1 与攻击矩阵诊断工具。它是仓库根目录 `Package.swift` 中的开发用 executable target，可用 `swift run D1Sweep` 运行；只构建发布库时使用 `swift build --product BlindWatermarkKit`。

生产代码不应依赖这里的测试协议或诊断接口。
