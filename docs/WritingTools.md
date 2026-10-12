# 统一书写工具开发版（build 17）

本轮分支为 `codex/unified-writing-tools`，从 `codex/complex-pdf-compatibility` 的最新成果开始。
开发标识为 `0.5.0-dev.17`；构建入口仍为 `zsh Scripts/build.sh`，输出 `.build/apps/Ecru Dev.app`。
正式 `/Applications/Ecru.app`、Beta 2 的 DMG、既有 Release 均不更新，不发布 GitHub Release。

## 使用方式

- 笔宽按钮打开原生浮层：0.2–12 pt 连续滑块、常用宽度、实时预览、压感开关与灵敏度、停笔规整开关。
- 压感使用 Google Ink 原来的压力响应曲线和距离阻尼；灵敏度只改变笔刷直径范围。原来的 AdaptivePositionModel 文件未修改。
- 鼠标和缺少真实压力的输入使用固定基础笔宽；关闭压感也使用固定宽度。没有用速度、抖动或时间伪造压力。
- 接触并停留约 0.65 秒识别直线、单笔箭头、圆/椭圆、方形/矩形、三角形、菱形。拟合误差、尺寸、闭合度、绕行与回折检查过滤普通字迹。只有识别成功才出现非模态预览；移动笔尖调尺寸，抬笔确认。接触中按 Esc 恢复原始 Google Ink 轮廓；完成后选择/圈选，再点“手绘”恢复。
- “图形填充”独立记忆填充颜色；默认无填充。形状选中后可调边框颜色、边框宽度、填充和透明度；控制点支持尺寸调整，圈选支持整体移动。
- 橡皮直径浮层有倾斜尺寸和擦后切回笔开关。倾角越小，半径越大，范围 2–48 PDF pt；事件之间平滑变化，沿移动路径插值擦除半径。没有倾角则使用固定半径。仅实际擦到几何、正常完整抬笔后自动切回笔；空点、焦点丢失、取消、断连均不触发。
- 文字高亮是整组选区的切换：完全同色则取消，否则换色。按 PDF 字符范围减去重叠，只保留未选中部分；跨行/页分别投影为标准高亮。取消不删除正文，换色保留正文关联。外部高亮不参加自动切换。
- 颜色浮层有 12 个常用色、8 个柔和色、原生自定义色控件、最近 8 色和透明度。笔、文字高亮、自由荧光笔各自记忆设置。自由荧光笔仍是独立路径，保留独立叠加行为。

## 保存与兼容

图形仍是 InkStroke 的可编辑对象，新增可选 `shape` 元数据、边框和独立填充，保留原手绘点与轮廓。标准 PDF InkList 与 PDF appearance 同时写入；其他阅读器能够显示外观。
图形和文字范围采用最低 reader 4，图形笔迹封装 schema 5，恢复记录版本 6；老笔迹 schema 1–4 和恢复 1–5 继续读取。旧 Beta 2 应保留新数据并受限只读，不能忽略填充后覆盖保存。
局部擦除用几何相减；完整图形被擦断后成为保留边框/填充外观的可编辑轮廓片段。撤销恢复完整形状。恢复、保存、选择及移动均沿用现有事务和页面覆盖层。

## 输入能力与 PadInk

已逐段审查 PadInk：
`Apps/iPad/Input/PencilView.swift` 使用 UIKit 实际 coalesced samples、`force / maximumPossibleForce`、`altitudeAngle` 与 `azimuthAngle`；传输样本保留三项；Mac `PencilInjectionBackend` 写入真实 pressure 与归一化 tilt X/Y；Ecru 读取 CGEvent 精确压力，并通过两个轴反算 altitude，不把压力当倾角。
原生 Mac 平板输入使用 AppKit tabletPoint 的 pressure/tilt，proximity 能力掩码用于拒绝缺少倾角的设备；未收到 proximity 的设备只有实际非零倾角才确认倾角能力。普通鼠标和普通触控板鼠标事件不声明 Pencil 压感。

PadInk 的压力和倾角链路已完整，不改 USB、视频、VPN 或 iPad 协议。唯一配套变更位于独立分支 `codex/ecru-pencil-terminal`：在此前未使用的 CGEvent `tabletEventPointZ` 加入 `0x50490000 | UIKitPhase`（begin=1、move=2、end=3、cancel/reset=4）。保留手势/序号 userData、原有 proximity、pressure、tilt、HID 注入与时间锚定。
Ecru 只在 v2 的真正 end 上自动回笔。旧 PadInk 能继续压力书写和倾斜擦除，但对自动回笔保守停用，避免将旧版断连 reset/up 误当抬笔。完整验收需要使用配套 Mac 开发候选；不需要重装 iPad 端。

用户设备为 iPad Air 5，Pencil 很可能是第 2 代。不同 Pencil 使用共同的 UIKit 输入接口，但感应器能力不同：USB-C Pencil 有倾角、没有压力感应。现有 PadInk 不传 Pencil 型号，也没有单独的“压力不可用”能力位；不能仅凭恒定/零压力推断型号。对于无压感笔，关闭压力动态笔宽即可使用滑块基础宽度，并继续倾斜擦除。第 1/2 代和 Pro 的真实体验须在相应兼容 iPad 上验收。

