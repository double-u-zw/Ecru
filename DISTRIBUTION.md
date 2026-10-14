# Ecru 分发与源码

Ecru 提供可构建源码与公开 Beta 安装包。第一方源码、文档和项目美术采用 Apache-2.0，见 LICENSE 与 NOTICE；第三方组件保留各自许可证，见 THIRD_PARTY_NOTICES.md、licenses/ 与相应源码目录。

Beta 6（Build 23）面向 macOS 13+ 的 Apple Silicon，提供 arm64 DMG。App 与 DMG 采用 Developer ID Application 签名及 Apple 公证，含已验证的公证票据。发行标签固定安装包对应源码；历史 Intel 包、发行标签和资产保留原有含义，不覆盖或替换。

开发构建显示为 Ecru，但使用独立身份、偏好和恢复目录。构建和测试默认生成工作区候选，不自动安装或替换日常应用。正式发行包不迁移开发版草稿。

构建、测试、签名、公证与发行边界统一见 [BUILDING.md](BUILDING.md)。私有开发 Git 历史、个人文档、恢复数据、私人轨迹及凭据不进入公开源码或安装包。
