20261124-070000 1.1.97 Update：
1. 几何/底部图层日志并进 iManager 能列出的那份文件：`appendGeometryLine` 原来写 `geometry-<pid>.log`，页面上看不到、也导不出来；现在写 `console-yyyyMMdd-pid<pid>.log`，和 TDConsoleLog 同一个文件。
   这样下一次导出 ConsoleLog 就能看到 `[geometry]` 与 `[bottom-overlays]` 的实测坐标/alpha，状态栏偏高、底部遮挡才能按数据改，不靠猜。

20261124-050000 1.1.96 补丁：
1. 修编译错误：给 LCWindowHasVisibleGuestContent 补前向声明（我的 swizzle 用在了定义之前）。
2. 回到主屏幕的刷新再接一路信号：isCoveredByScreen 由 true→false（访客窗口让开、桌面重新可见）时也 refreshAppsFromSource()，覆盖"首次进入/从其它场景返回桌面图标不刷新"。

20261124-030000 1.1.96 Update：
1. 修快手崩溃的根本原因：Ghidra 反编译 llykwai.dylib（LC_ID=/Library/MobileSubstrate/DynamicLibraries/zzztest4.dylib）的 0x46a48 = MBProgressHUD::showHUDAddedTo:animated:，它把拿到的 view 传进 initWithView:，而 initWithView: 里 NSParameterAssert(view) → 抛「View must not be nil」。调用方拿到的 view 是 nil，是因为我们在宿主 scene 里跑访客，keyWindow 不是访客窗口（上游 LiveContainer 给访客独立 scene，所以没事）。
   现在给访客补上 keyWindow：swizzle UIApplication.keyWindow，优先返回"装着访客画面"的窗口（LCWindowHasVisibleGuestContent），没有访客窗口时回退原实现。
2. 同进程多访客时，其它访客的镜像不再出现在当前访客的 _dyld 枚举里（tdv_is_hidden_path 只放行当前访客目录），避免被当成"注入的共享库"。

20261124-010000 1.1.95 Update：
1. 修 Reveil「发现注入的共享库」的**真正原因**：设备日志证明它对镜像调了 realpath，我们把它解析成了真实的 Documents 路径，于是"对外路径 vs realpath"不一致 → 判注入。现在 realpath 遇到对外伪路径就原样返回（文件操作走 open/stat 的反向翻译，不受影响）。
2. 辅助触控按钮恢复可见：上一版去掉 glass 后几乎看不见，改回显示玻璃底（showsGlass: true），位置仍默认在左侧不压 chevron。
3. 后台卡片去掉 0.125 右移和 1.018 放大（上一版截图里右侧被裁），宽度仍按 MIN(屏宽×0.72, previewHeight×aspect)，previewHeight = MIN(屏高×0.70, deck 高−60)。

20261123-230000 1.1.94 Update：
1. 卡片尺寸回到参考项目的原式，不再用截图像素常量：`previewHeight = MIN(屏幕高×0.70, (deck 高−60)/1.018−34)`、`maxCardWidth = 屏宽×0.72`、最终宽由 `MIN(maxCardWidth, previewHeight×aspect)` 决定；stride 0.77、右移 0.125、34pt 头部、1.018 保持。
2. Dyld.m 与 TDVRootShim.m 里剩下的 NSLog 全部改走 TDConsoleLog：`[vroot]`、`[hideLC]`、`[TDImageMap]`、`[LC]`、`[DyldLVBypass]` 这些行现在都写进 ConsoleLog 文件，iManager → ConsoleLog 能直接导出。

20261123-210000 1.1.93 Update：
1. 修首页图标要手动滑一下才出现：`@Published` 的 apps 只在数据变化时发一次，视图挂载前那次会被错过，之后一直是空数据列表。
   现在 Home 视图 `.onAppear` 与场景重新激活（UIScene.didActivateNotification）时都主动 `refreshAppsFromSource()` 重新同步并重排。
2. [vroot] 路径日志改走 `TDConsoleLog`（写 ConsoleLog 文件），不再是 NSLog —— 这样 iManager → ConsoleLog 页面里能直接看到。

20261123-190000 1.1.92 Update：
1. 加低音量路径诊断（只在涉及 .app/、mobileprovision、DynamicLibraries、/Tweaks/ 时记录，上限 60+40 行）：
   `[vroot] mask <真实> -> <对外>` 与 `[vroot] virtual->real <伪> -> <真实>`，直接落在设备日志，
   iManager → ConsoleLog 就能看到检测器到底读了哪个文件、被翻译成了什么。
2. 目的：Reveil 剩下两红（分发配置文件被篡改 / 权限配置文件被篡改）需要「它实际读到的文件与摘要」作为证据，
   下一次真机 run 就能闭合，不用再猜。

20261123-170000 1.1.91 Update：
1. 访客镜像伪路径补上 `<Name>.app` 这一级：真机正常安装一定是 /private/var/containers/Bundle/Application/<UUID>/<Name>.app/<Exec>，
   此前对外是 /private/var/containers/Bundle/Application/<UUID>/<Exec>（Reveil 截图里就是这个形状），检测器一眼判非法。
   现在用访客 bundle id 合成 <Name>.app；bundlePath 这类"路径本身就是应用目录"的情况也补这一级。
2. 反向翻译同步跳过合成出来的 `/<Name>.app`，真实目录里没有这一级。

