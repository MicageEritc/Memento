import SwiftUI
import AppKit

// MARK: - 「模型」页 —— 模型池（最多 2 个）+ 各功能独立选模型

struct ModelPanel: View {
    @ObservedObject var app: AppState

    var body: some View {
        // 统一规范：ScrollView Full-Bleed（自身零 padding），所有 padding 在内层 VStack 上，
        // 保证右侧滚动条轨道在模型/设置/关于三页间绝对一致（顶端/底端纹丝不动）。
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                // 模型服务：每个模型一张卡；不足 2 个时显示「添加模型」
                ForEach(Array(app.cfg.models.enumerated()), id: \.element.id) { idx, _ in
                    modelCard(index: idx)
                }
                if app.cfg.models.count < 2 {
                    addModelCard
                }

                SettingSectionCard(title: "AI 功能分配") { assignmentContent }
                    .frame(maxWidth: 640, alignment: .leading)

                SettingSectionCard(title: "模型配置") { globalConfigRows }
                    .frame(maxWidth: 640, alignment: .leading)
            }
            // 关键：外层容器必须铺满 detail 列（maxWidth .infinity），滚动条才会贴窗口右边；
            // 单张卡片各自限宽 640 靠左，避免内容被无限拉宽。
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 40)
            .padding(.trailing, 40)
            .padding(.vertical, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .scrollIndicators(.automatic)
        .defaultScrollAnchor(.top)
        .navigationTitle("模型")
        .onAppear { Task { await app.pingService() } }
        // 锚点 toolbar：保证窗口 NSToolbar 始终存在，切到本页时标题栏/边栏不跳动
        .toolbar {
            // 全局搜索为独立内容状态：搜索时清空整个 toolbar（不继承当前页面原有 items）
            if !app.isSearching {
                ToolbarItem(placement: .primaryAction) { ToolbarAnchor() }
            }
        }
    }

    // MARK: 单个模型卡（状态展示 + 配置编辑）

    private func modelCard(index: Int) -> some View {
        let p = app.cfg.models[index]
        let st = app.svcByModel[p.id] ?? ServiceState()
        return SettingSectionCard(title: p.name) {
            SettingRow("状态") {
                StatusTag(text: st.stateText, kind: st.stateKind)
            }
            SettingRow("类型") {
                StatusTag(text: typeLabel(p), kind: p.kind == .local ? .ok : .ok)
            }
            SettingRow("模型") {
                Text(p.modelName.isEmpty ? "—" : p.modelName)
                    .font(.callout.monospaced())
                    .foregroundStyle(T.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            SettingRow("接口") {
                Text(p.endpoint.isEmpty ? "—" : p.endpoint)
                    .font(.callout.monospaced())
                    .foregroundStyle(T.textDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            SettingRow("能力", divider: false) {
                Text(capabilityLabel(p))
                    .font(.callout)
                    .foregroundStyle(T.textDim)
            }

            HStack(spacing: 10) {
                Spacer()
                Button {
                    Task { await app.pingModel(id: p.id) }
                } label: {
                    Text(!p.endpoint.isEmpty ? "立即检测" : "请先填写 API 地址")
                }
                .controlSize(.regular)
                .disabled(p.endpoint.isEmpty)
                .help("检测在线状态与能力（与「启用」无关，未启用也可检测）")
            }
            .padding(.top, 10)

            Divider()
                .padding(.vertical, 8)

            configEditor(index: index)

            // 删除模型（仅当存在多个模型时）
            if app.cfg.models.count > 1 {
                Divider()
                    .padding(.vertical, 8)
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        app.removeModel(p.id)
                    } label: {
                        Label("删除此模型", systemImage: "trash")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(T.err)
                    .help("删除后，原分配给该模型的功能将回退到剩余模型")
                }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    // 类型展示：只显示「在线模型 / 本地模型」（自动判定，不写厂商/自定义）
    private func typeLabel(_ p: ModelProfile) -> String {
        guard !p.endpoint.isEmpty else { return "—" }
        return p.kind == .local ? "本地模型" : "在线模型"
    }

    // 能力展示：文本 / 图片 / 未检测
    private func capabilityLabel(_ p: ModelProfile) -> String {
        switch (p.capabilities.text, p.capabilities.vision) {
        case (.supported, .supported): return "文本 · 图片"
        case (.supported, .unsupported): return "文本"
        case (.supported, .unknown): return "文本 · 图片未检测"
        case (.unsupported, _): return "文本不支持"
        case (.unknown, _): return "未检测"
        }
    }

    // MARK: 单模型配置编辑

    @ViewBuilder
    private func configEditor(index: Int) -> some View {
        SettingRow("显示名称") { textField($app.cfg.models[index].name, width: 140) }
        SettingRow("API 地址") { textField($app.cfg.models[index].endpoint, width: 240) }
        SettingRow("API Key") { ApiKeyField(modelId: app.cfg.models[index].id, app: app) }
        SettingRow("模型名") { textField($app.cfg.models[index].modelName, width: 180) }
        SettingRow("启用") {
            Toggle("", isOn: $app.cfg.models[index].enabled)
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .help("启用后该模型才可被「AI 功能分配」选中使用")
        SettingRow("思考模式", divider: false) {
            Toggle("", isOn: $app.cfg.models[index].thinking)
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .help("开启：模型先输出思维链再给答案（更准确但更慢）；DeepSeek 与本地 Qwen 均生效")
    }

    // MARK: 添加模型

    private var addModelCard: some View {
        Button {
            app.addModel()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                Text("添加模型")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .controlSize(.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: AI 功能分配

    @ViewBuilder
    private var assignmentContent: some View {
        ForEach(AIFunction.allCases) { fn in
            SettingRow(fn.title, divider: fn != .muse) {
                ModelAssignMenu(fn: fn, app: app)
            }
        }
    }

    // MARK: 全局生成参数（仍按 AppConfig 统一，不随模型拆分）

    @ViewBuilder
    private var globalConfigRows: some View {
        SettingRow("总结字数") { number($app.cfg.summaryChars, range: 50...300) }
        SettingRow("单次请求超时（秒）", divider: false) { number($app.cfg.requestTimeoutSec, range: 20...900) }
    }

    // MARK: 输入控件

    private func textField(_ s: Binding<String>, width: CGFloat) -> some View {
        TextField("", text: s)
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .frame(width: width)
            .multilineTextAlignment(.trailing)
            .onChange(of: s.wrappedValue) { _, _ in app.scheduleSave() }
    }

    private func number(_ v: Binding<Int>, range: ClosedRange<Int>) -> some View {
        TextField("", value: v, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .frame(width: 96)
            .multilineTextAlignment(.trailing)
            .onChange(of: v.wrappedValue) { _, _ in app.scheduleSave() }
    }
}

// MARK: - API Key 输入框（Keychain 双向绑定）

private struct ApiKeyField: View {
    let modelId: String
    @ObservedObject var app: AppState
    @State private var text: String = ""
    @State private var loadedOnce = false

    var body: some View {
        SecureField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .frame(width: 240)
            .multilineTextAlignment(.trailing)
            .onAppear {
                // 仅首次从 Keychain 读取；避免页面切换/视图重建时覆盖用户正在输入的内容
                guard !loadedOnce else { return }
                loadedOnce = true
                text = app.modelApiKey(modelId)
            }
            .onChange(of: text) { _, new in
                // 只有值确实变化（用户输入/清空）才写回 Keychain，避免 onAppear 赋值触发误写
                if new != app.modelApiKey(modelId) {
                    app.setModelApiKey(modelId, new)
                }
            }
    }
}

// MARK: - 功能→模型选择下拉（瞬息/一念需视觉：选纯文本模型时弹提示并跳回多模态模型，不分配；未启用的模型不可选）

private struct ModelAssignMenu: View {
    let fn: AIFunction
    @ObservedObject var app: AppState
    @State private var warnText = ""

    private var warnBinding: Binding<Bool> {
        Binding(get: { !warnText.isEmpty }, set: { if !$0 { warnText = "" } })
    }

    var body: some View {
        let selectedId = app.selectedModelId(for: fn)
        let selected = app.cfg.models.first(where: { $0.id == selectedId })
        let selectedName = selected?.name ?? "未分配"
        return Menu {
            ForEach(app.cfg.models) { m in
                Button {
                    // 未启用的模型不可分配
                    guard m.enabled else {
                        warnText = "「\(m.name)」未启用，无法分配。请先在「模型」设置中开启「启用」。"
                        return
                    }
                    // 需要视觉的功能（瞬息/一念）禁止分配给纯文本模型：
                    // 弹提示并直接跳回首个支持视觉的模型，不让用户选纯文本模型
                    if fn.requiresVision && m.capabilities.vision == .unsupported {
                        warnText = "当前模型不支持图片理解，\(fn.title)需要视觉模型才能进行截图分析。"
                        if let alt = app.cfg.models.first(where: {
                            $0.id != m.id && $0.enabled && $0.capabilities.vision == .supported
                        }) {
                            app.assign(fn, to: alt.id)  // 跳回多模态模型
                        }
                        return
                    }
                    app.assign(fn, to: m.id)
                } label: {
                    Label(m.name + capSuffix(m) + (m.enabled ? "" : "（未启用）"),
                          systemImage: selectedId == m.id ? "checkmark" : "")
                }
                .disabled(!m.enabled)
            }
        } label: {
            HStack(spacing: 4) {
                Text(selectedName)
                    .font(.callout)
                    .foregroundStyle(selected?.enabled == false ? .secondary : .primary)
                if selected?.enabled == false {
                    Text("未启用").font(.caption2).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .alert("模型能力提醒", isPresented: warnBinding) {
            Button("好", role: .cancel) {}
        } message: { Text(warnText) }
    }

    private func capSuffix(_ m: ModelProfile) -> String {
        // 纯文本模型不再追加「纯文本」字样；仅当视觉能力「未检测」时给出提示
        if m.capabilities.vision == .unknown { return " · 图片未检测" }
        return ""
    }
}
