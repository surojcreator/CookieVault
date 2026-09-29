import SwiftUI
import AppKit
import Combine

// MARK: - API Keys Main View

struct APIKeysMainView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ZStack {
            if store.showAllValidKeys {
                AllValidKeysView()
            } else if let folder = store.selectedAPIFolder {
                FolderOverviewView(folderName: folder, tab: .apiKeys)
            } else if let file = store.selectedAPIFile {
                // .id ties the view's identity to the selected file, so switching to a
                // different API-key website rebuilds the detail (its @StateObject is
                // seeded once per identity — without this it showed the previous file).
                APIFileDetailView(file: file)
                    .id(file.id)
            } else {
                EmptyStateView(
                    icon: "key.fill",
                    title: "No API key file selected",
                    subtitle: "Import a .txt key file, a whole folder, or a .zip archive to inspect and verify API keys across 25+ providers.",
                    actionTitle: "Import API Keys",
                    action: { store.chooseFolder(tab: .apiKeys) }
                )
            }

            if let inspected = store.inspectedKey, let file = store.selectedAPIFile {
                Color.black.opacity(0.6).ignoresSafeArea()
                    .onTapGesture { store.inspectedKey = nil }
                KeyInspectorSheet(key: inspected, file: file) { store.inspectedKey = nil }
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }

            if store.showProxySheet {
                Color.black.opacity(0.6).ignoresSafeArea()
                    .onTapGesture { store.applyProxies(); store.showProxySheet = false }
                ProxySheet { store.applyProxies(); store.showProxySheet = false }
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.16), value: store.inspectedKey?.id)
        .animation(.easeOut(duration: 0.16), value: store.showProxySheet)
    }
}

// MARK: - Proxy settings sheet

struct ProxySheet: View {
    @EnvironmentObject var store: AppStore
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: "network.badge.shield.half.filled", tint: Theme.accent2, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Proxies for API checks").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.textPri)
                    Text("Rotated across every key check so no single IP gets rate limited")
                        .font(.system(size: 11)).foregroundColor(Theme.textTer)
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundColor(Theme.textTer) }
                    .buttonStyle(.plain)
            }
            .padding(18).background(Theme.surfaceHi)
            Rectangle().fill(Theme.border).frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                Text("One proxy per line. Supported formats:")
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.textSec)
                Text("host:port   ·   host:port:user:pass   ·   user:pass@host:port   ·   http(s)://user:pass@host:port   ·   socks5://host:port")
                    .font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.textTer)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: Binding(get: { store.proxyText }, set: { store.proxyText = $0 }))
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 190)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: Theme.rSm).fill(Theme.inset))
                    .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.border, lineWidth: 1))

                HStack(spacing: 10) {
                    Text("\(store.parsedProxies.count) valid").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.green)
                    if store.invalidProxyLineCount > 0 {
                        Text("\(store.invalidProxyLineCount) unparseable").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.orange)
                    }
                    Spacer()
                    Toggle(isOn: Binding(get: { store.proxyIncludeDirect }, set: { store.proxyIncludeDirect = $0; store.applyProxies() })) {
                        Text("Also use my direct IP").font(.system(size: 11)).foregroundColor(Theme.textSec)
                    }.toggleStyle(.switch).controlSize(.mini)
                }
            }
            .padding(18)

            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 12) {
                Button { store.applyProxies(); Task { await store.testProxies() } } label: {
                    GhostButton(title: "Test proxies", systemImage: "bolt.horizontal.circle", tint: Theme.gold)
                }.buttonStyle(.plain)
                Spacer()
                Button { store.applyProxies(); onClose() } label: {
                    FilledButton(title: "Save & Apply", systemImage: "checkmark", gradient: Theme.accentGrad, glow: Theme.accent)
                }.buttonStyle(.plain)
            }
            .padding(16).background(Theme.surfaceHi)
        }
        .frame(width: 560)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous).stroke(Theme.borderHi, lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 34, y: 14)
    }
}

// MARK: - API File View Model

final class APIFileVM: ObservableObject {
    @Published var searchText = ""
    @Published var filterStatus: FilterStatus = .all
    @Published var file: APIKeyFile
    @Published var selectMode = false
    @Published var selectedIDs: Set<UUID> = []

    init(file: APIKeyFile) { self.file = file }