20261123-150000 1.1.90 Update：
1. 后台卡片尺寸按原图像素重算：可见宽 593/1179 ≈ 0.503（再除以 1.018 聚焦缩放得布局宽），高度取 min(视口高×0.70, (deck 高−60)/1.018−34)，去掉 200pt 下限；stride 0.77、右移 0.125、34pt 头部、1.018 保持（依据 LCOrbitTaskSwitcher.m:552-576 与用户原图量测）。
2. 辅助触控浮钮：新增 showsGlass（默认开），全局浮钮显式关闭 → 去掉外圈圆底/半透明圆斑；未保存过位置时默认落在左侧 (34, 屏高×0.62)，不再压住右侧 chevron；首次拖动基准改用 effectiveOffset，避免松手跳回右侧。
3. 截图归属更正：此前被当作「首页渲染异常」的那张实际是访客浏览器主页，不是宿主首页，因此本轮不对宿主首页做盲改。

20261123-130000 1.1.89 Update：
1. 访客镜像对外路径补上 /private 前缀：真机正常安装是 /private/var/containers/Bundle/Application/<UUID>/<Name>.app/...，此前少了 /private，Reveil 仍把主可执行和它自带的 library_stub.framework 判成「注入的共享库」。
2. 反向翻译同时接受带/不带 /private 两种写法（Foundation 常把 /private 去掉）。

20261123-110000 1.1.88 Update：
1. 后台卡片宽度按实机截图量到的比例收到 0.56×屏宽（参考源码的 0.72 只是上限，实际由 MIN(maxCardWidth, previewHeight*aspect) 决定；0.72 在实机上偏宽）。

20261123-090000 1.1.87 Update：
1. 堆叠后台新增「背景」：跟随壁纸（用设置里的壁纸，模糊后铺底，和 iOS 后台一样）/ 跟随应用（当前实现，毛玻璃盖在应用画面上）。
2. 新增「背景模糊」滑杆 0–30：壁纸模式是实际模糊半径，应用模式换算成压暗强度。
3. 设置项：TDAppStackBackground（wallpaper/app）、TDAppStackBlur（0–30）。

20261123-070000 1.1.86 Update：
1. 后台卡片按参考项目 LCOrbitTaskSwitcher 的几何实现：卡片宽 ≤ 屏宽 72%、高 ≤ 可用高度 70%、按访客画面比例收窄；相邻卡片按 0.77 倍卡宽排列，整叠右移 12.5% 卡宽让左侧卡片露边；当前卡放大 1.018。
2. 每张卡片自带 44pt 头部：图标 + App 名（参考项目 card bounds 比画面高 34pt 的做法），所以露出来的相邻卡片也带着自己的图标和名字。
3. 画面圆角改 28（参考项目 poster 圆角）；去掉屏幕顶部那排图标、卡片上的胶囊/× /齿轮等额外控件，只保留长按更多菜单和底部「全部清除」圆形按钮（开关控制）。
4. 底部保留 dock 条（dock 里的 App），卡片与 dock 之间留出间距。

20261123-050000 1.1.85 Update：
1. 后台改成参考图那套三段式：左上角当前 App 图标(62pt)+名称(25pt)，中间一张卡（宽=屏宽减 20pt，吃满可视高度，比例按访客画面算），相邻卡按「卡宽+12」排列、横滑时才露出一条；卡片顶部一条胶囊：App 名 + 关闭 + 设置。
2. 点卡片间隙/两侧空白 = 回到前台；点左上角图标/名称 = 回到该 App。
3. 「全部清除」保留为底部圆形按钮，由开关控制显示与隐藏。

20261123-033000 1.1.84 Update：
1. 设置页版式统一：10 个设置详情页的 List 显式声明 `.listStyle(.insetGrouped)`；`SettingsPageMargins` 删除「自绘 UITableView 量 UIKit 边距」这套第二来源，只保留顶部间距与分组标题微调；iPhone 根设置列表同样显式声明，iPad 侧栏不动。
2. 辅助触控「始终显示」：**全局只有一个按钮**——宿主单窗口，跟随前台场景移动（不在每个 scene 各建一个）；层级取同场景最高可见窗口 +1；设置页/后台不再主动隐藏；访客进程在 always 下不建自己的按钮（经典全屏访客也跑在宿主进程里，由宿主的那个窗负责），「保持现状」档行为不变；设置变更经 Darwin 通知即时刷新（含 dim 参数）。
3. 底部遮挡/状态栏偏高：本轮不盲改几何（外包结论：缺设备日志，候选互斥），保留现有诊断日志。

20261123-023000 1.1.83 Update：
1. 卡片宽高按访客自己的画面比例算（旋转成横屏的卡片不再被裁），没有可用的访客尺寸时回退到 390×844。

20261123-020000 1.1.82 Update：
1. 后台卡片几何按原生手感重写：卡片宽 ≤ 屏宽 72%、高 ≤ 可用高 70%，按屏幕比例算宽高；相邻卡片按 0.77 倍卡宽排列，整叠右移 12.5% 卡宽让左边卡片露边；聚焦卡片放大 1.018。
2. 不再用「屏宽减边距」这种粗暴算法，卡片不会再溢出或显得过宽。

20261123-012000 1.1.81 Update：
1. 卡片宽度收到 24pt 边距（原来几乎贴着屏幕，相邻卡片露不出来），相邻卡片边缘可见。

20261123-010000 1.1.80 Update：
1. 堆叠后台改成原生 iOS 版式：去掉标题、页码/箭头、提示文字、底部 dock；卡片接近满宽、不缩放不下沉，相邻卡片只在边缘露出一条，不再超出边界。
2. 设置 → 堆叠后台：只保留「堆叠后台」「全部清除」两个开关，删掉重复的「全部清除」按钮和所有说明文字；开关开=显示按钮，关=不显示。

20261123-001500 1.1.79 Update：
1. 卡片圆角对齐 iOS 后台（26 → 40）。
2. `dladdr` 的 `dli_fname` 也返回伪路径，和镜像枚举、`NSBundle.bundlePath` 三者一致。

