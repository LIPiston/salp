# Flutter 重建依赖说明

本文件仅对应 `apps/salp`；根目录原有依赖清单为历史 Rust 实现。应用采用 GPL-3.0-or-later。

- Flutter 3.50.1 / Dart 3.14.0：BSD 系列许可证及其引擎第三方通知由 Flutter SDK/产物提供。
- Dart 包的准确版本以 `pubspec.lock` 为准。Flutter 打包时自动收集 `LICENSE`，设置中的许可证页展示相关文本；这不替代分发对应源码的要求。
- 本地修改的 `dartssh2` 4.1.0：MIT，保留上游 LICENSE，变更见 `third_party/dartssh2/SALP_PATCH.md`。
- 本地修改的 `xterm` 4.0.0：MIT，保留上游 LICENSE，变更见 `third_party/xterm/SALP_PATCH.md`。
- 本地修改的 `dart_mosh` 0.0.4：Apache-2.0，保留上游 LICENSE，变更见 `third_party/dart_mosh/SALP_PATCH.md`。
- FreeRDP / WinPR 3.33.1：Apache-2.0，上游来源 `https://github.com/FreeRDP/FreeRDP/tree/3.33.1`。Android 打包核心协议库；Linux 使用系统动态库。许可文本 `assets/licenses/FreeRDP.txt`。
- OpenSSL 4.0.1：Apache-2.0，上游来源 `https://github.com/openssl/openssl/tree/openssl-4.0.1`，静态链接到 Android FreeRDP/WinPR 库。许可文本 `assets/licenses/OpenSSL.txt`。
- FreeRDP/OpenSSL 源码下载地址、SHA-256、Android 产物 SHA-256 由 `tool/build_android_rdp.py` 写入 `native/android-sources.json`。Android WinPR 有一处私有目录适配补丁（`native/patches/android-private-path.patch`，SHA-256 记录在清单）；OpenSSL 未修改，构建选项保留在脚本中。对应压缩包位于隔离工具目录 `native-src`。
- Linux nightly 私有目录包含固定 FreeRDP 3.33.1、Ubuntu 22.04 的 OpenSSL 3 与 libserialport 动态库，并携带许可及 FreeRDP/应用源码。GTK3、GLib、libsecret、libudev 和 zlib 由发行版或 Flatpak runtime 提供；这些系统库不复制到应用目录。直接本地 `flutter build linux` 仍链接本机依赖。

Android APK 仅用于开发验证，尚未配置发布签名；Windows工作流已成功构建/启动开发包；完整公开发布分发清单仍需最终复核。

Windows CI 原生依赖由 `native/windows/vcpkg.json` 固定到vcpkg提交7281d8d64321f945f296e696d8561f68c8186c67，FreeRDP/WinPR版本3.32.2。它依赖的OpenSSL/cJSON/zlib版本以构建产物build-info.json的vcpkg状态清单为准；端口copyright随包复制。libserialport为LGPL-3.0-or-later，固定0.1.2标签对应提交bc8f88ef3399b76da7992a99badebada419d0e19，动态链接且完整未修改源码/COPYING随包提供。上游MSBuild宏版本字符串仍为0.1.1，不用它判断源码版本。Windows还打包Visual Studio可再分发CRT DLL，最终公开发布前需核对微软分发条件与全部通知。

已验证Windows构建d2304d7：OpenSSL3.6.5（vcpkg port-version2）、cJSON1.7.19、zlib1.4；上述依赖的实际copyright随包提供，Windows未附带Java/JNI。