    enum FilterStatus: String, CaseIterable {
        case all = "All", valid = "Valid", invalid = "Invalid"
        case quota = "Quota / Limited", unchecked = "Unchecked", error = "Error"
    }
}

// MARK: - API File Detail View

struct APIFileDetailView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var vm: APIFileVM

    init(file: APIKeyFile) { _vm = StateObject(wrappedValue: APIFileVM(file: file)) }

    var currentFile: APIKeyFile { store.apiKeyFiles.first { $0.id == vm.file.id } ?? vm.file }

    func count(_ status: APIFileVM.FilterStatus) -> Int {
        let keys = currentFile.keys
        switch status {
        case .all: return keys.count
        case .valid: return keys.filter { $0.status == .valid }.count
        case .invalid: return keys.filter { $0.status == .invalid }.count
        case .quota: return keys.filter { $0.status == .quotaExceeded || $0.status == .rateLimited || $0.status == .permissionDenied }.count
        case .unchecked: return keys.filter { $0.status == .idle }.count
        case .error: return keys.filter { $0.status == .error }.count
        }
    }

    func filtered(_ keys: [APIKey]) -> [APIKey] {
        var k = keys
        if !vm.searchText.isEmpty {
            let q = vm.searchText.lowercased()
            k = k.filter {
                $0.value.lowercased().contains(q) ||
                ($0.responseSnippet?.lowercased().contains(q) ?? false) ||
                ($0.details?.accountName?.lowercased().contains(q) ?? false) ||
                ($0.details?.planOrTier?.lowercased().contains(q) ?? false)
            }
        }
        switch vm.filterStatus {
        case .all: break
        case .valid: k = k.filter { $0.status == .valid }
        case .invalid: k = k.filter { $0.status == .invalid }
        case .quota: k = k.filter { $0.status == .quotaExceeded || $0.status == .rateLimited || $0.status == .permissionDenied }
        case .unchecked: k = k.filter { $0.status == .idle }
        case .error: k = k.filter { $0.status == .error }
        }
        // QoL: surface the useful keys first — valid, then limited, then the rest.
        func rank(_ s: CheckStatus) -> Int {
            switch s {
            case .valid: return 0
            case .quotaExceeded, .rateLimited, .permissionDenied: return 1
            case .checking: return 2
            case .idle: return 3
            case .error: return 4
            case .invalid: return 5
            }
        }
        return k.enumerated().sorted { a, b in
            let ra = rank(a.element.status), rb = rank(b.element.status)
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map { $0.element }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.border).frame(height: 1)
            filterBar
            Rectangle().fill(Theme.border).frame(height: 1)
            statsBar
            Rectangle().fill(Theme.border).frame(height: 1)
            revealsBar
            Rectangle().fill(Theme.border).frame(height: 1)
            if vm.selectMode {
                selectionBar
                Rectangle().fill(Theme.border).frame(height: 1)
            }
            keysList
            Rectangle().fill(Theme.border).frame(height: 1)
            actionBar
        }
        .background(Theme.bg0)
        .onReceive(store.$apiKeyFiles) { files in
            if let updated = files.first(where: { $0.id == vm.file.id }) { vm.file = updated }
        }
    }

    private var providerInfo: APIKeyChecker.ProviderInfo { APIKeyChecker.providerInfo(service: vm.file.service) }

    static func isDiscord(_ service: String) -> Bool {
        ["discord_user", "all_discord_tokens", "valid_discord_tokens"].contains(service.lowercased())
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            IconTile(symbol: vm.file.icon, tint: Theme.gold, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(vm.file.displayName).font(.system(size: 17, weight: .bold)).foregroundColor(Theme.textPri)
                    Pill(text: providerInfo.category, tint: Theme.accent2)
                    if let folder = vm.file.folderName { Pill(text: folder, systemImage: "folder.fill", tint: Theme.textSec) }
                }
                Text("\(currentFile.keys.count) keys · \(providerInfo.blurb)")
                    .font(.system(size: 12)).foregroundColor(Theme.textTer).lineLimit(1)
            }
            Spacer()
            if APIKeyChecker.dashboardURL(service: vm.file.service) != nil {
                Button { store.openProviderDashboard(service: vm.file.service) } label: {
                    GhostButton(title: "Dashboard", systemImage: "arrow.up.forward.app", tint: Theme.accent2)
                }.buttonStyle(.plain).help("Open the \(vm.file.displayName) account dashboard")
            }
            Button {
                vm.selectMode.toggle()
                if !vm.selectMode { vm.selectedIDs.removeAll() }
            } label: {
                GhostButton(title: vm.selectMode ? "Done" : "Select",
                            systemImage: vm.selectMode ? "checkmark.circle" : "checklist",
                            tint: vm.selectMode ? Theme.accent2 : Theme.textSec)
            }.buttonStyle(.plain)
            if !vm.selectMode {
                HStack(spacing: 5) {
                    Circle().fill(Theme.green).frame(width: 7, height: 7)
                    Text("Inspection ready").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.green)
                }
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Theme.green.opacity(0.12)))
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 16).background(Theme.bg1)
    }

    private var selectionBar: some View {
        let ids = vm.selectedIDs
        let hasSel = !ids.isEmpty
        return HStack(spacing: 8) {
            Text("\(ids.count) selected").font(.system(size: 12, weight: .bold)).foregroundColor(Theme.accent2)
            Button("All") { vm.selectedIDs = Set(filtered(currentFile.keys).map { $0.id }) }
                .font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.textSec).buttonStyle(.plain)
            Button("None") { vm.selectedIDs.removeAll() }
                .font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.textSec).buttonStyle(.plain)
            Spacer()
            Button { copySelected() } label: { GhostButton(title: "Copy", systemImage: "doc.on.doc") }
                .buttonStyle(.plain).disabled(!hasSel).opacity(hasSel ? 1 : 0.4)
            Button { exportSelected() } label: { GhostButton(title: "Export", systemImage: "square.and.arrow.up", tint: Theme.green) }
                .buttonStyle(.plain).disabled(!hasSel).opacity(hasSel ? 1 : 0.4)
            Button { Task { await store.checkKeys(ids, in: vm.file) } } label: {
                GhostButton(title: "Check", systemImage: "checkmark.shield", tint: Theme.gold)
            }.buttonStyle(.plain).disabled(!hasSel || store.isBatchChecking).opacity(hasSel ? 1 : 0.4)
            Button { store.deleteKeys(ids, in: vm.file); vm.selectedIDs.removeAll() } label: {
                GhostButton(title: "Delete", systemImage: "trash", tint: Theme.red)
            }.buttonStyle(.plain).disabled(!hasSel).opacity(hasSel ? 1 : 0.4)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Theme.accent.opacity(0.06))
    }

    private func selectedKeys() -> [APIKey] { currentFile.keys.filter { vm.selectedIDs.contains($0.id) } }
    private func copySelected() {
        let text = selectedKeys().map { $0.value }.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        store.showToast("Copied \(vm.selectedIDs.count) keys", type: .success)
    }
    private func exportSelected() {
        let keys = selectedKeys()
        guard !keys.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(vm.file.service)_selected.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? keys.map { $0.value }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
            store.showToast("Exported \(keys.count) keys", type: .success)
        }
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            CVSearchBar(text: Binding(get: { vm.searchText }, set: { vm.searchText = $0 }),
                        placeholder: "Search keys, accounts, responses…").frame(maxWidth: 300)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(APIFileVM.FilterStatus.allCases, id: \.self) { s in
                        FilterChip(title: s.rawValue, count: count(s), isSelected: vm.filterStatus == s) { vm.filterStatus = s }
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10).background(Theme.bg1)
    }

    private var statsBar: some View {
        HStack(spacing: 0) {
            statItem("Total", "\(currentFile.keys.count)", Theme.textSec)
            statDivider
            statItem("Valid", "\(count(.valid))", Theme.green)
            statDivider
            statItem("Invalid", "\(count(.invalid))", Theme.red)
            statDivider
            statItem("Quota", "\(count(.quota))", Theme.orange)
            statDivider
            statItem("Unchecked", "\(count(.unchecked))", Theme.gold)
        }
        .padding(.vertical, 10).background(Theme.inset)
    }
    private var statDivider: some View { Rectangle().fill(Theme.border).frame(width: 1, height: 28) }

    // Per-type descriptor: what a valid check of this provider surfaces.
    private var revealsBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 9)).foregroundColor(Theme.accent2)
            Text("Reveals:").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.textTer)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 5) {
                    ForEach(providerInfo.reveals, id: \.self) { r in
                        Text(r).font(.system(size: 9.5, weight: .medium)).foregroundColor(Theme.accent2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent.opacity(0.10)))
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 7).background(Theme.bg1)
    }

    private var keysList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                let keys = filtered(currentFile.keys)
                if keys.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundColor(Theme.textTer)
                        Text("No keys match this filter").font(.system(size: 13)).foregroundColor(Theme.textSec)
                    }
                    .frame(maxWidth: .infinity).padding(.top, 44)
                } else {
                    ForEach(keys) { key in
                        APIKeyRow(key: key, service: vm.file.service,
                                  onCheck: { Task { await store.checkKey(key, in: vm.file) } },
                                  onInspect: { store.inspectedKey = key },
                                  selectMode: vm.selectMode,
                                  isSelected: vm.selectedIDs.contains(key.id),
                                  onSelectToggle: {
                                      if vm.selectedIDs.contains(key.id) { vm.selectedIDs.remove(key.id) }
                                      else { vm.selectedIDs.insert(key.id) }
                                  },
                                  onOpen: Self.isDiscord(vm.file.service) ? { store.openDiscordToken(key) } : nil)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(Theme.bg0)
    }

    private var actionBar: some View {
        HStack(spacing: 12) {
            Button { Task { await store.checkAllKeys(in: vm.file) } } label: {
                FilledButton(title: store.isBatchChecking ? "Checking…" : "Check All Keys",
                             systemImage: store.isBatchChecking ? nil : "bolt.fill",
                             gradient: Theme.goldGrad, glow: Theme.gold)
            }
            .buttonStyle(.plain).disabled(store.isBatchChecking)

            Button { Task { await store.checkUncheckedKeys(in: vm.file) } } label: {
                GhostButton(title: "Check New (\(count(.unchecked)))", systemImage: "sparkle.magnifyingglass", tint: Theme.gold)
            }
            .buttonStyle(.plain).disabled(store.isBatchChecking || count(.unchecked) == 0)
            .opacity(count(.unchecked) == 0 ? 0.4 : 1)

            Button { store.copyValidKeys(in: vm.file) } label: {
                GhostButton(title: "Copy Valid", systemImage: "doc.on.doc", tint: Theme.textSec)
            }.buttonStyle(.plain).disabled(count(.valid) == 0).opacity(count(.valid) == 0 ? 0.4 : 1)

            Button { exportValid() } label: {
                GhostButton(title: "Export Valid (\(count(.valid)))", systemImage: "square.and.arrow.up.fill", tint: Theme.green)
            }.buttonStyle(.plain).disabled(count(.valid) == 0).opacity(count(.valid) == 0 ? 0.4 : 1)

            Spacer()

            Button { store.deleteAPIKeyFile(vm.file) } label: {
                GhostButton(title: "Delete File", systemImage: "trash", tint: Theme.red)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 16).padding(.vertical, 12).background(Theme.bg1)
    }

    func statItem(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundColor(color)
            Text(label).font(.system(size: 11)).foregroundColor(Theme.textTer)
        }
        .frame(maxWidth: .infinity)
    }

    func exportValid() {
        let keys = currentFile.keys.filter { $0.status == .valid }
        guard !keys.isEmpty else { store.showToast("No valid keys to export", type: .warning); return }
        let content = keys.map { $0.value }.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(vm.file.service)_valid.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? content.write(to: url, atomically: true, encoding: .utf8)
            store.showToast("Exported \(keys.count) valid keys", type: .success)
        }
    }
}