20261122-235000 1.1.78 Update：
1. NSBundle.bundlePath 也走同一套伪路径：访客拿到的 bundle 路径与 `_dyld_get_image_name` 一致（/var/containers/Bundle/Application/<uuid>/<App>.app/...），检测器把两者互比不再矛盾。文件访问照旧由 vroot 层翻回真实路径。

20261122-233000 1.1.77 Update：
1. 后台界面底部加 dock：复用 dock 里的 app，毛玻璃胶囊条，点图标直接切到该 app。
2. 后台顶部图标行显示当前 app 名称，跟 iOS 后台一致。

20261122-230000 1.1.76 Update：
1. 堆叠后台顺序与 iOS 对齐：当前 app 永远排在最右边，进后台默认聚焦它（之前默认选中最右一张，但那张不是当前窗口）。
2. 后台顶部新增 app 图标行：当前卡片对应的图标高亮，点图标直接切换。
3. 设置 → 堆叠后台新增「全部清除」按钮，由开关 `TDAppStackClearAllEnabled` 控制（默认开）；后台界面里的「全部清除」同受这个开关控制，按钮保留不删。

20261122-221000 1.1.75 Update：
1. 「反转」不生效：场景设置里只改 interfaceOrientation，deviceOrientation 仍是当前设备方向，UIKit 认为设备没转就忽略。现在四个档位同时设 deviceOrientation，反转（180°）和横屏才真的转。

20261122-213000 1.1.74 Update：
1. 访客镜像对外路径改为正常安装形状：`/Documents/Applications/<folder>/<App>.app/...` → `/var/containers/Bundle/Application/<UUID>/<App>.app/...`。UUID 由访客 bundle id 派生 UUIDv5（1.1.54 用全 0 UUID 被检测器识破，这次不是）。
2. 同步补上反向翻译：vroot 拦截层（TDVRootShim）收到伪路径先翻回真实路径再查内核，open/openat/stat/lstat/access/readlink/opendir 都走同一入口，避免"枚举是假路径、读文件找不到"的自相矛盾（1.1.54 坏就坏在这里）。

20261122-203000 1.1.73 Update：
1. 真正修掉「旋转方向」点了不转：之前宿主只往共享 defaults 写请求，靠访客进程里的 mask hook 生效，但嵌入的场景没有被要求按新方向重排，所以画面不动。现在宿主直接设置访客场景的 interfaceOrientation 并触发重排（默认=跟随宿主、横屏=LandscapeRight、竖屏=Portrait、反转=PortraitUpsideDown），访客进程内的 mask hook 仍然保留，两边一致。

20261122-190000 1.1.72 Update：
1. 修复 iManager「发现注入的共享库」误报：你截图里列的是 Reveil 访客自己包里的 library_stub.framework（/Documents/Applications/com.reveil.app.app/Frameworks/...），访客包里的库不是注入到宿主的东西；现在注入检测跳过访客 Applications 目录和容器自身框架。
2. 旋转方向没反应的根因已在 1.1.71 修掉：宿主写请求时用窗口 dataUUID，访客拿它跟 bundle id 比，永远对不上。1.1.71 起写 bundle id，四个方向才真正生效；如果你是在 1.1.69 上测的，装 1.1.72 即可（含全部修复）。

20261122-172000 1.1.71 Update：
1. 修复堆叠卡片「旋转方向」菜单点了没反应：宿主写的是窗口的数据 UUID，而访客拿这个 uuid 跟自己的 bundle id 比对（LCBootstrap 里 lcGuestAppId 是 bundle id），两边永远对不上，请求被直接忽略。现在写访客的 bundle id。
2. iManager 的「动态库注入检测」不再把容器自己的 LiveContainerShared / TweakLoader / CydiaSubstrate 报成注入库——它们本来就是 zContainer 自身的一部分，不是被注入到访客里的东西。

20261122-163000 1.1.70 Update：
1. 修复全能签(NSKSign)红项「检测到主程序依赖库与发行基线不一致」：这条检查(AISGuard_DepsMismatch)把磁盘上访客主可执行的依赖库列表与发行基线比对。容器把访客主可执行改成 dylib 并注入 TweakLoader 的加载命令，文件因此多出两条依赖，判定必然不一致。现在访客读自己主可执行时拿到的是"发行版"那份文件：安装时留存的原件优先；早期安装没有原件的，用当前文件去掉我们加的那两条命令生成一份。
2. 修复「访客读自己原件」的映射一直没生效：Foundation 的 NSFileHandle/NSData 与 libobjc 的 objc_msgSend 夹在 app 与文件之间，hook 里的返回地址永远不是访客的，映射因此从未命中，访客一直读到打过补丁的文件。现在沿调用栈找访客自己的帧（open/openat 这类 libc 调用同样适用）。
3. 1.1.69 已含：全能签四路 dyld 交叉校验修复（dyld 私有 API 一并重绑）+ litehook 重绑顺序修复 + 堆叠卡片「旋转方向」菜单编译修复。

