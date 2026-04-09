import AppKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var selectedSlot: Int?
    /// インスペクタはデフォルト格納。パッドクリックで開く。
    @State private var inspectorPresented = false
    @State private var sidebarTab: SidebarTab = .pads

    private enum SidebarTab: String, CaseIterable, Identifiable {
        case pads = "パッド"
        case settings = "設定"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $sidebarTab) {
                ForEach(SidebarTab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .navigationTitle("Starrypad Pondashi")
            .frame(minWidth: 140)
        } detail: {
            Group {
                switch sidebarTab {
                case .pads:
                    padsPane
                case .settings:
                    SettingsView()
                }
            }
            .frame(minWidth: detailMinWidth, minHeight: 520)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            vm.recoverEngineIfStoppedAfterBackground()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("全停止") {
                    vm.panic()
                }
                .keyboardShortcut(".", modifiers: [.command])
            }
            ToolbarItem(placement: .automatic) {
                if sidebarTab == .pads, selectedSlot != nil, !inspectorPresented {
                    Button {
                        inspectorPresented = true
                    } label: {
                        Label("インスペクタ", systemImage: "sidebar.leading")
                    }
                    .help("選択中パッドの設定を表示")
                }
            }
        }
    }

    private var detailMinWidth: CGFloat {
        if sidebarTab == .pads, inspectorPresented, selectedSlot != nil {
            return 880
        }
        return 560
    }

    private var padsPane: some View {
        HSplitView {
            ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    StarrypadLeftPanelView()
                        .frame(width: 272)

                    PadGridView(selectedSlot: $selectedSlot, inspectorPresented: $inspectorPresented)
                        .frame(minWidth: 380)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .layoutPriority(1)

            if inspectorPresented, let s = selectedSlot {
                PadInspectorView(slot: s, onDismiss: {
                    inspectorPresented = false
                })
                .padding()
                .frame(minWidth: 300, idealWidth: 340, maxWidth: 480)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }
}
