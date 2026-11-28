import SwiftUI

/// 音效面板（0.4.0）：播放页「更多」菜单进入。
/// 定位是「已经调好的成品」：总开关默认开、默认预设「震撼」，用户什么都不用动；
/// 面板存在的意义是状态看得见（当前预设、耳机修正是否已应用、曲线长什么样），
/// 以及想玩的人有滑杆可玩。关掉总开关 = 原声直出，随时 A/B 对比。
struct AudioEffectsPanel: View {
    @ObservedObject private var store = AudioEffectsStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    masterSwitch
                    statusLine
                    presetSection
                    bassSection
                    environmentSection
                    headphoneSection
                    equalizerSection
                    footer
                }
                .padding(20)
            }
            .navigationTitle("音效")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: 总开关 + 状态

    private var masterSwitch: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("音效").font(.headline)
                Text(store.enabled ? "已开启，声音经过均衡、压缩与耳机修正" : "已关闭，当前为原声直出")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $store.enabled).labelsHidden()
        }
    }

    private var statusLine: some View {
        let presetName = store.presetID == "custom" ? "自定义" : AudioEffectPresets.preset(id: store.presetID).name
        let envName = store.environment == .off ? "环境关" : "环境·\(store.environment.name)"
        let hpName = store.headphoneProfile.map { "耳机修正·\($0.name) 已应用" } ?? "耳机修正关"
        return Text(store.enabled ? "当前：\(presetName) · \(envName) · \(hpName)" : "当前：原声直出")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: 预设

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("预设").font(.subheadline.weight(.semibold))
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 10)], spacing: 10) {
                ForEach(AudioEffectPresets.all) { preset in
                    presetChip(id: preset.id, name: preset.name)
                }
                if store.presetID == "custom" {
                    presetChip(id: "custom", name: "自定义")
                }
            }
        }
        .disabled(!store.enabled)
        .opacity(store.enabled ? 1 : 0.45)
    }

    private func presetChip(id: String, name: String) -> some View {
        let selected = store.presetID == id
        return Button {
            store.presetID = id
        } label: {
            Text(name)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.secondary.opacity(0.15)),
                            in: RoundedRectangle(cornerRadius: 10))
                .foregroundStyle(selected ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: 低音 + 环境

    private var bassSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("低音增强").font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%+.1f dB", store.bassOffset)).font(.footnote).foregroundStyle(.secondary)
            }
            Slider(value: $store.bassOffset, in: -4...6, step: 0.5)
        }
        .disabled(!store.enabled)
        .opacity(store.enabled ? 1 : 0.45)
    }

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("环境").font(.subheadline.weight(.semibold))
            Picker("环境", selection: $store.environment) {
                ForEach(AudioEffectEnvironment.allCases) { env in
                    Text(env.name).tag(env)
                }
            }
            .pickerStyle(.segmented)
        }
        .disabled(!store.enabled)
        .opacity(store.enabled ? 1 : 0.45)
    }

    // MARK: 耳机适配

    private var headphoneSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("耳机适配").font(.subheadline.weight(.semibold))
            Text("按耳机型号加载实测频响修正，选完即生效，不用调任何参数。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("耳机型号", selection: $store.headphoneID) {
                Text("不使用").tag(String?.none)
                ForEach(HeadphoneLibrary.all) { profile in
                    Text("\(profile.name)（\(profile.kind)）").tag(String?.some(profile.id))
                }
            }
            .pickerStyle(.navigationLink)
            if let profile = store.headphoneProfile {
                curveView(profile: profile)
                Text("已应用：\(profile.name) 的修正曲线（前置增益 \(String(format: "%.1f", profile.preamp)) dB）")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.green)
            }
        }
        .disabled(!store.enabled)
        .opacity(store.enabled ? 1 : 0.45)
    }

    private func curveView(profile: HeadphoneProfile) -> some View {
        let points = AudioResponseCurve.points(filters: profile.filters, preamp: profile.preamp)
        return GeometryReader { geo in
            let rect = geo.frame(in: .local)
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.10))
                // 0 dB 参考线
                Path { path in
                    let y = yFor(db: 0, height: rect.height)
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: rect.width, y: y))
                }
                .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                Path { path in
                    for (i, point) in points.enumerated() {
                        let x = rect.width * CGFloat(log10(point.freq / 20.0) / 3.0)
                        let y = yFor(db: point.db, height: rect.height)
                        if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .frame(height: 110)
    }

    /// 曲线纵轴范围 +10 … −14 dB。
    private func yFor(db: Double, height: CGFloat) -> CGFloat {
        let clamped = min(max(db, -14), 10)
        return height * CGFloat((10 - clamped) / 24)
    }

    // MARK: 均衡器（可以有，但默认不需要碰）

    private var equalizerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("均衡器").font(.subheadline.weight(.semibold))
            Text("拖动任意一段会切换到「自定义」。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(0..<10, id: \.self) { band in
                HStack(spacing: 10) {
                    Text(AudioEffectPresets.bandLabels[band])
                        .font(.caption.monospacedDigit())
                        .frame(width: 32, alignment: .trailing)
                    Slider(value: Binding(
                        get: { Double(store.baseGains[band]) },
                        set: { store.setCustomGain(band: band, value: Float($0)) }
                    ), in: -12...12, step: 0.5)
                    Text(String(format: "%+.1f", store.baseGains[band]))
                        .font(.caption.monospacedDigit())
                        .frame(width: 36, alignment: .leading)
                }
            }
        }
        .disabled(!store.enabled)
        .opacity(store.enabled ? 1 : 0.45)
    }

    private var footer: some View {
        Text("耳机修正曲线数据：AutoEq（oratory1990 实测）。关掉总开关即原声直出，播放中切换开关就能 A/B 对比是否生效。")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