20261122-154629 1.1.69 Update：
1. 全能签(NSKSign)四路 dyld 交叉校验修复：Ghidra 实锤 NSKSign 枚举镜像用的是 dyld 私有 API（__dyld_image_count / __dyld_get_image_name / __dyld_get_image_header / __dyld_get_image_vmaddr_slide），我们此前只重绑了公开的 _dyld_*，检测器看到的 stable API 仍是全量、而 task_info 副本是裁剪后的，两个列表必然不一致 -> 判红。现在私有变体一并重绑到同一过滤实现，两个通道给出同一个可见集合。
2. 修正 litehook 重绑顺序：litehook 定位"重绑实现所在镜像"用的是公开 dyld API，原顺序先重绑公开 API 再建裁剪表，之后它只能看到裁剪后的表，本镜像被隐藏时后续重绑静默失效（index0 契约错位 -> 访客入口取错）。现在所有枚举重绑提前到裁剪表建立之前，并在裁剪未生效时不再做 index0 的访客头还原（避免改到宿主二进制头）。
3. task_info 副本门控改为「proc 伪值开关 或 镜像裁剪已生效」，两个通道的可见视图不再可能不一致。
4. 全能签崩溃点定性：NSKSign+0x714514 = swift_Concurrency_fatalError（唯一调用者 swift56override_swift_task_future_wait，报 "future reported an error, but wait cannot throw"），是 NSKSign 自带 Swift 5.6 并发兼容层在 async 任务抛错、等待方不能抛时的陷阱，不是反注入 abort（检测命中的真实路径是弹窗后 600ms 的 abort）。具体抛错任务待设备侧取证。
5. 复核：全能签的"证书公钥被篡改"检测查的是二进制内嵌公钥表，与访客重签无关（天然绿）；它检查的 5 个 DYLD_* 环境变量我们都没设。
6. 底部小块遮挡与快手崩溃继续待复测；全能签红项变化需真机确认。全局隐藏（TDGlobalHide）开着时宿主镜像对所有访客都不可见，不用再逐 app 去开「隐藏 Live Container」。
7. 修复 1.1.69 首次构建失败：堆叠卡片「旋转方向」菜单的 Swift 侧编译错误（NSUserDefaults.lcSharedDefaults 是类方法要带括号、CFSTR 在 Swift 里要用 CFNotificationName），旋转请求改为写共享 app group defaults，访客侧读的是同一个 suite。

20261122-033500 1.1.68 Update：
1. 修复多任务浮动窗口状态栏偏高（图一 vs 图二对比定位）：updateAppSafeArea 在顶栏隐藏（hideWindowBar）时仍清 44pt 顶部避让，guest 状态栏被推到真实状态栏下方 44pt；全屏 guest 无此 44pt 所以正常。现在避让跟随 navigationBar.hidden 同一个 hideWindowBar 条件，顶栏可见才清 44pt。
2. 1.1.67 已含：sigaction 查询伪值越界修复（只写 handler 字段）+ 状态栏沉浸迁入 iManager > 实验性。
3. 底部小块遮挡（图三 iManager 页"我的"上方）与全能签/Ensign 权限分发红项继续待复测；快手崩溃与全能签同源，等 1.1.68 复测。

20261122-031500 1.1.67 Update：
1. 修复 1.1.66 引入的 Reveil 3.4 闪退（stack buffer overflow）：sigaction 查询伪值早先把 old 结构的 mask/flags 一并清零（24 字节），部分调用方以紧凑缓冲区作 old，越界写 8 字节触发检测线程 __stack_chk_fail（123758.ips：FUN_100147270 尾部）。现在只写 handler @0 一个字段——这正是检测语义判断的字段；mask/flags 保持真实值。
2. 状态栏沉浸入口按用户要求迁到 iManager > 实验性（二级界面 + 卡片动画示例不变），不再放设置 > 高级。
3. 全能签/Ensign 仍未过：新版 Reveil 的权限/分发配置文件读的是进程 entitlements/profile（非 bundle 文件），我们已有的 SecTask 伪值通道是否覆盖其读取路径待复测确认；快手崩溃同源（全能签 abort）。多任务状态栏偏高与全屏 guest 对比的新证据（图一 vs 图二）本轮继续分析，底部小块遮挡（图三）一并排查。

20261122-023000 1.1.66 Update：
1. 新版 Reveil 3.4 的"已设置信号处理器"红项修复：Ghidra 实锤 FUN_100147270 case 0x1f 对信号 1…31 逐个 sigaction(sig, NULL, &old)，old.handler 非 SIG_DFL 即红。zContainer 自己的崩溃记录/Guard 处理器是合法注册，不能撤。现在 interpose sigaction：只有查询调用（act == NULL）且 caller 是 guest 且 TD_PROC_SPOOF 开启时把返回的 old 改为 SIG_DFL 形；注册调用完全透传，我们的处理器照常工作。litehook 全局重绑，NSKSign 的 fishhook 还原路径覆盖不到它。
2. 新增实验性功能"状态栏沉浸"：设置 > 高级 > 状态栏沉浸。开关存 app group（LCStatusBarImmersion），主屏幕把它并入现有状态栏隐藏条件；二级页面带卡片动画示例（状态栏滑出滑回的 spring 动画）。
3. 权限/分发配置文件两环境红项：新版 Reveil 读的是进程 entitlements/provisioning profile 而非 bundle 文件（图三图四两环境一致红），非同一根因；旧版多任务多红一项的差异需要真机复测后再定位。本轮先交付信号处理器修复，红项变化等复测。

20261122-020000 1.1.65 Update：
1. NSKSign 四路 dyld 交叉检查修复：Ghidra 实锤 _AISCollectStableApiVersusTask 同时对比 stable API (_dyld_image_count 等) 和 task_info(TASK_DYLD_INFO) 返回的 dyld_all_image_infos.infoArray。隐藏 LC/TweakLoader 镜像只改了 stable API，内核 task_info 仍返回全部条目，两个列表数量/内容不一致 -> 必命中。现在 interpose task_info，当 flavor=TASK_DYLD_INFO 且 caller 是 guest 且 TD_PROC_SPOOF 开启时，把 all_image_info_addr 指向删除隐藏条目后的副本，两视图一致。不指向空结构（1.1.45 教训），其余字段逐字节保留。
2. task_info interpose 用 litehook_rebind_symbol（GOT 重绑），不用 fishhook：NSKSign 的 _AISGuard_RestoreFishhookedDyldSymbols 会主动还原被 fishhook 改写的 dyld 符号 GOT 槽，但只针对固定 5 个 dyld 符号；task_info 不在其中。副本按 Dyld.m 同一 remap 状态填充（TDVDyldInfoVisibleIndices），与 stable API 保持一致。
3. 本轮八项检查中 1-7 项已分析为绿（text caves/prologues/MSHook trampolines/cert/SecKey imports/critical IMPs/injected load commands 均不与 litehook GOT 型注入冲突；第 4 项在 R29 原件映射修复后也绿）。第 8 项由本次 interpose 修复。不宣称真机全绿，待复测。

