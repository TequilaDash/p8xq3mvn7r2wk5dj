20261118-131020 1.1.43 Update：
1. 侧边下滑“全局应用”不再写 TDPendingOpenSettings，也不再 post openSettings 通知，只返回 zContainer 主界面。
2. 悬浮窗布局加强：固定按钮 52pt bounds，近零/越界坐标一律回到右侧默认，避免左上角不可点击。
3. 访客 bundle id 优先取原始记录，修复旧安装下 Reveil 读到宿主 ID。
4. 对 dlsym(RTLD_DEFAULT,"csops"/"csops_audittoken") 返回伪值实现，绕过 interpose 被 dlsym 跳过的检测路径。
5. 对 SecurityPresets.plist 的空 profile 哈希与 bundle id 基线做通用修正，基于 IPA Ghidra 反编译结果。
6. 版本号升至 1.1.43。

20261118-121148 1.1.42 Update：
1. 回退跨进程保存的悬浮窗位置：每次启动强制回到右侧默认位置，避免坏存档把按钮钉在左上角且无法点击。
2. 悬浮窗创建时强制重置布局，窗口显示与布局顺序恢复原有可靠流程。
3. 保留 1.1.41 的场景扫描、窗口就绪重试、侧边下滑不依赖悬浮窗、设置同步等修复。
4. 版本号升至 1.1.42。

20261117-162609 1.1.41 Update：
1. 修复辅助触控在 TweakLoader 晚于场景激活时完全不显示：启动后扫描已激活场景，并在应用窗口未就绪时短时重试创建悬浮窗。
2. 修复侧边下滑依赖悬浮窗的问题：边缘事件直接读取设置，即使悬浮窗尚未创建也能识别下滑。
3. 修复无悬浮窗时返回动作不执行：去掉对 `buttonController` 的强依赖。
4. 设置页写入后立即 `synchronize`，避免跨进程缓存导致开关看似无效。
5. 恢复宿主证书签名身份，修复 1.1.40 用访客 bundle id 重签导致的“签名仍然无效”。
6. 版本号升至 1.1.41。

20261117-145300 1.1.40 Update：
1. 修复辅助触控和侧边下滑修复包被旧 `Documents/Tweaks/TweakLoader.dylib` 挡住：每次启动都会把陈旧普通文件/旧符号链接刷新到当前宿主注入库。
2. 修复辅助触控位置反复回弹：恢复并保存拖拽位置，布局校正只在几何尺寸损坏时重置。
3. 增强侧边下滑“全局应用”：除左右边缘识别器外，接管 `UIApplication sendEvent:` 的 36pt 边缘触摸轨迹，下滑超过 80pt 直接触发返回。
4. 保留访客原始 Mach-O、Provisioning、Info.plist：安装/重签前备份原件，文件读取和 SecTask/csprs 查询优先返回访客原始身份与原始代码目录摘要。
5. 恢复访客主镜像 load commands，过滤 LC_ID_DYLIB、TweakLoader 注入项和补丁痕迹；版本号升至 1.1.40。

20261117-125904 1.1.39 Update：
1. 修复辅助触控跑到状态栏左上角且拖不动：场景坐标退化时窗口退回到主屏完整边界；创建和场景激活后延迟校正窗口/根视图尺寸，布局尺寸过小时不再把按钮算到 (0,0)。
2. 修复侧边下滑“全局应用”完全无响应：左右窄热区同时挂系统边缘手势和普通 pan 手势并去重；即使拿不到应用窗口快照，下滑超过阈值也直接触发宿主返回动作。
3. 修复设置切换不即时：读取 app group 共享偏好前先 synchronize；场景激活/回到应用时重新加载设置并校正几何。
4. 版本号升至 1.1.39。

