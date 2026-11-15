20261115-175014 1.1.5 Update：
1. 全局隐藏模式正式接线（默认关）：开启后对所有访客启用 sysctl/proc 伪值层；per-app 隐藏仍按各自开关生效。
2. 不再启用 csops/SecTask 伪值与二次 dyld 裁剪（1.1.3 已证实会新增异常项）。
3. HideShim 重新编入 LiveContainerShared，并由 LCBootstrap 在访客 dlopen 前安装。

[编译环境]
构建时自动填充
