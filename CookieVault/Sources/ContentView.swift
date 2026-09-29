import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Drag & Drop State
final class DropState: ObservableObject {
    @Published var isTargeted = false
}

// MARK: - Root shell

struct ContentView: View {
    @EnvironmentObject var store: AppStore
    @StateObject private var drop = DropState()

    var body: some View {
        ZStack {
            Theme.bg0.ignoresSafeArea()

            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 264)
                Rectangle().fill(Theme.border).frame(width: 1)
                Group {
                    switch store.currentTab {
                    case .cookies: CookiesMainView()
                    case .apiKeys: APIKeysMainView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if drop.isTargeted { dropOverlay }

            // Bottom-anchored overlays: launch status + toast
            VStack(spacing: 10) {
                Spacer()
                if store.isLaunching {
                    LaunchStatusBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if let toast = store.toastMessage {
                    ToastBannerView(message: toast, type: store.toastType)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, 22)
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: store.toastMessage)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: store.isLaunching)
        .animation(.easeOut(duration: 0.15), value: drop.isTargeted)
        .onDrop(of: [UTType.fileURL.identifier],
                isTargeted: Binding(get: { drop.isTargeted }, set: { drop.isTargeted = $0 })) { providers in
            handleDrop(providers: providers)
        }
    }

    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: Theme.rLg)
            .strokeBorder(style: StrokeStyle(lineWidth: 2.5, dash: [10, 6]))
            .foregroundColor(Theme.accent)
            .background(RoundedRectangle(cornerRadius: Theme.rLg).fill(Theme.accent.opacity(0.08)))
            .overlay(
                VStack(spacing: 12) {
                    Image(systemName: "arrow.down.doc.fill")
                        .font(.system(size: 40)).foregroundColor(Theme.accent2)
                    Text("Drop files, folders, or .zip to import")
                        .font(.system(size: 16, weight: .bold)).foregroundColor(Theme.textPri)
                }
            )
            .padding(18)
            .allowsHitTesting(false)
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                        if isDir.boolValue {
                            store.importFolder(from: url)
                        } else if url.pathExtension.lowercased() == "zip" {
                            store.importZip(from: url)
                        } else if store.currentTab == .cookies {
                            store.importCookieFile(from: url)
                        } else {
                            store.importAPIKeyFile(from: url)
                        }
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Launch status bar (Chromium injection / download progress)

struct LaunchStatusBar: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ProgressView().progressViewStyle(.circular).scaleEffect(0.6).frame(width: 16, height: 16)
                Text(store.launchStatus.isEmpty ? "Working…" : store.launchStatus)
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textPri)
                Spacer(minLength: 12)
                if store.launchProgress > 0 {
                    Text("\(Int(store.launchProgress * 100))%")
                        .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(Theme.accent2)
                }
            }
            if store.launchProgress > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08))
                        Capsule().fill(Theme.accentGrad)
                            .frame(width: max(4, geo.size.width * CGFloat(store.launchProgress)))
                    }
                }
                .frame(height: 5)
            }
        }
        .frame(width: 340)
        .cvCard(padding: 14, radius: 14, fill: Theme.surfaceHi, stroke: Theme.accent.opacity(0.35))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            // Brand header
            HStack(spacing: 11) {
                IconTile(symbol: "lock.shield.fill", tint: Theme.accent, size: 38, filled: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("CookieVault")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(Theme.textPri)
                    Text("Session & API intelligence")
                        .font(.system(size: 9.5)).foregroundColor(Theme.textTer)
                }
                Spacer()
                Button { store.killAllCookieSessions() } label: {
                    Image(systemName: "xmark.octagon.fill")
                        .font(.system(size: 13, weight: .bold)).foregroundColor(Theme.red)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.red.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.red.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Close all open cookie-session browser windows (leaves your own Chrome alone)")
            }
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 16)

            // Segmented tab switch
            HStack(spacing: 4) {
                ForEach(AppTab.allCases, id: \.self) { tab in
                    SidebarTabButton(tab: tab, isSelected: store.currentTab == tab,
                                     count: tab == .cookies ? store.cookieFiles.count : store.apiKeyFiles.count) {
                        withAnimation(.spring(response: 0.3)) { store.currentTab = tab }
                    }
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.bg0))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Theme.border, lineWidth: 1))
            .padding(.horizontal, 12)

            if store.isIndexing {
                HStack(spacing: 6) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(0.5).frame(width: 12, height: 12)
                    Text("Indexing accounts…").font(.system(size: 10)).foregroundColor(Theme.textTer)
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 10)
            }

            Rectangle().fill(Theme.border).frame(height: 1).padding(.top, 14)

            // Explorer
            if store.currentTab == .cookies {
                CookiesSidebarList()
            } else {
                APIKeysSidebarList()
            }

            Spacer(minLength: 0)

            Rectangle().fill(Theme.border).frame(height: 1)

            // Import actions
            VStack(spacing: 7) {
                Button { store.chooseFolder(tab: store.currentTab) } label: {
                    FilledButton(title: "Import Folder",
                                 systemImage: "folder.badge.plus",
                                 gradient: store.currentTab == .cookies ? Theme.accentGrad : Theme.goldGrad,
                                 glow: store.currentTab == .cookies ? Theme.accent : Theme.gold)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)

                Button { store.chooseFiles(tab: store.currentTab) } label: {
                    GhostButton(title: "Import Files / .zip", systemImage: "doc.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)

                if store.currentTab == .cookies {
                    // Cleanup menu: expired / free / all
                    Menu {
                        Button { store.removeExpiredCookieAccounts() } label: { Label("Delete all expired", systemImage: "clock.badge.xmark") }
                        Button { store.deleteFreeCookies() } label: { Label("Delete all free", systemImage: "tag.slash") }
                        Divider()
                        Button(role: .destructive) { store.deleteAllCookies() } label: { Label("Delete all cookies", systemImage: "trash") }
                    } label: {
                        GhostButton(title: "Clean up…", systemImage: "wand.and.sparkles").frame(maxWidth: .infinity)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                } else {
                    // Prominent global check + export/delete
                    Button { Task { await store.checkAllAPIKeys() } } label: {
                        FilledButton(title: store.isBatchChecking ? "Checking…" : "Check All Keys",
                                     systemImage: store.isBatchChecking ? nil : "bolt.fill",
                                     gradient: Theme.goldGrad, glow: Theme.gold).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain).disabled(store.isBatchChecking)
                    HStack(spacing: 8) {
                        SidebarMiniButton(title: "Export valid", icon: "square.and.arrow.up", tint: Theme.green) {
                            store.exportAllValidKeys()
                        }
                        SidebarMiniButton(title: "Delete all", icon: "trash", tint: Theme.red) {
                            store.deleteAllAPIKeys()
                        }
                    }
                }
            }
            .padding(12)
        }
        .background(Theme.bg1)
    }
}

