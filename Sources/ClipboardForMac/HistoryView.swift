import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var manager: ClipboardManager
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField

            if manager.entries.isEmpty {
                emptyState("コピーするとここに表示されます")
            } else if manager.filteredEntries.isEmpty {
                emptyState("見つかりませんでした")
            } else {
                historyList
            }

            Divider()
            footer
        }
        .frame(width: 400, height: 360)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .alert("エラー", isPresented: Binding(
            get: { manager.errorMessage != nil },
            set: { if !$0 { manager.errorMessage = nil } }
        )) {
            Button("OK") { manager.errorMessage = nil }
        } message: {
            Text(manager.errorMessage ?? "")
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                searchFocused = true
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("検索", text: $manager.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("履歴を検索")
            if !manager.query.isEmpty {
                Button {
                    manager.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("検索を消去")
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 34)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.16)))
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(manager.filteredEntries) { entry in
                        historyRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
            }
            .onChange(of: manager.selectedID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func historyRow(_ entry: ClipboardEntry) -> some View {
        let selected = manager.selectedID == entry.id
        return HStack(spacing: 9) {
            if entry.kind == .text {
                Text(entry.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if entry.kind == .image {
                preview(for: entry)
                    .frame(width: 38, height: 38)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                Spacer()
            } else {
                preview(for: entry)
                    .frame(width: 24, height: 24)
                Text(entry.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                manager.togglePin(entry)
            } label: {
                Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(entry.isPinned ? Color.accentColor : Color.secondary)
                    .frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
            .opacity(selected || entry.isPinned ? 1 : 0)
            .allowsHitTesting(selected || entry.isPinned)
            .help(entry.isPinned ? "固定を解除" : "履歴に固定")
            .accessibilityLabel(entry.isPinned ? "固定を解除" : "履歴に固定")
            .accessibilityHidden(!selected && !entry.isPinned)

            Button {
                manager.delete(entry)
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 24)
            }
            .buttonStyle(.plain)
            .opacity(selected ? 1 : 0)
            .allowsHitTesting(selected)
            .help("削除")
            .accessibilityLabel("削除")
            .accessibilityHidden(!selected)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 32)
        .background(
            selected ? Color.accentColor.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 9)
        )
        .contentShape(RoundedRectangle(cornerRadius: 9))
        .onTapGesture { manager.select(entry) }
        .onHover { inside in
            if inside { manager.selectedID = entry.id }
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func preview(for entry: ClipboardEntry) -> some View {
        switch entry.kind {
        case .image:
            if let image = manager.image(for: entry) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(2)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        case .files:
            if let path = entry.fileURLs?.first.flatMap(URL.init(string:))?.path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
            }
        case .text:
            EmptyView()
        }
    }

    private func emptyState(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            if !manager.canAutoPaste {
                Button("自動貼り付けを許可") { manager.requestAccessibility() }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            }
            Spacer()
            Menu {
                Button("範囲を撮影（⌥⇧S）") { manager.onScreenshotRequest?() }
                Divider()
                Toggle("ログイン時に起動", isOn: Binding(
                    get: { manager.launchAtLogin },
                    set: { manager.setLaunchAtLogin($0) }
                ))
                Divider()
                Button("未固定の履歴を消去") { manager.clearUnpinned() }
                    .disabled(!manager.entries.contains { !$0.isPinned })
                Divider()
                Button("終了") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 24)
            .accessibilityLabel("その他の操作")
        }
        .padding(.horizontal, 16)
        .frame(height: 40)
    }
}
