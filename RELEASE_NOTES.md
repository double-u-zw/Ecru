# Ecru 0.5.0-beta.3（Build 19）

这次更新让 PDF 不仅能手写，还能直接插入截图、编辑图片和修改已画好的图形。所有新增对象都保存在 PDF 中，重新打开后仍可继续编辑。

## 截图与图片：粘贴后就能调整

- 把系统截图复制到剪贴板，回到 PDF 页面按 **⌘V** 即可插入。也支持从 Finder 或系统截图缩略图拖入，**编辑 → 插入图片**，以及页面右键 **粘贴图片**。
- 支持 PNG、JPEG、HEIC/HEIF 和常见剪贴板图片数据；保留透明通道。不会从剪贴板网络 URL 自动下载图片。
- 普通粘贴放在当前页面可见区域中央；拖入和右键粘贴使用对应页面的位置。图片按比例适配可见区域，插入后自动选中。
- **拖动移动，拖角点等比例缩放。** 选中后的“图片”菜单还提供矩形裁剪、重置裁剪、90° 旋转、复制、剪切、删除、前后层级及位置锁定。
- **裁剪是非破坏式的。** 原图仍保留在 PDF 内，可重置裁剪；反复移动、缩放、裁剪和保存不会重新降低源图分辨率。

### 调整完，继续在图片上写

- 如果插入前使用笔工具，调整后点 **完成**，就会回到此前的笔色、笔宽和压感设置；完成点击不会多画一笔。
- 在图片上直接手写，或用自由荧光笔标记。橡皮只擦除 Ecru 笔迹，不会擦坏图片。
- 笔工具始终优先书写；进入 **选择 / 圈选** 才会选择和移动图片。锁定位置后仍可在上面写字。
- 图片与笔迹默认独立。想一起移动时，圈选图片、笔迹和图形后 **组合**，即可整体移动、等比例缩放或旋转；也可随时取消组合。
- 新图片默认放在已有手写批注下方，后续书写显示在图片上方；需要时可手动调整层级。
- **Esc** 取消当前选择但不删除图片；裁剪过程中按 Esc 取消这次裁剪。

## 已画好的图形：边框和填充分开修改

使用选择工具点击图形，或圈选多个图形，点击 **边框 / 线宽 / 填充** 即可编辑。

填充提供三种明确模式：

| 模式 | 行为 |
| --- | --- |
| 无填充 | 保留边框，内部透明 |
| 跟随边框 | 跟随这一个图形自己的边框颜色 |
| 自定义颜色 | 填充颜色与边框独立 |

填充面板复用常用色、柔和色、最近使用色和自定义颜色；拖动不透明度滑块会实时预览。支持多选统一修改、撤销、重做和保存重开。

修改笔工具颜色不会改变已有图形。编辑选中图形也不会改动以后画图的默认样式；需要沿用时，可明确选择 **对象 → 将当前图形样式设为默认**。历史图形保留原来的实际外观。

## 保存后的 PDF：看得见，也能继续编辑

图片使用标准 PDF 可显示结构，并在 PDF 内保存继续编辑所需的源图片、裁剪、旋转和组合信息。

- **删除原截图后，PDF 里的图片仍完整显示。** 文件不依赖原截图路径或临时缓存。
- macOS 预览等标准阅读器能看到图片、笔迹和图形；Ecru 重开后仍可移动、裁剪、旋转、删除及继续书写。
- 不把整张页面变成图片，保留原 PDF 的可选文字、字体和未修改资源。
- 沿用撤销重做、未保存草稿恢复、外部修改冲突检测和安全保存保护。
- Beta 1 / Beta 2 的历史文档仍可读取。含新图片、填充模式或组合的数据需要 **Beta 3** 继续编辑，旧版本可能进入只读保护。

## 复杂 PDF 的分级保护

