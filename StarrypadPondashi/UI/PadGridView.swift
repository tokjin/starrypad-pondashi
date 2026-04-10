import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 左下が PAD 1、上方向に番号が増える（画面上段が PAD 13–16）
struct PadGridView: View {
    @EnvironmentObject private var vm: AppViewModel
    @Binding var selectedSlot: Int?
    @Binding var inspectorPresented: Bool

    @State private var dropHoverSlot: Int?

    /// ドラッグ中のパッドを識別するペイロード（外部テキストと区別）
    private static let padDragPrefix = "starrypad-slot:"

    /// 画面上の行（上→下）。下段パッド付近の表記に相当するヒント。
    private static let rowHints: [[String]] = [
        ["SWING 56%", "SWING 58%", "SWING 60%", "TAP TEMPO"],
        ["TRANSPOSE-", "TRANSPOSE+", "OCTAVE-", "OCTAVE+"],
        ["1/4T", "1/8T", "1/16T", "1/32T"],
        ["1/4", "1/8", "1/16", "1/32"]
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("STARRYPAD")
                    .font(.title3.weight(.heavy))
                    .tracking(1.2)
                Text("DONNER")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.bottom, 4)

            // LazyVGrid 内の二重 ForEach では子が正しく並ばないことがあるため、行を明示する
            VStack(spacing: 10) {
                ForEach(0 ..< 4, id: \.self) { row in
                    HStack(spacing: 10) {
                        ForEach(0 ..< 4, id: \.self) { col in
                            let offset = (3 - row) * 4 + col
                            let slot = vm.uiBank * 16 + offset
                            let hint = Self.rowHints[row][col]
                            padCell(slot: slot, padLabel: offset + 1, hint: hint)
                        }
                    }
                }
            }
        }
    }

    private static func padBaseFill(cfg: SlotConfig) -> Color {
        if let t = cfg.padTint {
            return Color(red: t.r, green: t.g, blue: t.b, opacity: t.a)
        }
        return Color(nsColor: .controlBackgroundColor)
    }

    /// 着色ありで、白系ラベルのほうが読みやすいとき真（暗めプリセット想定）
    private static func padPrefersLightForeground(cfg: SlotConfig) -> Bool {
        guard let t = cfg.padTint else { return false }
        let l = 0.2126 * t.r + 0.7152 * t.g + 0.0722 * t.b
        return l < 0.52
    }

    private static func padNormalBorderColor(cfg: SlotConfig, lightFG: Bool) -> Color {
        if lightFG { return Color.white.opacity(0.22) }
        if cfg.padTint != nil { return Color.primary.opacity(0.18) }
        return Color.secondary.opacity(0.22)
    }

    private static func padCellBorderColor(hitFlash: Bool, isSelected: Bool, cfg: SlotConfig, lightFG: Bool) -> Color {
        if hitFlash { return Color.orange }
        if isSelected { return Color.accentColor }
        return padNormalBorderColor(cfg: cfg, lightFG: lightFG)
    }

    @ViewBuilder
    private func padCell(slot: Int, padLabel: Int, hint: String) -> some View {
        let cfg = vm.kit.slots[slot]
        let name = cfg.padDisplayLabel()
        let playing = vm.playingSlots.contains(slot)
        /// インスペクタ表示中のみ選択の青枠を付ける（格納時は付けない）
        let isSelected = inspectorPresented && selectedSlot == slot
        let hitFlash = vm.lastHitSlot == slot
        let isDropHover = dropHoverSlot == slot
        let lightFG = Self.padPrefersLightForeground(cfg: cfg)

        ZStack(alignment: .topTrailing) {
            // `Button` はドラッグを奪うため、タップで再生してドラッグは親に任せる
            VStack(spacing: 6) {
                Text("PAD \(padLabel)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(lightFG ? Color.white.opacity(0.62) : Color.secondary)
                Text(name)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(lightFG ? Color.white : Color.primary)
                Text(hint)
                    .font(.system(size: 8))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(lightFG ? Color.white.opacity(0.48) : Color(NSColor.tertiaryLabelColor))
            }
            .frame(minWidth: 76, minHeight: 88)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)
            .padding(.top, 4)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Self.padBaseFill(cfg: cfg))
                    if playing {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.accentColor.opacity(cfg.padTint != nil ? 0.22 : 0.32))
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        Self.padCellBorderColor(hitFlash: hitFlash, isSelected: isSelected, cfg: cfg, lightFG: lightFG),
                        lineWidth: hitFlash ? 3 : (isSelected ? 2.5 : 1)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        Color.accentColor.opacity(0.9),
                        style: StrokeStyle(lineWidth: 2, dash: [5, 4])
                    )
                    .opacity(isDropHover ? 1 : 0)
            )
            .overlay(alignment: .bottom) {
                if playing, cfg.filePath != nil {
                    PadPlaybackProgressBar(slot: slot, lightChrome: lightFG)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 6)
                }
            }
            .animation(.easeOut(duration: 0.12), value: vm.lastHitSlot)
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .onTapGesture {
                vm.triggerSlot(slot)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("PAD \(padLabel)、\(name)")
            .accessibilityAddTraits(.isButton)
            .help("クリックで再生。ドラッグで他パッドへ置き換え（⌥+ドロップで複製）")

            Button {
                selectedSlot = slot
                inspectorPresented = true
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(lightFG ? Color.white.opacity(0.72) : .secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("インスペクタを開く（再生しない）")
        }
        .onDrag {
            NSItemProvider(object: "\(Self.padDragPrefix)\(slot)" as NSString)
        }
        .onDrop(
            of: [UTType.plainText, UTType.fileURL],
            isTargeted: Binding(
                get: { dropHoverSlot == slot },
                set: { isHover in
                    if isHover { dropHoverSlot = slot }
                    else if dropHoverSlot == slot { dropHoverSlot = nil }
                }
            ),
            perform: { providers in
                handleDrop(providers: providers, destinationSlot: slot)
            }
        )
    }

    private func handleDrop(providers: [NSItemProvider], destinationSlot: Int) -> Bool {
        // Finder 等からの音声ファイルは `NSString` も併記されることがあり、先にテキスト分岐すると
        // パッド間ドラッグ扱いで失敗するため、ファイル URL を優先する。
        if let fileProvider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            fileProvider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                vm.assignAudioAsync(from: url, toSlot: destinationSlot)
            }
            return true
        }
        if let textProvider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) {
            textProvider.loadObject(ofClass: NSString.self) { obj, _ in
                guard let raw = obj as? String else { return }
                guard raw.hasPrefix(Self.padDragPrefix),
                      let src = Int(raw.dropFirst(Self.padDragPrefix.count)),
                      src >= 0, src < PresetKit.slotCount,
                      src != destinationSlot
                else { return }
                DispatchQueue.main.async {
                    if NSEvent.modifierFlags.contains(.option) {
                        vm.duplicatePadSlot(from: src, to: destinationSlot)
                    } else {
                        vm.replacePadSlot(from: src, to: destinationSlot)
                    }
                }
            }
            return true
        }
        return false
    }
}

/// パッド内の再生位置（閲覧のみ・シーク不可）
private struct PadPlaybackProgressBar: View {
    @EnvironmentObject private var vm: AppViewModel
    let slot: Int
    /// 暗い着色パッド上ではトラック／つまみを白系にする
    var lightChrome: Bool = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12.0, paused: false)) { _ in
            let t = vm.engine.playbackTimeline(for: slot)
            let fraction: CGFloat = {
                guard let t, t.durationSec > 0.000_1 else { return 0 }
                return CGFloat(t.positionSec / t.durationSec)
            }()

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(lightChrome ? Color.white.opacity(0.22) : Color.primary.opacity(0.14))
                    Capsule()
                        .fill(lightChrome ? Color.white.opacity(0.92) : Color.accentColor.opacity(0.9))
                        .frame(width: max(2, geo.size.width * fraction))
                }
            }
            .frame(height: 3)
            .frame(maxWidth: .infinity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
