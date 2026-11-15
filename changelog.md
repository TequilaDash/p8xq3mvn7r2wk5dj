20261115-181322 1.1.6 Update：
1. 修复 iManager 页“全局隐藏模式”开关未进入构建的问题（改用 @AppStorage("TDGlobalSpoof") 直读标准域）。
2. 保持 1.1.5 的隐藏层范围：全局开关仅启用 sysctl/proc 伪值；csops/SecTask/二次 dyld 裁剪不启用。

[编译环境]
构建时自动填充
