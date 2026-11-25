# Flutter 重建进度（2026-11-25，持续开发中）

用户目标为完整可用，尚未完成；Linux/Windows/Android 为首发平台。不编译旧 Rust。
项目依赖由代理安装；新系统包先告知。已授权 NDK 28.2、Gradle/Android 构建缓存和 arm64 APK。

## 已接入并有测试证据

- 主机编辑、分组搜索、标签；桌面横/纵分屏与拖动调整。
- SSH 私钥、密码、keyboard-interactive；Linux ssh-agent 真实认证（Windows agent 命名管道待补）。
- 主机密钥显式确认后重新连接；变更阻断；2 跳 + 目标；本地、远程、SOCKS5 隧道。
- 真实 Mosh UDP 输入；Telnet 编解码与 TCP 生命周期；真实 PTY UTF-8/resize。
- SFTP 字节文件名、不覆盖提交、队列/取消/重试；100文件已逐字节验证；Android SAF 系统文档提供器流式写入、冲突、取消和进程死亡临时文件恢复已实测。
- 系统密钥库保护本地加密保险库；可选启动验证、主密码、锁定代次。旧终端查询和 SFTP 预览不能在解锁后复活。
- WebDAV 主密码封装随机数据密钥、AES-GCM 数据加密、Argon2id、强 ETag 条件写入、服务器条件行为探针、三方合并与冲突界面、同步前加密双方备份、主密码封装迁移。
- OpenSSH 配置导入；不支持的ProxyCommand路由整项跳过；选定目录范围的顶部Include可展开，条件Include仍拒绝。WindTerm/NyaTerm JSON 为有限字段导入，真实导出兼容性待核对。
- 片段搜索/编辑/预览粘贴；会话日志显式开启、逐条加密、单份 16 MiB、7 天清理、只在本地。
- 串口 libserialport FFI 与设置界面，已验证枚举/错误处理；实体设备未测试。
- MCP 本机 HTTP 认证、Host/Origin、agent 范围、专用 SSH/Mosh 标签、逐次/智能/YOLO、精确字节审批、撤销和锁定连续性；真实 MCP→SSH 交互通过。
- VNC RFB 3.3/3.7/3.8，传统密码认证、Raw/CopyRect/DesktopSize、内嵌画面、键鼠、SSH 跳板。受控协议测试与真实TigerVNC直连/SSH跳板、OS键鼠及10轮重连通过。
- Linux RDP FreeRDP 原生桥接，工作线程、TLS/证书确认、内嵌帧、键鼠、SSH 跳板；真实 FreeRDP 示例服务器证书/800×600帧、Dart1280×720帧和锁定/关闭通过。
- Linux/Windows 系统锁屏通知桥接已写入；Linux 原生 D-Bus 通知→应用锁定和系统解锁已实测。

## 2026-11-25 本轮新增证据

- 可复现 Android 原生脚本补全 OpenSSL 下载/哈希/编译；FreeRDP3.33.1 + OpenSSL4.0.1 来源与产物清单、许可证随应用打包。
- Linux release 37.015 秒；Android arm64 增量 release 2.412 秒、约 34.7 MB（开发签名），均为本轮实际构建。Flutter 3.50.1 的 `--no-pub` 可能保留测试插件注册文件，release 构建改用默认元数据刷新。
- 完整普通测试 57 通过、16 明确跳过；OpenSSH fixture 14 通过（含 100 文件下载逐字节比较、Mosh 锁定队列、MCP）；原生 Linux 集成流程 1 通过。并非全部平台验收。
- 新增 `tool/verify_desktop.py` / `integration_test/desktop_flow_test.dart`。D-Bus、密钥库、数据目录均隔离，键盘通过 xdotool 送入真实 Flutter 窗口与 PTY。
- Ruling: 用户已明确 UI 视觉修改不急，后续可交付 Figma、截图或 HTML/CSS 原型；当前继续功能和稳定性，不设视觉设计审批门槛。
- 复用已有 Android36 x86_64 镜像与 arm64 转译运行 arm64 release APK。凭据保存后 force-stop/restart、RDP 证书指纹核对、1280×720 帧、系统输入文字、Ctrl-C 扫描码、触控事件与进程结束后的空会话恢复通过；`tool/verify_android.py` 可复验，详见 `android-runtime.json`。不等价于物理 arm64 真机证据。

