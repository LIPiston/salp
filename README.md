# salp

使用 Flutter/Dart 构建的跨平台终端与远程访问工作台，目标平台为 Linux、Windows 和 Android。当前处于开发阶段，UI 仍会调整。

已实现 SSH、SFTP、Mosh、Telnet、RDP、VNC、桌面本地终端与串口，以及加密凭据、主密码锁定、WebDAV 同步、主机导入、终端规则着色和受控 MCP 工具。各平台的编译、协议互通和设备运行证据不同，不代表全部功能已经完成发布验收。

- [环境、构建与使用说明](apps/salp/README.md)
- [开发和验证进度](docs/verification/flutter-spike/PROGRESS.md)
- [Windows GitHub Actions 工作流](.github/workflows/windows.yml)
- [Nightly 预发布工作流](.github/workflows/nightly.yml)
- [第三方依赖与许可证](apps/salp/THIRD-PARTY.md)

Windows工作流已生成可下载的x64便携开发包，见[已验证构建](https://github.com/LIPiston/salp/actions/runs/45556813920)（ZIP约19.2MB，解压约45.2MB）；Android 当前只构建 arm64 APK。构建缓存、原生二进制和本地测试数据不提交到仓库。旧 Rust 原型不在当前公开源码范围内。

Nightly 每天北京时间 03:17（UTC 19:17，GitHub 调度可能延迟）从 `main` 的最新提交构建 Windows x64 便携包。测试、构建和便携包检查全部通过后，将 `nightly` 分支与固定 `nightly` tag 更新到同一源码提交，并覆盖 [nightly 预发布](https://github.com/LIPiston/salp/releases/tag/nightly)中的 `salp-windows-x64-nightly.zip` 和 `SHA256SUMS`。构建失败时保留上一次成功的预发布。也可在 Actions 的 **Nightly release** 中选择 `main` 手动运行；定时工作流必须保留在默认分支 `main`。`nightly` 分支由工作流维护，不用于独立开发。

salp 使用 [GPL-3.0-or-later](LICENSE)。当前开发包未配置正式发布签名。
