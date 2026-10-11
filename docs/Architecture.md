# 架构与兼容性

`App.swift` 管理原生启动、系统打开事件、菜单及窗口生命周期。没有欢迎页；无恢复/外部文件时使用系统 PDF 打开面板。
`ReaderWindow.swift` 管理阅读工具、侧栏、搜索和批注锚点；`ReaderCanvas.swift` 接受局部 AppKit 输入，`PageInkPresentation.swift` 显示页面覆盖层。
`AnchoredNote.swift` 提供原生文本编辑与离线 WebKit 渲染；卡片先测量再显示，按正文/可用宽度缓存。默认阅读，编辑按钮或双击进入编辑。
`DocumentSession.swift` 管理保存、撤销、恢复及 PDF 标准投影；`AnnotationModel.swift` 定义可编辑记录及隐藏 PDF 清单。`HandwritingEngine.swift` 的 `NativePenInput` 与 `GoogleInkPenBuilder` 负责原生输入适配和轮廓更新；`Native/GoogleInkBridge.cc` 使用 Google Ink `InProgressStroke`、输入模型、笔刷行为及网格轮廓。Core Graphics 直接绘制其轮廓，`WritingNibEnvelope` 和 `PenBrush.swift` 保留作旧笔刷回归参考，`InkCore.swift` 负责编辑几何、绘制缓存和 PDF 编解码。旧 Observation/Perfect 实现保留作历史回归，正式构建只有一个默认引擎。详见 [手写实现](Handwriting.md)。

## 必须保留的兼容标识

- Bundle ID `local.leafink.reader.development`：维持安装身份、设置、最近文档和恢复关联。
- Application Support `LeafInk-development` 与窗口 autosave `LeafInkReaderWindow`：保持现有偏好、草稿和阅读位置。
- PDF 键 `/LeafInkStroke`、`/LeafInkDocument`、`/LeafInkMarkID`、`/LeafInkNoteID`、`/LeafInkAdapterID`，笔迹 annotation name 前缀及旧高亮内容 sentinel `LeafInk text highlight`：兼容旧文件和编辑身份，不改变存储格式。
- 旧 `LEAFINK_*` 环境配置保留为兼容别名；新 `ECRU_*` 优先。公开源码/脚本/执行文件采用 Ecru 命名。

这些是数据契约，不是用户界面品牌。未来如迁移必须具备设置/草稿/最近文档及旧 PDF 双读验证和回退方案。本轮没有迁移身份或用户数据。新建文字批注的作者及说明使用 Ecru；旧 PDF 原文和原有批注不作品牌替换。

## 输入安全与测试

正式构建不包含测试事件生成代码；UI runner 需 `ECRU_UI_TESTS` 显式编译。默认回归包含 InputBoundary 静态/二进制检查。输入诊断只能记录到显式指定目录，不将观察点事件时间解释为物理显示延迟。

公开回归使用 Tests/InkLegacyReference.swift 作旧笔迹数值对照，Tests/PublicWindowChecks.swift 作实际 AppKit/PDFKit 窗口检查。自动化输入不代表真实 Pencil/PadInk 体验。第三方许可保留在 ThirdParty、Resources/Licenses 与 licenses/ 中。

## PDF 保存与分架构构建

`PDFPagePreservation.swift` 通过 C 接口调用固定版本 QPDF，从原 PDF 复制页绘图流与继承资源到 PDFKit 的批注导出。PDFKit 保留批注及其外观流，保存前仍检查页面、目录、原绘图与图像资源、批注清单和显示一致性。较旧 macOS 的 PDFKit 可能重写底图，不能仅依赖其导出保证原内容不变。

`build.sh` 默认生成本机架构 App；`build-release.sh` 生成版本和资源一致的 arm64、x86_64 两份 App 与独立 DMG，最低目标均为 macOS 13。CI 在对应原生 runner 上分别构建、回归与打包。

Page identities also carry an optional character-inventory hash. Together with
unchanged page drawing hashes, this avoids false note-location warnings when
PDFKit changes text extraction order. Older manifests retain their exact-text
check. Generated note popups are presentation adapters, removed from the editable
layer and regenerated from their authoritative note; foreign popups remain intact.