20261122-013000 1.1.64 Update：
1. 修复多任务"应用程序分发配置文件被篡改"红项：Ghidra 实锤 Reveil 用 32 字节 SHA256 哈希当前 embedded.mobileprovision 字节并转 hex，然后对 secureMobileProvisioningProfileHashes 做 Set<String>.contains。之前的出厂空串基线永远不匹配真实 profile。现在改为记录当前 profile 的实际 SHA256（文件存在且非空时），不伪造。
2. 输入包本身无 embedded.mobileprovision（如 ReveilPatch.ipa）：Reveil 的 pathForResource 返回 nil 时立即返回失败，空串基线不等于"缺文件可信任"。只能对有真实 profile 的签名包修复此红项，不能对缺 profile 的包伪造。
3. 本轮不宣称全能签/环境检查全绿。Nyxian/Switzach/roothide 的隐藏技术分析继续，但同进程 dlopen 注入与 NSKSign 的内存完整性检查（text caves/prologues/MSHook trampolines/cert/SecKey imports/critical IMPs/injected load commands/dyld 四路交叉）存在根本冲突。

20261122-003000 1.1.63 Update：
1. 安装补丁 revision 恢复为 8；本地兼容性修复不再擅自提升它。只有相关上游源码更新确有需要时才同步调整。宿主发行版本号与补丁 revision 分开管理。
2. 修复 1.1.62 创建多任务窗口时的宿主 UIKit 层级异常：Home 与虚拟窗口宿主改为普通 UIKit 容器中的兄弟子控制器，访客视图只挂在其真实父控制器的视图内；不再把 Home 子控制器的视图放到 Home 视图外面。保留 SwiftUI 手势隔离，不新增悬浮 UIWindow。
3. 现代 hosting 直接提交 scene 设置时同步实际安全区与物理状态栏遮挡，不再依赖未经验证的私有 hook 调用关系；未挂载时保留初始 frame，避免回填零或过期 frame。
4. 发布工作流加入真实 iOS Simulator UIKit 层级回归，执行生产容器与挂载方法，覆盖重复挂载、单窗口移除、尺寸变化与宿主替换。编译成功不代表第三方 App 或环境检测已通过。
5. 环境入口修正：原件映射覆盖本地与共享应用根，并识别 /var 与 /private/var 同一路径；Foundation 直连同目标 mapper。任务端口查询改用已有 GOT rebinder 覆盖真实固定导入，仅对 guest/self/SEND 成功值按实时开关适配，宿主、其它端口及内核错误不变。
6. 尚无真机成功证据：Via/状态栏/底遮挡、快手窗口及全能签/环境全绿。缺失原 profile 的输入包不能靠伪造文件获得真实原件；不关闭插件、不篡改检测函数来冒充通过。

20261121-224818 1.1.62 Update：
1. 撤除 1.1.61 按自校验字符串自动关闭 TweakLoader 的方案；恢复遵循用户的注入/加载开关。安装补丁 revision 升为 9，使已受影响的应用重新应用用户配置；旧短占位命令重新启用注入时会扩容并保留后续 load commands，不再截断 TweakLoader 路径。不再用停用插件冒充兼容性修复。
2. 修正访客 main 返回后的进程生命周期：保留返回码并退出访客进程，不再落入宿主 SwiftUI main 第二次创建 UIApplication。对应快手新日志中的 returned 0 → UIApplicationInstantiateSingleton 异常；不宣称覆盖第三方应用所有退出原因。
3. 修正 iOS 18+ hosting 更新丢弃非 frame 设置的问题；按实际访客 viewport 发布安全区，尺寸不再重复扣除导航条。宿主挂载窗口限定为 Home Screen 的可见普通窗口，不再使用无序的第一个 scene/window。
4. 实体状态栏遮挡与刘海/底部安全区分开计算：实体状态栏矩形转换到实际访客 viewport 后取交集，经 FrontBoard 传给旧 statusBarFrame API；保留虚拟访客禁画第二条状态栏，不用固定高度或 notch 高度代替状态栏。安全区变化也触发更新。
5. 堆叠后台长按菜单新增目标应用“重新启动”：确认旧 PID 退出并清理窗口后，用原应用、原容器和原窗口类型走签名/JIT 启动。新原生窗口使用独立 launchID，每次启动独立消费 PID 回调；旧窗口的延迟断开/移除不影响后继窗口。失败显示原因，不靠等待时长假定退出。
6. 环境兼容修复：Foundation 只读接口保留访客调用来源并读取真实原件，修正 framework 内部 open 漏映射；原件拒绝写入而 vroot 保持可写。SecTask 限定明确 self 任务和访客调用，保留未知/其它任务与合法权限；移除错误的 CDHash 替换。恢复 factory profile 策略，不再把空字符串哈希当成缺文件也可信。
7. 仍未证明解决：任务端口红项、Reveil 配置检查全绿、全能签启动。Via/状态栏已修正具体源码路径，但外观未经真机复测；隔离行为证明、Xcode 构建与真机行为分开记录。

20261121-223500 1.1.61 Update：
1. 通用处理“检测自身可执行被改”类 App：安装补丁时扫描主可执行是否带自校验守卫（AISGuard_ / AISPromptThenAbort / AISAntiHook / verifyTextIntegrityOrAbort 等），命中则**不注入 TweakLoader 的 LC_LOAD_DYLIB**；启动时也跳过 fallback dlopen TweakLoader。全能签（NSKSign）属于此类，签名功能本身不依赖 TweakLoader。
2. 该判断是通用签名匹配，不按 bundle id 硬编码；普通 App 不受影响。
3. 说明：只解决“因为被改主可执行而拒绝运行”的路径，不等于伪造它的检测结果；其它环境的 SEC-2 类检查仍按实际环境判定。

