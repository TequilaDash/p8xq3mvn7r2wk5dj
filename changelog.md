20261115-213304 1.1.16 Update：
1. 回退 1.1.15 的 _NSGetExecutablePath interpose：它与 LiveContainer 自身的 dyld 路径重写（performHookDyldApi）冲突，导致同进程/多任务启动断言崩溃 (gdyldPtr != 0, Dyld.m:234)；LC 本来就通过 dyld config 重写该路径，无需再拦。
2. 保留 1.1.15 的 mach_port_get_refs 伪值（不与 dyld 路径重写冲突）。
3. 发行说明改为只取 changelog 最新一条，并每次现场生成 [编译环境]（Xcode/Build/SDK），不再复用旧块。

20261115-211904 1.1.15 Update：
1. 隐藏态下重定向 _NSGetExecutablePath 到访客主可执行：检测器原先拿到的是 LC 自己的二进制，于是把 LC 的依赖树/entitlements 当成访客的判为篡改。
2. 新增 mach_port_get_refs 伪值：自身任务端口的 SEND 引用数上限压到 2，消除“进程任务端口被额外引用”判定。
3. 两个新钩子分别复用 TD_PROC_SPOOF 门控，未新增环境键；隐藏关或未启动访客时全部透传真值。

20261115-205357 1.1.14 Update：
1. 新增裸 sysctl(3) MIB 拦截：对自身 kinfo_proc 清 P_TRACED/P_SELECT，消除 Reveil 的“Suspicious PFlag value”与附加标志检测（sysctlbyname 拦不到这条通道）。
2. 只处理 [CTL_KERN, KERN_PROC, KERN_PROC_PID, 自身] 这一条 MIB，其它 sysctl 查询（含 KERN_PROC_ALL、别的 pid）继续透传，避免破坏宿主与访客既有语义。
3. 该层复用 TD_SYSCTL_SPOOF 门控，不新增环境键，per-app/全局开关无需改接线。

20261115-193634 1.1.13 Update：
1. 全局隐藏统一使用 LiveContainerShared 捕获的宿主 Documents 路径，修复 iManager 在访客启动后写入错误容器的问题。
2. 修复隐藏状态页读取废弃 TDGlobalSpoof defaults，改为读取 TDGlobalHide 文件。
3. 普通启动和 LiveProcess 多进程启动统一门控；多任务通过载荷透传全局状态。
4. 全局隐藏只启用已验证的 dyld、sysctl、proc 层，避免全局开关误启用 SecTask/csops 造成签名检测异常。
5. 增加 `[TDGlobalHide]` 路径、文件值、载荷值、最终门控和 hook 环境日志。

20261115-193634 1.1.12 Update：
1. 全局隐藏标记使用“进程加载时捕获的宿主 HOME”（constructor 捕获），不再受访客 setenv("HOME") 污染。
2. iManager 页/隐藏状态页改用同一捕获目录，写与读一致。
