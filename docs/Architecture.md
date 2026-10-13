# 架构与兼容性

`App.swift` 管理原生启动、系统打开事件、菜单及窗口生命周期。没有欢迎页；无恢复/外部文件时使用系统 PDF 打开面板。
`ReaderWindow.swift` 管理阅读工具、侧栏、搜索和批注锚点；`ReaderCanvas.swift` 接受局部 AppKit 输入，`PageInkPresentation.swift` 显示页面覆盖层。
`AnchoredNote.swift` 提供原生文本编辑与离线 WebKit 渲染；卡片先测量再显示，按正文/可用宽度缓存。默认阅读，编辑按钮或双击进入编辑。
`DocumentSession.swift` 管理保存、撤销、恢复及 PDF 标准投影；`AnnotationModel.swift` 定义可编辑记录及隐藏 PDF 清单。`HandwritingEngine.swift` 的 `NativePenInput` 与 `GoogleInkPenBuilder` 负责原生输入适配和轮廓更新；`Native/GoogleInkBridge.cc` 使用 Google Ink `InProgressStroke`、输入模型、笔刷行为及网格轮廓。Core Graphics 直接绘制其轮廓，`WritingNibEnvelope` 和 `PenBrush.swift` 保留作旧笔刷回归参考，`InkCore.swift` 负责编辑几何、绘制缓存和 PDF 编解码。旧 Observation/Perfect 实现保留作历史回归，正式构建只有一个默认引擎。详见 [手写实现](Handwriting.md)。

## 必须保留的兼容标识

- Bundle ID `local.leafink.reader.development`：维持日常 Ecru 的安装身份、设置、最近文档和恢复关联。Ecru Dev 使用 `local.ecru.reader.development` 与 `Ecru-Dev` 独立恢复目录。
- Application Support `LeafInk-development` 与窗口 autosave `LeafInkReaderWindow`：保持现有偏好、草稿和阅读位置。
- PDF 键 `/LeafInkStroke`、`/LeafInkDocument`、`/LeafInkMarkID`、`/LeafInkNoteID`、`/LeafInkAdapterID`，笔迹 annotation name 前缀及旧高亮内容 sentinel `LeafInk text highlight`：兼容旧文件和编辑身份，不改变存储格式。
- 旧 `LEAFINK_*` 环境配置保留为兼容别名；新 `ECRU_*` 优先。公开源码/脚本/执行文件采用 Ecru 命名。基线对照脚本的旧编译标志仅用于构建冻结源码。

这些是数据契约，不是用户界面品牌。未来如迁移必须具备设置/草稿/最近文档及旧 PDF 双读验证和回退方案。本轮没有迁移身份或用户数据。新建文字批注的作者及说明使用 Ecru；旧 PDF 原文和原有批注不作品牌替换。

## 输入安全与测试

正式构建不包含测试事件生成代码；UI runner 需 `ECRU_UI_TESTS` 显式编译。默认回归包含 InputBoundary 静态/二进制检查。输入诊断只能记录到显式指定目录，不将观察点事件时间解释为物理显示延迟。

Tests/ObservationReference 是数值对照，Tests/UI 是实际 AppKit/PDFKit 窗口检查。自动化输入不代表真实 Pencil/PadInk 体验。第三方许可在 ThirdParty 与 Resources/Preview/vendor 中，不改写其材料。

## 复杂 PDF 与保存

`PDFPagePreservation.swift` 通过 C 接口调用固定版本 QPDF；`PDFCapabilities` 区分完整编辑、只读和显式转换的静态批注副本。特征来自解析后的直接与间接对象，密码先经 PDFKit 解锁再经 QPDF 严格解析。活动结构在仅用于显示的内存副本中禁用。

QPDF 以原始对象图为保存底，只接入 Ecru 管理的新批注，并保留原外来注释及字段/附件引用。对象图验证使用间接引用的双向映射和原流字节，原有内容、批注及原子保存验证继续执行。完整重写不是增量更新；签名与加密暂不写回。只读会话也禁止草稿写入/恢复覆盖，保留原路径旧恢复记录。能力边界和用户流程见 [PDF 兼容性](PDFCompatibility.md)。

## 当前恢复、历史与搜索边界

`AnnotationChange.swift` 保存动作级可逆几何和元数据变化，撤销/重做继续使用原始修订标识。`RecoveryStore.swift` 在独立串行队列持久化不可变 PDF/图片源、检查点和前向变化；同一个原子提交头引用一整套经过哈希验证的对象，失败或中断不能提交部分状态。跨进程锁保护读取、提交与清理；另一个会话改变提交头后，旧缓存重新生成完整检查点，不能引用已被清理的对象。旧 JSON 在新对象全部可靠落盘前保留。

`DocumentOpenCoordinator.swift` 在独占加载队列创建新会话并完成原有校验，完成后一次性将对象图移交主线程；密码提示和窗口只在主线程创建。显示的 PDFKit 对象图由主线程独占。保存捕获不可变模型和字节，在保存队列重新解析、导出并执行原有全量保留/内容/冲突校验。搜索队列另行解析不可变的静态阅读数据，分页面检索并只返回字符范围与字符串；主线程按需创建当前显示文档的 PDFSelection。异步搜索不与显示或保存共享 PDFDocument、PDFPage 或 PDFSelection。源码身份变化或恢复换文档时使缓存失效。

圈选及对象组合的可移动集合只包含笔迹和图片；文字标记与批注区域保留锚定语义。当前使用与验证命令统一见 [README](../README.md)。