20261121-214500 1.1.60 Update：
1. 多任务“窗口”模式（Decorated 窗口）此前从未下发设备安全区 inset，也没写几何日志：Via/状态栏在窗口里和在独立 scene 里表现不同。现在窗口模式与独立 scene 走同一套 `peripheryInsets`/`safeAreaInsetsPortrait` 和 frame 计算，并写 `geometry-<pid>.log`（tag=decorated，含 view/window/safe/frame/maximized/方向）。
2. 1.1.59 的“应用信息”崩溃修复、包文件名菜单、宿主屏幕隐藏悬浮按钮保持不变。
3. 说明：本版让窗口模式与独立 scene 对齐并补齐可测日志；Via/状态栏是否完全恢复，需用本版 geometry 日志和截图确认。

20261121-211500 1.1.59 Update：
1. 修复从堆叠后台打开“应用信息”时的 SIGTRAP：设置页改由宿主 AppRootView 用完整 SwiftUI 环境打开，不再在堆叠的独立 hosting 窗口里创建缺 EnvironmentObject 的页面（20:30 崩溃栈即 EnvironmentObject.error ← Picker/Menu/Form）。
2. 堆叠长按菜单新增“包文件名”（bundle identifier）显示，直接复用 App 设置里的值。
3. 宿主屏幕（iManager 设置、App 信息页等）打开时自动隐藏悬浮辅助触控，避免像图四那样压住列表文字；关闭宿主屏幕后自动恢复。
4. 本版未改检测注入与几何数值；“分发配置/权限配置文件”红项仍需按 1.1.58 的基线适配实测确认。

20261121-200819 1.1.58 Update：
1. 辅助触控单击/双击改为互斥识别（双击优先，单击等双击失败），双击不再同时回主屏；堆叠显示时隐藏宿主按钮，叠层不再挡住卡片。
2. 堆叠后台改版：卡片按手机屏幕比例、缩略图铺满卡片不再出现黑色边框；背景改为毛玻璃；长按卡片可用“应用信息 / 分屏 / 画中画 / 清除”；底部新增“全部清除”透明胶囊按钮。
3. 在 zContainer 设置界面双击辅助触控进入堆叠后，点卡片会先关闭设置层，能真正进入对应多任务窗口。
4. 恢复访客自身 SecurityPresets 基线适配：bundle id、主可执行 __TEXT 哈希、entitlements 键集合与安装副本一致；描述文件哈希保持出厂 `[""]`（信任）语义，并清理旧版本遗留的 0 字节描述文件。目标：修“应用程序分发配置被篡改 / 权限配置文件被篡改”两项。
5. 任务端口引用数的伪值同时覆盖 SEND 与 RECEIVE 两种 right，均压到 ≤2，处理全屏访客独有的“进程任务端口被额外引用”。
6. 仍在跟进、本版不宣称修复：Via 界面异常、状态栏几何、快手 llykwai 的 View must not be nil 崩溃、全能签 NSKSign 的 Swift 并发 fatalError。新包会输出 `geometry-<pid>.log`（含实际下发的 frame/inset），请连同全屏/多任务对照截图反馈。

20261121-184500 未发布验证分支（R25，构建 44896691755）：
1. 辅助触控单击/双击改为真正的互斥手势（双击优先，单等双击失败），消除“双击既开堆叠又回主屏、堆叠一闪而过”；堆叠窗口显示时隐藏宿主按钮，避免挡住卡片。
2. 几何诊断不再因缺少 app-group 而静默丢失：状态栏与多任务激活日志按 TD_CONSOLE_LOG_DIR → LC_HOME_PATH/Documents/ConsoleLog → app-group 顺序落盘；另新增 `mode=multitask-applied` 行，记录实际送入访客 scene 的 frame、安全区 inset 与方向。下次导出应出现 geometry-<pid>.log。
3. 全屏模式在 fallback TweakLoader 加载后重建 dyld 可见镜像映射，并在重建时按路径再次裁剪晚期加载的隐藏镜像，收紧全屏/多任务的枚举面差异（不伪造检测结果）。
4. 构建证据：源码 817de092，Archive/IPA 成功，IPA SHA256 4afc6c78114e569a75cd95290b4ec7ad25653fbbc5909f4e3a86a412c7f01e0c。版本仍 1.1.57，未发布。
5. 崩溃归因更新：全能签 NSKSign +0x714514 = swift_Concurrency_fatalError，唯一调用点 swift56override_swift_task_future_wait，即其自带 Swift 5.6 并发兼容层在 async 任务报错时 abort；不是反注入 abort，尚未定位具体失败操作。另一崩溃仍是 guest llykwai.dylib 的 “View must not be nil” 断言，非宿主帧。
6. 状态栏/Via/底栏：本次未改几何数值；旧构建未产出 geometry 日志，无法用实测证明改对。新包需导出 geometry 日志和同 bundle 全屏/多任务对照截图后再定位。
20261121-141000 未发布验证分支（R24，构建 44880898284）：
1. 辅助触控只保留一个：开启「全局显示」时来宾不再各画一个，宿主穿透窗口只响应按钮圆盘区域；单击最小化访客并回主屏，双击打开堆叠。
2. 堆叠卡片比例改为手机屏幕比例；已最小化的窗口保留上一次可见快照，不再只有当前应用有画面。
3. 全屏与多任务改用同一处 bootstrap 应用 per-app 门控（隐藏/四个伪值/keepDebugged），扩展不再重复设置；移除两个只回调研判的空 hook。
4. 状态栏改为读访客 scene 的 UIStatusBarManager 几何，不再固定 20pt 或用宿主屏幕高度。
5. 构建证据：源码 98a4425f，Archive/IPA 成功，IPA SHA256 9112bb0a4344808fba212655a2c5714a7868ee4f2551cb4724871686910d6760。版本仍 1.1.57，未发布。
6. 仍开放：两份崩溃仍在来宾代码；多任务扩展录音受 Apple 扩展限制，无法在扩展内实现；Reveil 红项随进程架构不同，不伪造。
20261121-123000 未发布验证分支（R23，构建 44862900423）：
1. 堆叠后台卡片改为显示应用真实界面的缩小快照，图标移到卡片左上角；不再用图标占位。
2. 实验性设置新增「堆叠后台」二级页面：真实开关（TDAppStackEnabled）与卡片动画示例；关闭后双击不再打开。
3. 宿主辅助触控改为独立穿透窗口，覆盖「App 已被终止」等弹窗；主屏双击打开堆叠，单击仍回主屏。全屏访客双击后回主屏再打开堆叠。
4. 状态栏兜底从固定 20pt 改为访客窗口顶部安全区，Dynamic Island 机型不再把内容压到时钟下。
5. 音频：多任务窗口运行在 LiveProcess 扩展进程，按 Apple 扩展编程指南不能访问麦克风；设置页说明原因，并给出关闭「在窗口中打开」改用全屏的可行方案，不再伪装成功。
6. 仍未修复/未证实：两份新崩溃均在来宾自身代码（discover 递归 +0xd92f41c；llykwai 断言 View must not be nil +0x4784c），未落在保留的宿主帧；Via 界面异常和两种模式环境差异仍未定位，不宣称已解决。
7. 多任务启动载荷补传 per-app「隐藏 LiveContainer」等门控，并给 hostUrlScheme/选中项/bookmark 加 nil 防护，避免字典字面量与 addObject:nil 崩溃；全屏与多任务现在读同一组 per-app 门控。
8. 构建证据：源码 35b407a3，Xcode 26.6 / iPhoneOS 26.5，Archive/IPA成功；IPA SHA256 0776c4f6625cff1bab08fa5e7009ee26c16ee173440ac071907b4a95b07fe635。包内版本仍 1.1.57，未发布、未覆盖旧 tag。

