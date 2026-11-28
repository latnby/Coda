import AVFoundation
import AudioToolbox
import Combine
import Foundation

// MARK: - 龙音乐音效（0.4.0）
//
// 官方 App 的「会员音效」拆开看是三件事：均衡曲线、动态压缩、环境混响，
// 外加按耳机型号做的频响修正。文件本身不动，本链挂在播放器自带的
// attach(nodes:) 扩展点上（rateNode → 本链 → mainMixerNode），对解码后、
// 送出之前的声音数据做处理。关掉总开关时四个节点全部真旁路，原声直出。
//
// 调校原则（Lon 的要求：现成标准、不用他试）：
// - 预设曲线用流传多年的经典标准曲线数值；默认「震撼」按等响度思路配：
//   低频与高频两头抬、中间保人声，配压缩把密度推满，整体留 −2 dB 余量防爆。
// - 耳机修正用 AutoEq 的实测数据（oratory1990 测量），纯数据、无主观成分。

// MARK: 耳机修正滤波器（AutoEq 参数化格式）

struct HeadphoneFilter: Equatable {
    enum Kind: Equatable { case lowShelf, peak, highShelf }
    var kind: Kind
    var frequency: Float
    var gain: Float
    var q: Float
}

struct HeadphoneProfile: Identifiable, Equatable {
    var id: String
    var name: String
    var kind: String          // 头戴 / 入耳
    var preamp: Float
    var filters: [HeadphoneFilter]
}

enum HeadphoneLibrary {
    // 数据来源：AutoEq（github.com/jaakkopasanen/AutoEq），oratory1990 实测，
    // ParametricEQ 结果原文转录，2026-11-28 取数。
    private static func f(_ kind: HeadphoneFilter.Kind, _ fc: Float, _ gain: Float, _ q: Float) -> HeadphoneFilter {
        HeadphoneFilter(kind: kind, frequency: fc, gain: gain, q: q)
    }

    static let all: [HeadphoneProfile] = [
        HeadphoneProfile(id: "sony-xm5", name: "Sony WH-1000XM5", kind: "头戴", preamp: -6.2, filters: [
            f(.lowShelf, 105, -3.2, 0.70), f(.peak, 2448, 6.9, 2.46), f(.peak, 173, -5.6, 0.96),
            f(.peak, 3028, -5.4, 2.03), f(.peak, 1327, 3.3, 0.58), f(.highShelf, 10000, 4.9, 0.70),
            f(.peak, 6110, -2.3, 5.81), f(.peak, 875, -1.2, 4.07), f(.peak, 1197, 1.0, 3.28),
            f(.peak, 63, 0.4, 2.13)]),
        HeadphoneProfile(id: "sony-xm4", name: "Sony WH-1000XM4", kind: "头戴", preamp: -6.1, filters: [
            f(.lowShelf, 105, -4.2, 0.70), f(.peak, 143, -5.2, 1.10), f(.peak, 2289, 6.1, 1.57),
            f(.peak, 56, 1.2, 1.19), f(.peak, 5144, -3.2, 6.00), f(.highShelf, 10000, -1.0, 0.70),
            f(.peak, 407, 1.7, 3.14), f(.peak, 6715, 3.0, 5.99), f(.peak, 1007, 1.0, 3.41),
            f(.peak, 576, -1.2, 3.55)]),
        HeadphoneProfile(id: "airpods-max", name: "Apple AirPods Max", kind: "头戴", preamp: -4.7, filters: [
            f(.lowShelf, 105, -3.0, 0.70), f(.peak, 7273, 3.6, 2.41), f(.peak, 218, -2.9, 1.41),
            f(.peak, 1031, -3.2, 0.99), f(.peak, 3185, 3.1, 0.56), f(.highShelf, 10000, -5.5, 0.70),
            f(.peak, 9508, 2.7, 2.20), f(.peak, 66, 0.6, 1.65), f(.peak, 4045, 2.1, 5.82),
            f(.peak, 4834, -1.8, 6.00)]),
        HeadphoneProfile(id: "momentum-4", name: "Sennheiser Momentum 4", kind: "头戴", preamp: -6.4, filters: [
            f(.lowShelf, 105, -7.4, 0.70), f(.peak, 195, -3.6, 1.22), f(.peak, 2393, 6.1, 1.81),
            f(.peak, 1726, 1.6, 1.71), f(.peak, 2893, -3.2, 5.94), f(.highShelf, 10000, 0.5, 0.70),
            f(.peak, 63, 1.7, 2.86), f(.peak, 652, 1.2, 2.25), f(.peak, 952, -1.0, 3.69),
            f(.peak, 316, -0.9, 3.46)]),
        HeadphoneProfile(id: "sony-wf-xm5", name: "Sony WF-1000XM5", kind: "入耳", preamp: -2.6, filters: [
            f(.lowShelf, 105, 5.4, 0.70), f(.peak, 68, -4.8, 0.27), f(.peak, 1377, 2.6, 0.31),
            f(.peak, 1806, -3.5, 1.16), f(.peak, 6875, 1.8, 3.49), f(.highShelf, 10000, 2.3, 0.70),
            f(.peak, 3757, 0.3, 2.56), f(.peak, 5057, -0.7, 5.70), f(.peak, 449, 0.3, 4.15),
            f(.peak, 677, -0.2, 2.75)]),
        HeadphoneProfile(id: "sony-wf-xm4", name: "Sony WF-1000XM4", kind: "入耳", preamp: -7.5, filters: [
            f(.lowShelf, 105, -0.6, 0.70), f(.peak, 176, -4.2, 0.60), f(.peak, 9973, 3.7, 1.01),
            f(.peak, 6316, 4.4, 0.91), f(.peak, 498, -1.4, 1.46), f(.highShelf, 10000, 3.7, 0.70),
            f(.peak, 1732, 1.2, 2.28), f(.peak, 3942, -0.8, 3.10), f(.peak, 978, -0.3, 1.49),
            f(.peak, 38, -0.2, 2.02)]),
        HeadphoneProfile(id: "buds2-pro", name: "Samsung Galaxy Buds2 Pro", kind: "入耳", preamp: -2.3, filters: [
            f(.lowShelf, 105, -2.3, 0.70), f(.peak, 7526, 2.2, 2.78), f(.peak, 266, -0.8, 1.35),
            f(.peak, 3426, -2.3, 3.70), f(.peak, 64, 2.2, 1.18), f(.highShelf, 10000, -3.8, 0.70),
            f(.peak, 8817, 1.6, 2.28), f(.peak, 2283, 1.2, 3.75), f(.peak, 4955, -1.2, 5.11),
            f(.peak, 977, 1.0, 5.18)]),
    ]

