20261115-191936 1.1.11 Update：
1. 全局隐藏标记路径错误修复：NSHomeDirectory() 在第一个访客启动后会被 setenv 到访客容器且不再恢复，导致 iManager 写入和 LCBootstrap 读取都落在错误容器。改为使用宿主 .app bundle 路径（恒定）。

[编译环境]
构建时自动填充