20261121-083358 未发布验证分支（不是 v1.1.57 发行更新）：
1. 用户在 v1.1.57 真机上仍复现崩溃、双击堆叠入口、侧滑、状态栏及音频问题；此前条目中的“已修复”不作为真机通过结论。
2. 本次源码调整：移除错误释放借用 envp 的 spawn interposer；对加载失败、缺失入口及 LiveProcess 退出传播明确错误；堆叠窗口由管理器持有，双击请求等待宿主前台窗口，单/双击使用原生手势识别器；状态栏几何查询加入重入保护和线程安全快照。上述行为仍待真机回归。
3. 不再备份或回写来宾的 SecurityPresets.plist / embedded.mobileprovision；profile 解析结果仅是当前文件的声明，不验证 CMS 签名，也不证明原始发布身份。
4. 音频入口改为“音频会话诊断”，删除虚构波形及“宿主桥接输入成功”提示；当前只有访客 AVAudioSession 调用日志，没有跨进程麦克风音频传输。
5. 完整编译证据：源码提交 67fa6bf7ef，Xcode 26.6 / iPhoneOS SDK 26.5，Actions run 44844231233 的 Archive、IPA 打包和上传均成功；此前 run 44843502785 的五条 Swift 编译错误已修正。
6. 验证产物：LiveContainer.ipa 10737645 字节，SHA256 f9b9e9930b6b1761f4b2859934d32788715d425e398118592d5b2b12677250d2，ZIP CRC 检查通过。包内版本仍是 1.1.57，仅用于构建取证；未发布、未覆盖旧 tag，不能按版本号与已安装发行包混同。
7. discover 递归与 NSKSign abort 的具体触发点、Reveil 检测结果和音频 TCC/路由原因仍无新增真机证据；不宣称这些故障已消失。

20261120-183000 1.1.57 Update：
1. 修复访客进程爆栈崩溃（2026-11-20 170705.ips）：访客 stat 自己请求的路径却拿到容器内备份原件的 inode，访客侧判定"文件被替换"后反复重试导致递归爆栈；元数据/路径解析类 hook 改为只做隐藏判定，不再替换被查询路径。
2. 修复侧边下滑手势无响应：设置读取从"每个 UIEvent 读一次"改为"每次手势开始读一次"，并去掉每次读取的强制落盘（synchronize）。
3. 修复状态栏错位：swizzle 非幂等导致 hook 偶数次交换后失效，改为只交换一次；状态栏宽度改用访客窗口宽度而非全屏宽，多任务窗口内不再按全屏宽排版。
4. 诊断增强：访客可见镜像清单按启动模式落盘（ConsoleLog/imagemap-fullscreen.txt / imagemap-multitask.txt），全屏与多任务的日志统一到 app group 便于对比。

20261120-150000 1.1.56 Update：
1. 修复侧边下滑手势失效：1.1.54 把该开关改成"每个 UIEvent 实时读"，每次读都新建 suite 并 synchronize（同步落盘），主线程被拖死导致手势无响应；改为每次手势开始时读一次，手势期间复用。
2. 修复"隐藏"开关对 dyld 裁剪完全无效：TD_DYLD_TRIM 只有读端从未被写入；现在按 per-app 隐藏开关透传。
3. 修复多任务与全屏访客环境不一致：多任务走 LiveProcess 扩展进程，hideLiveContainer/四个伪值开关/全局隐藏都没传进扩展（全局隐藏只写在宿主沙盒 Documents，扩展读不到）；改为经 userInfo + app group 双向同步。
4. 修复 sysctl/SecTask/csops/proc 四个伪值门控读的是进程首次启动时的旧值：全部改为实时读环境变量。
5. 修复"应用程序分发配置文件被篡改"红项：不再伪造 0 字节 embedded.mobileprovision，profile 哈希基线恢复出厂值（空串=信任）。

