import SwiftUI

/// 左側：ノブ・フェーダー・キー・トランスポートのブロック（MIDI なしでもスライダーで操作可能）
struct StarrypadLeftPanelView: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 20) {
                knobBlock(index: 0, label: "K1")
                knobBlock(index: 1, label: "K2")
            }
            .frame(maxWidth: .infinity)

            HStack(alignment: .bottom, spacing: 16) {
                verticalFader(index: 0, label: "F1")
                verticalFader(index: 1, label: "F2")
            }
            .frame(maxWidth: .infinity)

            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 6) {
                    hardwareKey(title: "A")
                    hardwareKey(title: "B")
                    hardwareKey(title: "FULL LEVEL")
                    hardwareKey(title: "PAD BANK") {
                        vm.uiBank = (vm.uiBank + 1) % PresetKit.banks
                    }
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 6) {
                    Text("バンク")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    VStack(spacing: 4) {
                        ForEach(0 ..< PresetKit.banks, id: \.self) { i in
                            let labels = ["A", "B", "C"]
                            Button {
                                vm.uiBank = i
                            } label: {
                                Text(labels[i])
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 44, height: 28)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(vm.uiBank == i ? Color.accentColor.opacity(0.35) : Color(nsColor: .windowBackgroundColor))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(vm.uiBank == i ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: vm.uiBank == i ? 2 : 1)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minWidth: 52)
            }

            transportCluster
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
    }

    private func knobBlock(index: Int, label: String) -> some View {
        let v = vm.knobDisplay[min(index, vm.knobDisplay.count - 1)]
        let knobRole = vm.kit.knobRoles.indices.contains(index) ? vm.kit.knobRoles[index] : KnobRole.none
        let knobCaption: String = {
            if knobRole == .playbackRate {
                return String(format: "%.2f×", PlaybackRateMapping.rate(fromNormalized: v))
            }
            return String(format: "%.0f%%", Double(v) * 100)
        }()
        return VStack(spacing: 6) {
            knobDial(label: label, value: v, caption: knobCaption)
            Slider(
                value: Binding(
                    get: { Double(vm.knobDisplay[min(index, vm.knobDisplay.count - 1)]) },
                    set: { vm.setKnob(index: index, value: Float($0)) }
                ),
                in: 0 ... 1
            )
            .controlSize(.small)
            Picker("ノブの役割", selection: Binding(
                get: { vm.kit.knobRoles.indices.contains(index) ? vm.kit.knobRoles[index] : .none },
                set: { vm.setKnobRole(index: index, role: $0) }
            )) {
                ForEach(KnobRole.allCases) { r in
                    Text(r.displayName).tag(r)
                }
            }
            .labelsHidden()
            .frame(width: 112)
        }
    }

    private var transportCluster: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("トランスポート")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                smallKey("KNOB\nBANK")
                smallKey("FADER\nBANK")
            }
            HStack(spacing: 8) {
                iconKey("▶︎")
                smallKey("NOTE\nREPEAT")
                iconKey("▲")
            }
            HStack(spacing: 8) {
                iconKey("●")
                smallKey("SHIFT")
                iconKey("▼")
            }
        }
    }

    private func knobDial(label: String, value: Float, caption: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.35), lineWidth: 3)
                    .frame(width: 52, height: 52)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0.02, value)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 52, height: 52)
                    .rotationEffect(.degrees(-90))
                Text(label)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.primary)
            }
            Text(caption)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func verticalFader(index: Int, label: String) -> some View {
        let fv = vm.faderDisplay[min(index, vm.faderDisplay.count - 1)]
        let faderRole = vm.kit.faderRoles.indices.contains(index) ? vm.kit.faderRoles[index] : FaderRole.none
        let faderCaption: String = {
            if faderRole == .playbackRate {
                return String(format: "%.2f×", PlaybackRateMapping.rate(fromNormalized: fv))
            }
            return String(format: "%.0f%%", Double(fv) * 100)
        }()
        return VStack(spacing: 6) {
            VerticalFader(
                value: Binding(
                    get: { vm.faderDisplay[min(index, vm.faderDisplay.count - 1)] },
                    set: { vm.setFader(index: index, value: $0) }
                )
            )
            .frame(width: 36, height: 120)

            Text(label)
                .font(.caption2.weight(.bold))
            Picker("役割", selection: Binding(
                get: { vm.kit.faderRoles.indices.contains(index) ? vm.kit.faderRoles[index] : .none },
                set: { vm.setFaderRole(index: index, role: $0) }
            )) {
                ForEach(FaderRole.allCases) { r in
                    Text(r.displayName).tag(r)
                }
            }
            .labelsHidden()
            .frame(width: 112)
            Text(faderCaption)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func hardwareKey(title: String, action: (() -> Void)? = nil) -> some View {
        Group {
            if let action {
                Button(action: action) {
                    keyLabel(title)
                }
                .buttonStyle(.plain)
            } else {
                keyLabel(title)
            }
        }
    }

    private func keyLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
    }

    private func smallKey(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9, weight: .semibold))
            .multilineTextAlignment(.center)
            .frame(minWidth: 56, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.2)))
    }

    private func iconKey(_ symbol: String) -> some View {
        Text(symbol)
            .font(.title3)
            .frame(minWidth: 56, minHeight: 36)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.secondary.opacity(0.2)))
    }
}

/// 回転 `Slider` によるヒット領域ズレを避ける縦フェーダー（0=下・1=上）
private struct VerticalFader: View {
    @Binding var value: Float

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let w = geo.size.width
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 5)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.55), Color.accentColor.opacity(0.2)],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(height: max(3, CGFloat(value) * h))
                Capsule()
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.45), lineWidth: 1))
                    .frame(width: w - 4, height: 10)
                    .offset(y: -CGFloat(value) * (h - 10))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let y = min(max(g.location.y, 0), h)
                        value = max(0, min(1, Float(1 - y / max(h, 1))))
                    }
            )
        }
    }
}
