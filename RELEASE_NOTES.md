# Ecru 0.5.0-beta.4（Build 20）

这次更新新增原生激光笔，并修正普通课件被导航动作误判为只读的问题。原有手写、图形填充、图片批注、文字批注和保存恢复功能保留。

## 激光笔：指示页面，停笔后自然消失

工具栏顺序为 **选择、笔、橡皮、文字高亮、自由荧光笔、圈选、激光笔**。激光笔独立放在最后，快捷键 **⌘7**；原有 ⌘1–⌘6 保持。

- **激光轨迹 / 激光光点**：用鼠标按住拖动，或通过 PadInk 用 Apple Pencil 接触页面。
- 默认红色、约 **2 秒**。连续指示时保留完整轨迹；停笔后短暂停留，最后约 0.4 秒整体柔和淡出。连续模糊光晕与细亮芯一起淡去。
- 点击“轨迹 · 设置”调整颜色、**1–12 屏幕 pt** 粗细、发光强度及 **0.3–10 秒** 消失时间。
- 位置锚定 PDF 页面坐标，跟随滚动、缩放、旋转与裁剪；视觉粗细按屏幕点保持。
- 工具、页面、文档切换，窗口失焦和关闭时清理临时内容；不同窗口的轨迹互不混用。

激光仅为临时页面显示，**不写入 PDF、不创建批注、不产生撤销重做事务或恢复记录，也不使文档变成未保存状态**。只读 PDF 也可使用激光，原写入保护继续有效。

激光采用独立轻量逻辑，未改 Google Ink 手写算法。仍保留 Pencil 无箭头、无瞄准光标的交互。激光是原生窗口像素，可被普通屏幕录制捕获，并进入 PadInk 现有视频链路。

## 更多普通课件可编辑

常见 PDF 课件带有翻页、返回、查找等本地导航命令。此前这些 `/Named` 命令会让整份 PDF 进入只读保护；现在对明确识别的本地导航放行。

支持的命令为 `/FirstPage`、`/LastPage`、`/NextPage`、`/PrevPage`、`/Find`、`/GoBack`、`/GoForward`、`/GoToPage`。空 `/AA` 事件表和只含本地导航的事件也不会单独禁用批注。自动触发器在内存阅读视图中移除，安全的手动链接保留；保存继续保留原 PDF 对象图、原导航动作及关系。

未知命令、脚本链、自动外部 URI、加密、签名和结构异常仍受保护。普通 AcroForm、附件及符合既有条件的静态批注副本沿用原兼容能力；这不是对任意 PDF 的无条件编辑承诺。

## 书写与编辑能力保留

Google Ink 日常笔、真实压力、图形规整与恢复手绘、倾斜橡皮自动回笔、文字高亮、自由荧光笔和离线 Markdown / 数学公式预览保持。图片仍可粘贴、拖入、移动、缩放、非破坏裁剪、旋转、锁定及与笔迹组合；已有图形的边框和填充独立编辑。保存、另存为、撤销重做、外部冲突及草稿恢复保持。

新增七工具在窄窗口中使用紧凑间距，保留笔参数入口。激光不提高 PDF 批注清单版本；历史文档保持现有兼容规则。图片、填充模式和组合数据仍需 Beta 3 或更新版本继续编辑。

## 安装包与验证范围

- **Apple Silicon / M 系列：** `Ecru-0.5.0-beta.4-arm64.dmg`
- **Intel：** `Ecru-0.5.0-beta.4-x86_64.dmg`
- 两份安装包功能相同，最低 **macOS 13**；下载校验使用同一 Release 的 `SHA256SUMS.txt`。
- 采用 **ad-hoc 签名，未经过 Developer ID 签名或 Apple 公证**。首次运行按安装说明使用系统的单 App 放行流程。
- 验证使用合成文件和隔离恢复数据；实际两架构检查记录见随包验证记录和 [验证说明](https://github.com/double-u-zw/Ecru/blob/v0.5.0-beta.4/docs/Validation.md)。

物理 Apple Pencil 跟手、PadInk 到 iPad 的真实视频延迟、真实 Intel 输入、macOS 13 实机、多显示器 / 混合 DPI 和长期大 PDF 负载仍需真人验收。合成事件、位图耗时和本机 Rosetta 检查不代替这些测量。

历史 Beta 3、Beta 2、Beta 1 的标签、Release 与安装包保持不变。没有自动更新；本版本安装不迁移 Ecru Dev 的设置或恢复数据。OCR、加密写回、签名验证、动态 XFA 编辑仍不提供。

功能详情：[激光笔](https://github.com/double-u-zw/Ecru/blob/v0.5.0-beta.4/docs/LaserPointer.md)、[PDF 兼容性](https://github.com/double-u-zw/Ecru/blob/v0.5.0-beta.4/docs/PDFCompatibility.md)。反馈请附版本、macOS、芯片、输入设备和复现步骤：[提交问题](https://github.com/double-u-zw/Ecru/issues/new/choose)。

---

**Native temporary laser trails and dots.** Use Command-7 with a mouse or PadInk + Apple Pencil. Soft Gaussian light stays intact briefly and fades as a whole after contact ends; color, width, glow and lifetime are adjustable. Laser pixels are captured by screen recording but never enter the PDF, undo history or draft recovery. Common local navigation actions no longer make ordinary slide PDFs read-only. Google Ink and existing editable images, shapes and safe-save behavior remain unchanged. Separate Apple Silicon and Intel DMGs require macOS 13+. This Beta is ad-hoc signed, not Apple-notarized; historical releases remain unchanged.