## 新发现并修复的重要问题

1. 不支持的 OpenSSH 路由被降级为直连：整项拒绝导入。
2. 解锁时缓存 DSR 查询触发新输入：渲染缓存期间保持输入锁定。
3. SFTP 预览锁定后解锁仍返回旧数据：绑定操作代次。
4. SSH/PTy 的 Uint8List 流在 UTF-8 解码运行时类型失败：显式 cast<List<int>>()。
5. SSHSession.flush 与通道写入竞争导致 StreamSink bound：终端走专门 writeGuarded，窗口等待期间重新校验授权，无无限期 stdin 排队。
6. MCP 已批准输入等待窗口后仍可能在撤销后发出：授权回调贯穿 InputGate 和逐包写入。
7. 仓库失败回滚可污染后续成功保存：全部运行时修改迁入串行、独立草稿事务；落盘完成才发布内存状态，锁定前提交前重检。
8. Mosh 锁定后发送尚未发出的命令：真实 mosh-server 复现并修复，丢弃未发送后缀，初次发送重检审批；已发状态保留协议重传且不承诺撤回。
9. 未设主密码时 OS 锁屏不阻断应用：原生通知贯穿锁定；无主密码仅 OS 解锁恢复，有主密码必须再次应用验证。
10. 系统快速输入将 `pri` 发送为重复前缀：xterm 改用 DeltaTextInputClient，真实键盘→PTY 与中文组合增量测试通过。
11. 并发 MCP 连接可超过16个：预留连接槽位，真实 HTTP 重现17→16。
12. SFTP 不响应永久挂起/关闭等待：15秒握手/请求超时关闭该文件通道，关闭本地立即完成，错误明确结果可能未知。
13. 私钥整份读取后才限大小、锁定后旧文件选择仍返回：流式限额与代次/窗口有效性检查。

14. Android FreeRDP 初始化错误0：WinPR 在 Android 没有桌面 HOME，改为读取应用专用 SALP_RDP_PRIVATE_DIR，ConfigPath 指向私有目录；已在 APK 实测证书与帧。
15. RDP/VNC 无软键盘：共享增量输入组件，组合文本提交一次；关输入连接时丢弃 composition，锁定后新按键不受旧组合状态阻塞。Ctrl/Alt/Meta 组合键使用 RDP 扫描码，补充 Unicode 代理项；真实 RDP 服务端确认收到。
16. 800×600 下侧栏与设置内容溢出：短窗口侧栏可滚动，设置对话框启用内容滚动；功能可达性测试通过，视觉改版仍待后续设计。
17. SFTP 文件选择器跨锁定后仍排队：捕获会话代次与目录，上载/下载/新建/重命名/删除的异步确认返回后重检；真实 SFTP + 延迟原生选择器返回测试先失败后通过。

18. Android SAF 进程死亡留下正式名半成品：唯一临时文档+持久化恢复记录；启动只清理临时名，提交结果不明保留最终文件并提示。150000字节比对、保留双方、取消、后到冲突、强杀重启均通过。关闭 Android 自动备份，避免本地存储/恢复记录被复制到其他设备。
19. Android 文件选择器触发后台锁导致编辑器关闭：PlatformFiles 标记应用发起的选择，后台锁保留正常文件选择；原生 SCREEN_OFF/USER_PRESENT 独立触发锁定。实测选择器保持、选择期间关屏锁定、系统解锁仍要求主密码。

## 仍需完成，不得称完整支持

