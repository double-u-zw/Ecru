# Ecru 0.5.0-beta.1

Ecru 的首个 GitHub 公开 Beta，应用构建号 **12**。面向 **Apple Silicon / macOS 13+**，保留已确认的 Google Ink 日常书写体验。

## 本次发布

- 原生 PDF 阅读、搜索、目录、缩略图与多窗口。
- 选择、手写笔、文字高亮、自由荧光笔、橡皮与圈选移动。
- 撤销重做、PDF 内嵌保存与重新编辑、未保存草稿恢复和旧批注兼容。
- 与原文关联的文字批注，以及离线 Markdown 和数学公式预览。
- 统一 Ecru 名称、批准的应用图标与 Beta 版本信息；应用内提供使用说明、反馈与许可证入口。
- 独立分发仓库、DMG 安装包与 SHA-256 校验文件；补齐第三方组件和 KaTeX 字体许可。

Google Ink 引擎及笔迹参数在本次发布中冻结；不对已有笔迹重新生成外观。

## 安装

下载 **Ecru-0.5.0-beta.1-arm64.dmg**，打开后将 Ecru 拖入 Applications，再推出映像。

本 Beta **使用临时签名，未进行 Developer ID 分发签名与 Apple 公证**。首次启动被拦截时，前往 **系统设置 → 隐私与安全性 → 仍要打开**，按系统提示确认。参考 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。无需关闭系统安全功能。

下载 `SHA256SUMS.txt` 并与 DMG 放在同一目录，运行 `shasum -a 256 -c SHA256SUMS.txt` 检查完整性。

## 验证

在 Apple Silicon / macOS 27.0.1 上通过核心保存、恢复、旧批注和 PDF 往返回归；原生窗口工作流 175 项、界面布局 133 项，以及 WindowServer 路径的 PadInk 手势 11 项检查通过。公开截图的示例笔迹也已保存并重开验证。真实设备与较早系统的验证范围见下方限制。

## 已知限制

- 仅提供 Apple Silicon 安装包；界面主要为中文。
- 加密、数字签名、表单、附件和部分交互结构的 PDF 暂不支持。
- 没有 OCR 或自动更新；扫描页的文字搜索依赖已有文本层。
- 外部编辑器可能改变私有批注数据，从而使部分内容不可编辑。
- 中文输入法、各类真实输入设备、混合 DPI 多显示器及长期多窗口仍需更多实机反馈。
- 编译最低系统为 macOS 13；本次实机环境为 Apple Silicon / macOS 27.0.1，未逐一验证全部较早系统。

完整使用方法见 [项目页面](https://github.com/double-u-zw/Ecru)。问题请提交到 [Issues](https://github.com/double-u-zw/Ecru/issues/new/choose)。

This first public Beta targets Apple Silicon on macOS 13+, with a primarily Chinese interface. It is ad-hoc signed and not notarized. Install via the DMG and use Privacy & Security → Open Anyway if macOS blocks first launch. Intel, OCR, auto-update, encrypted/signed/form PDFs are not supported.