    static func profile(id: String?) -> HeadphoneProfile? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }
}

// MARK: 预设

struct AudioEffectPreset: Identifiable {
    var id: String
    var name: String
    /// 31/62/125/250/500/1k/2k/4k/8k/16k 十段增益（dB）
    var gains: [Float]
    var dynamics: Bool
    var globalGain: Float
    /// 非 nil 时该预设自带环境（如演唱会）
    var reverb: (preset: AVAudioUnitReverbPreset, mix: Float)?
}

enum AudioEffectPresets {
    static let bandFrequencies: [Float] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let bandLabels = ["31", "62", "125", "250", "500", "1K", "2K", "4K", "8K", "16K"]

    static let all: [AudioEffectPreset] = [
        AudioEffectPreset(id: "flat", name: "原声",
                          gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0], dynamics: false, globalGain: 0, reverb: nil),
        AudioEffectPreset(id: "impact", name: "震撼",
                          gains: [5, 4, 3, 1, 0, 1, 2, 3, 4, 4], dynamics: true, globalGain: -2, reverb: nil),
        AudioEffectPreset(id: "pop", name: "流行",
                          gains: [-1, -1, 0, 2, 4, 4, 2, 0, -1, -2], dynamics: true, globalGain: -1, reverb: nil),
        AudioEffectPreset(id: "rock", name: "摇滚",
                          gains: [4, 3, 2, 0, -1, 0, 2, 3, 4, 4], dynamics: true, globalGain: -2, reverb: nil),
        AudioEffectPreset(id: "classical", name: "古典",
                          gains: [4, 3, 2, 1, 0, 0, -1, -2, -3, -4], dynamics: false, globalGain: -1, reverb: nil),
        AudioEffectPreset(id: "bass", name: "超重低音",
                          gains: [6, 5, 4, 2, 1, 0, 0, 0, 0, 0], dynamics: true, globalGain: -3, reverb: nil),
        AudioEffectPreset(id: "vocal", name: "人声",
                          gains: [-2, -2, -1, 1, 3, 3, 2, 1, 0, -1], dynamics: true, globalGain: -1, reverb: nil),
        AudioEffectPreset(id: "concert", name: "演唱会",
                          gains: [3, 3, 2, 1, 0, 1, 2, 2, 3, 3], dynamics: true, globalGain: -2,
                          reverb: (.largeHall, 16)),
    ]

    static func preset(id: String) -> AudioEffectPreset {
        all.first { $0.id == id } ?? all[1]
    }
}

