20261115-185913 1.1.9 Update：
1. 修复全局隐藏模式无效：NUDUserDefaults hook 会把 standardUserDefaults 域改写为访客域，导致 LCBootstrap 读不到宿主的全局开关。将读取提前到 NUD hook 之前。
2. 启动日志新增 [TDGlobalHide] guest/global (pre-NUD)，可在 td-console.log 中核对。

[编译环境]
构建时自动填充