20261117-050500 1.1.38 Update：
1. 修复辅助触控卡在状态栏/左上角：按钮窗口和根视图显式带完整尺寸，根视图自适应窗口，布局无效时强制回默认右侧。
2. 修复侧边下滑“全局应用”：改用 UIScreenEdgePanGestureRecognizer，只有 `TDSideSwipeMode=always` 时启用；开启后允许与应用手势同时识别。
3. 修复设置切换：回到应用/场景激活时重新读取 `TDAssistiveTouchMode`，只有“始终显示”才显示按键。

20261117-021500 1.1.37 Update：
1. 修复 1.1.36 构建失败与描述文件备份时机：只在需要重签时保存原始 `embedded.mobileprovision`，避免破坏已签名应用资源封印。
2. 修复辅助触控显示/位置：保持单窗口，只在“始终显示”开启时显示，启动时固定回默认右侧；侧边下滑全局应用只保留手势。
3. 修复 CydiaSubstrate 旧路径依赖：签名前把 tweak 的 `/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate` 与 `@executable_path/libsubstrate.dylib` 统一改写成 `@rpath/CydiaSubstrate` 并补 LC rpath。
4. 访客主 Bundle 的 `bundleIdentifier` 返回原始标识符；原始描述文件读取使用 `.td-original.mobileprovision`。
5. 常驻进程按宿主 bundle 路径定位 `lcImageIndex`，避免镜像 index 0 指错。

20261117-013000 1.1.36 Update：
1. 签名前统一修复 tweak 的 CydiaSubstrate 依赖：把 `/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate` 与 `@executable_path/libsubstrate.dylib` 改写为 `@rpath/CydiaSubstrate`，并补 LC 的 CydiaSubstrate framework rpath。
2. 访客主 Bundle 的 `bundleIdentifier` 在内存中返回原始标识符，不再暴露被改写的宿主标识符。
3. 安装/重签前保存原始 `embedded.mobileprovision`，访客读取该文件时返回原始副本，避免静态哈希被重签破坏。
4. 常驻进程按宿主 bundle 路径定位 `lcImageIndex`，不再按第一个 `MH_EXECUTE` 猜测，避免镜像枚举 index 0 指向旧访客/宿主。
5. 版本号升至 1.1.36。

20261116-231500 1.1.35 Update：
1. 修正签名策略：恢复上游“已签则跳过”的 tweak 预检，验签改为 pread 读取 Mach-O，不再 mmap 未签名页；不再每次启动全量重签。
2. 侧边下滑“全局应用”接入宿主现成设置呈现链路：访客写共享标记并发 Darwin 通知，宿主用 HomeScreenPresentation 打开设置页，而不是 guest 内自造转场。
3. 辅助触控保持单窗口，仅“始终显示”时显示；位置每次回到默认右侧，不再沿用导致左上角的旧保存位置。
4. 修正 M9 根源码漂移，统一 vendor 与根源码；版本号升至 1.1.35，避免重复重指 1.1.34。

20261116-180000 1.1.34 Update：
1. 通用化镜像裁剪规则：所有进程始终隐藏 TweakLoader 与 Documents/Tweaks 注入镜像，全局隐藏开关只控制 LiveContainer 自身镜像是否可见；不再按应用名称区分。
2. 修复崩溃信号采集开关：扩展入口提前读取共享设置，ConsoleLog 目录在 app group 环境变量就绪后重新解析，信号处理器每次启动按开关重装。
3. 侧边下滑“全局应用”恢复跟手快照与回弹：慢速下拉也可触发，超过阈值后复用宿主返回路径；未开启辅助触控时按键隐藏，只保留边缘手势。
4. 修复快速重新打开 Dock 应用时旧通知再次收起窗口的问题。
5. 辅助触控保持单窗口：仅“始终显示”开启时显示按键；侧边下滑“全局应用”独立生效时按键隐藏。
6. 镜像裁剪不在 dyld add-image 回调里执行，改为 dlopen 完成后刷新，避免 tweak 加载时重入 dyld 触发签名页错误。
7. 修复 tweak 只在手动点模块页签名后才生效：启动前自动签名路径的预检会误判已签并跳过；根源码同步 M9，跳过预校验，直接交给 ZSign 幂等重签。
8. 辅助触控每次从默认右侧位置开始，不再沿用上次保存的位置导致跑到左上角。

