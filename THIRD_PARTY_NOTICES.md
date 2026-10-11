# 第三方组件与许可证

Ecru 的本地 PDF 阅读、手写及文字预览使用以下组件。完整版权与许可证文本保存在 [licenses/](licenses/)，也随 App 和 DMG 提供；应用内“帮助 → 第三方许可”可打开相同声明。

| 组件 | 来源 / 版本 | 许可证 |
| --- | --- | --- |
| Google Ink C++ | [google/ink](https://github.com/google/ink)，b6def591a73a6aa0ffce1e58dc69b39de31484ba | [Apache-2.0](licenses/Google-Ink.txt) |
| Google Ink Stroke Modeler | [google/ink-stroke-modeler](https://github.com/google/ink-stroke-modeler)，f2388813b0b25bc3e33d143d369a8367ab2e30c8 | [Apache-2.0](licenses/Google-Ink-Stroke-Modeler.txt) |
| Abseil C++ | [abseil/abseil-cpp](https://github.com/abseil/abseil-cpp)，20260526.0 / 5650e9cf76d3be4318d5fa3af38ee483ddfd5e4a | [Apache-2.0](licenses/Abseil.txt) |
| perfect-freehand | [steveruizok/perfect-freehand](https://github.com/steveruizok/perfect-freehand)，176e00f2399f4969e1b0965c5921d96a3e50ce9f | [MIT](licenses/perfect-freehand-MIT.txt) |
| markdown-it | [markdown-it/markdown-it](https://github.com/markdown-it/markdown-it)，14.1.0 | [MIT](licenses/markdown-it-MIT.txt) |
| markdown-it-texmath | [goessner/markdown-it-texmath](https://github.com/goessner/markdown-it-texmath) | [MIT](licenses/markdown-it-texmath-MIT.txt) |
| KaTeX | [KaTeX/KaTeX](https://github.com/KaTeX/KaTeX)，0.16.22 | [MIT](licenses/KaTeX-MIT.txt) |
| KaTeX 字体 | Design Science, Inc. / Khan Academy；原始字体与 Reserved Font Names | [SIL OFL 1.1](licenses/KaTeX-Fonts-OFL-1.1.txt) |

[完整版权与集成声明](licenses/THIRD-PARTY-NOTICES.txt)

Google Ink、Abseil 的上游源码保持未修改；Ecru 自己实现输入模型、C 接口、日常笔刷及绘制适配。perfect-freehand 包含原生 Swift 移植及 Ecru 的轮廓适配，用于历史笔迹兼容；默认书写使用 Google Ink。Google Ink Stroke Modeler 保留在本地静态归档的历史代码路径中，不是默认笔的输入模型。

Google Ink、Google Ink Stroke Modeler 与 Abseil 的指定上游版本均未发现独立 NOTICE 文件，保留原 LICENSE，并汇总版权声明。KaTeX 字体按其字体元数据中的 SIL Open Font License 分发，保留字体名称、版权声明与完整许可。

构建配置下载的 googletest 不会随 App 分发。Apple 系统框架由 macOS 提供。以上项目及其权利人不为 Ecru 背书，第三方许可证只适用于各自组件；Ecru 第一方源码采用 Apache-2.0，见 [LICENSE](LICENSE) 与 [NOTICE](NOTICE)。
