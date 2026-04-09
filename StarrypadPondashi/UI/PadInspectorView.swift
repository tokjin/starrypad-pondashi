import AppKit
import SwiftUI

/// 選択中パッドの再生方法・ミキサー設定
struct PadInspectorView: View {
    /// フェード／開始位置（ms）の桁数。4〜5 桁でも切れない幅にする。
    private static let msFieldMinWidth: CGFloat = 112

    @EnvironmentObject private var vm: AppViewModel
    let slot: Int
    /// インスペクタパネルを閉じる（格納）
    var onDismiss: (() -> Void)?

    private var padNumberInBank: Int { slot % 16 + 1 }
    private var bankLetter: String {
        let b = slot / 16
        return ["A", "B", "C"][min(b, 2)]
    }

    var body: some View {
        Group {
            if slot < 0 || slot >= PresetKit.slotCount {
                Text("スロットを選択してください")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .center) {
                        Text("インスペクタ")
                            .font(.headline)
                        Spacer(minLength: 8)
                        Text("バンク \(bankLetter) · PAD \(padNumberInBank)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let onDismiss {
                            Button {
                                onDismiss()
                            } label: {
                                Label("格納", systemImage: "sidebar.right")
                            }
                            .help("パッド表示を広げる")
                            .keyboardShortcut(.escape, modifiers: [])
                        }
                    }
                    .padding(.bottom, 8)

                    Form {
                        Section {
                            HStack {
                                Button("試聴") {
                                    vm.triggerSlot(slot)
                                }
                                Button("音声を割当…") { pickAudio() }
                                Button("クリア", role: .destructive) { vm.clearSlot(slot) }
                            }
                            if let path = vm.kit.slots[slot].filePath {
                                Text((path as NSString).lastPathComponent)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            } else {
                                Text("音声なし（クリックでは鳴りません）")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        } header: {
                            Text("音声")
                        }

                        if vm.playingSlots.contains(slot), vm.kit.slots[slot].filePath != nil {
                            Section {
                                InspectorPlaybackSeekBar(slot: slot)
                            } header: {
                                Text("再生中")
                            }
                        }

                        Section {
                            Picker("再生の扱い", selection: playbackModeSelection) {
                                Text("最後まで再生（ノートオフ無視）").tag(0)
                                Text("ゲート（ノートオフでフェード停止）").tag(1)
                            }
                            .pickerStyle(.radioGroup)

                            Toggle("MIDI ベロシティを音量に反映", isOn: velocitySensitiveBinding)

                            Toggle("ループ再生", isOn: loopBinding)

                            Slider(value: volumeBinding, in: 0 ... 2) {
                                Text("スロット音量")
                            }

                            HStack(alignment: .firstTextBaseline) {
                                Text("フェードイン")
                                Spacer(minLength: 8)
                                TextField("ms", value: fadeInBinding, format: .number)
                                    .multilineTextAlignment(.trailing)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: Self.msFieldMinWidth, alignment: .trailing)
                            }
                            HStack(alignment: .firstTextBaseline) {
                                Text("フェードアウト")
                                Spacer(minLength: 8)
                                TextField("ms", value: fadeOutBinding, format: .number)
                                    .multilineTextAlignment(.trailing)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: Self.msFieldMinWidth, alignment: .trailing)
                            }

                            HStack(alignment: .firstTextBaseline) {
                                Text("再生開始位置")
                                Spacer(minLength: 8)
                                TextField("ms", value: startOffsetBinding, format: .number)
                                    .multilineTextAlignment(.trailing)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: Self.msFieldMinWidth, alignment: .trailing)
                            }

                            Picker("チョークグループ", selection: chokeBinding) {
                                Text("なし").tag(0)
                                ForEach(1 ... 8, id: \.self) { n in
                                    Text("\(n)").tag(n)
                                }
                            }

                            Picker("同じパッドを再生中にもう一度押したとき", selection: retriggerBinding) {
                                ForEach(RetriggerBehavior.allCases) { b in
                                    Text(b.displayName).tag(b)
                                }
                            }
                        } header: {
                            Text("再生方法")
                        } footer: {
                            Text("ゲートは MIDI のノートオフ、または対応パッドの離脱に反応します。ループ時は最初の一周だけ開始位置が使われ、続くループはファイル先頭からになります。開始位置がファイル長を超えると鳴りません。")
                                .font(.caption2)
                        }
                    }
                    .formStyle(.grouped)
                }
                .frame(maxWidth: 420, alignment: .leading)
            }
        }
    }

    /// 0 = one-shot (ignore note off), 1 = gated
    private var playbackModeSelection: Binding<Int> {
        Binding(
            get: { vm.kit.slots[slot].respectNoteOff ? 1 : 0 },
            set: { v in replaceSlot { $0.respectNoteOff = (v == 1) } }
        )
    }

    private var velocitySensitiveBinding: Binding<Bool> {
        Binding(
            get: { vm.kit.slots[slot].velocitySensitive },
            set: { v in replaceSlot { $0.velocitySensitive = v } }
        )
    }

    private var volumeBinding: Binding<Float> {
        Binding(
            get: { vm.kit.slots[slot].volume },
            set: { v in replaceSlot { $0.volume = v } }
        )
    }

    private var loopBinding: Binding<Bool> {
        Binding(
            get: { vm.kit.slots[slot].loop },
            set: { v in replaceSlot { $0.loop = v } }
        )
    }

    private var fadeInBinding: Binding<Double> {
        Binding(
            get: { vm.kit.slots[slot].fadeInMs },
            set: { v in replaceSlot { $0.fadeInMs = v } }
        )
    }

    private var fadeOutBinding: Binding<Double> {
        Binding(
            get: { vm.kit.slots[slot].fadeOutMs },
            set: { v in replaceSlot { $0.fadeOutMs = v } }
        )
    }

    private var startOffsetBinding: Binding<Double> {
        Binding(
            get: { vm.kit.slots[slot].startOffsetMs },
            set: { v in replaceSlot { $0.startOffsetMs = max(0, v) } }
        )
    }

    private var chokeBinding: Binding<Int> {
        Binding(
            get: { vm.kit.slots[slot].chokeGroup ?? 0 },
            set: { v in replaceSlot { $0.chokeGroup = v == 0 ? nil : v } }
        )
    }

    private var retriggerBinding: Binding<RetriggerBehavior> {
        Binding(
            get: { vm.kit.slots[slot].retriggerBehavior },
            set: { v in replaceSlot { $0.retriggerBehavior = v } }
        )
    }

    private func replaceSlot(_ body: (inout SlotConfig) -> Void) {
        var k = vm.kit
        guard slot >= 0, slot < k.slots.count else { return }
        body(&k.slots[slot])
        vm.kit = k
    }

    private func pickAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.begin { r in
            guard r == .OK, let url = panel.url else { return }
            try? vm.assignAudio(url: url, toSlot: slot)
        }
    }
}

