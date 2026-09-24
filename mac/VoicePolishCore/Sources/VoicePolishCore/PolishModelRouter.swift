import Foundation

/// 「自动选择」润色模型路由（千问/百炼专用）。
///
/// 设置页把 `qwen_polish_model` 存成 `auto` 时生效：按质量优先的固定队列
/// 取第一个未被标记「额度用完」的模型发请求；请求层捕获到 403 额度类失败后
/// 调 `markExhausted` 并换下一个候选重试，用户无感。标记带冷却期，到期自动再试，
/// 避免误判后永久拉黑。
///
/// 队列顺序 2026-08-06 实测定（官网真机案例 × 3 轮）：各档速度差在 1 秒内、
/// 质量 max 档 > flash 档。
/// 2026-08-18 Ray 拍板：质量优先改为 qwen3.7-plus 打头——他觉得 max 档爱加编号/改写过头，
/// 3.7-plus 用词更贴近他这一版。已知代价（8-14 实测）：3.7-plus 不消解「哎不对」改口、
/// 8-06 有过一次整句编造、最慢；编号问题的根因在提示词（见 memory polish_model_auto_router），
/// 这里只是过渡，等提示词条款 v2 落码后再重新评估队列。
public enum PolishModelRouter {
    /// `qwen_polish_model` 的哨兵值：自动 · 质量优先。
    public static let autoValue = "auto"
    /// `qwen_polish_model` 的哨兵值：自动 · 速度优先。
    public static let autoSpeedValue = "auto-speed"

    /// 质量优先队列。每个模型在百炼各送 100 万 Token 免费额度（北京地域）。
    public static let qualityChain = ["qwen3.7-plus", "qwen3.8-max", "qwen3.7-max", "qwen3.7-flash", "qwen3.6-flash"]

    /// 速度优先队列：flash 档先上（按质量从高到低；实测出字约 130 字/秒 vs max 档约 75 字/秒，
    /// 长段落差距明显），flash 免费额度都用完后再落 max 档继续免费。
    public static let speedChain = ["qwen3.7-flash", "qwen3.6-flash", "qwen3.8-max", "qwen3.7-max"]

    /// 队列全部被标记时的兜底：付费单价最便宜的模型（用户若关了「用完即停」，走它花费最少）。
    public static let lastResort = "qwen3.7-flash"

    /// 额度标记冷却 20 小时：免费额度当天不会恢复，次日自动重试一次也只花一个极快的 403。
    public static let cooldown: TimeInterval = 20 * 3600
    /// 模型未开通 / 无权限：用户去控制台开通后应尽快恢复，只冷却 1 小时
    static let unavailableCooldown: TimeInterval = 3600

    /// 哪些润色错误要标记冷却并换下一个模型；nil = 不降级（网络等错误原样返回）
    static func cooldown(for error: AIPolisher.PolishError) -> TimeInterval? {
        switch error {
        case .quotaExhausted: return cooldown
        case .modelUnavailable: return unavailableCooldown
        default: return nil
        }
    }

    static func exhaustedKey(_ model: String) -> String { "polish_auto_exhausted_until." + model }

    public static func isAuto(_ value: String?) -> Bool { value == autoValue || value == autoSpeedValue }

    /// 依次尝试的候选列表（已跳过冷却中的模型）；全被标记时退化为 [lastResort]。
    /// `value` 传设置里存的哨兵值：`auto-speed` 用速度优先队列，其余用质量优先队列。
    public static func candidates(for value: String? = nil, now: Date = Date(), defaults: UserDefaults = .standard) -> [String] {
        let chain = (value == autoSpeedValue) ? speedChain : qualityChain
        let free = chain.filter { !isExhausted($0, now: now, defaults: defaults) }
        return free.isEmpty ? [lastResort] : free
    }

    /// 标记某模型额度类失败（403），冷却期内自动路由与设置页都视为「额度可能已用完」。
    public static func markExhausted(_ model: String, for duration: TimeInterval = cooldown,
                                     now: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(now.timeIntervalSince1970 + duration, forKey: exhaustedKey(model))
    }

    public static func isExhausted(_ model: String, now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        now.timeIntervalSince1970 < defaults.double(forKey: exhaustedKey(model))
    }
}
