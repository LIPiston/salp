# salp · Flutter/Dart

正式重建入口为此目录，目标是 Linux、Windows、Android。旧 Rust 源码保留作历史参考，不参与这里的构建。当前仍在开发，平台编译、真实协议测试和设备运行是不同层级的证据；完整状态见 [PROGRESS](../../docs/verification/flutter-spike/PROGRESS.md)。

## 环境与运行

当前验证版本：Flutter 3.50.1、Dart 3.14.0。`tool/run.py` 默认复用 `~/.local/share/salp-flutter-spike` 中的隔离工具与 pub 缓存，可通过 `SALP_TOOLCHAIN` 指定；没有隔离工具时使用 PATH 中的 Flutter。Linux 需要 GTK3、libsecret、CMake、Ninja、C/C++ 编译器，RDP 使用 FreeRDP 3 / WinPR 3，串口使用 libserialport。运行时需要解锁的 Secret Service；无法取得保险库密钥时不会创建明文替代文件。

在仓库根目录运行：

```sh
python3 apps/salp/tool/run.py flutter pub get
python3 apps/salp/tool/run.py flutter run -d linux
python3 apps/salp/tool/run.py flutter analyze --no-pub
python3 apps/salp/tool/run.py flutter test --no-pub
python3 apps/salp/tool/verify_ssh.py
dbus-run-session -- xvfb-run -a -s "-screen 0 1280x844x24" python3 apps/salp/tool/verify_desktop.py
python3 apps/salp/tool/measure.py linux-release python3 tool/run.py flutter build linux --release
```

Linux 产物 `build/linux/x64/release/bundle/` 需要整个目录。它动态链接本机 GTK、Secret Service 和 FreeRDP 依赖，并非独立静态可执行文件。

## Android arm64

复用 Android SDK 36、NDK 28.2.13676358，最低 Android API 24。原生 FreeRDP/OpenSSL 构建需要现有 CMake、Ninja、Make、Perl，脚本不会安装系统包：

```sh
python3 apps/salp/tool/build_android_rdp.py
python3 apps/salp/tool/measure.py android-arm64 python3 tool/run.py flutter build apk --release --target-platform android-arm64
python3 apps/salp/tool/storage.py
# 已启动独立模拟器时，可运行：
python3 apps/salp/tool/verify_android.py --serial emulator-5580
python3 apps/salp/tool/verify_android_saf.py --serial emulator-5580
python3 apps/salp/tool/verify_android_lock.py --serial emulator-5580
```

原生脚本下载固定版本、验证 SHA-256、用两个作业编译并裁剪动态库，输出 `android/app/src/main/jniLibs/arm64-v8a/`。编译缓存、源码与压缩包均复用隔离目录；脚本支持 `--jobs` 和 `--rebuild-openssl`。源码哈希及产物清单见 [native/android-sources.json](native/android-sources.json)。三个库按 16 KiB 页面对齐，OpenSSL 静态链接，未启用设备/音视频重定向。

APK 为 `build/app/outputs/flutter-apk/app-release.apk`，当前使用开发签名。已在 Android36 模拟器通过 arm64转译验证凭据重启保存、RDP证书/画面/键盘/触控、SAF实际文档流与进程死亡恢复、系统锁屏。真实Android设备、第三方文档提供器和Windows/xrdp认证仍待完成，不能当成发布验收。Windows CI 已完成原生构建和运行检查，下载见下节。

## Windows x64（GitHub Actions）

仓库推送到 GitHub 后，`.github/workflows/windows.yml` 会在 Flutter 项目变更时运行，也可在 Actions 手动触发。使用 windows-2022 runner，固定 Flutter 3.50.1、vcpkg 提交及原生源码哈希，不需要在你的 Windows 系统安装开发环境。工作流先跑静态分析/测试，再进行原生凭据与PowerShell终端流程，最后构建正式入口并检查便携目录的 DLL 加载和首帧窗口。

