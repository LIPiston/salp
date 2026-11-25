# salp

使用 Flutter/Dart 构建的跨平台终端与远程访问工作台，目标平台为 Linux、Windows 和 Android。当前处于开发阶段，UI 仍会调整。

已实现 SSH、SFTP、Mosh、Telnet、RDP、VNC、桌面本地终端与串口，以及加密凭据、主密码锁定、WebDAV 同步、主机导入、终端规则着色和受控 MCP 工具。各平台的编译、协议互通和设备运行证据不同，不代表全部功能已经完成发布验收。

- [环境、构建与使用说明](apps/salp/README.md)
- [开发和验证进度](docs/verification/flutter-spike/PROGRESS.md)
- [Windows GitHub Actions 工作流](.github/workflows/windows.yml)
- [第三方依赖与许可证](apps/salp/THIRD-PARTY.md)

Windows工作流已生成可下载的x64便携开发包，见[已验证构建](https://github.com/LIPiston/salp/actions/runs/45556813920)（ZIP约19.2MB，解压约45.2MB）；Android 当前只构建 arm64 APK。构建缓存、原生二进制和本地测试数据不提交到仓库。旧 Rust 原型不在当前公开源码范围内。

salp 使用 [GPL-3.0-or-later](LICENSE)。当前开发包未配置正式发布签名。
