# 轻工具 · Light Tools

项目仓库：[ZhuTango/light-tools](https://github.com/ZhuTango/light-tools)。面向 macOS 的轻量工具合集，后续工具统一接入菜单栏与设置。

原生 Swift / AppKit macOS 菜单栏工具，包含多屏桌面背景、剪贴板历史和统一设置。当前版本 **1.8.4**，支持 macOS 13 及以上。

无第三方运行时依赖，无常驻网页引擎；应用不联网，数据仅保存在本机。

## 发布管理

版本流程见 [发布规则](RELEASING.md)，版本变更见 [更新日志](CHANGELOG.md)。

## 功能

### 桌面背景

- 每个显示器独立选择图片、视频或混合列表，按显示器 UUID 保存配置。
- 菜单栏只显示已连接的显示器，提供选择文件、下一项、轮换间隔、停止/恢复和清除配置。
- 断开显示器后保留配置，重新连接时恢复。
- 支持自动轮换，间隔可设为 10–86400 秒。
- 统一设置中的画质选项适用于所有屏幕：原画（默认）、均衡（1440p/30 fps）、低耗（1080p/30 fps）。
- 支持低内存循环与无缝循环；桌面被完全遮挡时可自动暂停，休眠和低电量模式下暂停播放。
- 同一视频及播放配置共享播放器；视频资源消耗仍取决于分辨率、帧率、编码和显示器数量。

### 剪贴板

- 保存文字、图片和文件引用；图片保存本地副本，文件不复制原文件。
- 搜索支持中文、拼音、首字母和匹配高亮。
- 支持固定、分组、别名和当前会话内撤销最近一次删除。
- 保留时间可选 7 / 30 天，最多 100 条记录，图片缓存上限 256 MiB。
- 最多固定 20 条；固定项不自动过期，手动删除或清空仍会移除。
- 可配置全局呼出快捷键；打开后直接输入搜索。
- 回车或双击复制，可选自动粘贴到原应用；自动粘贴需要辅助功能权限。
- 横向滚动与懒加载，非文字编辑状态下可按 Backspace 删除。

### 设置

通用、剪贴板、桌面背景集中在同一窗口，支持中文/英文、跟随系统语言、登录时启动。使用分组卡片和悬停/按下反馈，动效遵循系统减少动态效果偏好。部分诊断信息尚未完整本地化。

## 构建与运行

需要 macOS 13+ 和 Apple Command Line Tools：

```sh
xcode-select --install
bash scripts/build.sh
open 'dist/轻工具.app'
```

构建脚本使用本机 Swift 编译器和 ad-hoc 签名，不下载第三方依赖。默认输出 `dist/轻工具.app`；可用 `OUTPUT_APP` 指定输出路径。运行新版前先退出旧版。

```sh
OUTPUT_APP='.build/release/轻工具.app' bash scripts/build.sh
```

## 验证

```sh
# 剪贴板数据逻辑
bash scripts/test.sh --clipboard-only

# 全局背景偏好持久化，不修改真实桌面
bash scripts/test.sh --wallpaper-preferences-only

# AppKit 界面与交互检查，需要桌面会话
bash scripts/test-clipboard-ui.sh

# 完整背景检查：会临时操作桌面背景与播放窗口
bash scripts/test.sh
```

自动化界面检查使用隔离数据与测试剪贴板，不等同于真实应用中的粘贴验收。测试截图、日志与构建产物不提交到仓库。

## 数据与权限

背景配置位于 `~/Library/Application Support/local.tango.macbglive/displays.json`，剪贴板数据也存于此应用的本地支持目录。背景转码缓存位于 `~/Library/Caches/local.tango.macbglive/video-v1/`。

- 原始背景文件不会修改；文件被移动或删除后需重新选择。
- 转码缓存目前不自动清理历史副本。
- 剪贴板记录可暂停，默认不会上传任何内容；无敏感标记的内容仍可能被记录。
- ad-hoc 签名会随重新编译变化，辅助功能授权可能需要重新添加当前应用。正式分发建议使用稳定的开发者签名。
- 开机启动默认关闭，通过 macOS 登录项服务注册。

## 目录

- `Sources/WallpaperCore`：背景配置、缓存、播放器和屏幕管理。
- `Sources/ToolCore`：剪贴板存储与搜索。
- `Sources/WallpaperApp`：菜单栏和 AppKit 界面。
- `Tests`：核心逻辑检查。
- `scripts`：构建、图标生成和界面测试。
- `Resources`：应用元数据。