- 密码 PDF 可以解锁阅读；加密和签名 PDF 保持只读，不开放写回。
- 普通 AcroForm 表单和附件文档可在保留原结构的前提下保存 Ecru 批注，并检查结构完整性。
- XFA、活动内容、Portfolio 等特殊文件采用受保护的静态阅读；符合条件时，可明确确认结构损失后创建静态批注副本。加密和签名文件不开放这种编辑副本。

详见 [PDF 兼容性说明](https://github.com/double-u-zw/Ecru/blob/v0.5.0-beta.3/docs/PDFCompatibility.md) 与 [图片和图形编辑说明](https://github.com/double-u-zw/Ecru/blob/v0.5.0-beta.3/docs/EditableObjects.md)。

## 原有书写功能保留

Google Ink、真实压感、连续笔宽、停笔图形规整和恢复手绘、倾斜橡皮自动回笔、文字高亮重复取消、自由荧光笔、文字批注及离线 Markdown / 数学公式预览均保留。六工具布局不变，没有新增常驻图片工具。本次没有重新设计手写算法，笔迹 recipe 仍为 `google-ink-daily-v5`。

## 下载与验证

选择适合芯片的安装包：

- **Apple Silicon / M 系列：** `Ecru-0.5.0-beta.3-arm64.dmg`
- **Intel：** `Ecru-0.5.0-beta.3-x86_64.dmg`

两份安装包功能相同，均要求 **macOS 13 或更新版本**。从本 Release 下载 `SHA256SUMS.txt` 后，可运行 `shasum -a 256 -c SHA256SUMS.txt --ignore-missing` 校验下载。历史 Beta 2、历史标签与安装包继续保留。

[本次原生 CI](https://github.com/double-u-zw/Ecru/actions/runs/38276748166) 已通过 **macOS 14 Apple Silicon** 和 **macOS 15 Intel** 的构建、核心回归、图片 / 填充 78 项及安装包生成。对应源码为 `9231496b9dadc5ca5e5341fdcb3795246ce9bf08`，发布标签标记同一冻结源码。

本地另外通过两个架构各 59 项原生窗口检查、复杂 PDF 218 项、独立结构 32 项和原生兼容 64 项；已检查两轮保存重开、原图片删除后的显示、PNG alpha、标准 PDF 图片资源和 macOS 预览显示。两份发布 DMG 只读挂载后，完整 App 文件、架构、源码身份、签名和许可证均已验证。

## 当前限制

- 仍为 Beta。采用 **ad-hoc 签名，尚未经过 Developer ID 签名或 Apple 公证**；首次运行如被 macOS 拦截，按安装说明使用系统的单 App 放行流程。
- 图片转换为完整像素的 **8-bit SDR sRGB PNG**，保留 alpha；HDR 增益图和超出 SDR 的亮度不保留。
- 单图最多 **4000 万像素**、归一化 PNG **24 MiB**，整份可编辑批注数据 **64 MiB**；超限会拒绝插入并保留现有内容。
- 当前采用矩形裁剪、90° 旋转、同页组合，一次文件插入一张图片。跨软件复制提供原图；Ecru 内复制保留可编辑裁剪、旋转和组关系。
- 真实 Intel 输入设备、macOS 13 实机、真实 HDR 来源、混合 DPI 多屏和长期手写负载仍需更多反馈。CI 和合成事件不代表真实设备手感。
- 没有 OCR，也没有自动更新。

反馈时请附版本、macOS、芯片、输入设备和复现步骤：[提交问题](https://github.com/double-u-zw/Ecru/issues/new/choose)。

---

**Editable images and independent shape fills.** Paste screenshots into PDF pages, move and proportionally resize them, crop non-destructively, rotate, lock or group them with ink. Write over images and return to your previous tool when adjustments finish. Images and editable geometry are embedded in the PDF, so they remain visible in standard readers and editable in Ecru after reopening. Shape borders and fills can be changed independently. Native Apple Silicon and Intel CI passed; separate DMGs require macOS 13+. This Beta is ad-hoc signed, not Apple-notarized; images are normalized to SDR sRGB. Beta 2 and historical releases remain unchanged.