// MARK: 环境

enum AudioEffectEnvironment: String, CaseIterable, Identifiable {
    case off, concert, hall
    var id: String { rawValue }
    var name: String {
        switch self {
        case .off: return "关闭"
        case .concert: return "演唱会"
        case .hall: return "音乐厅"
        }
    }
    var reverb: (preset: AVAudioUnitReverbPreset, mix: Float)? {
        switch self {
        case .off: return nil
        case .concert: return (.largeHall, 16)
        case .hall: return (.mediumHall, 12)
        }
    }
}

// MARK: 计算后的链路参数（不可变快照，喂给节点）

struct AudioEffectsParameters: Equatable {
    var enabled: Bool
    var eqGains: [Float]
    var eqGlobalGain: Float
    var dynamicsOn: Bool
    var reverbPreset: AVAudioUnitReverbPreset?
    var reverbMix: Float
    var headphone: HeadphoneProfile?

    static let bypass = AudioEffectsParameters(
        enabled: false, eqGains: Array(repeating: 0, count: 10), eqGlobalGain: 0,
        dynamicsOn: false, reverbPreset: nil, reverbMix: 0, headphone: nil)
}

// MARK: 设置存储

final class AudioEffectsStore: ObservableObject {
    static let shared = AudioEffectsStore()

    private let defaults = UserDefaults.standard
    private enum Key {
        static let enabled = "audiofx.enabled"
        static let preset = "audiofx.preset"
        static let bass = "audiofx.bass"
        static let environment = "audiofx.environment"
        static let headphone = "audiofx.headphone"
        static let customGains = "audiofx.customGains"
    }

    /// 参数变化广播：PlayerServiceIOS 订阅它把新参数推给正在播的链。
    let parametersSubject = PassthroughSubject<AudioEffectsParameters, Never>()

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Key.enabled); broadcast() }
    }
    @Published var presetID: String {
        didSet { defaults.set(presetID, forKey: Key.preset); broadcast() }
    }
    /// 低音偏移（dB），叠加在预设的 31/62 两段（125 段一半）。
    @Published var bassOffset: Float {
        didSet { defaults.set(bassOffset, forKey: Key.bass); broadcast() }
    }
    @Published var environment: AudioEffectEnvironment {
        didSet { defaults.set(environment.rawValue, forKey: Key.environment); broadcast() }
    }
    @Published var headphoneID: String? {
        didSet { defaults.set(headphoneID, forKey: Key.headphone); broadcast() }
    }
    @Published var customGains: [Float] {
        didSet {
            defaults.set(customGains.map { Double($0) }, forKey: Key.customGains)
            broadcast()
        }
    }

    init() {
        // 默认值即「开箱调好」：总开关开、预设震撼。
        enabled = defaults.object(forKey: Key.enabled) as? Bool ?? true
        presetID = defaults.string(forKey: Key.preset) ?? "impact"
        bassOffset = Float(defaults.double(forKey: Key.bass))
        environment = AudioEffectEnvironment(rawValue: defaults.string(forKey: Key.environment) ?? "off") ?? .off
        headphoneID = defaults.string(forKey: Key.headphone)
        let saved = defaults.array(forKey: Key.customGains) as? [Double]
        customGains = (saved?.count == 10) ? saved!.map { Float($0) } : AudioEffectPresets.preset(id: "impact").gains
    }

    var headphoneProfile: HeadphoneProfile? { HeadphoneLibrary.profile(id: headphoneID) }

    /// 当前生效的十段增益（预设或自定义 + 低音偏移）。
    var activeGains: [Float] {
        var gains = presetID == "custom" ? customGains : AudioEffectPresets.preset(id: presetID).gains
        gains[0] += bassOffset
        gains[1] += bassOffset
        gains[2] += bassOffset / 2
        return gains
    }

    var parameters: AudioEffectsParameters {
        guard enabled else { return .bypass }
        let preset = AudioEffectPresets.preset(id: presetID)
        let reverb = environment.reverb ?? preset.reverb
        return AudioEffectsParameters(
            enabled: true,
            eqGains: activeGains,
            eqGlobalGain: presetID == "custom" ? -1 : preset.globalGain,
            dynamicsOn: presetID == "custom" ? true : preset.dynamics,
            reverbPreset: reverb?.preset,
            reverbMix: reverb?.mix ?? 0,
            headphone: headphoneProfile)
    }

    private func broadcast() {
        parametersSubject.send(parameters)
    }

    /// 用户拖动某段滑杆：切到自定义并记录。
    func setCustomGain(band: Int, value: Float) {
        if presetID != "custom" {
            customGains = baseGains
            presetID = "custom"
        }
        guard customGains.indices.contains(band) else { return }
        customGains[band] = value
    }

    /// 不含低音偏移的基础增益（预设或自定义原文），面板滑杆编辑的就是它。
    var baseGains: [Float] {
        presetID == "custom" ? customGains : AudioEffectPresets.preset(id: presetID).gains
    }
}