// MARK: - Sidebar tab button

struct SidebarTabButton: View {
    let tab: AppTab
    let isSelected: Bool
    var count: Int = 0
    let action: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: tab.icon).font(.system(size: 12, weight: .semibold))
                Text(tab.rawValue).font(.system(size: 12.5, weight: isSelected ? .bold : .medium))
                if count > 0 {
                    Text(count >= 1000 ? shortNum(Double(count)) : "\(count)")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .fixedSize()
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(isSelected ? Color.white.opacity(0.25) : Color.white.opacity(0.08)))
                }
            }
            .foregroundColor(isSelected ? .white : Theme.textSec)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(Theme.accentGrad) : AnyShapeStyle(hover.on ? Color.white.opacity(0.05) : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.on)
    }
}

// MARK: - Sidebar mini (maintenance) button

struct SidebarMiniButton: View {
    let title: String
    let icon: String
    let tint: Color
    let action: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1)
            }
            .foregroundColor(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(hover.on ? tint.opacity(0.12) : Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(Theme.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.1), value: hover.on)
    }
}

// MARK: - Smart tier folder row

struct SmartFolderRow: View {
    let title: String
    let count: Int
    let icon: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: icon, tint: color, size: 26)
                Text(title)
                    .font(.system(size: 12.5, weight: isSelected ? .bold : .medium))
                    .foregroundColor(isSelected ? Theme.textPri : Theme.textSec)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .foregroundColor(isSelected ? .white : color)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(color.opacity(isSelected ? 0.4 : 0.16)))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                    .fill(isSelected ? color.opacity(0.16) : (hover.on ? Color.white.opacity(0.04) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                    .stroke(isSelected ? color.opacity(0.4) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.1), value: hover.on)
    }
}