/// 再生中スロットのシークバー（`AVAudioPlayerNode` を再スケジュール）
private struct InspectorPlaybackSeekBar: View {
    @EnvironmentObject private var vm: AppViewModel
    let slot: Int
    @State private var isDragging = false
    @State private var dragNorm: Float = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { _ in
            let t = vm.engine.playbackTimeline(for: slot)
            let durationSec = t?.durationSec ?? 0
            let liveNorm: Float = {
                guard let t, t.durationSec > 0.000_1 else { return 0 }
                return Float(t.positionSec / t.durationSec)
            }()
            let displayNorm = isDragging ? dragNorm : liveNorm
            let posSec = Double(displayNorm) * durationSec

            HStack(alignment: .center, spacing: 12) {
                Slider(
                    value: Binding(
                        get: { Double(displayNorm) },
                        set: { v in
                            isDragging = true
                            dragNorm = Float(v)
                        }
                    ),
                    in: 0 ... 1,
                    onEditingChanged: { editing in
                        if !editing {
                            vm.engine.seek(slotIndex: slot, normalized: dragNorm)
                            isDragging = false
                        }
                    }
                )
                .frame(maxWidth: .infinity)
                Text(Self.formatClock(durationSec))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 48, alignment: .trailing)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("再生位置")
            .accessibilityValue("\(Self.formatClock(posSec)) / \(Self.formatClock(durationSec))")
        }
    }

    private static func formatClock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
