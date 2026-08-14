import AppKit

// 单实例锁：已经有一个「留刻」在跑就把它唤到前台，自己退出
// 用实际 bundle id（而不是写死常量），这样 .app 之外的调试副本不会被误挡
let selfBundleId = Bundle.main.bundleIdentifier ?? AppInfo.bundleId
let runningSame = NSRunningApplication.runningApplications(withBundleIdentifier: selfBundleId)
    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
if !runningSame.isEmpty {
    runningSame.first?.activate(options: [.activateAllWindows])
    exit(0)
}

// 顶层代码不是 @MainActor —— 这里已经在主线程上，显式声明即可
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
