import SwiftUI

/// The report's entry card on the 「我的」 page, above the playlist area:
/// the title plus this week's listening time as the teaser.
struct ListeningReportEntryCard: View {
    @ObservedObject private var stats = ListeningStatsStore.shared
    @State private var showReport = false

    var body: some View {
        Button {
            showReport = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "chart.bar.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("听歌报告")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("四个平台的听歌都算在一起")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !weekTeaser.isEmpty {
                    Text(weekTeaser)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showReport) {
            NavigationStack {
                ListeningReportView()
            }
        }
    }

    private var weekTeaser: String {
        let seconds = stats.summary(for: .week).totalSeconds
        guard seconds > 0 else { return "" }
        return "本周 \(ListeningReportFormat.duration(seconds))"
    }
}

/// A plain report page — headline totals across all four platforms, the
/// top songs and artists, a platform share bar and one listening-habit
/// line. No story cards, by request.
struct ListeningReportView: View {
    @ObservedObject private var stats = ListeningStatsStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var period: ListeningStatsStore.Period = .week

    var body: some View {
        let summary = stats.summary(for: period)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Picker("时段", selection: $period) {
                    ForEach(ListeningStatsStore.Period.allCases, id: \.self) { period in
                        Text(period.rawValue).tag(period)
                    }
                }
                .pickerStyle(.segmented)

                if summary.totalSeconds <= 0 {
                    Text("还没有听歌记录。听歌报告从这一版开始在本机记录，听上几首再来看看。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    headline(summary)
                    topSongs(summary)
                    topArtists(summary)
                    platformShare(summary)
                    if let hour = summary.peakHour {
                        Text("你最爱在\(ListeningReportFormat.hourBand(hour))听歌，\(hour) 点前后听得最多。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("数据只存在这台设备上，四个平台合并统计，不上传。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
        .navigationTitle("听歌报告")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("关闭") { dismiss() }
            }
        }
    }

    private func headline(_ summary: ListeningStatsStore.Summary) -> some View {
        HStack(spacing: 12) {
            statBlock(title: "总时长", value: ListeningReportFormat.duration(summary.totalSeconds))
            statBlock(title: "听歌", value: "\(summary.playCount) 首")
            statBlock(title: "听歌天数", value: "\(summary.activeDays) 天")
        }
    }

    private func statBlock(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title3.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func topSongs(_ summary: ListeningStatsStore.Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最爱歌曲")
                .font(.headline)
            ForEach(Array(summary.topSongs.enumerated()), id: \.element.id) { index, song in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(song.name)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(song.artists)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(song.plays) 次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func topArtists(_ summary: ListeningStatsStore.Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最爱歌手")
                .font(.headline)
            ForEach(Array(summary.topArtists.enumerated()), id: \.element.id) { index, artist in
                HStack(spacing: 10) {
                    Text("\(index + 1)")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 18)
                    Text(artist.name)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer()
                    Text("\(artist.plays) 次")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func platformShare(_ summary: ListeningStatsStore.Summary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("平台分布")
                .font(.headline)
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    ForEach(summary.platformShares) { share in
                        Rectangle()
                            .fill(Self.color(for: share.provider))
                            .frame(width: max(2, proxy.size.width * CGFloat(share.seconds / max(summary.totalSeconds, 1))))
                    }
                }
            }
            .frame(height: 10)
            .clipShape(Capsule())
            ForEach(summary.platformShares) { share in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Self.color(for: share.provider))
                        .frame(width: 8, height: 8)
                    Text(share.provider.name)
                        .font(.caption)
                    Spacer()
                    Text("\(Int((share.seconds / max(summary.totalSeconds, 1) * 100).rounded()))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private static func color(for provider: MusicProvider) -> Color {
        switch provider {
        case .netease: return .red
        case .qq: return .green
        case .kugou: return .blue
        case .qishui: return .orange
        }
    }
}

enum ListeningReportFormat {
    static func duration(_ seconds: Double) -> String {
        if seconds >= 3600 {
            let hours = seconds / 3600
            return hours >= 10 ? "\(Int(hours.rounded())) 小时" : String(format: "%.1f 小时", hours)
        }
        return "\(max(1, Int((seconds / 60).rounded()))) 分钟"
    }

    static func hourBand(_ hour: Int) -> String {
        switch hour {
        case 6..<9: return "早晨"
        case 9..<12: return "上午"
        case 12..<14: return "中午"
        case 14..<18: return "下午"
        case 18..<23: return "晚上"
        default: return "深夜"
        }
    }
}
