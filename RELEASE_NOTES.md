# Ecru 0.5.0-beta.3 (19)

可编辑图片批注、独立图形填充与分级 PDF 兼容。

## 本次更新

- 将系统截图或图片直接粘贴进 PDF，也可通过 Finder / 截图缩略图拖入，或使用“编辑 → 插入图片”。文本输入框内的粘贴仍按原有方式处理。
- 图片支持移动、等比例缩放、非破坏式矩形裁剪与重置、90° 旋转、复制剪切删除、前后层级和位置锁定。
- 可在图片上直接书写及荧光标记；橡皮只擦除 Ecru 笔迹。图片可与笔迹、图形一起圈选、组合、变换、取消组合。调整完成后恢复之前的工具及笔设置。
- 选择已有图形即可独立修改边框、线宽、填充模式、填充颜色和不透明度，支持多选和实时预览。修改已有对象不改变绘图默认值，可明确将当前样式设为默认。
- 图片资源及透明通道真正嵌入 PDF，标准阅读器可显示；Ecru 重开后仍可编辑图片、图形和组合。移动、裁剪和重复保存不重新降低源图分辨率。
- 保留 Google Ink 与真实压感、连续笔宽、停笔图形规整及恢复手绘、倾斜橡皮自动回笔、文字高亮重复取消、自由荧光笔、文字批注和离线数学预览。
- 扩展复杂 PDF 的安全处理：密码解锁与签名文件只读；支持普通 AcroForm / 附件文档的结构保留保存；XFA、活动内容和 Portfolio 使用静态阅读与保护。详见 [PDF 兼容性](docs/PDFCompatibility.md)。

## 兼容与限制

- 仍为公开 Beta；Apple Silicon 与 Intel 分别提供 arm64 / x86_64 DMG，最低 macOS 13。
- 历史 Beta 1 / Beta 2 文档可读取；含新图片、填充模式或组合的文档需要本版本继续编辑。旧版本可能进入只读保护。
- 图片转换为完整像素的 8-bit SDR sRGB PNG，并保留 alpha；HDR 增益图不保留。最多 4000 万像素、单图归一化 PNG 24 MiB、整个可编辑批注数据 64 MiB。超限会拒绝插入并保留现有内容。
- 一次文件插入处理一张图片；矩形裁剪、90° 旋转；组合位于同一页。跨软件复制提供原图，Ecru 内复制保留可编辑几何和组合。
- 加密和签名 PDF 不开放写回；真实 HDR 输入、实际 Intel 设备手写、旧系统和混合 DPI 多屏仍需更多验证。
- ad-hoc 签名，尚未 Developer ID 签名或 Apple 公证；无 OCR、无自动更新。

## 验证范围

本次功能以维护者已接受的 Ecru Dev Build 18 为基线。已通过图片 / 填充 78 项、原生 UI 33 项、复杂 PDF 218 项、独立结构 32 项和原生兼容 64 项；已检查 macOS 预览显示、两轮保存重开、删除原图片后的独立显示，以及 arm64 / Rosetta x86_64 回归。

Build 19 只冻结发布身份和分发材料，笔迹算法保持 `google-ink-daily-v5`。发布准备另外对导出的公开源码执行核心及图片回归，并只读挂载两份 DMG，核对复制后的完整 App、签名、许可证、架构和版本。新版本尚未运行云端原生 Intel CI；不沿用 Beta 2 的 CI 结果宣称本次通过。

详情见 [可编辑对象](docs/EditableObjects.md) 与 [验证说明](docs/Validation.md)。

---

Editable embedded image annotations, independent shape fill editing, and tiered PDF safety. Paste screenshots, resize/crop/rotate images, write over them, group with ink, and continue editing after saving and reopening. PNG transparency and source resolution are preserved; imported images are normalized to SDR sRGB. Apple Silicon and Intel packages require macOS 13+. This Beta is ad-hoc signed and not Apple-notarized. Actual Intel input, HDR sources and older OS hardware remain further validation items.
