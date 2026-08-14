import Foundation

/// 日期工具 —— 与原 Electron 版 store.js 中的 pad / ymd / ym / hms / isoLocal 行为完全一致。
/// 全部基于「本地时区」，不要改成 UTC，否则历史数据目录会对不上。
enum DateUtil {

    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()

    @inline(__always)
    static func pad(_ n: Int) -> String {
        n < 10 && n >= 0 ? "0\(n)" : String(n)
    }

    struct Parts {
        var year = 0, month = 0, day = 0, hour = 0, minute = 0, second = 0
    }

    static func parts(_ d: Date) -> Parts {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: d)
        return Parts(year: c.year ?? 0, month: c.month ?? 0, day: c.day ?? 0,
                     hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0)
    }

    /// YYYY-MM-DD
    static func ymd(_ d: Date) -> String {
        let p = parts(d)
        return "\(p.year)-\(pad(p.month))-\(pad(p.day))"
    }

    /// YYYY-MM
    static func ym(_ d: Date) -> String {
        let p = parts(d)
        return "\(p.year)-\(pad(p.month))"
    }

    /// HH-mm-ss（文件名用）
    static func hms(_ d: Date) -> String {
        let p = parts(d)
        return "\(pad(p.hour))-\(pad(p.minute))-\(pad(p.second))"
    }

    /// HH:mm:ss（JS 的 toTimeString().slice(0,8)）
    static func clockTime(_ d: Date) -> String {
        let p = parts(d)
        return "\(pad(p.hour)):\(pad(p.minute)):\(pad(p.second))"
    }

    /// HH:mm
    static func clockShort(_ d: Date) -> String {
        let p = parts(d)
        return "\(pad(p.hour)):\(pad(p.minute))"
    }

    /// 本地带时区偏移的 ISO 串：2026-08-06T09:53:33+08:00
    static func isoLocal(_ d: Date) -> String {
        let offSec = TimeZone.current.secondsFromGMT(for: d)
        let offMin = offSec / 60
        let sign = offMin >= 0 ? "+" : "-"
        let a = abs(offMin)
        let p = parts(d)
        return "\(ymd(d))T\(pad(p.hour)):\(pad(p.minute)):\(pad(p.second))\(sign)\(pad(a / 60)):\(pad(a % 60))"
    }

    static func hour(_ d: Date) -> Int { parts(d).hour }

    /// 当前小时（0...23），洞察页时间分布高亮用
    static func currentHour() -> Int { hour(Date()) }

    /// 解析 'YYYY-MM-DD' → 本地当天 0 点
    static func parseDateStr(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count == 10 else { return nil }
        let seg = t.split(separator: "-")
        guard seg.count == 3,
              let y = Int(seg[0]), let m = Int(seg[1]), let d = Int(seg[2]),
              seg[0].count == 4, seg[1].count == 2, seg[2].count == 2,
              m >= 1, m <= 12, d >= 1, d <= 31 else { return nil }
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        c.hour = 0; c.minute = 0; c.second = 0
        return calendar.date(from: c)
    }

    /// 把某个日期换成当天指定小时的 0 分 0 秒
    static func atHour(_ d: Date, _ h: Int) -> Date {
        calendar.date(bySettingHour: h, minute: 0, second: 0, of: d) ?? d
    }

    /// 当天 0 点
    static func startOfDay(_ d: Date) -> Date { calendar.startOfDay(for: d) }

    static func addDays(_ d: Date, _ n: Int) -> Date {
        calendar.date(byAdding: .day, value: n, to: d) ?? d
    }

    static func addHours(_ d: Date, _ n: Int) -> Date {
        calendar.date(byAdding: .hour, value: n, to: d) ?? d
    }

    /// 毫秒时间戳
    static func epochMs(_ d: Date = Date()) -> Int64 {
        Int64((d.timeIntervalSince1970 * 1000).rounded())
    }

    static func fromEpochMs(_ ms: Int64) -> Date {
        Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    /// UTC ISO8601（对应 JS 的 new Date().toISOString()，用于 summary.generatedAt）
    static func isoUTC(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: d)
    }

    /// 解析 summary.generatedAt（UTC ISO），失败返回 nil
    static func parseISO(_ s: String) -> Date? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: s) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: s)
    }

    /// 中文星期
    static func weekdayCN(_ d: Date) -> String {
        let w = calendar.component(.weekday, from: d) // 1=周日
        let names = ["日", "一", "二", "三", "四", "五", "六"]
        return "周" + names[max(0, min(6, w - 1))]
    }

    /// 该日期所在周（周一为首日）的 7 天日期串
    static func weekDates(of d: Date) -> [String] {
        let day = calendar.component(.weekday, from: d) // 1=周日 … 7=周六
        let deltaToMonday = (day == 1) ? -6 : (2 - day)
        let monday = startOfDay(addDays(d, deltaToMonday))
        return (0..<7).map { ymd(addDays(monday, $0)) }
    }

    /// 该日期所在月的全部日期串
    static func monthDates(of d: Date) -> [String] {
        let p = parts(d)
        var c = DateComponents(); c.year = p.year; c.month = p.month; c.day = 1
        guard let first = calendar.date(from: c),
              let range = calendar.range(of: .day, in: .month, for: first) else { return [ymd(d)] }
        return range.map { ymd(addDays(first, $0 - 1)) }
    }

    /// 该日期所在年的全部日期串（用于年报，量大但只做文本聚合）
    static func yearDates(of d: Date) -> [String] {
        let p = parts(d)
        var out: [String] = []
        for m in 1...12 {
            var c = DateComponents(); c.year = p.year; c.month = m; c.day = 1
            guard let first = calendar.date(from: c),
                  let range = calendar.range(of: .day, in: .month, for: first) else { continue }
            for i in range { out.append(ymd(addDays(first, i - 1))) }
        }
        return out
    }
}

@inline(__always)
func clampVal<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
    min(hi, max(lo, v))
}

/// 人类可读字节数（1:1 对应 renderer.js fmtBytes：B 取整、KB/MB 一位、GB 两位小数）
func formatBytes(_ n: Int64) -> String {
    let b = Double(n)
    if b < 1024 { return "\(Int(b)) B" }
    if b < 1_048_576 { return String(format: "%.1f KB", b / 1024) }
    if b < 1_073_741_824 { return String(format: "%.1f MB", b / 1_048_576) }
    return String(format: "%.2f GB", b / 1_073_741_824)
}
