20261115-171423 1.1.3 Update：
1. 将 iManager 隐藏扩展层接入 zcontainer 访客启动：per-app 隐藏开启时同时启用 sysctl/SecTask/csops/proc 伪值与 dyld 镜像裁剪。
2. iManager 隐藏实现迁至 iManager/HideShim，作为 LiveContainer target 的同步文件夹编译。
3. 隐藏状态页与设置入口去注释化；dyld 覆盖率按 per-app hide 统计。

[编译环境]
Xcode: 构建时自动填充
Build: 构建时自动填充
SDK: 构建时自动填充