- Android FreeRDP/OpenSSL arm64 已构建打包，只有 arm64 库、API 24+、16 KiB 对齐；模拟器运行已验证，真机与实际 Windows/xrdp 仍待测。Windows原生DLL、Debug/Release应用已在Actions编译，凭据/PowerShell集成流程通过；便携DLL加载和首帧启动已通过，agent命名管道仍缺。
- 终端规则着色已实现（跨换行、中文、ANSI 颜色保留、正则隔离超时）；按主机覆盖/继承已接入并实测保存；实际视觉确认仍待完成。
- MCP已补结构化exec/SFTP、监听配置和元数据审计；64MiB分块上传和批量移动/删除已接入；覆盖选项仍待补，单块最多64KiB、拒绝覆盖。
- VNC TigerVNC直连/SSH跳板已通过，Android 真实中文 IME（组合逻辑已有测试，系统英文输入与触控已验证），RDP 真实 Windows/xrdp，远端分辨率主动协商、断线重连压力测试。
- Android SAF 真机/第三方文档提供器待测；系统文档提供器进程死亡清理已验证；≥100 文件下载已实测；SFTP 超时与关闭已验证，取消压力及符号链接竞态仍待处理。
- 同步真实WsgiDAV产品端已通过；断电/上传中断仍待补；加密备份恢复与撤销已接入并在Linux原生验证；事务持久化已落地，Windows 文件替换仍待实机验证。原子 PUT 依赖服务器规范保证，目前只验证条件响应。
- 导入Include用户范围展开已加入，条件Include与真实WindTerm/NyaTerm导出格式仍待补；串口配置持久化已完成，硬件证据仍缺。
- 高级日志脱敏/保留期设置，敏感操作再认证类别开关。
- Linux 已验证原生 ScreenSaver 信号→应用锁定/系统解锁、系统密钥库→保存→重新读取、系统键盘→PTY。实际桌面锁屏器（含 login1）、全界面布局/输入法、Windows 与 Android 真机运行仍待验证。
- 发布签名与全部依赖许可证/分发清单。现有 APK 为开发签名，未发布。

## 检查命令

```sh
python3 apps/salp/tool/run.py flutter analyze --no-pub
python3 apps/salp/tool/run.py flutter test --no-pub
python3 apps/salp/tool/verify_ssh.py
python3 apps/salp/tool/verify_android.py --serial emulator-5580
dbus-run-session -- xvfb-run -a -s "-screen 0 1280x844x24" python3 apps/salp/tool/verify_desktop.py
SALP_PTY_FIXTURE=1 LD_LIBRARY_PATH="$PWD/apps/salp/build/linux/x64/release/bundle/lib" python3 apps/salp/tool/run.py flutter test --no-pub test/pty_integration_test.dart
cmake -S apps/salp/native -B apps/salp/build/native-rdp -DCMAKE_BUILD_TYPE=Release
cmake --build apps/salp/build/native-rdp -j2
WLOG_LEVEL=OFF python3 apps/salp/tool/verify_rdp.py
python3 apps/salp/tool/measure.py linux-release python3 tool/run.py flutter build linux --release
python3 apps/salp/tool/measure.py android-arm64 python3 tool/run.py flutter build apk --release --target-platform android-arm64
```

资源基线与增量见 `baseline.json`、`storage.json`，构建结果为同目录 `linux-release.json`、`android-arm64.json`。测试普通命令有明确跳过，真实协议/PTY/RDP 由独立 fixture 命令运行。截图只证明实际窗口捕获，尚未完成视觉验收。

### 最新检查补充（本轮继续）

- 普通测试57通过、16个按条件跳过；真实 SSH/SFTP/Mosh/MCP 14通过；RDP桥接+真实Unicode/组合键服务端事件通过；Linux原生应用链路1通过。静态分析无问题。
- 正式入口已恢复；Linux release37.015秒，Android arm64增量release2.412秒、34662538字节（34.7MB），仅arm64库。时间为缓存条件下实际运行，非冷构建。
- Android SAF/锁屏测试使用独立临时入口，脚本finally自动恢复正式入口APK。正式APK已重新安装并完成RDP运行复验。

- 本轮新增项目工具 `verify_android.py`、`verify_android_saf.py`、`verify_android_lock.py`；不安装系统包，复用已有模拟器镜像。最新磁盘增量约9.79 GiB，其中AVD约2.00 GiB，详见storage.json；共享Gradle缓存可能混有其他活动。

## MCP 结构化操作与生命周期补充