// MARK: - Account row (a cookie file)

struct AccountSidebarRow: View {
    let file: CookieFile
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = Hover()

    private var allExpired: Bool { !file.cookies.isEmpty && file.cookies.allSatisfy { $0.isExpired } }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: file.tier == .premium ? "crown.fill" : "tag.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Theme.tierColor(file.tier))
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.accountEmail ?? file.name)
                        .font(.system(size: 11.5, weight: isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? Theme.textPri : Theme.textSec)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let plan = file.planName {
                            Text(plan).font(.system(size: 8.5, weight: .bold))
                                .foregroundColor(Theme.tierColor(file.tier))
                            Text("·").foregroundColor(Theme.textTer)
                        }
                        Text("\(file.cookies.count) cookies")
                            .font(.system(size: 9)).foregroundColor(Theme.textTer)
                    }
                }
                Spacer()
                Circle().fill(allExpired ? Theme.red : Theme.green).frame(width: 5, height: 5)
            }
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Theme.accent.opacity(0.18) : (hover.on ? Color.white.opacity(0.04) : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.1), value: hover.on)
    }
}

// MARK: - Cookies sidebar list

struct CookiesSidebarList: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16, pinnedViews: []) {
                if !store.cookieFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionLabel(text: "Account Tiers").padding(.horizontal, 10)
                        SmartFolderRow(title: "Premium", count: store.premiumCookieFiles.count,
                                       icon: "crown.fill", color: Theme.gold,
                                       isSelected: store.selectedCookieFolder == "SMART_PREMIUM") {
                            selectSmart("SMART_PREMIUM", tier: .premium)
                        }
                        SmartFolderRow(title: "Free", count: store.freeCookieFiles.count,
                                       icon: "tag.fill", color: Theme.blue,
                                       isSelected: store.selectedCookieFolder == "SMART_FREE") {
                            selectSmart("SMART_FREE", tier: .free)
                        }
                        SmartFolderRow(title: "All Accounts", count: store.cookieFiles.count,
                                       icon: "square.stack.3d.up.fill", color: Theme.accent2,
                                       isSelected: store.selectedCookieFolder == "ALL_ACCOUNTS") {
                            selectSmart("ALL_ACCOUNTS", tier: nil)
                        }
                        SmartFolderRow(title: "Saved", count: store.savedCookieFiles.count,
                                       icon: "star.fill", color: Theme.gold,
                                       isSelected: store.selectedCookieFolder == "SAVED") {
                            selectSmart("SAVED", tier: nil)
                        }
                    }
                }

                // Sites — accounts grouped by detected website/service
                if !store.cookieSites.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionLabel(text: "Sites").padding(.horizontal, 10)
                        ForEach(store.cookieSites, id: \.self) { site in
                            siteGroup(site)
                        }
                    }
                }

                if !store.cookieFolders.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionHeader(title: "Import Folders") { store.chooseFolder(tab: .cookies) }
                        ForEach(store.cookieFolders, id: \.self) { folder in
                            folderGroup(folder)
                        }
                    }
                }

                if !store.standaloneCookieFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        SectionHeader(title: "Standalone Files") { store.chooseFiles(tab: .cookies) }
                        ForEach(store.standaloneCookieFiles) { file in
                            AccountSidebarRow(file: file,
                                              isSelected: store.selectedCookieFile?.id == file.id && store.selectedCookieFolder == nil) {
                                selectFile(file)
                            }
                        }
                    }
                }

                if store.cookieFiles.isEmpty { sidebarEmpty }
            }
            .padding(.horizontal, 10).padding(.top, 12).padding(.bottom, 12)
        }
    }

    // Cap how many rows expand inline; overflow opens the full list in the panel.
    private let inlineRowCap = 40

    private func selectSmart(_ key: String, tier: AccountTier?) {
        store.selectedCookieFolder = key
        store.selectedCookieTier = tier
        store.selectedCookieFile = nil
        store.selectedCookie = nil
    }
    private func selectFile(_ file: CookieFile) {
        store.selectedCookieFolder = nil
        store.selectedCookieTier = nil
        store.selectedCookieFile = file
        store.selectedCookie = nil
    }
    private func openSite(_ site: String, tier: AccountTier?) {
        store.pendingCookieTier = tier
        selectSmart("SITE::\(site)", tier: nil)
    }

    // A site group (accounts sharing a detected website)
    @ViewBuilder private func siteGroup(_ site: String) -> some View {
        let key = "s_\(site)"
        let isExpanded = store.expandedFolders.contains(key)
        let files = store.cookieFilesForSite(site)
        let brand = ServiceBrandHelper.brand(for: site)
        let premCount = files.filter { $0.tier == .premium }.count
        let selKey = "SITE::\(site)"
        VStack(spacing: 2) {
            FolderSidebarRow(
                title: site,
                subtitle: "\(files.count) accounts",
                icon: brand.icon,
                badge: premCount > 0 ? "\(premCount) 👑" : nil,
                isExpanded: isExpanded,
                isSelected: store.selectedCookieFolder == selKey,
                color: Color(hex: brand.colorHex),
                onToggle: { store.toggleFolderExpansion(key: key) },
                onSelect: { openSite(site, tier: nil) },
                onDelete: {}, // sites are virtual — not deletable
                onBadgeTap: { openSite(site, tier: .premium) }, // tap 👑 badge → premium only
                canDelete: false
            )
            if isExpanded { accountRows(files, openGroup: selKey, tier: nil) }
        }
    }

    @ViewBuilder private func folderGroup(_ folder: String) -> some View {
        let isExpanded = store.expandedFolders.contains("c_\(folder)")
        let files = store.cookieFilesInFolder(folder)
        let brand = ServiceBrandHelper.brand(for: folder)
        let premCount = files.filter { $0.tier == .premium }.count
        VStack(spacing: 2) {
            FolderSidebarRow(
                title: brand.name != "Session" ? brand.name : folder.replacingOccurrences(of: "_hits", with: "").capitalized,
                subtitle: "\(files.count) accounts",
                icon: brand.icon,
                badge: premCount > 0 ? "\(premCount) 👑" : nil,
                isExpanded: isExpanded,
                isSelected: store.selectedCookieFolder == folder,
                color: Color(hex: brand.colorHex),
                onToggle: { store.toggleFolderExpansion(key: "c_\(folder)") },
                onSelect: {
                    store.selectedCookieFolder = folder; store.selectedCookieTier = nil
                    store.selectedCookieFile = nil; store.selectedCookie = nil
                },
                onDelete: { store.deleteCookieFolder(folder) }
            )
            if isExpanded { accountRows(files, openFolder: folder) }
        }
    }

    // Renders account rows for an expanded group, capped so huge groups stay snappy.
    @ViewBuilder private func accountRows(_ files: [CookieFile],
                                          openFolder: String? = nil,
                                          openGroup: String? = nil,
                                          tier: AccountTier? = nil) -> some View {
        let shown = Array(files.prefix(inlineRowCap))
        VStack(spacing: 2) {
            ForEach(shown) { file in
                AccountSidebarRow(file: file,
                                  isSelected: store.selectedCookieFile?.id == file.id && store.selectedCookieFolder == nil) {
                    selectFile(file)
                }
            }
            if files.count > shown.count {
                Button {
                    if let openGroup { selectSmart(openGroup, tier: tier) }
                    else if let openFolder {
                        store.selectedCookieFolder = openFolder; store.selectedCookieTier = nil
                        store.selectedCookieFile = nil; store.selectedCookie = nil
                    }
                } label: {
                    Text("+ \(files.count - shown.count) more →")
                        .font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 12)
    }

    private var sidebarEmpty: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 24)).foregroundColor(Theme.textTer)
            Text("No cookies yet").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textSec)
            Text("Drag a folder or .zip here to import")
                .font(.system(size: 10)).foregroundColor(Theme.textTer)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 30)
    }
}