20261116-174839 1.1.33 Update：
1. 修复关闭全局隐藏时常驻进程可能把仍驻留的上一访客选作主镜像：启动路径尚未解析前回退扫描现在优先最新加载的访客可执行文件，精确路径解析完成后仍使用对应镜像索引。
2. 修复辅助触控返回多任务时黑屏：LiveProcess 不再盖住访客窗口，直接通知宿主复用 Dock 的最小化动画，并在宿主补发通知后复位按键状态；扩展进程保持运行。
3. 修复侧边下滑手势取消后快照残留、横向手势误触和按键被快照覆盖；仅从当前场景应用窗口取快照，取消时回弹并清理。

20261116-162656 1.1.32 Update：
1. 修复多任务主屏按键完全失效：旧代码先判断 LCSharedUtils 是否存在，TweakLoader 未链接该类时直接 return；多任务分支现在先执行，不再被这个判断拦住。
2. 修复崩溃捕获在扩展内未安装：LiveProcessMain 一进入就安装文件记录器，任何访客代码导致退出前都有机会写入 ConsoleLog；崩溃记录不弹窗。
3. 多任务最小化通知在宿主前台后补发一次，避免宿主在后台时丢失通知导致窗口黑屏。

20261116-160714 1.1.31 Update：
1. 侧边下滑改为交互式过渡：整屏快照跟随手指下移淡出，松手未过阈值会回弹；快照取应用窗口，不再把辅助触控一起带走。
2. 崩溃记录恢复为“只写 ConsoleLog、不弹窗”：未捕获异常与 SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP/SIGTERM/SIGINT/SIGHUP；不再有应用终止弹窗。
3. 保留多任务主屏键不结束扩展进程的修复。

20261116-135017 1.1.30 Update：
1. 多任务主屏键不再结束扩展：扩展内改为直接打开宿主并通知宿主把多任务窗口最小化进 Dock，进程保持存活；不再走会在完成后 SIGKILL 的 launchToGuestApp。
2. 按你的要求删除我们加的崩溃捕获与“应用异常终止”弹窗（对齐上游，减少干扰）；ConsoleLog 仅保留启动面包屑。
3. 辅助触控确认弹窗改为中文（“退出应用 / 退出当前应用并返回 zContainer 主界面？”）。
4. 侧边下滑增加过渡：向下滑后快照随手下移淡出再回主界面，不再生硬跳变。

20261116-133137 1.1.29 Update：
1. 辅助触控（现有主屏按键）多任务单击：宿主收到通知后把所有多任务窗口最小化、扩展进程保持存活，再回到 zContainer 主界面；全屏启动且开启「始终显示」时先弹确认再退出。
2. ConsoleLog 恢复顶部工具栏外观，右上角改为单一菜单（导出/删除/完成），修复菜单点击无响应。
3. 新增实验性「侧边下滑」：任意界面从屏幕左右边缘向下滑动回到 zContainer 主界面；二级页含手指下滑动画卡片，可选择保持现状或全局开启。
4. ESign 诊断：LiveProcess 进入扩展入口与收到启动请求时都会写入 ConsoleLog，用于判断它是否在到达启动器前就退出。

20261116-130535 1.1.28 Update：
1. 辅助触控（现有主屏按键）在多任务里改为最小化：不再结束 LiveProcess，多任务应用保持存活，只把 zContainer 拉到前台。
2. 辅助触控设置页去掉说明文字与“显示方式”标题，只保留“保持现状 / 始终显示”两个选项。
3. ConsoleLog 的操作移到下方固定栏（全选/取消全选、导出、删除、完成），修复右上角“更多”无响应。
4. 崩溃信号采集增加 SIGTERM/SIGINT/SIGHUP，便于捕获 ESign 这类被终止而不是崩溃退出的情况。