- 已接入独立SSH exec和SFTP stat/list/read/write/mkdir/rename/remove。每个代理会话命令上限16，stdout/stderr总保留256KiB、独立分页游标；文件读写单次64KiB、原始字节路径，不接受本地文件路径，写入临时文件后不覆盖提交。
- 智能模式只有显式结构化读取免审批；通用命令与变更绑定精确JSON输入、代理/主机/会话/锁定代次。真实OpenSSH验证写入/冲突/移动/删除、输出/退出码/截断，以及锁定解锁后旧审批不能写入。
- 本机元数据审计逐条加密并flush；只含请求ID、服务端代理/主机ID、操作、审批者、结果与耗时。命令、路径、内容、密钥不落审计。每轮1MiB，7天、约20MiB总量；满额或文件被删后拒绝新动作，重启创建新日志。停止期间未完成请求保留started为结果未知。
- MCP可配置IP/端口、精确Host与额外Origin；非回环必须在应用内确认明文风险。默认回环，通配监听必须显式提供访问地址；允许列表按启动周期隔离。
- 修复SFTP超时不包含SSH窗口等待、关闭时未监听reply错误；修复SSH通道打开/exec/subsystem回复无期限等待，迟到通道不再补发命令。真实OpenSSH延迟输入验证命令未执行且原连接仍可用。
- 修复MCP启动后停止仍产生监听器、旧审批写入新审计文件；stdout/stderr分页独立推进，避免跳过迟到输出。
- 普通测试65通过、19条件跳过；真实SSH/SFTP/Mosh/MCP17通过；Linux原生凭据/PTY/锁屏/MCP界面启停1通过，静态分析无问题。非回环测试只在受控本机请求，无公网部署。
- Ruling: MCP文件初版直接以base64传递有界字节，不开放任意本地路径；大型暂存与批量操作继续实现。结果未知的写入不自动重试，可能保留远端.part。

## 同步备份恢复与并发补充

- 同步界面可恢复同步前的本地/远端版本，也可撤销最近一次恢复。预览仅列新增/修改/移除及名称，默认隐藏凭据和片段正文；提交验证当前主密码、锁定代次及预览时数据/备份状态。
- 恢复在同一加密仓库事务中保存恢复前版本，只替换主机/凭据/片段；主机密钥信任、MCP授权、同步base/endpoint保留，下一次上传仍需重新预览。备份增加生成时间与来源。
- Linux原生界面实测：设置→同步→恢复→主密码→提交→系统密钥库重新打开仓库，恢复数据、原凭据与undo快照均正确。
- 修复跨服务实例同步与主密码变更并发：仓库统一互斥同步/恢复/密码迁移；预览绑定验证器与同步历史，密码改变后旧预览不得发起上传。受控HTTP等待回归先失败后通过。
- 最新普通测试68通过、19条件跳过；真实SSH/SFTP/Mosh/MCP17通过；Linux原生链路1通过；静态分析无问题。完整可用目标仍在进行，平台/真实远端产品/批量MCP等缺项未豁免。

## 串口配置与MCP批量补充

- 桌面串口可命名保存、载入、确认覆盖及删除参数；最多100份，设备路径和参数经验证，使用本机加密仓库事务，不同步、不暴露给MCP。真实Linux界面保存、重开仓库与再次载入通过；未连接实体串口。
- MCP `sftp_batch` 对1–100个精确移动/删除目标作一次审批，移动拒绝覆盖，删除不递归。按序执行，错误返回已完成数量与失败索引，并停止后续项目；锁定仍阻断数据返回与新发送，不自动重试。真实OpenSSH验证第二项冲突后第三项删除不执行。
- 最新普通测试70通过、19条件跳过；真实SSH/SFTP/Mosh/MCP17通过；Linux原生链路含串口配置/同步恢复/MCP启停1通过；静态分析无问题。Windows环境已异步询问，其他可独立开发的事项继续推进。
- Ruling: 串口配置以本机加密记录保存，不同步设备路径；跨设备端口名无可移植含义。MCP批量移动初版固定不覆盖，覆盖选项与大文件暂存仍待补。

## 真实WebDAV、按主机规则与分块上传