// MARK: - API keys sidebar list

struct APIKeysSidebarList: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                if !store.apiKeyFiles.isEmpty {
                    APIValidSmartRow(
                        count: store.totalValidKeyCount,
                        isSelected: store.showAllValidKeys
                    ) {
                        store.showAllValidKeys = true
                        store.selectedAPIFile = nil
                        store.selectedAPIFolder = nil
                    }
                    .padding(.bottom, 4)
                }

                // Dedicated Discord-token import → creates a "Discord Tokens" section.
                Button { store.importDiscordTokens() } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7).fill(Color(hex: "5865f2").opacity(0.18)).frame(width: 28, height: 28)
                            Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 12)).foregroundColor(Color(hex: "5865f2"))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Check Discord Tokens").font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.textSec)
                            Text("import a token list, then Check All").font(.system(size: 10)).foregroundColor(Theme.textTer)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill").font(.system(size: 14)).foregroundColor(Color(hex: "5865f2"))
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: Theme.rSm).fill(Color(hex: "5865f2").opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Color(hex: "5865f2").opacity(0.25), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)

                // Proxy pool for API checks (avoid rate limits).
                Button { store.showProxySheet = true } label: {
                    HStack(spacing: 10) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7).fill(Theme.accent2.opacity(0.16)).frame(width: 28, height: 28)
                            Image(systemName: "network.badge.shield.half.filled").font(.system(size: 12)).foregroundColor(Theme.accent2)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Proxies").font(.system(size: 12.5, weight: .semibold)).foregroundColor(Theme.textSec)
                            Text(store.parsedProxies.isEmpty ? "add proxies to dodge rate limits" : "\(store.parsedProxies.count) active").font(.system(size: 10)).foregroundColor(Theme.textTer)
                        }
                        Spacer()
                        if !store.parsedProxies.isEmpty {
                            Text("\(store.parsedProxies.count)").font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(Theme.green)
                                .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Theme.green.opacity(0.14)))
                        } else {
                            Image(systemName: "plus.circle.fill").font(.system(size: 14)).foregroundColor(Theme.accent2)
                        }
                    }
                    .padding(.horizontal, 9).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: Theme.rSm).fill(Theme.accent.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.accent2.opacity(0.22), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)

                if !store.apiKeyFolders.isEmpty {
                    SectionHeader(title: "Folders") { store.chooseFolder(tab: .apiKeys) }
                    ForEach(store.apiKeyFolders, id: \.self) { folder in
                        let isExpanded = store.expandedFolders.contains("a_\(folder)")
                        let files = store.apiKeyFilesInFolder(folder)
                        VStack(spacing: 2) {
                            FolderSidebarRow(
                                title: folder, subtitle: "\(files.count) files",
                                icon: "key.horizontal.fill",
                                isExpanded: isExpanded,
                                isSelected: store.selectedAPIFolder == folder,
                                color: Theme.gold,
                                onToggle: { store.toggleFolderExpansion(key: "a_\(folder)") },
                                onSelect: { store.showAllValidKeys = false; store.selectedAPIFolder = folder; store.selectedAPIFile = nil },
                                onDelete: { store.deleteAPIFolder(folder) }
                            )
                            if isExpanded {
                                VStack(spacing: 1) {
                                    ForEach(files) { file in
                                        SidebarFileRow(name: file.displayName, subtitle: "\(file.keys.count) keys",
                                                       icon: file.icon, color: Theme.gold,
                                                       isSelected: store.selectedAPIFile?.id == file.id && store.selectedAPIFolder == nil,
                                                       isIndented: true,
                                                       validCount: file.keys.filter { $0.status == .valid }.count) {
                                            store.showAllValidKeys = false; store.selectedAPIFolder = nil; store.selectedAPIFile = file
                                        }
                                    }
                                }
                                .padding(.leading, 12)
                            }
                        }
                    }
                }

                if !store.standaloneAPIKeyFiles.isEmpty {
                    SectionHeader(title: "Standalone Files") { store.chooseFiles(tab: .apiKeys) }
                    ForEach(store.standaloneAPIKeyFiles) { file in
                        SidebarFileRow(name: file.displayName, subtitle: "\(file.keys.count) keys",
                                       icon: file.icon, color: Theme.gold,
                                       isSelected: store.selectedAPIFile?.id == file.id && store.selectedAPIFolder == nil,
                                       isIndented: false,
                                       validCount: file.keys.filter { $0.status == .valid }.count) {
                            store.showAllValidKeys = false; store.selectedAPIFolder = nil; store.selectedAPIFile = file
                        }
                    }
                }

                if store.apiKeyFiles.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "key.slash").font(.system(size: 22)).foregroundColor(Theme.textTer)
                        Text("No API keys yet").font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textSec)
                        Text("Import a .txt, folder, or .zip")
                            .font(.system(size: 10)).foregroundColor(Theme.textTer).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 28)
                }
            }
            .padding(.horizontal, 10).padding(.top, 12)
        }
    }
}

