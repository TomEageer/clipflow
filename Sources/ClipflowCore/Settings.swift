import Foundation

/// 用户设置。存 UserDefaults，Core 只负责定义与读写，不碰 UI。
public struct ClipflowSettings: Codable, Sendable, Equatable {

    /// 历史保留期。到期条目会被清理。
    public enum Retention: Int, Codable, Sendable, CaseIterable {
        case days7 = 7
        case days30 = 30
        case days90 = 90
        case days365 = 365
        case forever = 0

        public var label: String {
            switch self {
            case .days7: return "7 天"
            case .days30: return "30 天"
            case .days90: return "90 天"
            case .days365: return "1 年"
            case .forever: return "永久保留"
            }
        }
    }

    /// 敏感内容（token/密码）的保留时长。默认很短 —— 这类内容留着就是风险。
    public enum SensitiveTTL: Int, Codable, Sendable, CaseIterable {
        case seconds60 = 60
        case minutes10 = 600
        case hours1 = 3600
        case sameAsNormal = -1
        case never = 0

        public var label: String {
            switch self {
            case .seconds60: return "60 秒后删除"
            case .minutes10: return "10 分钟后删除"
            case .hours1: return "1 小时后删除"
            case .sameAsNormal: return "与普通条目相同"
            case .never: return "不记录敏感内容"
            }
        }
    }

    public var retention: Retention = .days365
    public var sensitiveTTL: SensitiveTTL = .seconds60
    /// 条目数上限，0 = 不限。到达上限时按最久未用淘汰。
    public var maxItems: Int = 0
    /// 存储上限（MB），0 = 不限。超过时从最久未用开始清理。
    public var maxStorageMB: Int = 2048
    /// 单条最大字节，超过不记录
    public var maxItemSizeMB: Int = 50
    /// 被排除的来源 App（bundle id）
    public var excludedBundleIDs: [String] = []
    /// 启动时捕获剪贴板已有内容
    public var captureOnStart: Bool = true
    /// 启动时自动检查更新。默认开，但这是本应用唯一的网络请求，可随时关掉。
    public var autoCheckUpdates: Bool = true
    /// 对图片做文字识别，让截图里的文字可被搜索。完全本地（Vision 框架），但耗电。
    public var enableOCR: Bool = true

    /// 面板尺寸。用户可自由拉伸，记住上次的大小。
    public var panelWidth: Double = 720
    public var panelHeight: Double = 480

    /// 列表占面板宽度的比例，剩下的给预览。拖分隔条时更新。
    /// 存**比例**而不是像素宽度：面板本身可自由拉伸，存死宽度的话
    /// 把窗口拉宽后所有增量都会压给预览，列表永远保持原样。
    public var splitRatio: Double = 0.53

    /// 预览区里「原文」占的高度比例，剩下的给「处理结果」。拖中间那条横杠时更新。
    /// 同样存比例不存像素 —— 面板高度会变。
    public var previewSplitRatio: Double = 0.5

    /// 界面缩放。默认 1.0；小屏或视力需要时调大，所有字号与间距按比例走。
    public var uiScale: Double = 1.0

    /// 开发者模式：自动识别 JSON 并格式化预览，启用粘贴变换（JSON / URL / Base64 等）。
    /// 默认关 —— 对非程序员完全隐形。
    public var developerMode: Bool = false

    public init() {}