// MARK: 处理链（每首歌随播放器新建一组节点，参数从存储快照灌入）

final class AudioEffectsChain {
    let eq = AVAudioUnitEQ(numberOfBands: 10)
    let headphoneEQ = AVAudioUnitEQ(numberOfBands: 10)
    let dynamics: AVAudioUnitEffect?
    let reverb = AVAudioUnitReverb()
    private var loadedReverbPreset: AVAudioUnitReverbPreset?

    var nodes: [AVAudioNode] {
        var list: [AVAudioNode] = [eq, headphoneEQ]
        if let dynamics { list.append(dynamics) }
        list.append(reverb)
        return list
    }

    init(parameters: AudioEffectsParameters) {
        // 图形均衡段位固定：首低架、尾高架、中间参量（带宽 1 倍频程）。
        for (i, band) in eq.bands.enumerated() {
            band.frequency = AudioEffectPresets.bandFrequencies[i]
            band.bypass = false
            if i == 0 { band.filterType = .lowShelf }
            else if i == eq.bands.count - 1 { band.filterType = .highShelf }
            else { band.filterType = .parametric; band.bandwidth = 1.0 }
        }
        // 苹果的 DynamicsProcessor（压缩器）——会员音效「又清晰又震撼」的核心件。
        let desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        dynamics = AVAudioUnitEffect(audioComponentDescription: desc)
        apply(parameters)
    }

    func apply(_ p: AudioEffectsParameters) {
        // 总开关关 → 全部真旁路（A/B 对比时听到的就是原文件直出）。
        guard p.enabled else {
            eq.bypass = true
            headphoneEQ.bypass = true
            dynamics?.bypass = true
            reverb.bypass = true
            return
        }
        eq.bypass = false
        for (i, band) in eq.bands.enumerated() {
            band.gain = p.eqGains.indices.contains(i) ? p.eqGains[i] : 0
        }
        eq.globalGain = p.eqGlobalGain

        // 耳机修正：无型号时整段旁路；有型号时按实测滤波器逐个设。
        if let profile = p.headphone {
            headphoneEQ.bypass = false
            for (i, band) in headphoneEQ.bands.enumerated() {
                if i < profile.filters.count {
                    let filter = profile.filters[i]
                    band.bypass = false
                    switch filter.kind {
                    case .lowShelf: band.filterType = .lowShelf
                    case .peak: band.filterType = .parametric
                    case .highShelf: band.filterType = .highShelf
                    }
                    band.frequency = filter.frequency
                    band.gain = filter.gain
                    band.bandwidth = Self.bandwidthOctaves(fromQ: filter.q)
                } else {
                    band.bypass = true
                    band.gain = 0
                }
            }
            headphoneEQ.globalGain = profile.preamp
        } else {
            headphoneEQ.bypass = true
        }

        // 压缩：阈值 −18 dB、动态余量 9 dB、慢启动慢释放、+2 dB 补偿——
        // 行业里「胶水压缩」的常规取值，把小声抬上来、大声压实，不抢拍。
        if let dynamics {
            dynamics.bypass = !p.dynamicsOn
            if p.dynamicsOn {
                Self.setDynamics(dynamics, kDynamicsProcessorParam_Threshold, -18)
                Self.setDynamics(dynamics, kDynamicsProcessorParam_HeadRoom, 9)
                Self.setDynamics(dynamics, kDynamicsProcessorParam_ExpansionRatio, 1)
                Self.setDynamics(dynamics, kDynamicsProcessorParam_ExpansionThreshold, -60)
                Self.setDynamics(dynamics, kDynamicsProcessorParam_AttackTime, 0.01)
                Self.setDynamics(dynamics, kDynamicsProcessorParam_ReleaseTime, 0.24)
                Self.setDynamics(dynamics, kDynamicsProcessorParam_MasterGain, 2)
            }
        }

        // 环境混响：换预设会重置单元状态（轻微咔哒），只在预设变化时重载。
        if let preset = p.reverbPreset, p.reverbMix > 0 {
            reverb.bypass = false
            if loadedReverbPreset != preset {
                reverb.loadFactoryPreset(preset)
                loadedReverbPreset = preset
            }
            reverb.wetDryMix = p.reverbMix
        } else {
            reverb.bypass = true
        }
    }