- 新增隔离项目验证环境WsgiDAV4.3.3+Cheroot11.1.2，约21MiB，固定依赖见tool/webdav-requirements.txt；未安装系统包。tool/verify_webdav.py使用loopback临时认证目录，验证失败密码、双方加密同步、过期ETag冲突保护、备份恢复不修改远端和探针清理。1条真实产品端流程通过。
- WsgiDAV暴露探针chunked请求在412之后复用连接broken pipe；改为固定Content-Length=32，实测失败→通过。WsgiDAV上传断电/截断及原子覆盖仍未验证，不能由ETag测试推导。
- 全局/按主机着色：主机菜单及终端菜单可配置继承或覆盖；仅本机保存。规则隔离/持久化/恢复继承、Unicode/ANSI/超时测试通过；Linux原生添加规则→保存→重开仓库通过。视觉质量仍待后续UI交付。
- 片段按“分组 / 名称”现有命名格式筛选，兼容旧记录；选择片段预览保留精确内容及换行。无额外自动回车。
- MCP分块上传：每会话最多4份、每份最多64MiB、15分钟有效，开始声明路径/长度/SHA-256，每块最多64KiB且严格顺序、每块精确审批；结束读回远端临时文件核对长度和SHA-256（最多10分钟）后不覆盖提交。锁定代次/输入/连接变化使旧上传失效；需显式取消临时文件，不自动重试。撤销或关闭不擅自发远端清理动作，可能留下.part。
- 真实OpenSSH验证150000字节逐字节一致、错误摘要拒绝、同长度远端篡改拒绝、锁定解锁后不能续传。校验到rename间无法排除远端特权进程竞态，不宣称远端内容不可变。
- 最新普通测试73通过、20条件跳过；OpenSSH/Mosh/SFTP/MCP17通过；WsgiDAV产品端1通过；Linux原生链路1通过。构建与报告正在刷新，完整可用目标未完成。

## OpenSSH Include与资源上限补充

- 桌面导入可选择Include允许目录；顶部Include按顺序/通配排序展开，相对路径和~/以选定目录为根（常规选择.ssh）。总读取4MiB、最多128文件、深度16；拒绝范围外真实路径、符号链接越界、循环、变量和条件Include。不执行任何配置命令。Android仍只解析所选单文件，条件Include/原生目录选择器尚未完整验收。
- 解析排序/拒绝越界/锁定失效和界面“选择范围→预览→提交”测试通过；界面测试的系统选择器为文件插件替身，真实文件读取和加密落盘，无实际桌面选择器端到端证据。
- Ruling: MCP分块上传初版上限调整为64MiB，使单次满块上传约1024调用能够纳入1MiB审计容量；其他调用仍消耗审计额度，满额时明确停止，不保证无视已有审计占用的大文件完成。每块审批策略仍保留。原256MiB实现上限已替换，不应当成可用承诺。

## Windows CI与真实VNC补充（2026-11-25）

- 用户有Windows双系统，优先GitHub Actions，暂不要求切换或安装Windows开发环境。新增.github/workflows/windows.yml、tool/build_windows.ps1：固定Flutter/vcpkg/串口源码，Release-only原生依赖缓存，两并发作业，Flutter普通测试和Windows原生凭据/PowerShell输入锁定集成流程，正式release入口及便携ZIP。包内含DLL、许可、libserialport源码、当前应用源码和构建版本/体积清单。
- Windows运行检查使用清理后的PATH，加载便携目录全部DLL、枚举串口并启动正式exe观察首帧窗口。该脚本必须由Windows runner执行；Linux只完成actionlint、PowerShell AST解析、Python编译和共用RDP配置的Linux编译/协议回归。当前无Git远端，无云端构建、Windows运行成功证据；已一次性询问仓库地址。
- Ruling: Windows先选择x64便携开发包，用vcpkg固定FreeRDP3.32.2（Linux/Android3.33.1），以减少手工工具链配置；本机不新增系统包。若该版本平台差异导致互通问题，CI及Windows真实协议验证必须暴露并修复，不能仅由本地检查推定成功。
- 真实TigerVNC1.16.2-6 + GTK + OpenSSH测试通过：错误密码拒绝；直连与SSH跳板均640×480、红蓝像素精确；OS键鼠事件到达GTK；锁定时发送的键和点击未到达，解锁后marker正常。仅生产VncSession协议证据，不声称Flutter界面视觉验收。初次GTK继承Wayland导致窗口落在当前桌面，fixture已强制GDK_BACKEND=x11并重跑通过；临时服务均关闭。
- Android最新正式APK模拟器复验通过，SHA256 0a8e185698224265b6eb64a57443c20b849a9d4a0ae4dca3a57b75080573972a；凭据重启保存、RDP证书/画面/输入/触控通过。仍为x86_64模拟器arm64转译，非真机。
- 最新普通测试75通过、21个条件跳过；静态分析无问题；真实VNC1通过；FreeRDP样例原生桥接和Dart1通过。Windows脚本检查工具仅解压在隔离目录中，新增占用计入storage.json，不修改系统包。

## 公开仓库与首轮Windows执行

