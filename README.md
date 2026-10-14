# WSA Houdini vfork / Scudo Fix

作者：**[wuldas](https://github.com/wuldas)** · `0.4.0-experimental` · GPL-3.0

An experimental Magisk root/ptrace compatibility guard for a **specific x86_64 WSA / Houdini build**. It keeps the APK and system libraries unchanged and adjusts one exact `clone` flag combination at runtime. This is **not** a universal WSA fix, a 32-bit ARM fix, or a video-codec fix.

**实验性预发布，请先备份。** 这是常驻 root / ptrace 模块，不是单纯的文件覆盖补丁。可能影响其他应用的反调试检测、原生崩溃转储、性能和内存占用。不保证所有应用或长期稳定性。

- [下载预发布安装包](https://github.com/wuldas/wsa-houdini-scudo-fix/releases/tag/v0.4.0-experimental)
- [提交问题](https://github.com/wuldas/wsa-houdini-scudo-fix/issues)
- [许可证](LICENSE) · [第三方声明与对应源码](THIRD_PARTY_NOTICES.md)

## 为什么需要它

在 WSA 的 ARM64 应用兼容性排障中，原生轨迹确认了以下链路：

1. Houdini 使用 `clone(0x4111)` 创建共享地址空间子进程。
2. 子进程注册 host Scudo TLS 统计节点，退出时没有完成对应清理。
3. Houdini 释放该节点所在映射。
4. 父进程后续在 `scudo_mallinfo+128` 解引用悬空节点，触发 SIGSEGV。

`wsa-vfork-guard` 在固定 Houdini 指令处使用硬件执行断点。仅当 RIP 为 `base+0x30d661`、RAX 为 `56`、RDI 恰好为 `0x4111` 时，将 RDI 改为 `0x4011`：

- 清除 `CLONE_VM`，子进程使用私有 CoW 地址空间。
- 保留 `CLONE_VFORK` 的父线程等待与 `SIGCHLD`。
- 其他 flags、系统调用号、返回值和代码字节不变。

本项目不修改 Houdini 的授权、时间、自检逻辑，也不修改 APK。模块包不含 `system/` 或 `.so` 文件。

## 支持范围：先核对，再安装

| 项目 | 验证环境 / 必须匹配的值 |
|---|---|
| WSA | `2407.40000.4.0`，Windows/WSA 指纹 |
| Android / host ABI | Android 13 / API 33 / `x86_64` |
| Magisk | 30.6 实测；安装器接受 30.0+，其他版本未验证 |
| 目标库 | `/vendor/lib64/libhoudini.so`，9,421,784 字节 |
| 原库 SHA256 | `5ef64035ec89bca3d5e33b9f3b6556f98f6c11d11957387d403ae4a4d7cc40ec` |
| 原库 GNU BuildId | `19382d6a127b7398830586473f428f5201d86b5f` |
| 进程范围 | `zygote64` 的后续子进程和线程；不支持 32 位 `zygote` |

安装器和启动脚本会核对平台及原始库身份，不匹配即拒绝。**不要为绕过错误而删除 SHA 检查或替换成另一个库的摘要。** 相同 WSA 版本号并不保证 Houdini 二进制相同。

Houdini 预加载在 `zygote64` 内，不能仅靠它的映射判断应用是否执行 ARM 代码。因此 **x86-only 子进程也可能一直处于 ptrace 状态**。模块不追溯保护启动前已存在的应用，安装/启用后必须完整重启 WSA。

## 下载与安装

Release 中：

- `wsa_houdini_vfork_scudo-0.4.0-experimental.zip`：唯一的 Magisk 安装包。
- `SHA256SUMS`：发布文件校验和。
- `wsa-vfork-guard.o`、`glibc_*.tar.xz`、`glibc_*.dsc`：重链接/对应源码材料，**不是安装包**。
- GitHub 自动提供的 Source code：本项目完整源码、脚本、文档和许可证。

本版守护二进制 SHA256：

```text
bbaa8ad38d28754df4af8c63c620c34a31a750d0040c24ae997986e911315083
```

模块 ZIP SHA256：

```text
39c0d1f427cf9c322dabbb29d0f96824dc0318b0200eb8d67bfa986b0214c6ee
```

### 1. 备份并准备环境

1. 保存 WSA 内正在进行的工作，**完全关闭 WSA**。
2. 冷备份实际活动的数据盘和 metadata 盘。文件名可能是 `userdata.2.vhdx`、`metadata.2.vhdx`，也可能不同；不要对正在运行的 VHDX 做普通文件复制并当作有效备份。
3. 启动 WSA，启用开发者模式；准备 Android Platform Tools 的 adb。
4. 在 Magisk 中明确允许 Shell/ADB root。模块不会替你修改 root 授权策略。

### 2. 安装

可在 Magisk「模块 → 从本地安装」选择 Release 的模块 ZIP；或下载/克隆本仓库，在 Windows PowerShell 5.1 中运行管理器：

```powershell
$adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
& $adb connect 127.0.0.1:58526

# 把 Release 安装包放在当前目录，或传入实际路径。
.\Manage-Patch.ps1 Install -ZipPath .\wsa_houdini_vfork_scudo-0.4.0-experimental.zip -AdbPath $adb
```

安装完后，保存工作并**完整关闭、重新打开 WSA**。可使用 WSA 设置中的关闭功能，或已注册 `WsaClient.exe /shutdown`。不要使用 `wsl --shutdown` 干扰无关 WSL 发行版。

### 3. 确认生效，再启动应用

```powershell
.\Manage-Patch.ps1 Status -AdbPath $adb
```

应同时看到：

- 模块无 `disable/remove` 标志；原始 Houdini 摘要正确。
- 守护为 `RUNNING VERIFIED`，ready token 为 `0.4.0`。
- `guard.status` 中 `state=watching`、`ready=1`、`errors=0`。

`enabled` 只表示模块允许启动，**不代表守护正在运行**。刚开机可能还在等待 zygote/库加载；若状态持续异常，不要假定应用受到保护。

## 停用、重新启用与卸载

```powershell
.\Manage-Patch.ps1 Disable -AdbPath $adb
.\Manage-Patch.ps1 Enable -AdbPath $adb
.\Manage-Patch.ps1 Uninstall -AdbPath $adb
```

- **Disable**：标记 active/pending 模块禁用，使用已核验的 native helper 请求当前守护有序停止，恢复调试寄存器并解除附加；不 force-stop 应用。
- **Enable**：先核对模块和原始桥接库，再解除禁用。仅在下一次完整 WSA 启动时重新运行守护，不现场重附加。
- **Uninstall**：标记本模块删除、请求同样的安全停止；Magisk 在下一次启动删除模块。不会使用 `--remove-modules` 或删除其他模块。
- Magisk 界面自身的禁用/卸载按其重启生命周期处理。要立即停止当前守护，请使用 `Disable` 管理命令。

停止 helper 先打开 pidfd，再验证进程的 executable 身份，通过 pidfd 发送 SIGTERM 并等待**同一个进程实例**退出，避免数字 PID 被复用时误杀。**不要 SIGKILL 强杀守护。** 停止无法确认时，管理器返回失败，不假报成功；此时先保持模块禁用，再保存工作并完整重启 WSA。

如果 WSA 完全无法启动，在线 adb 管理器不可用。需从 Windows 侧在 WSA 停止后恢复冷备份，或通过可信的离线数据盘操作禁用本模块。恢复整盘会丢失备份之后的数据，操作前请确认路径和备份。

## 已验证什么，未验证什么

以下是该版本的实测范围，不是兼容性保证：

| 场景 | 结果 |
|---|---|
| 目标 `0x4111` clone | 子进程写入不再出现在父进程的内存中 |
| `0x11`、`0x111`、`0x4011` | 原有私有/共享内存行为保持 |
| 新线程、新子进程、非主线程 exec | 实际内核运行验证通过 |
| SIGUSR1、SIGSTOP/SIGCONT | 信号递送、暂停执行和恢复通过 |
| 重复启动 | flock 拒绝第二实例，原实例继续运行 |
| pidfd 停止和断点恢复 | `threads=0`、`TracerPid=0`，PID/ready 清除，原始共享内存行为恢复 |
| WSA 冷启动 | 自动启动并达到 ready 状态 |
| 已测试的 ARM64 应用 | 真实主界面可达；后台 10 秒再返回保持同一主进程 |
| 系统库完整性 | Houdini、guest libc 的 SHA256 保持原件 |

生命周期测试分别在 GNU/Linux 和 WSA 的独立 PID+mount namespace 中运行，WSA 测试使用了发布包相同摘要的二进制。生产会话观察约 9 分钟时，守护修正了 2 次目标调用，错误计数为 0。

回滚底层路径在隔离环境验证，**未对正在使用的生产会话执行完整 Disable/Uninstall 演练**。匿名结果列于此处；设备截图、日志、APK、系统镜像和备份不公开。

未覆盖：

- 所有第三方应用、长时间压力和后续 WSA/Houdini 构建。
- 32 位 ARM，以及在守护之前已启动的进程。
- exec 后不创建新线程、仅在原线程延迟自行加载 Houdini 的原生程序。
- HEVC/-1010 黑屏、播放解码或 DRM 问题。

ptrace 会影响反调试应用，也可能阻止另一个调试器/debuggerd 附加。日志中的 `fault-forward` 只是原信号转发记录；ART 可能正常使用可处理的 SIGSEGV，不能把单条记录当作应用崩溃，也不能把没有 tombstone 当作无故障。

## 源码构建与重新打包

构建机需要 x86_64 GNU/Linux 和 GCC。已验证工具链为 Debian GCC `12.2.0-14+deb12u1`、glibc `2.36-9+deb12u14`。

```sh
sh ./Build-Guard.sh
# 输出：out/build/wsa-vfork-guard、out/build/wsa-vfork-guard.o
```

将二进制取回 Windows（放在 staging 之外），使用 PowerShell 5.1 打包：

```powershell
.\Publish-Patch.ps1 -DaemonPath .\out\build\wsa-vfork-guard
# 重新生成已有产物需显式允许覆盖：
.\Publish-Patch.ps1 -DaemonPath .\out\build\wsa-vfork-guard -Force
```

输出目录：`out/dist/`。发布器检查静态 ELF64LE/x86_64/ET_EXEC、无 PT_INTERP、原样 Magisk 安装器、精确 ZIP 条目/摘要和许可证。路径检查防止 staging 清理误删输入或模板。输出固定时间戳、LF 文本和 Unix 可执行位；不同工具链的二进制摘要可能不同。

修改、重新编译或重新链接守护后，必须重新运行真实内核和 WSA 场景验证；构建通过不等于兼容性通过。glibc 对应源码、对象文件和重链接说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 诊断与安全反馈

状态文件在 `/data/adb/wsa_houdini_vfork_scudo/`，仅 root 可读，包括 `guard.pid`、`guard.ready`、`guard.status`、`guard.log`。模块不启用 Zygisk、不写 system.prop/sepolicy、不修改 root 授权或应用数据。

提交 Issue 时提供：WSA/API/ABI、Magisk 版本、Houdini SHA256、应用版本、复现步骤和去敏后的状态摘要。**不要上传凭据、个人信息、完整用户目录、APK 或数据盘备份。**

## 许可证与归属

本项目原创部分由 **wuldas** 以 GPL-3.0-only 发布。Magisk 安装器、静态链接的 glibc 和 GCC runtime 保留各自版权与许可证；安装包附带完整声明，Release 同时提供对应源码材料。

未分发 Intel Houdini、WSA 系统库或被分析应用。该项目与 Microsoft、Intel、Google、Magisk 或应用厂商没有官方隶属/背书关系。

参考：[clone(2)](https://man7.org/linux/man-pages/man2/clone.2.html)、[ptrace(2)](https://man7.org/linux/man-pages/man2/ptrace.2.html)、[pidfd_send_signal(2)](https://man7.org/linux/man-pages/man2/pidfd_send_signal.2.html)、[Magisk 模块指南](https://topjohnwu.github.io/Magisk/guides.html)。