    private static func setDynamics(_ unit: AVAudioUnitEffect, _ param: AudioUnitParameterID, _ value: Float) {
        // 尽力而为：某个参数被 AU 拒绝时保留其默认值，链路照常工作
        // （与 DeckChain 限幅器的同款处理）。
        AudioUnitSetParameter(unit.audioUnit, param, kAudioUnitScope_Global, 0, value, 0)
    }

    /// Q 值 → 倍频程带宽（RBJ 标准换算）。
    static func bandwidthOctaves(fromQ q: Float) -> Float {
        let q = max(q, 0.05)
        let x = 1.0 / (2.0 * Double(q))
        let asinh = log(x + (x * x + 1.0).squareRoot())
        return Float(2.0 * asinh / log(2.0))
    }
}

// MARK: 曲线计算（面板上画给用户看的修正曲线，按 RBJ 双二阶公式算总响应）

enum AudioResponseCurve {
    /// 在 20 Hz–20 kHz 对数刻度上采样总响应（dB，含 preamp）。
    static func points(filters: [HeadphoneFilter], preamp: Float, sampleRate: Double = 48000, count: Int = 96) -> [(freq: Double, db: Double)] {
        let coeffs = filters.map { coefficients(for: $0, sampleRate: sampleRate) }
        return (0..<count).map { i in
            let t = Double(i) / Double(count - 1)
            let freq = 20.0 * pow(1000.0, t)
            var db = Double(preamp)
            for c in coeffs { db += magnitudeDB(c, freq: freq, sampleRate: sampleRate) }
            return (freq, db)
        }
    }

    private struct Biquad { var b0, b1, b2, a1, a2: Double }

    private static func coefficients(for filter: HeadphoneFilter, sampleRate: Double) -> Biquad {
        let gain = Double(filter.gain)
        let a = pow(10.0, gain / 40.0)
        let w0 = 2.0 * Double.pi * Double(filter.frequency) / sampleRate
        let cosW = cos(w0), sinW = sin(w0)
        let q = Double(max(filter.q, 0.05))
        switch filter.kind {
        case .peak:
            let alpha = sinW / (2.0 * q)
            let b0 = 1.0 + alpha * a, b1 = -2.0 * cosW, b2 = 1.0 - alpha * a
            let a0 = 1.0 + alpha / a, a1 = -2.0 * cosW, a2 = 1.0 - alpha / a
            return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
        case .lowShelf:
            let alpha = sinW / 2.0 * (2.0).squareRoot() * (1.0) // Q=0.707 近似的架式斜率
            let sqA = a.squareRoot()
            let t = 2.0 * sqA * alpha
            let b0 = a * ((a + 1) - (a - 1) * cosW + t)
            let b1 = 2.0 * a * ((a - 1) - (a + 1) * cosW)
            let b2 = a * ((a + 1) - (a - 1) * cosW - t)
            let a0 = (a + 1) + (a - 1) * cosW + t
            let a1 = -2.0 * ((a - 1) + (a + 1) * cosW)
            let a2 = (a + 1) + (a - 1) * cosW - t
            _ = alpha
            return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
        case .highShelf:
            let sqA = a.squareRoot()
            let alpha = sinW / 2.0 * (2.0).squareRoot()
            let t = 2.0 * sqA * alpha
            let b0 = a * ((a + 1) + (a - 1) * cosW + t)
            let b1 = -2.0 * a * ((a - 1) + (a + 1) * cosW)
            let b2 = a * ((a + 1) + (a - 1) * cosW - t)
            let a0 = (a + 1) - (a - 1) * cosW + t
            let a1 = 2.0 * ((a - 1) - (a + 1) * cosW)
            let a2 = (a + 1) - (a - 1) * cosW - t
            return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
        }
    }

    private static func magnitudeDB(_ c: Biquad, freq: Double, sampleRate: Double) -> Double {
        let w = 2.0 * Double.pi * freq / sampleRate
        let cosW = cos(w), cos2W = cos(2.0 * w)
        let sinW = sin(w), sin2W = sin(2.0 * w)
        let numR = c.b0 + c.b1 * cosW + c.b2 * cos2W
        let numI = -(c.b1 * sinW + c.b2 * sin2W)
        let denR = 1.0 + c.a1 * cosW + c.a2 * cos2W
        let denI = -(c.a1 * sinW + c.a2 * sin2W)
        let mag2 = (numR * numR + numI * numI) / max(denR * denR + denI * denI, 1e-12)
        return 10.0 * log10(max(mag2, 1e-12))
    }
}