已验证的[第9次构建及产物](https://github.com/LIPiston/salp/actions/runs/45556813920)提供约19.2MB ZIP、解压约45.2MB（包括许可和源码）。

成功后下载 `salp-windows-x64-<运行编号>` artifact，解压其中 ZIP 并保留整个目录，运行 `salp.exe`。开发包未签名；`build-info.json` 记录工具/依赖版本与目录体积，`windows-smoke.json` 记录原生加载和启动检查。日志 artifact 保留14天。Windows SSH agent 命名管道仍在开发，桌面锁定/实际RDP服务端/硬件需要后续运行验证。

`tool/build_windows.ps1` 是同一构建入口：Windows 本机构建需要 Visual Studio 2022 C++ 桌面组件、Flutter、Git、Python 和固定版本 vcpkg；工作流提供这些依赖。FreeRDP/WinPR 使用 vcpkg 的3.32.2版本，与Linux/Android当前3.33.1不同，核心API相同但Windows互通仍待CI与实机证明。串口库0.1.2源码和所有原生许可、当前应用源码归档随开发包分发。

工作流已通过 actionlint 和 PowerShell 解析检查，Windows的最新构建结果以仓库Actions为准。已验证构建d2304d7：74普通测试通过/23条件跳过，原生凭据与PowerShell流程通过，Release便携DLL加载和窗口首帧通过。系统锁屏、实体串口、实际Windows/xrdp远端认证仍待验证。

## 桌面 MCP

从侧栏“MCP代理”启动，默认127.0.0.1随机端口；每个agent独立密钥与主机范围。非回环IP需要确认明文风险，通配绑定必须填写实际访问主机名/IP；Host与Origin使用精确允许列表。密钥仅放Authorization请求头。

专用终端支持SSH/Mosh；SSH另有exec命令和SFTP文件工具。智能模式仅结构化读取自动通过，所有通用命令/原始输入/文件变更需逐次审批。命令输出有界分页且不可信；文件工具只处理远端路径，读写单次64KiB、拒绝覆盖。锁定/撤销/上下文变化后未发送动作失效，已发送操作不保证撤回，也不自动重试。

审计仅含操作元数据，本机加密保留7天、总量约20MiB；每轮上限1MiB，达到上限或写入不可用时拒绝新动作。审计入口可查看；有开始记录而无结果意味着操作结果未知。批量移动/删除一次审批最多100项，首个失败后停止；分块上传最多64MiB，固定目标/长度/SHA-256、严格顺序，读回校验后提交；锁定后旧上传失效。覆盖选项仍在开发。

桌面串口参数可在串口对话框命名保存、载入和删除；配置仅本机加密保存，设备路径不参与同步。

## 数据与许可证

凭据随本地保险库加密保存，密钥保存在系统安全存储中；`SALP_DATA_DIR` 只供隔离验证使用。正常编辑通过串行事务：落盘成功后才更新可见配置。WebDAV 额外使用主密码保护数据密钥；连接密码不明文上传。终端日志需显式开启且仅在本地加密保存。同步界面可预览并恢复上次同步前的双方备份，验证主密码后仅替换本地同步记录；恢复前版本保留用于撤销，远端修改仍需下一次同步预览。

salp 使用 GPL-3.0-or-later，见仓库根目录 LICENSE。Flutter 自动收集 Dart 包许可证，原生 FreeRDP/WinPR 与 OpenSSL 许可证也随应用提供，可从设置的“第三方许可证”查看。[THIRD-PARTY.md](THIRD-PARTY.md) 记录原生来源和已修改的 Dart 依赖。分发完整应用仍须提供对应源码及构建说明；目前未执行发布。

验证WsgiDAV产品端（仅测试依赖，不进入应用）：在隔离工具目录创建webdav-verify虚拟环境，安装tool/webdav-requirements.txt，运行 `python3 apps/salp/tool/verify_webdav.py`。该流程验证认证、条件写入、加密合并与恢复；上传断电与原子替换仍待验证。

真实VNC验证：`python3 apps/salp/tool/verify_vnc.py` 复用隔离工具目录中的TigerVNC，创建临时loopback服务、GTK桌面与OpenSSH跳板，验证错误密码、精确像素、键鼠及锁定阻断。工具要求已有GTK Python绑定、xdotool、xauth与OpenSSH；未安装系统包，未启动公网监听。