20261116-124329 1.1.27 Update：
1. 辅助触控改为增强现有的主屏按键（不再新增悬浮球）：新增二级设置页，可选「保持现状」或「始终显示」；始终显示时任何应用界面都显示同一个按键，且只保留单击回到主界面。
2. 修复 ConsoleLog 选择：可逐行点选/取消，新增“完成”退出选择，全选可取消。
3. 移除 1.1.26 新造的悬浮球及其开关。

20261116-122836 1.1.26 Update：
1. 新增实验性「辅助触控」：宿主悬浮球覆盖访客界面，可拖拽、空闲 3.5 秒自动淡化，触摸穿透不影响访客操作。
2. 点按悬浮球可打开 ConsoleLog 或关闭悬浮球（可在 iManager → 实验性重新开启）。
3. 支持「在所有应用上显示」；关闭时只在当前前台应用上显示，保持原有多窗口行为。

20261116-121221 1.1.25 Update：
1. 修复关闭全局隐藏后任意 App 启动闪退：App 自带的 fishhook（微信等）会重绑 open/stat，我们按符号调用会与其 hook 互相递归导致栈溢出；现在 open/openat/stat/lstat/fstatat/access/opendir/realpath/readlink/mkdir/rename/unlink/getattrlist/getmntinfo/getuid 等全部改为加载时捕获真实地址。
2. ConsoleLog 增加多选/全选、导出、删除；单个日志分享真实文件，多文件时生成只包含所选日志的文件夹再分享，不再把内容当文本发送。

20261116-115542 1.1.24 Update：
1. 隐藏状态页的“伪值层”改为读取实验性「环境伪值」开关，不再错误地跟随全局隐藏显示。
2. 启动面包屑补密：dlopen 起点、bundle 加载、入口跳转与各阶段失败原因都写入 ConsoleLog，用于定位 ESign 这类在 guest index 之前就退出的应用。

20261116-005429 1.1.23 Update：
1. ConsoleLog 改写到 app group 共享目录，LiveProcess 崩溃日志现在与宿主 App 可见位置一致；旧版写在扩展沙盒导致“崩溃日志里没有日志”。
2. 信号处理器改为实验性开关（默认关闭）：默认只保留 NSException 通道，不再让 Reveil 多报“可疑信号处理器”。
3. iManager 诊断页把入口改名为 ConsoleLog，并读取 app group 与 Documents 两处日志。
4. 新增实验性「环境伪值」总开关（默认开启，app group 持久化）：关闭后所有访客都不做 sysctl/SecTask/csops/proc 伪值。
5. 多任务扩展恢复旧裁剪策略：只有隐藏开启时才裁剪 dyld 镜像，修复 ESign 多任务一启动即终止（同进程访客仍始终裁剪注入镜像）。

20261116-003054 1.1.22 Update：
1. 修复 TweakLoader 加载 CydiaSubstrate 失败：访客启动后 lcMainBundle 会被改写，旧代码因此去 <访客>/Documents/Frameworks 找库；现在从 TweakLoader 自身镜像路径反推 LC app，并保留旧路径作回退。

20261116-001600 1.1.21 Update：
1. 修复真机 SIGSEGV 递归崩溃：tweak（如 FakeTools 的 hooked_sysctl）会再次改写 _sysctl 绑定，我们改为在镜像加载时捕获真实 sysctl/sysctlbyname 地址，不再与对方 hook 互相递归。
2. 新增 ConsoleLog：启动面包屑写入 Documents/ConsoleLog/console-YYYYMMDD.log；未捕获异常与 SIGABRT/SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP 写入 crash-*.log，含进程回溯。
3. iManager 诊断新增“崩溃日志”页，可直接查看并分享 ConsoleLog 下的文件。
4. 崩溃日志目录统一：访客进程写 LC_HOME_PATH/Documents/ConsoleLog，与 iManager 读取位置一致。
5. 异常终止提示：访客没有留下正常退出标记而扩展中断时，弹出“应用异常终止”并指向崩溃日志；正常退出与手动关闭不再误报。

