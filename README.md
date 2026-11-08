# 翻译一下

macOS 划词、截图与输入翻译应用，支持 macOS 13 及以上版本，提供 Apple Silicon 与 Intel 通用安装包。

[下载 v1.0.1 安装包](https://github.com/cjy20010719/fanyi-yixia/releases/download/v1.0.1/Yi-1.0.1-universal.dmg) · [发布页面与校验文件](https://github.com/cjy20010719/fanyi-yixia/releases)

## 安装

打开 DMG，将「翻译一下.app」拖入 Applications，再从应用程序文件夹启动。在系统设置中按需启用辅助功能和屏幕录制权限。本应用使用本地临时签名，没有 Apple Developer ID 签名与公证；首次打开可能被 macOS 阻止，请先核对发布页的 SHA256SUMS.txt，并参考 [Apple 官方说明](https://support.apple.com/zh-cn/102445)。

## 功能

- 自动划词翻译、截图本机 OCR 与输入后自动翻译；默认自动识别原文并译成简体中文，支持多语言目标切换。
- 菜单中的「翻译源」可选择 Google 或有道，自动保存选择。两者均为免密钥接入，可能限流或因接口变化暂时不可用，不承诺无限额度。
- 默认 Option＋A 翻译选中文字，Option＋S 框选截图，Option＋D 开关自动划词，Option＋Command＋A 打开主界面。「快捷键设置…」可自定义。
- 输入停止约 0.6 秒自动翻译，回车立即翻译，Shift＋回车换行，支持输入法组词。
- 白色、黑色、浅色玻璃和深色玻璃四种气泡。切换后自动预览；按住复制按钮左侧图标上下拖动可调背景深浅并自动保存。长译文可滚动阅读。
- 点击菜单栏图标显示或隐藏主窗口，右键打开功能菜单。开启「开机静默启动」后登录时后台启动。
- 主窗口黄色按钮最小化后进入 Dock 与 Command＋Tab，切回时恢复主窗口。

## 隐私与兼容性

原文只发送给当前选择的翻译服务；截图在本机使用 Apple Vision 识别，图像不会上传。不保存翻译历史。玻璃气泡可临时读取背后的屏幕区域，在本机模糊后显示，相关画面在内存中处理。

划词需要辅助功能权限，截图与玻璃背景读取需要屏幕录制权限。经用户开启「兼容取词」后，可在标准选区读取失败时临时复制选中文字，并尽量恢复原剪贴板；遇到新的复制操作会优先保留新内容。图片、扫描件和不提供选区的应用请使用截图翻译。

## 构建与图标

需要 macOS 和 Command Line Tools。在项目根目录运行 `zsh build.sh`，生成 `dist/翻译一下.app`；`zsh package.sh` 生成 Universal DMG、ZIP、安装说明和 SHA256 校验文件。

`Assets/Yi.png` 是应用图标原图，`Assets/AppIcon.icns` 用于 Finder、Dock、主窗口与关于窗口。`Assets/MenuBarIcon.png` 是从同一原图预生成的透明图案，运行时只加载小图并由系统模板着色。`zsh build-icon.sh` 可重建图标。

## 自动更新与发布

Sparkle 2.10.1 使用 GitHub Releases 提供更新 ZIP，GitHub Pages 提供 [签名 appcast](https://cjy20010719.github.io/fanyi-yixia/appcast.xml)。默认每天检查，用户确认后下载安装；菜单可手动检查或关闭自动检查。更新源和更新包均验证 EdDSA 签名。

当前版本为 1.0.1（构建 102）。已安装 1.0.0 的用户可从菜单栏检查更新。临时签名可能导致更新后需要重新授予系统隐私权限。

后续在持有原 EdDSA 私钥并已登录 GitHub 的 Mac 上，提交代码与新版本说明后运行：

```sh
zsh scripts/release.sh 1.0.2 docs/release-v1.0.2.md
```

私钥保存在仓库外，不进入源码、GitHub、CI、安装包或日志。GitHub Actions 仅构建和验证应用，发布签名在本机执行。详见 [发布维护说明](docs/发布维护.md)。