输入语义参考：[Apple NSEvent tilt](https://developer.apple.com/documentation/appkit/nsevent/tilt)、[UITouch force](https://developer.apple.com/documentation/uikit/uitouch/force)、[Apple Pencil 型号功能](https://www.apple.com/apple-pencil/)。

## 自动化证据

- `Scripts/test.sh`：旧输入生命周期、笔迹几何、存储/恢复、批注、Google Ink 真实记录与历史算法对照全部通过；加入 `test-writing-tools.sh`。
- `Scripts/test-writing-tools.sh`：147 项，包括八类图形、单笔连续压力、无压力固定宽度、真实 tablet 字段的倾角反算和实际擦除半径、取消与正常抬笔、形状恢复/圈选/移动、文字范围切分、外部注释保护、批注正文和 PDF 安全保存重开。
- `Scripts/test.sh --ui-only`：101 项窗口、5 项独立重开、3 项阅读位置、61 项笔记及历史手写对照通过。
- `Scripts/test-writing-ui.sh`：21 项，正常 AppKit 运行循环中的真实定时停笔预览、无模态抢焦点、接触移动与抬笔确认、原生滑块与色控件、工具栏布局、手绘恢复和擦完回笔通过。证据位于 `output/writing-tools-ui-results.json` 与 `output/writing-tools-ui/`。
- PadInk `swift test`：532 项，0 失败，6 项按既有规则跳过；Mac 开发候选 Xcode 构建通过。测试使用内存事件接收器，没有向系统注入测试 Pencil 事件。

本地首轮笔记 UI 回归遇到系统 Python 缺少 pypdf；改用工作区自带 Python 与 pypdf 6.10.0 后通过。可用 `ECRU_TEST_PYTHON` 指定测试解释器，未改系统依赖。

## 真人验收（待完成）

用合成 PDF `output/pdf/Ecru-Dev-writing-acceptance-*.pdf`，不要在日常 PDF 上试新格式。使用 Ecru Dev 和配套 PadInk Mac 候选，保持 VPN 开启。

1. 50/100/200/400% 各写一段中文、英文、积分/分式及小下标。轻压→重压→轻压，比较原来的 Google Ink 手感；检查是否有突粗、锯齿、轨迹变形或延迟。关闭压感再写，确认固定宽度。
2. 每种图形各画两次；接触停留，再调整尺寸并抬笔。试写普通文字中的圆、钩、长竖，记录误识别；用 Esc 和“手绘”恢复。选择/圈选改边框、填充和透明度，移动，撤销/重做，保存退出重开。
3. 橡皮竖直→倾斜→竖直，检查跟随圈与实际擦除一致、连续稳定；在浅色/有色背景上确认是真实空缺。短暂停留不切回笔；抬笔才切换并恢复笔设置；关闭自动回笔后连续擦几次。
4. 擦除中断开 USB 或取消接触，确认工具保留橡皮；正常重新连接后再擦，确认只有完整正常抬笔才回笔。确认现有 USB 输入、双指导航和视频仍正常。
5. 选同一行同色高亮两次，再换色；选半行和跨行/页范围，确认边界与原文一致，未选区保留。给高亮加正文后取消高亮，确认正文仍在。自由荧光笔独立试写。
6. 对一个旧批注 PDF 的副本检查旧笔迹、正文和恢复；保存为新文件，再重开。新格式文件交给旧 Beta 2 时应只读保护。

自动化不能代替实体 Apple Pencil 控制、USB 断连、iPad 回传画面或输入到显示延迟验收。第 1 代、Pro、USB-C 及其他平板也尚未做真人验收。

## 真人反馈修正（build 17）

用户以 iPad Air 5 / Apple Pencil 第 2 代确认橡皮行为正常；真实压感与原书写手感、图形仍须继续验收。

- 行尾句号的 `PDFSelection` 会把换行包含在范围里。之前减去选中字符后残留换行，再投影成同一个句号，实际验收文稿形成 15 层重复标记。现在所有范围排除换行，PDFKit 返回范围被限制在要求的字符集合内；重复旧标记也可一起取消。几何回退改用单字符 selection，避免 PDFKit 的 glyph inventory 与提取字符串不同序。
- 快速直线只收到两个输入点时也可拟合；接触停留允许 8 屏幕点范围内的晃动，拟合先使用完整轨迹，失败时再用停留开始处的轨迹排除尾部晃动。识别器按弧长采样，并对闭合度、拟合误差和多边形角点使用适合真实手绘的容差。这个采样只用于识别，原 Google Ink 位置算法和显示轮廓保持原样，恢复手绘仍保留完整原点和轮廓。
- `Tests/Fixtures/pencil-shape-feedback.json` 是此次真人绘制的两条轨迹（合成测试 PDF 上，不包含个人文稿）；测试覆盖模型识别和实际定时窗口预览。`text-range-punctuation.pdf` 是原合成文稿的基底副本，用于复现行尾范围、部分取消、撤销重做、保存重开及旧重复标记清理。
- 图形填充增加“跟随笔色”：新图形采用该笔实际边框 RGB，透明度单独保存；已选图形使用各自边框 RGB。调整透明度保留跟随模式；另选自定义颜色则切换为独立填充。仍可选择无填充，默认不自动填充。
- 窗口回归补充接触抖动、两条真实轨迹、快速稀疏直线，以及跟随填充颜色和透明度。真人仍须验证新增容差是否在小字长竖、圈和钩中造成误识别，可用 Esc /“手绘”恢复。

连续调整宽度、填充透明度或颜色时保持浮层锚点视图，避免首次调整后 AppKit 自动关闭面板；窗口回归验证持续调整时面板仍打开。