// MARK: - "All Valid Keys" smart row

struct APIValidSmartRow: View {
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Theme.green.opacity(isSelected ? 0.28 : 0.16))
                        .frame(width: 28, height: 28)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .bold)).foregroundColor(Theme.green)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("All Valid Keys").font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(isSelected ? Theme.textPri : Theme.textSec)
                    Text("across every type").font(.system(size: 10)).foregroundColor(Theme.textTer)
                }
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, weight: .bold, design: .rounded)).foregroundColor(Theme.green)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.green.opacity(0.14)))
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.rSm)
                .fill(isSelected ? Theme.green.opacity(0.12) : (hover.on ? Theme.surfaceHi : .clear)))
            .overlay(RoundedRectangle(cornerRadius: Theme.rSm)
                .stroke(isSelected ? Theme.green.opacity(0.45) : Theme.border.opacity(hover.on ? 1 : 0), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
    }
}

// MARK: - Folder row

struct FolderSidebarRow: View {
    let title: String
    let subtitle: String
    var icon: String = "folder"
    var badge: String? = nil
    let isExpanded: Bool
    let isSelected: Bool
    let color: Color
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void
    var onBadgeTap: (() -> Void)? = nil
    var canDelete: Bool = true
    @StateObject private var hover = Hover()

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onToggle) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Theme.textTer)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)

            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.system(size: 12)).foregroundColor(color).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).font(.system(size: 12, weight: isSelected ? .bold : .semibold))
                            .foregroundColor(isSelected ? Theme.textPri : Theme.textSec).lineLimit(1)
                        Text(subtitle).font(.system(size: 9)).foregroundColor(Theme.textTer)
                    }
                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if let badge {
                if let onBadgeTap {
                    Button(action: onBadgeTap) { Pill(text: badge, tint: Theme.gold) }
                        .buttonStyle(.plain)
                        .help("Show only Premium")
                } else {
                    Pill(text: badge, tint: Theme.gold)
                }
            }

            if canDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 10)).foregroundColor(Theme.red)
                        .opacity(hover.on ? 1 : 0)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                .fill(isSelected ? color.opacity(0.16) : (hover.on ? Color.white.opacity(0.04) : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                .stroke(isSelected ? color.opacity(0.4) : .clear, lineWidth: 1)
        )
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.on)
    }
}

// MARK: - Generic file row

struct SidebarFileRow: View {
    let name: String
    let subtitle: String
    let icon: String
    let color: Color
    let isSelected: Bool
    var isIndented: Bool = false
    var validCount: Int? = nil
    let action: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 11)).foregroundColor(color).frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? Theme.textPri : Theme.textSec).lineLimit(1)
                    Text(subtitle).font(.system(size: 9)).foregroundColor(Theme.textTer)
                }
                Spacer()
                if let vc = validCount, vc > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.seal.fill").font(.system(size: 7))
                        Text("\(vc)").font(.system(size: 9, weight: .bold, design: .rounded))
                    }
                    .foregroundColor(Theme.green)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Theme.green.opacity(0.15)))
                    .help("\(vc) valid key\(vc == 1 ? "" : "s")")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? color.opacity(0.16) : (hover.on ? Color.white.opacity(0.04) : .clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.1), value: hover.on)
    }
}

// MARK: - Section header (label + add button)

struct SectionHeader: View {
    let title: String
    var action: () -> Void

    var body: some View {
        HStack {
            SectionLabel(text: title)
            Spacer()
            Button(action: action) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.textTer)
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.05)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 2)
    }
}
