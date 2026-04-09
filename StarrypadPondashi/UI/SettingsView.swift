import AppKit
import CoreAudio
import CoreMIDI
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var midi: StarrypadMIDIClient
    @State private var profileExportText: String = ""

    var body: some View {
        Form {
            Section("MIDI 入力") {
                Picker("ソース", selection: $midi.selectedSourceID) {
                    Text("未選択").tag(Optional<MIDIUniqueID>.none)
                    ForEach(midi.sources) { s in
                        Text(s.displayName).tag(Optional(s.id))
                    }
                }
                Button("デバイス一覧を更新") {
                    midi.refreshSources()
                }
                Picker("MIDI チャンネル", selection: Binding(
                    get: {
                        if let ch = vm.profile.midiChannel { return ch + 1 }
                        return 0
                    },
                    set: { (v: Int) in
                        var p = vm.profile
                        p.midiChannel = v == 0 ? nil : v - 1
                        vm.profile = p
                    }
                )) {
                    Text("すべて").tag(0)
                    ForEach(1 ... 16, id: \.self) { n in
                        Text("\(n)").tag(n)
                    }
                }
            }

            Section("音声出力") {
                Picker("出力先", selection: Binding(
                    get: { vm.selectedAudioOutputDeviceID },
                    set: { vm.selectAudioOutputDevice($0) }
                )) {
                    Text("システム既定").tag(Optional<AudioDeviceID>.none)
                    ForEach(vm.audioOutputDeviceList, id: \.id) { row in
                        Text(row.name).tag(Optional(row.id))
                    }
                }
                Text("システムの効果音・通知音は OS の経路で、本アプリは AVAudioEngine 経由です。特定デバイスを選ぶと、メニューバーで変えた既定出力とずれて無音に見えることがあります。「システム既定」か、下のリセットを試してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("出力デバイス一覧を更新") {
                    vm.refreshAudioOutputDevices()
                }
                Button("保存した出力先をやめてシステム既定に戻す") {
                    vm.clearSavedOutputDeviceAndUseSystemDefault()
                }
            }

            Section("キット") {
                TextField("プリセット名", text: $vm.kit.name)
                HStack {
                    Button("プリセットを保存…") { vm.savePresetPanel() }
                    Button("プリセットを読込…") { vm.loadPresetPanel() }
                }
                Stepper(value: $vm.kit.maxPolyphony, in: 1 ... 64) {
                    Text("最大同時発音: \(vm.kit.maxPolyphony)")
                }
                Toggle("上限時は古い声を切る", isOn: $vm.kit.stealOldestVoice)
                Slider(value: $vm.kit.masterVolume, in: 0 ... 1) {
                    Text("マスター")
                }
            }

            Section("マッピングキャプチャ") {
                Text("初期マッピングは目安です。キャプチャで合わせ、必要なら Application Support に保存してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let msg = vm.captureControlMessage {
                    Text(msg)
                        .font(.caption)
                }
                HStack {
                    Button("パッド bank A を学習") { vm.startPadCapture(bank: 0) }
                    Button("B") { vm.startPadCapture(bank: 1) }
                    Button("C") { vm.startPadCapture(bank: 2) }
                }
                HStack {
                    Button("フェーダー1 CC") { vm.startFaderCapture(index: 0) }
                    Button("フェーダー2 CC") { vm.startFaderCapture(index: 1) }
                }
                HStack {
                    Button("ノブ1 CC") { vm.startKnobCapture(index: 0) }
                    Button("ノブ2 CC") { vm.startKnobCapture(index: 1) }
                }
                Button("キャプチャ取消") { vm.cancelCapture() }
                Button("プロファイルを Application Support に保存") {
                    try? vm.saveProfileToApplicationSupport()
                }
            }

            Section("プロファイル JSON") {
                Button("クリップボードにエクスポート") {
                    if let s = vm.exportProfileJSON() {
                        profileExportText = s
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(s, forType: .string)
                    }
                }
                if !profileExportText.isEmpty {
                    TextEditor(text: .constant(profileExportText))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 120)
                }
            }

            Section("MIDI ログ") {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(vm.midiLog.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(.caption2, design: .monospaced))
                        }
                    }
                }
                .frame(minHeight: 120)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            vm.refreshAudioOutputDevices()
            vm.applySavedAudioOutputDevice()
        }
        .onChange(of: vm.kit.masterVolume) { _ in
            vm.syncMasterOutputToEngine()
        }
    }
}