    // MARK: 解码容错
    //
    // ⚠️ **必须手写 `init(from:)`，不能用合成的。**
    //
    // Swift 合成的 Decodable 对缺失的非可选字段直接抛 `keyNotFound`，
    // **不会**回退到属性的默认值。而 `load()` 用 `try?` 吞异常 → 返回全默认值。
    // 后果：**每加一个设置字段，用户已存的所有设置被静默清空** ——
    // 面板尺寸、分栏比例、开发者模式、保留期一起回到出厂状态，还不报错。
    // 实测踩过两次（加 splitRatio、加 previewSplitRatio）。
    //
    // 逐字段 `decodeIfPresent ?? 默认值` 之后，加字段就永远安全了。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ClipflowSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: k)) ?? nil) ?? fallback
        }
        retention        = v(.retention, d.retention)
        sensitiveTTL     = v(.sensitiveTTL, d.sensitiveTTL)
        maxItems         = v(.maxItems, d.maxItems)
        maxStorageMB     = v(.maxStorageMB, d.maxStorageMB)
        maxItemSizeMB    = v(.maxItemSizeMB, d.maxItemSizeMB)
        excludedBundleIDs = v(.excludedBundleIDs, d.excludedBundleIDs)
        captureOnStart   = v(.captureOnStart, d.captureOnStart)
        autoCheckUpdates = v(.autoCheckUpdates, d.autoCheckUpdates)
        enableOCR        = v(.enableOCR, d.enableOCR)
        panelWidth       = v(.panelWidth, d.panelWidth)
        panelHeight      = v(.panelHeight, d.panelHeight)
        splitRatio       = v(.splitRatio, d.splitRatio)
        previewSplitRatio = v(.previewSplitRatio, d.previewSplitRatio)
        uiScale          = v(.uiScale, d.uiScale)
        developerMode    = v(.developerMode, d.developerMode)
    }

    // MARK: 持久化

    private static let key = "com.tomeageer.clipflow.settings"

    public static func load(from defaults: UserDefaults = .standard) -> ClipflowSettings {
        guard let data = defaults.data(forKey: key),
              let s = try? JSONDecoder().decode(ClipflowSettings.self, from: data) else {
            return ClipflowSettings()
        }
        return s
    }

    public func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

// MARK: - 清理

extension ClipflowStore {

    public struct CleanupResult: Sendable {
        public var byRetention = 0
        public var bySensitiveTTL = 0
        public var byMaxItems = 0
        public var byStorage = 0
        public var freedBytes = 0
        public var total: Int { byRetention + bySensitiveTTL + byMaxItems + byStorage }
    }

    /// 按设置清理过期与超量内容。
    ///
    /// 顺序有意义：先按时间清（语义最明确），再按数量/体积兜底。
    /// **已分组的条目永不自动清理** —— 用户明确归过类的东西不能悄悄删掉。
    /// （原来是置顶条目受保护，置顶已被分组取代。）
    @discardableResult
    public func cleanup(settings: ClipflowSettings, now: Date = Date()) throws -> CleanupResult {
        var r = CleanupResult()
        let before = try stats().totalBytes

        // ① 敏感条目 TTL
        switch settings.sensitiveTTL {
        case .never, .sameAsNormal:
            break
        case .seconds60, .minutes10, .hours1:
            let cutoff = now.addingTimeInterval(-Double(settings.sensitiveTTL.rawValue))
            r.bySensitiveTTL = try deleteWhere(
                "sensitivity = 1 AND groupID IS NULL AND createdAt < ?", [cutoff])
        }

        // ② 保留期
        if settings.retention != .forever {
            let cutoff = now.addingTimeInterval(-Double(settings.retention.rawValue) * 86400)
            r.byRetention = try deleteWhere("groupID IS NULL AND lastUsedAt < ?", [cutoff])
        }

        // ③ 条目数上限：淘汰最久未用的
        if settings.maxItems > 0 {
            r.byMaxItems = try deleteOldestBeyond(limit: settings.maxItems)
        }

        // ④ 存储上限
        if settings.maxStorageMB > 0 {
            let budget = settings.maxStorageMB * 1024 * 1024
            var guardCount = 0
            while try stats().totalBytes > budget, guardCount < 50 {
                let removed = try deleteOldestBatch(count: 200)
                if removed == 0 { break }
                r.byStorage += removed
                guardCount += 1
            }
        }

        r.freedBytes = max(0, before - (try stats().totalBytes))
        return r
    }

    /// 清理不再被任何 representation 引用的 blob。
    /// 删条目只删了数据库行，CAS 里的文件要单独回收，否则磁盘只涨不降。
    @discardableResult
    public func vacuumBlobs() throws -> (removed: Int, freed: Int) {
        let referenced = Set(try allBlobHashes())
        var removed = 0, freed = 0
        guard let e = FileManager.default.enumerator(
            at: paths.blobs, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else {
            return (0, 0)
        }
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  v.isRegularFile == true else { continue }
            let hash = url.lastPathComponent
            if !referenced.contains(hash) {
                freed += v.fileSize ?? 0
                try? FileManager.default.removeItem(at: url)
                removed += 1
            }
        }
        return (removed, freed)
    }
}
