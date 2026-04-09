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

    @ViewBuilder
    private func padCell(slot: Int, padLabel: Int, hint: String) -> some View {
        let cfg = vm.kit.slots[slot]
        let name = (cfg.filePath as NSString?)?.lastPathComponent ?? "空"
        let playing = vm.playingSlots.contains(slot)
        let isSelected = selectedSlot == slot
        let hitFlash = vm.lastHitSlot == slot
        let isDropHover = dropHoverSlot == slot

        ZStack(alignment: .topTrailing) {
            // `Button` はドラッグを奪うため、タップで再生してドラッグは親に任せる
            VStack(spacing: 6) {
                Text("PAD \(padLabel)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                Text(hint)
                    .font(.system(size: 8))
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: 76, minHeight: 88)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(8)
            .padding(.top, 4)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(playing ? Color.accentColor.opacity(0.32) : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        hitFlash ? Color.orange : (isSelected ? Color.accentColor : Color.secondary.opacity(0.22)),
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
                    .foregroundStyle(.secondary)
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