- 已按用户授权用gh创建公开仓库https://github.com/LIPiston/salp，首提交d6a7e2f，仅含Flutter应用/测试/构建工作流/许可证/说明，共368文件；旧Rust源码、密钥、日志、缓存和APK未提交。后续Windows构建修正继续提交同一范围。
- Windows首轮45548777813实际编译FreeRDP/WinPR和salp_rdp/libserialport成功、静态分析通过；普通测试73通过/22条件跳过/1失败，失败是测试删除活动审计日志在Windows报sharing violation（Windows本身阻止删除），未进入Flutter原生集成/正式包阶段。
- 测试改为Windows断言删除被系统拒绝、文件保留且下一次动作写入审计；POSIX仍断言成功删除后阻止动作。缓存保存改为即使后续测试失败也保留已完成原生包，减少重复下载编译。下一轮CI是这次修复的Windows证明。
- RDP新增真实OpenSSH跳板链路：证书、帧、输入及锁定均通过；仍为FreeRDP样例端，不代替Windows/xrdp NLA互通。
- 本机总增量约10.08GiB（包含已授权SDK/NDK/缓存、模拟器、项目工具），详见本地storage.json。Windows构建发生在GitHub runner，不占本机原生依赖缓存。模拟器验证后已关闭。

- Windows第二轮45550131580：审计文件删除保护测试已通过；容量压力测试（上千次真实HTTP+逐条加密flush）超过默认30秒，其他73测试通过。仅该压力测试上限调整为2分钟，继续验证；已保存Flutter和原生二进制缓存。
- RDP拒绝证书实测不建立桌面；TigerVNC额外10轮直连/SSH跳板交替重连逐轮画面和OS输入通过。普通Linux75通过、22条件跳过。

- Windows第三/四轮普通74通过、23条件跳过，Debug构建通过，原生流程停在PowerShell marker；CRLF尝试未解决。第五轮采集到PowerShell在提示符前退出，插件默认环境缺少SystemRoot等Windows变量；生产openLocal改为Windows显式继承当前环境。第六轮45554894604原生凭据/UI/串口枚举/PowerShell命令/锁定输入阻断通过，Release也编译成功。
- 第六轮便携DLL加载发现dartjni.dll依赖runner系统Java。JNI来自Android文件选择器的间接依赖，桌面不用JVM；Windows CMake禁用JNI探测，下一轮以隔离DLL加载复验。工作流拆分原生依赖、测试、Release打包三步方便观察。

## Windows首个全绿便携构建

- 公开仓库：https://github.com/LIPiston/salp 。成功run45556813920 / commit d2304d72c4e46858dc250b11892cbe5d93f4323a：https://github.com/LIPiston/salp/actions/runs/45556813920 。第9次触发中有1轮被新提交自动取消，前述故障逐一记录，没有跳过失败门槛。
- Windows普通测试74通过、23条件跳过；原生界面保存主机→系统安全存储重新读取加密凭据→串口枚举→PowerShell真实文件写入→锁定输入无副作用通过。最终测试使用应用实际的单CR Enter，CRLF尝试已撤回；实质修复为保留Windows运行环境。
- Release便携包在去除开发工具PATH后加载全部随包DLL、验证RDP导出/串口枚举、启动正式exe并观察Flutter首帧通过。禁用Windows JNI，避免从runner JDK引入jvm.dll依赖。Python环境键使用Windows大写SYSTEMROOT，先前验证脚本大小写错误已修复。
- ZIP 19186136字节，解压45211046字节（含许可、libserialport完整源码、应用源码归档），SHA256 6e81a6efa7d13c713a021bf3ad9deb0ec580f5ef2a7e0644c3926534d6666345。已下载检查ZIP CRC、文件清单和CI哈希一致，artifact保留14天；不是正式签名发布。
- Windows运行平台为windows-2022 CI（Windows Server2022），不等价于用户Windows双系统；OS锁屏/系统输入法/文件选择器/Windows ssh-agent/真实RDP端/实体串口仍待完成。窗口首帧检查仅证明启动，原生交互另由integration_test提供。
- Linux原生流程复验通过；最新Linuxrelease31.041秒，Androidarm64release32.748秒、34728074字节；Android模拟器凭据/RDP再次通过，APK SHA256 348fdc5354b97127085cadd556387420783a1a1b0033592e9d685b30431be997。当前源码普通Linux75通过、22条件跳过，静态分析通过。
