<img src="assets/icon.png" width="96" alt="Ecru">

# Ecru

原生 macOS PDF 阅读与手写批注应用。支持直接书写、文字高亮、图片编辑和原文锚定批注，批注保存于 PDF，重开后可继续编辑。

**0.5.0-beta.6（Build 23）** · **macOS 13+** · **Apple Silicon** · **Apache-2.0**

[下载安装包](https://github.com/double-u-zw/Ecru/releases/download/v0.5.0-beta.6/Ecru-0.5.0-beta.6-arm64.dmg) · [发布说明与校验文件](https://github.com/double-u-zw/Ecru/releases/tag/v0.5.0-beta.6) · [构建与测试](BUILDING.md) · [问题反馈](https://github.com/double-u-zw/Ecru/issues/new/choose)

## 主要功能

- **PDF 阅读**：多窗口、目录、缩略图、页面导航、缩放与文本搜索。
- **手写与标记**：Google Ink 手写引擎、压感笔迹、文字高亮、自由荧光笔、橡皮和圈选编辑。
- **图形与图片**：图形边框和填充编辑；截图与图片粘贴、拖入、缩放、裁剪、旋转、锁定及组合。
- **文字批注**：关联原文的批注，支持离线 Markdown 和数学公式预览。
- **临时激光笔**：轨迹与光点，可调整颜色、粗细、发光和消失时间；不写入 PDF。
- **保存与恢复**：按动作撤销与重做、保存与另存为、未保存草稿恢复及外部修改冲突检测。

阅读、书写和批注预览均在本机完成，无需账号或运行时联网。笔迹、图形、图片和文字批注可保存于 PDF，无需伴随文件。

可使用鼠标或系统支持的压感输入。Apple Pencil 需配合 PadInk，将 iPad 输入传递到 Mac。

## 下载与安装

1. 下载适用于 Apple Silicon（M 系列）的 [arm64 DMG](https://github.com/double-u-zw/Ecru/releases/download/v0.5.0-beta.6/Ecru-0.5.0-beta.6-arm64.dmg)。
2. 打开 DMG，将 **Ecru.app** 拖入 **Applications（应用程序）**，然后推出磁盘映像。
3. 从“应用程序”启动 Ecru。更新已有版本前，请先保存文档并正常退出旧版本。

本版本采用 Developer ID Application 签名，App 与 DMG 均通过 Apple 公证并附有公证票据。新版本仅支持 Apple Silicon；历史 Intel 安装包仍可从 [历史 Releases](https://github.com/double-u-zw/Ecru/releases) 获取。

可下载同一 Release 的 `SHA256SUMS.txt`，与 DMG 放在同一目录后校验：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

## 基本操作

| 操作 | 快捷键 |
| --- | --- |
| 打开 PDF | ⌘O |
| 保存 / 另存为 | ⌘S / ⇧⌘S |
| 撤销 / 重做 | ⌘Z / ⇧⌘Z |
| 搜索 | ⌘F |
| 选择 / 笔 | ⌘1 / ⌘2 |
| 文字高亮 / 自由荧光笔 | ⌘3 / ⌘4 |
| 橡皮 / 圈选 / 激光笔 | ⌘5 / ⌘6 / ⌘7 |
| 为选中文字添加批注 | ⇧⌘N |

圈选可移动 Ecru 笔迹、图形与图片；文字高亮和文字批注的原文锚定区域不参与移动。选择图形后可编辑填充，图片调整完成后可继续书写。草稿恢复后仍需保存；原文件被外部修改时，可另存为新文件。

详细说明：[可编辑对象](docs/EditableObjects.md) · [书写工具](docs/WritingTools.md) · [激光笔](docs/LaserPointer.md) · [PDF 兼容性](docs/PDFCompatibility.md)

## Beta 6 更新

本版集中改善持续编辑、恢复和长文档搜索：恢复记录共享 PDF 基底与图片源，批注按检查点和增量提交；减少连续书写的抬笔提交开销；搜索支持防抖、取消和逐步结果，并保护中文组合输入。Google Ink 算法、配方和手写参数保持不变。

同时修正文字高亮及原文批注区域的圈选行为，略微加粗图标线条，并加入正式签名和公证。完整变更见 [发布说明](RELEASE_NOTES.md)。

## 兼容性与限制

- 最低 macOS 13，仅支持 Apple Silicon；当前版本仍为 Beta。
- 加密和签名 PDF 保持只读；普通表单和附件采用结构保留保存；XFA、活动内容和 Portfolio 按能力提供受保护的静态阅读与批注副本。
- 没有 OCR。扫描文档可以书写，但文字选择和搜索需要 PDF 自带文本层。
- 其他软件生成的批注会尽量保留，但不保证全部可编辑；修改 Ecru 的内嵌数据可能使对象进入保护状态。
- 图片支持矩形裁剪、90° 旋转和单页组合，HDR 来源会转换为 SDR sRGB。
- 没有自动更新；开发版本和公开发行版本的设置及恢复记录互相独立。

自动化验证覆盖核心功能、合成手写、独立进程恢复、搜索、复杂 PDF、图片/图形与原生窗口。实体 Pencil、真实中文输入法、混合 DPI、macOS 13 实机及长期使用仍需独立验收。实际验证范围见 [验证说明](docs/Validation.md)。

## 构建与贡献

源码使用 Swift、AppKit/PDFKit、C++20 和 CMake。开发环境、依赖安装、构建、测试、隔离存储及签名公证统一见 [BUILDING.md](BUILDING.md)。默认开发构建保留独立身份，不自动替换已安装应用。

欢迎通过 [Issues](https://github.com/double-u-zw/Ecru/issues/new/choose) 提交问题，或按 [贡献说明](CONTRIBUTING.md) 提交改进。问题报告请包含应用版本、macOS 版本、芯片、输入设备及复现步骤；示例文档应适合公开分享。

## 许可证

Ecru 第一方源码、文档和项目美术采用 [Apache-2.0](LICENSE)。第三方组件保留各自许可证，详见 [NOTICE](NOTICE)、[第三方声明](THIRD_PARTY_NOTICES.md) 与 [分发说明](DISTRIBUTION.md)。

---

Ecru is a native PDF reader and handwriting annotation app for macOS 13+ on Apple Silicon. Beta 6 uses Developer ID signing and Apple notarization. Reading, handwriting and Markdown/math previews run locally. OCR and automatic updates are not available. See [BUILDING.md](BUILDING.md) for development instructions.