20261116-000349 1.1.20 Update：
1. 修复多任务误报：扩展中断与手动关闭不再弹“extension interrupted”，只有启动阶段失败才提示；访客 main 正常返回 (code 0) 视为正常退出，不再当错误。
2. 修复 dylibC：启动前扫描二进制里的 TweakLoader 依赖名，发现尾随脏字节就强制重打补丁并重签，已安装的应用无需重装。
3. 注入镜像始终裁剪：隐藏开关只决定 LiveContainer 自身镜像是否可见，TweakLoader 与 Documents/Tweaks 在任何模式下都不进入访客的 dyld 枚举（应对全能签 AISGuard_HasInjectedLoadCommands 一类自检）。
4. 修正 csops 伪值位：补上 CS_REQUIRE_LV (0x2000) 并不再误清，消除“共享库验证是必须的 / 已禁用共享库校验”。
5. 环境门控默认开启：关闭隐藏不再连带关掉 sysctl / SecTask / csops / proc 伪值；多任务扩展同步同一套门控。
6. 新增 TDLaunchLog.txt（宿主 Documents）：记录每次启动的隐藏状态、门控与访客镜像索引，便于真机取证。

20261115-233017 1.1.19 Update：
1. 修复关闭全局或单应用隐藏后访客被立即终止：隐藏关闭时镜像扫描把宿主可执行文件当成访客，取到宿主 LC_MAIN 后跳错入口；现在扫描跳过宿主镜像，并在 dlopen 成功后按访客路径确定真实索引。
2. appMainImageIndex 不再取被重绑的可见镜像数量，避免常驻进程内反复启动访客时索引偏移。
3. 不再原地改写 dyld 维护的镜像路径（该写入不可逆，会污染后续访客）；隐藏只依赖索引映射，新镜像回调也受隐藏开关门控。
4. 环境隐藏补全：每次启动按「全局隐藏或单应用开关」重设 sysctl / SecTask / csops / proc 门控，关闭时显式写 0，不再继承上一个访客；多任务扩展与启动载荷同步传递这些开关。
5. 保留注入依赖名修复：已存在的 TweakLoader 命令槽先清零再限长写入，避免 dylibC 尾缀。
6. 保留多任务启动错误展示：扩展中断或启动失败时切到终止页显示原因。

20261115-222414 1.1.18 Update：
1. 修复注入依赖名尾随脏字节（现场为 TweakLoader.dylibC）：插入 load command / rpath 前先清零命令区，__TEXT 头部空洞不是零页，strncpy 又不写 NUL，残留字节会被 dyld 当成依赖名的一部分。
2. 每次启动访客重置 dyld 裁剪状态：同一进程内先开隐藏再关隐藏的启动不再沿用旧索引表（index0 错位会取错主可执行入口，表现为“App已被终止”）。
3. 多任务启动失败时切到终止页并打印/显示具体原因，不再是纯黑屏无提示。
4. 隐藏态首次建立镜像映射表时输出 [TDImageMap] 完整可见镜像清单，便于定位残留真名依赖。

20261115-215941 1.1.17 Update：
1. dyld 镜像清单改为显式映射表：剔除 LC 自身全部镜像（不再只减两个尾部条目）与 Documents/Tweaks 下的 tweak dylib，index 0 固定为访客主可执行。
2. 新镜像加载即重建映射，消除旧实现“数量相等即认为未变化”的陈旧判断。
3. 访客主可执行改用 MH_EXECUTE 扫描定位，不再依赖隐藏态下语义不可靠的 appMainImageIndex。
4. lcMainBundlePath 改为自有缓冲区，避免 NSString fileSystemRepresentation 生命周期问题。

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