// MARK: - API Key Row

final class KeyRowHover: ObservableObject { @Published var on = false }
final class KeyVisibility: ObservableObject { @Published var showFull = false }

struct APIKeyRow: View {
    let key: APIKey
    let service: String
    let onCheck: () -> Void
    let onInspect: () -> Void
    var selectMode: Bool = false
    var isSelected: Bool = false
    var onSelectToggle: () -> Void = {}
    var onOpen: (() -> Void)? = nil
    @StateObject private var hover = KeyRowHover()
    @StateObject private var vis = KeyVisibility()

    private var isChecked: Bool { key.status != .idle && key.status != .checking }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if selectMode {
                    Button(action: onSelectToggle) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 16)).foregroundColor(isSelected ? Theme.accent : Theme.textTer)
                    }.buttonStyle(.plain)
                }
                ZStack {
                    Circle().fill(statusColor.opacity(0.15)).frame(width: 30, height: 30)
                    Image(systemName: statusSymbol).font(.system(size: 12, weight: .bold)).foregroundColor(statusColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(vis.showFull ? key.value : masked)
                            .font(.system(size: 11, design: .monospaced)).foregroundColor(Theme.textPri)
                            .lineLimit(1).textSelection(.enabled)
                        Button { vis.showFull.toggle() } label: {
                            Image(systemName: vis.showFull ? "eye.slash" : "eye").font(.system(size: 10)).foregroundColor(Theme.textTer)
                        }.buttonStyle(.plain)
                        Pill(text: key.status.title, tint: statusColor)
                    }
                    if !isChecked {
                        Text("Not checked yet — press Check for a full analysis")
                            .font(.system(size: 9.5)).foregroundColor(Theme.textTer)
                    }
                }

                Spacer()

                if let onOpen {
                    Button(action: onOpen) {
                        HStack(spacing: 4) { Image(systemName: "arrow.up.forward.app"); Text("Open") }
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(Color(hex: "5865f2"))
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color(hex: "5865f2").opacity(0.14)))
                    }.buttonStyle(.plain).help("Open this account in an isolated logged-in browser")
                }

                Button(action: onInspect) {
                    HStack(spacing: 4) { Image(systemName: "magnifyingglass"); Text("Details") }
                        .font(.system(size: 10, weight: .medium)).foregroundColor(Theme.accent2)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.accent.opacity(0.12)))
                }.buttonStyle(.plain)

                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key.value, forType: .string)
                } label: { IconButton(symbol: "doc.on.doc") }
                .buttonStyle(.plain).opacity(hover.on ? 1 : 0.55)

                Button(action: onCheck) {
                    if key.status == .checking {
                        ProgressView().progressViewStyle(.circular).scaleEffect(0.6).frame(width: 26, height: 26)
                    } else {
                        HStack(spacing: 4) { Image(systemName: "checkmark.shield"); Text(isChecked ? "Recheck" : "Check") }
                            .font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.gold)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.gold.opacity(0.14)))
                    }
                }
                .buttonStyle(.plain).disabled(key.status == .checking)
            }

            if isChecked { analysisPanel }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.rMd).fill(isSelected ? Theme.accent.opacity(0.10) : (hover.on ? Theme.surfaceHi : Theme.surface)))
        .overlay(RoundedRectangle(cornerRadius: Theme.rMd).stroke(isSelected ? Theme.accent : borderColor, lineWidth: isSelected ? 1.5 : 1))
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.1), value: hover.on)
    }

    // MARK: Inline analysis (shown up-front once the key is checked)

    private var analysisChips: [(String, String, Color)] {
        var out: [(String, String, Color)] = []
        if let d = key.details {
            if let v = d.accountName { out.append(("person.fill", v, Theme.accent2)) }
            if let v = d.email { out.append(("envelope.fill", v, Theme.accent2)) }
            if let v = d.planOrTier { out.append(("rosette", v, Theme.blue)) }
            if let v = d.balanceOrQuota { out.append(("creditcard.fill", v, Theme.green)) }
            if let v = d.httpCode { out.append(("network", "HTTP \(v)", Theme.textSec)) }
            if let v = d.latencyMs { out.append(("speedometer", "\(v) ms", Theme.textSec)) }
            if let p = d.permissions, !p.isEmpty { out.append(("checkmark.shield.fill", "\(p.count) scopes", Theme.accent2)) }
            if let m = d.models, !m.isEmpty { out.append(("cpu", "\(m.count) models", Theme.green)) }
        }
        return out
    }

    @ViewBuilder private var analysisPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.badge.magnifyingglass").font(.system(size: 10)).foregroundColor(statusColor)
                SectionLabel(text: "Key Analysis")
                Spacer()
                if let checked = key.checkedAt {
                    Text(checked.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 9)).foregroundColor(Theme.textTer)
                }
            }

            // Human summary line (the checker's verdict), colored by status.
            if let summary = key.responseSnippet ?? key.details?.rawSnippet, !summary.isEmpty {
                Text(summary.prefix(200))
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Fact chips
            if !analysisChips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(analysisChips.enumerated()), id: \.offset) { _, chip in
                            detailPill(chip.0, chip.1, chip.2)
                        }
                    }
                }
            }

            // Scopes & models detail
            if let perms = key.details?.permissions, !perms.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Scopes (\(perms.count))")
                    FlowTagsView(tags: perms, color: Theme.accent2)
                }
            }
            if let models = key.details?.models, !models.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel(text: "Models (\(models.count))")
                    FlowTagsView(tags: Array(models.prefix(14)), color: Theme.green)
                }
            }

            // Nothing structured? show at least the raw reason.
            if analysisChips.isEmpty, (key.responseSnippet ?? "").isEmpty, key.details == nil {
                Text("No further detail returned for this \(key.status.title.lowercased()) key.")
                    .font(.system(size: 10)).foregroundColor(Theme.textTer)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.rSm).fill(Theme.inset))
        .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(statusColor.opacity(0.22), lineWidth: 1))
    }

    func detailPill(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 8))
            Text(text).font(.system(size: 9, weight: .medium)).lineLimit(1)
        }
        .foregroundColor(color).padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.12)))
    }

    var masked: String {
        let v = key.value; guard v.count > 20 else { return v }
        return String(v.prefix(10)) + "•••••••••••••" + String(v.suffix(6))
    }
    var statusColor: Color {
        switch key.status {
        case .idle: return Theme.textTer
        case .checking: return Theme.gold
        case .valid: return Theme.green
        case .invalid: return Theme.red
        case .quotaExceeded: return Theme.orange
        case .rateLimited: return Theme.yellow
        case .permissionDenied: return Theme.pink
        case .error: return Theme.red
        }
    }
    var statusSymbol: String {
        switch key.status {
        case .idle: return "minus"
        case .checking: return "clock"
        case .valid: return "checkmark"
        case .invalid: return "xmark"
        case .quotaExceeded: return "exclamationmark.triangle.fill"
        case .rateLimited: return "hourglass"
        case .permissionDenied: return "lock.fill"
        case .error: return "exclamationmark"
        }
    }
    var borderColor: Color {
        switch key.status {
        case .valid: return Theme.green.opacity(0.3)
        case .invalid: return Theme.red.opacity(0.2)
        case .quotaExceeded: return Theme.orange.opacity(0.25)
        case .rateLimited: return Theme.yellow.opacity(0.25)
        case .permissionDenied: return Theme.pink.opacity(0.25)
        case .error: return Theme.red.opacity(0.2)
        default: return Theme.border
        }
    }
}

