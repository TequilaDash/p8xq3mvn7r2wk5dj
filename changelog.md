20261115-071829 1.1.1 Update：
1. 主线上游切换为 zcontainer 1.1（getzeusapp/LiveContainer zcontainer 分支），根目录与上游逐文件对齐（仅保留 iManager/、changelog.md、imanager-release.yml、设置页入口、pbxproj 同步组五处本仓增量）。
2. TequilaDa自杀 源码整体迁入 iManager/，作为 zcontainer 内置功能（设置 → iManager，TequilaDash 图标/名称 iManager）。
3. 移除旧沙盒容器实现与独立 App 外壳（TDLCWindow/TDLCUIHost/LCUtils 桥/多任务桥/Sandbox 视图/旧 LiveProcess/Tunnel 扩展/HostGuestEntry/App.swift）。
4. 首片内置功能：全局隐藏模式开关、隐藏状态、exploit 日志。
5. 子模块严格对齐上游提交：OpenSSL 623c84da、litehook a7e9f59（无 fishhook）；CI 使用上游归档 + .github/build_github.sh 打包单 IPA。

[编译环境]
Xcode: Xcode 26.6 Build version 17F113
Build: 25G332
SDK: 26.5
