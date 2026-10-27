import Foundation
import ServiceManagement

@MainActor
enum AppLanguage {
    static var selection: String {
        get { UserDefaults.standard.string(forKey: "appLanguage") ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: "appLanguage") }
    }
    static var english: Bool {
        selection == "en" || (selection == "system" && !(Locale.preferredLanguages.first ?? "en").hasPrefix("zh"))
    }
    static func text(_ value: String) -> String {
        guard english else { return value }
        if let result = translations[value] { return result }
        for (key, translated) in translations where value.hasPrefix(key + " · ") {
            return translated + value.dropFirst(key.count)
        }
        let patterns = [
            ("^屏幕 ([0-9]+)", "Display $1"),
            ("^未连接 · ", "Disconnected · "),
            ("^切换间隔 · ([0-9]+) 秒$", "Interval · $1 seconds"),
            ("^背景列表 · 第 ([0-9]+)/([0-9]+) 项$", "Playlist · $1/$2"),
            ("^([0-9]+) 秒$", "$1 seconds"), ("^([0-9]+) 分钟$", "$1 minutes"),
            ("^([0-9]+) 项$", "$1 items"), ("^([0-9]+) 个字符$", "$1 characters"),
            ("^([0-9]+) 个文件$", "$1 files"), ("^([0-9]+) 分钟前$", "$1 min ago"),
            ("^([0-9]+) 小时前$", "$1 hr ago"), ("^([0-9]+) 天前$", "$1 days ago")
        ]
        for (pattern, replacement) in patterns {
            if let expression = try? NSRegularExpression(pattern: pattern),
               expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil {
                return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: replacement)
            }
        }
        return value
    }
    static let translations: [String: String] = [
        " · 点击修改": " · Change", "刚刚": "Just now", " · 主屏": " · Main",
        "编辑所选项的分组与别名": "Edit group and alias", "撤销删除（⌘Z）": "Undo last deletion (⌘Z)",
        "剪贴板分组": "Clipboard groups", "搜索剪贴板历史": "Search clipboard history", "撤销删除": "Undo deletion",
        "固定此项（不自动过期）": "Pin (does not expire)", "取消固定（恢复普通保留规则）": "Unpin (normal retention applies)",
        "未固定": "Not pinned", "轻工具 · 剪贴板列表": "Light Tools · Clipboard",
        "背景详细设置…": "Wallpaper Settings…", "未检测到可配置的屏幕": "No displays available",
        "适用于所有屏幕和以后选择的背景。各屏幕的文件与播放操作请使用菜单栏。": "Applies to all displays and future backgrounds. Use the menu bar for each display’s files and playback.",
        "设置": "Settings", "通用": "General", "剪贴板": "Clipboard", "桌面背景": "Wallpaper",
        "轻工具": "Light Tools", "剪贴板列表…": "Clipboard History…", "设置…": "Settings…",
        "剪贴板设置": "Clipboard Settings", "关于轻工具": "About Light Tools", "退出": "Quit",
        "记录新的剪贴板内容": "Record new clipboard content", "历史保留时间": "Keep history for",
        "7 天": "7 days", "30 天": "30 days", "呼出快捷键": "Global shortcut", "恢复默认": "Reset",
        "录制快捷键…": "Record shortcut…", "请按新快捷键…": "Press a shortcut…",
        "回车或双击时直接粘贴到原应用": "Paste into the previous app on Return or double-click",
        "管理记录方式、历史保留时间与粘贴行为。": "Manage capture, retention, and paste behavior.",
        "直接粘贴需要 macOS 辅助功能授权。不开启也可复制后按 ⌘V。": "Direct paste requires Accessibility permission. Otherwise, copy and press ⌘V.",
        "辅助功能已授权。开启后可直接粘贴到原应用。": "Accessibility access is granted. Enable direct paste to paste into the previous app.",
        "已选择开启，等待辅助功能授权，暂时仅复制。若已授权仍无效，请退出本应用，在系统设置中移除旧条目，重新添加当前版本，再打开应用。": "Enabled, awaiting Accessibility permission; currently copies only. If access still fails, quit, remove the old entry in System Settings, and add this version again.",
        "缓存上限：100 条记录，图片共 256 MB。\n图片保存本地副本；文件仅保存引用，不复制原文件。\n固定项最多 20 条，不自动过期；容量优先保留固定项。": "Limits: 100 entries and 256 MB of images.\nImages are stored locally; files are references, not copies.\nUp to 20 pins; pins do not expire and take priority.",
        "仅存储在本机。跳过系统标记为敏感的内容；没有敏感标记的内容仍可能被记录。": "Stored only on this Mac. Sensitive-marked content is skipped; unmarked secrets may still be recorded.",
        "清空全部历史…": "Clear All History…", "清空全部剪贴板历史？": "Clear all clipboard history?",
        "删除所有历史（包括固定项）和缓存图片，原文件与系统当前剪贴板不受影响。": "Deletes history (including pins) and cached images. Original files and the current clipboard are unchanged.",
        "清空历史": "Clear History", "取消": "Cancel", "保存": "Save", "知道了": "OK",
        "历史": "History", "已固定": "Pinned", "文字": "Text", "链接": "Links", "图片": "Images", "文件": "Files",
        "复制所选": "Copy", "粘贴所选": "Paste", "删除": "Delete", "全部分组": "All Groups", "未分组": "Ungrouped",
        "搜索 / 拼音 / 首字母": "Search / Pinyin", "分组与别名": "Group & Alias", "别名": "Alias",
        "分组（设置分组会固定此项）": "Group (adding a group pins this item)",
        "别名（可留空，不修改原内容）": "Alias (optional; original content is unchanged)",
        "选择或输入新分组，留空取消分组": "Choose or type a group; leave blank to remove",
        "关闭列表": "Close", "来源未记录": "Source unavailable", "取消固定": "Unpin", "固定此项": "Pin",
        "直接输入搜索 · ⌥←→ 选择 · 回车复制 · ⌘P 固定 · ⌫ 删除": "Type to search · ⌥←→ select · Return copy · ⌘P pin · ⌫ delete",
        "记录已暂停，可在设置中开启": "Recording paused. Enable it in Settings.",
        "没有匹配的历史。试试其他关键词或切换内容类型。": "No matches. Try another search or content type.",
        "请选择屏幕": "Select a display", "使用系统当前背景": "Using the system wallpaper",
        "已保存，等待连接": "Saved; waiting for display", "照片": "Photo", "视频已停止": "Video stopped",
        "桌面被遮挡，已暂停": "Paused while covered", "视频播放中": "Video playing",
        "低电量模式已停播": "Paused in Low Power Mode", "视频待恢复": "Video waiting to resume",
        "正在生成低耗副本（首次需要片刻）…": "Preparing optimized video…", "正在读取文件…": "Reading files…",
        "选择背景文件…（可多选图片和视频）": "Choose Files… (photos and videos)",
        "下一项": "Next Background", "自动轮换": "Auto Rotate", "自定义秒数…": "Custom Seconds…",
        "低耗 · 1080p / 30 fps": "Economy · 1080p / 30 fps", "均衡 · 1440p / 30 fps": "Balanced · 1440p / 30 fps",
        "原画 · 原始分辨率和帧率": "Original · full resolution and frame rate",
        "低内存循环（接缝可能短暂停顿）": "Efficient loop (may pause at the seam)",
        "无缝循环（预加载下一轮）": "Seamless loop (preloads the next cycle)",
        "恢复此屏背景": "Resume Wallpaper", "停止此屏视频与轮换": "Stop Video & Rotation",
        "重新加载此屏视频": "Reload Video", "清除此屏配置（保留系统壁纸）": "Clear Configuration (keep system wallpaper)",
        "停止全部视频与轮换": "Stop All Videos & Rotation", "桌面被遮挡时自动暂停": "Pause when the desktop is covered",
        "休眠 / 低电量模式自动停播": "Playback pauses during sleep / Low Power Mode",
        "轻壁纸 · 每屏独立背景": "Independent wallpaper per display", "配置自动保存，重启与重连后恢复": "Settings are saved and restored automatically",
        "无法保存剪贴板设置": "Could Not Save Settings", "剪贴板操作未完成": "Clipboard Action Failed",
        "内容已复制，未自动粘贴": "Copied, but not pasted automatically",
        "请包含 ⌘、⌃ 或 ⌥，再加字母、数字或空格。": "Use ⌘, ⌃, or ⌥ with a letter, number, or Space.",
        "按 ⌘ / ⌃ / ⌥ 与字母、数字或空格组合；Esc 取消。": "Press ⌘ / ⌃ / ⌥ with a letter, number, or Space. Esc cancels.",
        "无法注册此快捷键，可能已被占用；已保留原快捷键。": "Shortcut unavailable. Your previous shortcut is unchanged."
    ]
}

@MainActor
struct LoginItemAccess {
    var status: () -> SMAppService.Status
    var register: () throws -> Void
    var unregister: () throws -> Void
    static var system: Self {
        Self(status: { SMAppService.mainApp.status }, register: { try SMAppService.mainApp.register() }, unregister: { try SMAppService.mainApp.unregister() })
    }
}