// MARK: - All Valid Keys (global "filter for all valids" view)

final class AllValidVM: ObservableObject {
    @Published var search = ""
    @Published var collapsed: Set<UUID> = []
}

struct AllValidKeysView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var vm = AllValidVM()

    private var groups: [(file: APIKeyFile, valid: [APIKey])] {
        let q = vm.search.lowercased()
        return store.filesWithValidKeys().compactMap { g in
            guard !q.isEmpty else { return g }
            // match against provider name/service OR individual key values
            if g.file.displayName.lowercased().contains(q) || g.file.service.lowercased().contains(q) {
                return g
            }
            let keys = g.valid.filter { $0.value.lowercased().contains(q) || ($0.details?.accountName?.lowercased().contains(q) ?? false) }
            return keys.isEmpty ? nil : (file: g.file, valid: keys)
        }
    }

    private var shownCount: Int { groups.reduce(0) { $0 + $1.valid.count } }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.border).frame(height: 1)
            filterBar
            Rectangle().fill(Theme.border).frame(height: 1)
            content
        }
        .background(Theme.bg0)
    }

    private var topBar: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(Theme.green.opacity(0.16)).frame(width: 44, height: 44)
                Image(systemName: "checkmark.seal.fill").font(.system(size: 20, weight: .bold)).foregroundColor(Theme.green)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("All Valid Keys").font(.system(size: 17, weight: .bold)).foregroundColor(Theme.textPri)
                Text("\(store.totalValidKeyCount) valid across \(store.filesWithValidKeys().count) types · \(store.totalCheckedKeyCount) checked total")
                    .font(.system(size: 12)).foregroundColor(Theme.textTer)
            }
            Spacer()
            Button { store.copyAllValidKeys() } label: {
                GhostButton(title: "Copy All", systemImage: "doc.on.doc", tint: Theme.textSec)
            }.buttonStyle(.plain)
            Button { store.exportAllValidKeys() } label: {
                FilledButton(title: "Export All Valid", systemImage: "square.and.arrow.up.fill",
                             gradient: LinearGradient(colors: [Theme.green, Theme.green.opacity(0.7)], startPoint: .top, endPoint: .bottom), glow: Theme.green)
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 16).background(Theme.bg1)
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            CVSearchBar(text: Binding(get: { vm.search }, set: { vm.search = $0 }), placeholder: "Filter by provider or key…").frame(maxWidth: 340)
            Spacer()
            if !groups.isEmpty {
                Text("\(shownCount) shown").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.textTer)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10).background(Theme.bg1)
    }

    @ViewBuilder private var content: some View {
        if store.totalValidKeyCount == 0 {
            VStack(spacing: 12) {
                ZStack {
                    Circle().fill(Theme.green.opacity(0.10)).frame(width: 84, height: 84)
                    Image(systemName: "checkmark.seal").font(.system(size: 32)).foregroundColor(Theme.green)
                }
                Text("No valid keys yet").font(.system(size: 17, weight: .bold)).foregroundColor(Theme.textPri)
                Text("Run “Check All Keys” on your key files — every valid key across all provider types collects here.")
                    .font(.system(size: 12.5)).foregroundColor(Theme.textSec)
                    .multilineTextAlignment(.center).frame(maxWidth: 380).lineSpacing(2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg0)
        } else if groups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 24)).foregroundColor(Theme.textTer)
                Text("No valid keys match “\(vm.search)”").font(.system(size: 13)).foregroundColor(Theme.textSec)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(groups, id: \.file.id) { g in
                        groupSection(g.file, g.valid)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .background(Theme.bg0)
        }
    }

    private func groupSection(_ file: APIKeyFile, _ keys: [APIKey]) -> some View {
        let info = APIKeyChecker.providerInfo(service: file.service)
        let isCollapsed = vm.collapsed.contains(file.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if isCollapsed { vm.collapsed.remove(file.id) } else { vm.collapsed.insert(file.id) }
            } label: {
                HStack(spacing: 10) {
                    IconTile(symbol: file.icon, tint: Theme.green, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(file.displayName).font(.system(size: 13.5, weight: .bold)).foregroundColor(Theme.textPri)
                            Pill(text: info.category, tint: Theme.accent2)
                            if let folder = file.folderName { Pill(text: folder, systemImage: "folder.fill", tint: Theme.textTer) }
                        }
                        Text(info.blurb).font(.system(size: 10.5)).foregroundColor(Theme.textTer).lineLimit(1)
                    }
                    Spacer()
                    Text("\(keys.count) valid")
                        .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(Theme.green)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.green.opacity(0.14)))
                    Button { store.copyValidKeys(in: file) } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundColor(Theme.textSec)
                    }.buttonStyle(.plain).help("Copy this type's valid keys")
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 10, weight: .bold)).foregroundColor(Theme.textTer)
                }
            }.buttonStyle(.plain)

            if !isCollapsed {
                // What a valid key of this type reveals — the per-type "detailed view".
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(info.reveals, id: \.self) { r in
                            HStack(spacing: 3) {
                                Image(systemName: "sparkle").font(.system(size: 7))
                                Text(r).font(.system(size: 9, weight: .medium))
                            }
                            .foregroundColor(Theme.accent2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent.opacity(0.10)))
                        }
                    }
                }
                VStack(spacing: 6) {
                    ForEach(keys) { key in
                        APIKeyRow(key: key, service: file.service,
                                  onCheck: { Task { await store.checkKey(key, in: file) } },
                                  onInspect: { store.selectedAPIFile = file; store.inspectedKey = key },
                                  onOpen: APIFileDetailView.isDiscord(file.service) ? { store.openDiscordToken(key) } : nil)
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: Theme.rMd).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.rMd).stroke(Theme.green.opacity(0.18), lineWidth: 1))
    }
}

// MARK: - Filter Chip

struct FilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var chipColor: Color {
        switch title {
        case "Valid": return Theme.green
        case "Invalid": return Theme.red
        case "Quota / Limited": return Theme.orange
        case "Unchecked": return Theme.gold
        case "Error": return Theme.red
        default: return Theme.accent
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 11, weight: isSelected ? .bold : .regular))
                Text("\(count)").font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(isSelected ? chipColor.opacity(0.3) : Color.white.opacity(0.08)))
            }
            .foregroundColor(isSelected ? chipColor : Theme.textSec)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.rSm).fill(isSelected ? chipColor.opacity(0.12) : .clear))
            .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(isSelected ? chipColor.opacity(0.4) : Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.1), value: isSelected)
    }
}
