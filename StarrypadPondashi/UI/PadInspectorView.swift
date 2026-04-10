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

    @State private var appearanceExpanded = false
    @State private var youtubeInput = ""

    private var padNumberInBank: Int { slot % 16 + 1 }
    private var bankLetter: String {
        let b = slot / 16
        return ["A", "B", "C"][min(b, 2)]
    }

    /// スロット／割当音声のいずれかが変わったら ytId 入力を捨てる（次回まで残さない）
    private var slotAudioSignature: String {
        guard slot >= 0, slot < vm.kit.slots.count else { return "" }
        return "\(slot)|\(vm.kit.slots[slot].filePath ?? "")"
    }

    /// 格納時は1行で、現在の着色をサムネ表示
    private var appearanceSectionLabel: some View {
        HStack(spacing: 8) {
            Text("外観")
            Spacer(minLength: 4)
            if slot >= 0, slot < vm.kit.slots.count, let t = vm.kit.slots[slot].padTint {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(red: t.r, green: t.g, blue: t.b, opacity: t.a))
                    .frame(width: 16, height: 16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                    )
            } else {
                Text("既定")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
                            if vm.kit.slots[slot].filePath != nil {
                                HStack(alignment: .center, spacing: 10) {
                                    Text("表示名")
                                        .foregroundStyle(.secondary)
                                        .frame(width: 48, alignment: .leading)
                                    TextField("", text: fileDisplayNameBinding)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                Text("音声なし（クリックでは鳴りません）")
                                    .font(.caption)
                                    .foregroundStyle(.orange)

                                VStack(alignment: .leading, spacing: 8) {
                                    Text("YouTube から取り込み")
                                        .font(.subheadline.weight(.semibold))
                                    HStack(alignment: .center, spacing: 10) {
                                        Text("ytId")
                                            .foregroundStyle(.secondary)
                                            .frame(width: 40, alignment: .leading)
                                        TextField("", text: $youtubeInput)
                                            .textFieldStyle(.roundedBorder)
                                            .multilineTextAlignment(.leading)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .onChange(of: youtubeInput) { _ in
                                                vm.clearYoutubeImportError()
                                            }
                                    }
                                    .onChange(of: slotAudioSignature) { _ in
                                        youtubeInput = ""
                                        vm.clearYoutubeImportError()
                                    }
                                    HStack(spacing: 10) {
                                        Button("MP3 をダウンロードして登録") {
                                            vm.importYouTubeToPad(rawInput: youtubeInput, slot: slot)
                                        }
                                        .disabled(
                                            youtubeInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                || vm.youtubeImportInProgress
                                        )
                                        if vm.youtubeImportInProgress {
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                    }
                                    if let err = vm.youtubeImportError {
                                        Text(err)
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.top, 4)
                            }
                        } header: {
                            Text("音声")
                        }

                        Section {
                            DisclosureGroup(isExpanded: $appearanceExpanded) {
                                Text("おすすめ（暗め・白字向け）")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 76), spacing: 8)],
                                    spacing: 8
                                ) {
                                    ForEach(PadColorPreset.builtin) { preset in
                                        padPresetButton(preset)
                                    }
                                }
                                .padding(.vertical, 2)

                                ColorPicker("カスタムの色", selection: padTintColorBinding, supportsOpacity: true)
                                Button("デフォルトの色に戻す") {
                                    replaceSlot { $0.padTint = nil }
                                }
                                .disabled(vm.kit.slots[slot].padTint == nil)
                            } label: {
                                appearanceSectionLabel
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
                            Text("ゲートは MIDI のノートオフ、または対応パッドの離脱に反応します。ループ時も毎周、再生開始位置から繰り返します。開始位置がファイル長を超えると鳴りません。")
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
            set: { v in
                replaceSlot { $0.volume = v }
                vm.applyLiveSlotVolume(slotIndex: slot)
            }
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

    /// パッド上の表示テキスト。ファイル名と同じ／空にすると `fileDisplayName` を nil に戻す。
    private var fileDisplayNameBinding: Binding<String> {
        Binding(
            get: {
                guard slot >= 0, slot < vm.kit.slots.count else { return "" }
                let cfg = vm.kit.slots[slot]
                guard let path = cfg.filePath else { return "" }
                let base = (path as NSString).lastPathComponent
                if let custom = cfg.fileDisplayName, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return custom
                }
                return base
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                replaceSlot { cfg in
                    guard let path = cfg.filePath else { return }
                    let base = (path as NSString).lastPathComponent
                    if trimmed.isEmpty || trimmed == base {
                        cfg.fileDisplayName = nil
                    } else {
                        cfg.fileDisplayName = trimmed
                    }
                }
            }
        )
    }

    private var padTintColorBinding: Binding<Color> {
        Binding(
            get: {
                if let t = vm.kit.slots[slot].padTint {
                    return Color(red: t.r, green: t.g, blue: t.b, opacity: t.a)
                }
                return Color(nsColor: .controlBackgroundColor)
            },
            set: { color in
                let ns = NSColor(color)
                guard let rgb = ns.usingColorSpace(.deviceRGB) else {
                    replaceSlot { $0.padTint = nil }
                    return
                }
                var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
                replaceSlot {
                    $0.padTint = PadSlotTint(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
                }
            }
        )
    }

    private func replaceSlot(_ body: (inout SlotConfig) -> Void) {
        var k = vm.kit
        guard slot >= 0, slot < k.slots.count else { return }
        body(&k.slots[slot])
        vm.kit = k
    }

    @ViewBuilder
    private func padPresetButton(_ preset: PadColorPreset) -> some View {
        let current = vm.kit.slots[slot].padTint
        let selected = preset.matches(current)
        Button {
            replaceSlot { $0.padTint = preset.tint }
        } label: {
            VStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(red: preset.tint.r, green: preset.tint.g, blue: preset.tint.b, opacity: preset.tint.a))
                    .frame(height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(
                                selected ? Color.accentColor : Color.primary.opacity(0.2),
                                lineWidth: selected ? 2 : 1
                            )
                    )
                Text(preset.name)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.name)の色を適用\(selected ? "、選択中" : "")")
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
