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

## 复杂 PDF 与保存

`PDFPagePreservation.swift` 通过 C 接口调用固定版本 QPDF；`PDFCapabilities` 区分完整编辑、只读和显式转换的静态批注副本。特征来自解析后的直接与间接对象，密码先经 PDFKit 解锁再经 QPDF 严格解析。活动结构在仅用于显示的内存副本中禁用。

QPDF 以原始对象图为保存底，只接入 Ecru 管理的新批注，并保留原外来注释及字段/附件引用。对象图验证使用间接引用的双向映射和原流字节，原有内容、批注及原子保存验证继续执行。完整重写不是增量更新；签名与加密暂不写回。只读会话也禁止草稿写入/恢复覆盖，保留原路径旧恢复记录。能力边界和用户流程见 [PDF 兼容性](PDFCompatibility.md)。