20261120-010000 1.1.55 Update：
1. 回滚 1.1.54 的访客镜像路径伪值改写（全 0 UUID 被检测器识别为注入共享库，且破坏多任务+隐藏的绿色），恢复 1.1.53 真值路径。
2. 任务端口伪值门控（TD_PROC_SPOOF）改为完全实时读取：全屏常驻宿主进程不再被 init-once 缓存冻结。
3. 状态栏高度兜底改为前台窗口 safeAreaInsets.top（iOS 26 上屏幕几何差恒 0 导致 20pt 错值，via 界面异常），保留重入守卫防递归崩溃。
4. 清理 1.1.53 残留在 SecurityPresets.plist 的 profile 哈希脏值：启动时显式重置为出厂空基线（信任不校验）。
5. 音频输入改由 LiveProcess 扩展进程自授权（有前台 scene，可自激活 session/申请 TCC）；移除宿主代答，不再打断后台正在播放的 App。

20261119-180000 1.1.54 Update：
1. 修复 Reveil 等检测器"权限配置文件被篡改"红项：不再改写 SecurityPresets 的 profile 基线（空基线=信任，与原版行为一致）。
2. 修复全屏模式下"任务端口被额外引用"红项：proc 伪值门控改为实时读取环境变量，不再缓存首读结果。
3. 修复访客自身镜像路径暴露（Documents/Applications）导致的"注入的共享库"红项：dyld 枚举时伪值为正常安装路径形状。
4. 修复多任务窗口状态栏高度获取的无限递归（RCT createView 崩溃）。
5. 修复侧滑手势开关实时生效（去缓存）。

20261119-140000 1.1.53 Update：
1. 实验性新增"修复音频输入"：多任务窗口 App 的麦克风授权/会话激活经宿主代答（开关+卡片动画+独立日志弹窗，可导出/删除）。

20261119-130000 1.1.52 Update：
1. SecurityPresets 基线改为当前可见文件哈希，profile/可执行读路径字节一致（修"权限配置文件被篡改"）。
2. 删除侧滑边缘热区窗口，手势统一走 sendEvent 通路（修右缘滚动拖不动）。
3. 扩展进程退出后保活主 runloop，永不返回（修退出时 uimain SIGTRAP/被误判"已终止"）。

20261118-223000 1.1.51 Update：
1. 修复 SecurityPresets 读改写导致小红书递归爆栈（guest 读磁盘原样返回）。
2. 侧边下滑退出动画改用宿主 minimizeWindow 官方 Dock 飞入，删除自创快照动画。
3. "主可执行文件被篡改"改为对比 .td-original.executable 原始副本，删除首次运行基线。

20261118-212500 1.1.50 Update：
1. 修复虚拟窗口下无 SceneDelegate 的 App 状态栏高度为 0，内容顶入宿主状态栏。

20261118-195000 1.1.49 Update：
1. 修复 SecurityPresets entitlement 基线可能为非 NSSet 导致启动即终止。

20261118-174500 1.1.48 Update：
1. 修复辅助触控按钮 self.button 未赋值导致的拖拽、隐藏、淡化失效。
2. 恢复“保持现状”语义：沿用全局“应用内显示主屏按键”和每个 App 自己的开关；“始终显示”覆盖全部界面并新增桌面浮层。
3. 辅助触控新增空闲淡化开关与透明度设置，设置页新增动画示例卡片。
4. TweakLoader 绝对路径回退每次启动重试并写入 ConsoleLog；侧边下滑设置读取增加共享默认值回退与触摸事件缓存。
5. SecurityPresets entitlement 基线改为原包/当前包/已有允许项并集，修复 Reveil 最后一项权限红线。
6. 修复 NSDictionary hook 对 SecurityPresets 的重入 SIGBUS。
7. 崩溃采集加入单进程写入上限，避免异常路径刷盘。
8. 版本号升至 1.1.48。


20261118-150240 1.1.47 Update：
1. TweakLoader 未注入但允许加载的 App 统一从宿主 Frameworks 绝对路径 dlopen，修复侧边下滑只在部分 App 生效。
2. 启动前按 SecurityPresets.plist 修正 bundle id、mobileprovision、可执行 text 段、entitlement keys 基线，修复 Reveil 四项静态篡改红线。
3. 辅助触控初始化即设置右侧 52pt frame，不再等待可能失效的首轮布局，避免左上角不可点击。
4. 版本号升至 1.1.47。

20261118-135359 1.1.46 Update：
1. 紧急回退 1.1.44/1.1.45 的全局 fileExists/NSDictionary/task_info hook，修复除 Reveil 外所有 App 启动即终止。
2. 恢复到 1.1.43 的稳定注入基线，仅保留此前已验证不会全局崩溃的修复。
3. 版本号升至 1.1.46。

20261118-133938 1.1.45 Update：
1. 根据 全能签 IPA 的 Ghidra 反编译，hook task_info(TASK_DYLD_INFO)，隐藏 dyld image 数组，覆盖 task_info 注入库检测旁路。
2. 版本号升至 1.1.45。

20261118-133211 1.1.44 Update：
1. 清理旧版本残留的 TDPendingOpenSettings，避免侧边下滑返回后被带到设置页。
2. 补上 NSDictionary -initWithContentsOfFile: hook，覆盖 Swift plist 加载路径。
3. 虚拟 embedded.mobileprovision 文件：无真实 profile 时返回与 plist 基线一致的空数据哈希，修复 patched Reveil 的描述文件红项。
4. 版本号升至 1.1.44。

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
