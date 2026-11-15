20261115-190819 1.1.10 Update：
1. 全局隐藏改用文件标记（Documents/TDGlobalHide），绕开 NUDUserDefaults 进程级 hook —— 该 hook 在首个访客运行后常驻，会把后续所有 NSUserDefaults 读写重定向到访客域，导致全局开关读取失效。
2. iManager 页开关与隐藏状态页同步改为读/写该文件标记。

[编译环境]
构建时自动填充
