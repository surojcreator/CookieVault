import SwiftUI
import AppKit

// MARK: - View Models

final class FolderVM: ObservableObject {
    @Published var searchText = ""
    @Published var tierFilter: AccountTier = .unknown

    // Adaptive metadata filters (followers, cc, country, verified, …)
    @Published var showFilters = false
    @Published var country: String? = nil
    @Published var year: Int? = nil
    @Published var plan: String? = nil                  // e.g. "Premium Family"
    @Published var stateFilter: AccountState? = nil     // active / on-hold / no-sub / …
    @Published var validity: Int = 0                    // 0 = any, 1 = live session, 2 = expired
    @Published var minMetric: [String: Double] = [:]    // key → minimum (0 = off, "≥")
    @Published var maxMetric: [String: Double] = [:]    // key → maximum (0 = off, "≤")
    @Published var flagFilter: [String: Bool] = [:]     // key → required value
    @Published var sortKey: String? = nil               // metric key to sort by
    @Published var sortDesc = true

    var activeFilterCount: Int {
        (country != nil ? 1 : 0) + (year != nil ? 1 : 0) + (plan != nil ? 1 : 0)
            + (stateFilter != nil ? 1 : 0) + (validity != 0 ? 1 : 0)
            + minMetric.values.filter { $0 > 0 }.count + maxMetric.values.filter { $0 > 0 }.count + flagFilter.count
    }
    func clearMetaFilters() {
        country = nil; year = nil; plan = nil; stateFilter = nil; validity = 0
        minMetric = [:]; maxMetric = [:]; flagFilter = [:]; sortKey = nil
    }
}

// Compact number formatting for stat chips (1.2K, 3.4M).
func shortNum(_ v: Double) -> String {
    let n = abs(v)
    if n >= 1_000_000 { return String(format: "%.1fM", v / 1_000_000).replacingOccurrences(of: ".0M", with: "M") }
    if n >= 1_000 { return String(format: "%.1fK", v / 1_000).replacingOccurrences(of: ".0K", with: "K") }
    if v.rounded() == v { return String(Int(v)) }
    return String(format: "%.2f", v)
}

final class InspectorVM: ObservableObject {
    @Published var showFullKey = false
}

// MARK: - Folder Overview Dashboard

struct FolderOverviewView: View {
    @EnvironmentObject var store: AppStore
    let folderName: String
    let tab: AppTab
    @StateObject private var vm = FolderVM()

    // A site view is encoded as folderName "SITE::<name>".
    var siteName: String? { folderName.hasPrefix("SITE::") ? String(folderName.dropFirst(6)) : nil }
    // Virtual (non-deletable) views: tiers, all-accounts, and site groups.
    var isSmartTierFolder: Bool {
        store.selectedCookieTier != nil || folderName == "SMART_PREMIUM" || folderName == "SMART_FREE"
            || folderName == "ALL_ACCOUNTS" || folderName == "SAVED" || siteName != nil
    }
    var activeTier: AccountTier? {
        if store.selectedCookieTier != nil { return store.selectedCookieTier }
        if folderName == "SMART_PREMIUM" { return .premium }
        if folderName == "SMART_FREE" { return .free }
        return nil
    }
    var brand: ServiceBrand {
        if let site = siteName { return ServiceBrandHelper.brand(for: site) }
        if folderName == "SAVED" { return ServiceBrand(name: "Saved", icon: "star.fill", colorHex: "F5A524") }
        if folderName == "ALL_ACCOUNTS" { return ServiceBrand(name: "All Accounts", icon: "square.stack.3d.up.fill", colorHex: "9B8AF8") }
        if let tier = activeTier {
            return tier == .premium
                ? ServiceBrand(name: "Premium Cookies", icon: "crown.fill", colorHex: "F5A524")
                : ServiceBrand(name: "Free Cookies", icon: "tag.fill", colorHex: "38BDF8")
        }
        return ServiceBrandHelper.brand(for: folderName)
    }
    var headerTitle: String {
        if let site = siteName { return site }
        if isSmartTierFolder { return brand.name }
        return folderName.replacingOccurrences(of: "_hits", with: "").capitalized
    }
    var cookieFiles: [CookieFile] {
        if let site = siteName { return store.cookieFilesForSite(site) }
        if folderName == "SAVED" { return store.savedCookieFiles }
        if folderName == "ALL_ACCOUNTS" { return store.cookieFiles }
        if let tier = activeTier { return tier == .premium ? store.premiumCookieFiles : store.freeCookieFiles }
        return store.cookieFilesInFolder(folderName)
    }
    var apiKeyFiles: [APIKeyFile] { store.apiKeyFilesInFolder(folderName) }
    var totalItemsCount: Int {
        tab == .cookies ? cookieFiles.reduce(0) { $0 + $1.cookies.count } : apiKeyFiles.reduce(0) { $0 + $1.keys.count }
    }
    var premiumCookieCount: Int { cookieFiles.filter { $0.tier == .premium }.count }
    var freeCookieCount: Int { cookieFiles.filter { $0.tier == .free }.count }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                header
                if tab == .cookies { filterControls }
                if store.isBatchChecking { progressCard }
                content
            }
            .padding(22)
        }
        .background(Theme.bg0)
        .onAppear { consumePendingTier(resetIfNone: true) }
        .onChange(of: folderName) { _, _ in
            // Different site → different available facets; start filters fresh.
            vm.clearMetaFilters(); vm.showFilters = false
            consumePendingTier(resetIfNone: true)
        }
        .onChange(of: store.pendingCookieTier) { _, new in if new != nil { consumePendingTier(resetIfNone: false) } }
    }

    // Applies a one-shot tier requested from the sidebar (e.g. a site's 👑 badge → Premium).
    private func consumePendingTier(resetIfNone: Bool) {
        if let t = store.pendingCookieTier {
            vm.tierFilter = t
            store.pendingCookieTier = nil
        } else if resetIfNone {
            vm.tierFilter = .unknown
        }
    }

    // Header card
    private var header: some View {
        HStack(spacing: 16) {
            IconTile(symbol: brand.icon, tint: Color(hex: brand.colorHex), size: 58, filled: true)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(headerTitle)
                        .font(.system(size: 22, weight: .bold, design: .rounded)).foregroundColor(Theme.textPri)
                    if let tier = activeTier {
                        Pill(text: tier == .premium ? "All Premium" : "All Free",
                             systemImage: tier == .premium ? "crown.fill" : "tag.fill", tint: Theme.tierColor(tier))
                    } else if folderName == "SAVED" {
                        Pill(text: "Saved", systemImage: "star.fill", tint: Theme.gold)
                    } else if folderName == "ALL_ACCOUNTS" {
                        Pill(text: "All Sessions", systemImage: "globe", tint: Theme.accent2)
                    } else if siteName != nil {
                        Pill(text: "Site", systemImage: "globe", tint: Color(hex: brand.colorHex))
                    } else {
                        Pill(text: "Folder", systemImage: "folder.fill", tint: Theme.textSec)
                    }
                }
                if tab == .cookies {
                    HStack(spacing: 10) {
                        Label("\(premiumCookieCount) Premium", systemImage: "crown.fill")
                            .font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.gold)
                        Text("·").foregroundColor(Theme.textTer)
                        Label("\(freeCookieCount) Free", systemImage: "tag.fill")
                            .font(.system(size: 11, weight: .medium)).foregroundColor(Theme.blue)
                        Text("·").foregroundColor(Theme.textTer)
                        Text("\(cookieFiles.count) accounts · \(totalItemsCount) cookies")
                            .font(.system(size: 11)).foregroundColor(Theme.textSec)
                    }
                } else {
                    Text("\(apiKeyFiles.count) files · \(totalItemsCount) API keys")
                        .font(.system(size: 12)).foregroundColor(Theme.textSec)
                }
            }
            Spacer()
            headerActions
        }
        .cvCard(padding: 20, radius: Theme.rLg)
    }

    @ViewBuilder private var headerActions: some View {
        HStack(spacing: 10) {
            if tab == .cookies {
                if let first = filteredCookieFiles.first, let firstCookie = first.cookies.first {
                    Button { store.openInBrowser(cookie: firstCookie, file: first) } label: {
                        FilledButton(title: store.isLaunching ? "Launching…" : "Launch First",
                                     systemImage: store.isLaunching ? nil : "safari.fill")
                    }
                    .buttonStyle(.plain).disabled(store.isLaunching)
                }
                // Save all "good" (premium + usable + live) accounts in this category
                let goodCount = cookieFiles.filter { store.isGoodCookie($0) && !$0.saved }.count
                if goodCount > 0 {
                    Button { store.saveGoodCookies(in: cookieFiles, scopeLabel: headerTitle) } label: {
                        GhostButton(title: "Save \(goodCount) good", systemImage: "star", tint: Theme.gold)
                    }.buttonStyle(.plain)
                }
                // Per-category cleanup (scoped to this site/folder/tier view)
                let expiredCount = cookieFiles.filter { !$0.cookies.isEmpty && $0.cookies.allSatisfy { $0.isExpired } }.count
                if expiredCount > 0 || freeCookieCount > 0 {
                    Menu {
                        if expiredCount > 0 {
                            Button { store.deleteExpiredCookies(in: cookieFiles, scopeLabel: headerTitle) } label: {
                                Label("Delete \(expiredCount) expired", systemImage: "clock.badge.xmark")
                            }
                        }
                        if freeCookieCount > 0 {
                            Button { store.deleteFreeCookies(in: cookieFiles, scopeLabel: headerTitle) } label: {
                                Label("Delete \(freeCookieCount) free", systemImage: "tag.slash")
                            }
                        }
                    } label: {
                        GhostButton(title: "Clean up", systemImage: "wand.and.sparkles")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                }
            } else {
                Button { Task { await store.checkAllKeysInFolder(folderName) } } label: {
                    FilledButton(title: store.isBatchChecking ? "Checking…" : "Check All Keys",
                                 systemImage: store.isBatchChecking ? nil : "bolt.fill",
                                 gradient: Theme.goldGrad, glow: Theme.gold)
                }
                .buttonStyle(.plain).disabled(store.isBatchChecking)
                Button { store.exportValidKeysInFolder(folderName) } label: {
                    GhostButton(title: "Export Valid", systemImage: "square.and.arrow.up", tint: Theme.green)
                }.buttonStyle(.plain)
            }
            if let site = siteName {
                Button { store.deleteCookieSite(site) } label: {
                    GhostButton(title: "Delete \(cookieFiles.count)", systemImage: "trash", tint: Theme.red)
                }.buttonStyle(.plain)
            } else if !isSmartTierFolder {
                Button {
                    tab == .cookies ? store.deleteCookieFolder(folderName) : store.deleteAPIFolder(folderName)
                } label: { IconButton(symbol: "trash", tint: Theme.red) }.buttonStyle(.plain)
            }
        }
    }

    private var filterControls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    tierSeg("All \(cookieFiles.count)", "square.stack.3d.up.fill", .unknown, Theme.accent)
                    tierSeg("Premium \(premiumCookieCount)", "crown.fill", .premium, Theme.gold)
                    tierSeg("Free \(freeCookieCount)", "tag.fill", .free, Theme.blue)
                }
                // Filters toggle (plan/status/validity apply to any cookie set)
                do {
                    Button { withAnimation(.easeOut(duration: 0.15)) { vm.showFilters.toggle() } } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 11))
                            Text("Filters").font(.system(size: 11, weight: .semibold))
                            if vm.activeFilterCount > 0 {
                                Text("\(vm.activeFilterCount)").font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.accent)).foregroundColor(.white)
                            }
                        }
                        .foregroundColor(vm.showFilters || vm.activeFilterCount > 0 ? Theme.accent2 : Theme.textSec)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: Theme.rSm).fill(Color.white.opacity(0.04)))
                        .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(vm.showFilters ? Theme.accent.opacity(0.45) : Theme.border, lineWidth: 1))
                    }.buttonStyle(.plain)
                }
                Spacer()
                CVSearchBar(text: Binding(get: { vm.searchText }, set: { vm.searchText = $0 }),
                            placeholder: "Search by email, user, or plan…").frame(maxWidth: 260)
            }
            if vm.showFilters { filterPanel }
        }
    }

    // Facets available for the accounts currently in view.
    private var facets: (metrics: [String], flags: [String], countries: [String], years: [Int]) {
        store.availableFacets(in: cookieFiles)
    }
    private var availablePlans: [String] { Array(Set(cookieFiles.compactMap { $0.planName })).sorted() }
    private var availableStates: [AccountState] {
        var set = Set<AccountState>()
        for f in cookieFiles { let s = store.state(for: f); if s.label != nil { set.insert(s) } }
        return Array(set).sorted { ($0.label ?? "") < ($1.label ?? "") }
    }

    @ViewBuilder private var filterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Row 1: plan / state / validity / country / year / sort / clear
            HStack(spacing: 10) {
              ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                if availablePlans.count > 1 {
                    Menu {
                        Button("Any plan") { vm.plan = nil }
                        Divider()
                        ForEach(availablePlans, id: \.self) { p in Button(p) { vm.plan = p } }
                    } label: { filterMenuLabel(icon: "rosette", text: vm.plan ?? "Plan") }
                }
                if !availableStates.isEmpty {
                    Menu {
                        Button("Any status") { vm.stateFilter = nil }
                        Divider()
                        Button("Active only") { vm.stateFilter = .active }
                        ForEach(availableStates, id: \.self) { s in
                            Button(s.label ?? s.rawValue) { vm.stateFilter = s }
                        }
                    } label: { filterMenuLabel(icon: "circle.badge.checkmark", text: vm.stateFilter.flatMap { $0.label ?? "Active" } ?? "Status") }
                }
                Menu {
                    Button("Any session") { vm.validity = 0 }
                    Button("Live session") { vm.validity = 1 }
                    Button("Expired") { vm.validity = 2 }
                } label: { filterMenuLabel(icon: "bolt.horizontal", text: ["Session", "Live", "Expired"][vm.validity]) }
                if !facets.countries.isEmpty {
                    Menu {
                        Button("Any country") { vm.country = nil }
                        Divider()
                        ForEach(facets.countries, id: \.self) { c in
                            Button(c) { vm.country = c }
                        }
                    } label: { filterMenuLabel(icon: "globe", text: vm.country ?? "Country") }
                }
                if !facets.years.isEmpty {
                    Menu {
                        Button("Any year") { vm.year = nil }
                        Divider()
                        ForEach(facets.years, id: \.self) { y in Button(String(y)) { vm.year = y } }
                    } label: { filterMenuLabel(icon: "calendar", text: vm.year.map(String.init) ?? "Year") }
                }
                if !facets.metrics.isEmpty {
                    Menu {
                        Button("Default order") { vm.sortKey = nil }
                        Divider()
                        ForEach(facets.metrics, id: \.self) { k in
                            Button(AccountMetrics.label(forMetric: k)) { vm.sortKey = k }
                        }
                    } label: {
                        filterMenuLabel(icon: "arrow.up.arrow.down",
                                        text: vm.sortKey.map { "Sort: \(AccountMetrics.label(forMetric: $0))" } ?? "Sort")
                    }
                    if vm.sortKey != nil {
                        Button { vm.sortDesc.toggle() } label: {
                            filterMenuLabel(icon: vm.sortDesc ? "arrow.down" : "arrow.up", text: vm.sortDesc ? "High→Low" : "Low→High")
                        }.buttonStyle(.plain)
                    }
                }
                } // inner HStack
              } // horizontal ScrollView
                Spacer()
                if vm.activeFilterCount > 0 || vm.sortKey != nil {
                    Button { vm.clearMetaFilters() } label: {
                        Text("Clear").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.red)
                    }.buttonStyle(.plain)
                }
            }

            // Row 2: numeric range filters (more/less), one per available metric
            if !facets.metrics.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: "More / less than")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(facets.metrics, id: \.self) { key in
                                Menu {
                                    Button("Any amount") { vm.minMetric[key] = 0; vm.maxMetric[key] = 0 }
                                    Divider()
                                    Menu("At least (≥)") {
                                        ForEach(thresholds(for: key), id: \.self) { t in
                                            Button("≥ \(shortNum(t))") { vm.minMetric[key] = t }
                                        }
                                    }
                                    Menu("At most (≤)") {
                                        ForEach(thresholds(for: key), id: \.self) { t in
                                            Button("≤ \(shortNum(t))") { vm.maxMetric[key] = t }
                                        }
                                    }
                                } label: {
                                    let lo = vm.minMetric[key] ?? 0, hi = vm.maxMetric[key] ?? 0
                                    let txt: String? = (lo > 0 && hi > 0) ? "\(shortNum(lo))–\(shortNum(hi))"
                                        : lo > 0 ? "≥ \(shortNum(lo))" : hi > 0 ? "≤ \(shortNum(hi))" : nil
                                    metricChip(AccountMetrics.label(forMetric: key), txt, active: lo > 0 || hi > 0)
                                }
                            }
                        }
                    }
                }
            }

            // Row 3: boolean flag filters (tri-state)
            if !facets.flags.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    SectionLabel(text: "Status")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(facets.flags, id: \.self) { key in
                                Button { cycleFlag(key) } label: {
                                    let state = vm.flagFilter[key]
                                    metricChip(AccountMetrics.label(forFlag: key),
                                               state == nil ? nil : (state! ? "Yes" : "No"),
                                               active: state != nil,
                                               tint: state == false ? Theme.red : Theme.green)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
        .cvCard(padding: 14, radius: Theme.rMd, fill: Theme.surface, stroke: Theme.border)
    }

    private func cycleFlag(_ key: String) {
        switch vm.flagFilter[key] {
        case nil: vm.flagFilter[key] = true
        case .some(true): vm.flagFilter[key] = false
        case .some(false): vm.flagFilter[key] = nil
        }
    }
    private func thresholds(for key: String) -> [Double] {
        switch key {
        case "cc", "coins", "karma", "friends", "games", "projects", "credits", "playlists", "tracks", "mems", "companies":
            return [1, 5, 10, 25, 50, 100]
        case "balance":
            return [1, 5, 10, 25, 50, 100, 500]
        default:
            return [1, 10, 100, 1_000, 10_000, 100_000, 1_000_000]
        }
    }
    private func filterMenuLabel(icon: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundColor(Theme.textSec)
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Theme.rSm).fill(Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.border, lineWidth: 1))
    }
    private func metricChip(_ label: String, _ value: String?, active: Bool, tint: Color = Theme.accent2) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.system(size: 10, weight: .semibold))
            if let value { Text(value).font(.system(size: 10, weight: .bold)) }
            Image(systemName: "chevron.down").font(.system(size: 7))
        }
        .foregroundColor(active ? tint : Theme.textSec)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(active ? tint.opacity(0.14) : Color.white.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(active ? tint.opacity(0.4) : Theme.border, lineWidth: 1))
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(store.batchCheckCurrentTask).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.gold)
                Spacer()
                Text("\(Int(store.batchCheckProgress * 100))%").font(.system(size: 12, weight: .bold, design: .rounded)).foregroundColor(Theme.textPri)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(Theme.goldGrad)
                        .frame(width: max(4, min(geo.size.width, geo.size.width * CGFloat(store.batchCheckProgress))))
                }
            }
            .frame(height: 6)
        }
        .cvCard(padding: 16, radius: Theme.rMd, stroke: Theme.gold.opacity(0.3))
    }

    @ViewBuilder private var content: some View {
        if tab == .cookies {
            let files = filteredCookieFiles
            if files.isEmpty {
                emptyFilter
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(files) { file in
                        CookieAccountCard(file: file) {
                            store.selectedCookieFolder = nil; store.selectedCookieTier = nil
                            store.selectedCookieFile = file; store.selectedCookie = nil
                        }
                    }
                }
            }
        } else {
            LazyVStack(spacing: 8) {
                ForEach(filteredAPIKeyFiles) { file in
                    APIKeyFileCardRow(file: file) { store.selectedAPIFolder = nil; store.selectedAPIFile = file }
                }
            }
        }
    }

    private var emptyFilter: some View {
        VStack(spacing: 10) {
            Image(systemName: "line.3.horizontal.decrease.circle").font(.system(size: 30)).foregroundColor(Theme.textTer)
            Text("No accounts match this filter").font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.textSec)
        }
        .frame(maxWidth: .infinity).padding(.top, 44)
    }

    func tierSeg(_ title: String, _ icon: String, _ tier: AccountTier, _ color: Color) -> some View {
        let isSelected = vm.tierFilter == tier
        return Button { vm.tierFilter = tier } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11))
                Text(title).font(.system(size: 11, weight: isSelected ? .bold : .medium))
            }
            .foregroundColor(isSelected ? color : Theme.textSec)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: Theme.rSm).fill(isSelected ? color.opacity(0.16) : Color.white.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(isSelected ? color.opacity(0.45) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    var filteredCookieFiles: [CookieFile] {
        var list = cookieFiles
        if vm.tierFilter != .unknown { list = list.filter { $0.tier == vm.tierFilter } }
        if !vm.searchText.isEmpty {
            let q = vm.searchText.lowercased()
            list = list.filter {
                $0.name.lowercased().contains(q) ||
                ($0.accountEmail?.lowercased().contains(q) ?? false) ||
                ($0.planName?.lowercased().contains(q) ?? false) ||
                $0.cookies.contains { $0.domain.lowercased().contains(q) }
            }
        }

        // Plan / account-state / session-validity filters
        if let plan = vm.plan { list = list.filter { $0.planName == plan } }
        if let st = vm.stateFilter { list = list.filter { store.state(for: $0) == st } }
        if vm.validity == 1 { list = list.filter { !$0.cookies.isEmpty && !$0.cookies.allSatisfy { $0.isExpired } } }
        else if vm.validity == 2 { list = list.filter { !$0.cookies.isEmpty && $0.cookies.allSatisfy { $0.isExpired } } }

        // Metadata filters (country / year / numeric range / boolean flags)
        let activeMins = vm.minMetric.filter { $0.value > 0 }
        let activeMaxs = vm.maxMetric.filter { $0.value > 0 }
        if vm.country != nil || vm.year != nil || !activeMins.isEmpty || !activeMaxs.isEmpty || !vm.flagFilter.isEmpty {
            list = list.filter { file in
                let m = store.metrics(for: file)
                if let c = vm.country, m.country != c { return false }
                if let y = vm.year, m.year != y { return false }
                for (k, minV) in activeMins where (m.metrics[k] ?? 0) < minV { return false }
                for (k, maxV) in activeMaxs where (m.metrics[k] ?? 0) > maxV { return false }
                for (k, req) in vm.flagFilter where m.flags[k] != req { return false }
                return true
            }
        }

        // Sort by a chosen metric.
        if let key = vm.sortKey {
            list.sort { a, b in
                let va = store.metrics(for: a).metrics[key] ?? 0
                let vb = store.metrics(for: b).metrics[key] ?? 0
                return vm.sortDesc ? va > vb : va < vb
            }
        }
        return list
    }
    var filteredAPIKeyFiles: [APIKeyFile] {
        if vm.searchText.isEmpty { return apiKeyFiles }
        let q = vm.searchText.lowercased()
        return apiKeyFiles.filter { $0.displayName.lowercased().contains(q) || $0.service.lowercased().contains(q) }
    }
}

// MARK: - Cookie Account Card

struct CookieAccountCard: View {
    @EnvironmentObject var store: AppStore
    let file: CookieFile
    let onOpenDetails: () -> Void
    @StateObject private var hover = Hover()

    var brand: ServiceBrand { ServiceBrandHelper.brand(for: file.serviceName ?? file.folderName ?? file.name) }
    var isPremium: Bool { file.tier == .premium }
    // A session is live only if at least one cookie is still unexpired (an empty file is not "valid").
    var hasLiveSession: Bool { file.cookies.contains { !$0.isExpired } }

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: brand.icon, tint: Color(hex: brand.colorHex), size: 44)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(file.accountEmail ?? file.name)
                        .font(.system(size: 14, weight: .bold)).foregroundColor(Theme.textPri).lineLimit(1)
                    TierBadge(tier: file.tier, plan: file.planName)
                    if let s = store.state(for: file).label {
                        Pill(text: s, systemImage: "exclamationmark.circle.fill", tint: Theme.amber)
                    }
                }
                HStack(spacing: 8) {
                    StatusDot(ok: hasLiveSession, okText: "Valid session", badText: "Expired")
                    Text("·").foregroundColor(Theme.textTer)
                    Text("\(file.cookies.count) cookies").font(.system(size: 11)).foregroundColor(Theme.textSec)
                    if let domain = file.cookies.first?.domain {
                        Text("·").foregroundColor(Theme.textTer)
                        Text(domain).font(.system(size: 11)).foregroundColor(Theme.accent2).lineLimit(1)
                    }
                }
                metricStrip
            }
            Spacer()
            if let firstCookie = file.cookies.first {
                Button { store.openInBrowser(cookie: firstCookie, file: file) } label: {
                    FilledButton(title: "Launch", systemImage: "safari.fill",
                                 gradient: isPremium ? Theme.goldGrad : Theme.accentGrad,
                                 glow: isPremium ? Theme.gold : Theme.accent, compact: true)
                }
                .buttonStyle(.plain).disabled(store.isLaunching)
            }
            Button { store.toggleSaved(file) } label: {
                Image(systemName: file.saved ? "star.fill" : "star")
                    .font(.system(size: 12)).foregroundColor(file.saved ? Theme.gold : Theme.textSec)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 7).fill(file.saved ? Theme.gold.opacity(0.14) : Color.white.opacity(0.04)))
            }.buttonStyle(.plain).help(file.saved ? "Remove from Saved" : "Save this account")
            Button { copyNetscape() } label: { IconButton(symbol: "doc.on.doc") }.buttonStyle(.plain)
            Button(action: onOpenDetails) {
                HStack(spacing: 4) { Text("Details"); Image(systemName: "chevron.right") }
                    .font(.system(size: 11, weight: .medium)).foregroundColor(Theme.accent2)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.accent.opacity(0.12)))
            }.buttonStyle(.plain)
            Button { store.deleteCookieFileConfirmed(file) } label: {
                IconButton(symbol: "trash", tint: Theme.red)
            }.buttonStyle(.plain).help("Delete this account")
        }
        .cvCard(padding: 14, radius: Theme.rMd, fill: Theme.surface,
                stroke: hover.on ? (isPremium ? Theme.gold.opacity(0.5) : Theme.accent.opacity(0.5))
                                 : (isPremium ? Theme.gold.opacity(0.15) : Theme.border))
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.on)
        .contextMenu {
            Button { onOpenDetails() } label: { Label("Open Details", systemImage: "chevron.right") }
            if let firstCookie = file.cookies.first {
                Button { store.openInBrowser(cookie: firstCookie, file: file) } label: {
                    Label("Launch Session", systemImage: "safari.fill")
                }
                if file.lastOpenedURL != nil {
                    Button { store.reopenLastURL(cookie: firstCookie, file: file) } label: {
                        Label("Reopen last URL", systemImage: "arrow.clockwise")
                    }
                }
                Button { store.openAtCustomURL(cookie: firstCookie, file: file) } label: {
                    Label("Open at URL…", systemImage: "link")
                }
            }
            Button { store.toggleSaved(file) } label: {
                Label(file.saved ? "Remove from Saved" : "Save", systemImage: file.saved ? "star.slash" : "star")
            }
            Button { copyNetscape() } label: { Label("Copy Netscape", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive) { store.deleteCookieFileConfirmed(file) } label: {
                Label("Delete Account", systemImage: "trash")
            }
        }
    }

    // Per-account stat strip (followers / views / cc / country / verified …)
    @ViewBuilder private var metricStrip: some View {
        let m = store.metrics(for: file)
        let shownMetrics = Array(AccountMetrics.metricOrder.filter { m.metrics[$0] != nil }.prefix(5))
        let shownFlags = Array(AccountMetrics.flagOrder.filter { m.flags[$0] == true }.prefix(3))
        if m.country != nil || !shownMetrics.isEmpty || !shownFlags.isEmpty {
            HStack(spacing: 6) {
                if let c = m.country { statChip("globe", c, Theme.textSec) }
                ForEach(shownMetrics, id: \.self) { k in
                    statChip(metricIcon(k), "\(shortNum(m.metrics[k] ?? 0)) \(AccountMetrics.label(forMetric: k))", Theme.blue)
                }
                ForEach(shownFlags, id: \.self) { k in
                    statChip("checkmark.seal.fill", AccountMetrics.label(forFlag: k), Theme.green)
                }
            }
            .padding(.top, 1)
        }
    }
    private func statChip(_ icon: String, _ text: String, _ tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(text).font(.system(size: 9, weight: .medium)).lineLimit(1)
        }
        .foregroundColor(tint).padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
    private func metricIcon(_ k: String) -> String {
        switch k {
        case "followers", "following", "friends": return "person.2.fill"
        case "subs": return "person.badge.plus"
        case "views": return "eye.fill"
        case "videos": return "play.rectangle.fill"
        case "likes": return "heart.fill"
        case "coins", "balance": return "dollarsign.circle.fill"
        case "cc": return "creditcard.fill"
        case "karma": return "sparkles"
        case "tracks", "playlists": return "music.note"
        default: return "chart.bar.fill"
        }
    }

    func copyNetscape() {
        let str = file.cookies.map { c -> String in
            let exp = c.expiry.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            return "\(c.domain)\t\(c.flag ? "TRUE" : "FALSE")\t\(c.path)\t\(c.secure ? "TRUE" : "FALSE")\t\(exp)\t\(c.name)\t\(c.value)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(str, forType: .string)
        store.showToast("Copied Netscape cookies", type: .success)
    }
}

// MARK: - API Key File Card Row

struct APIKeyFileCardRow: View {
    @EnvironmentObject var store: AppStore
    let file: APIKeyFile
    let onOpen: () -> Void
    @StateObject private var hover = Hover()

    var validCount: Int { file.keys.filter { $0.status == .valid }.count }
    var invalidCount: Int { file.keys.filter { $0.status == .invalid }.count }
    var uncheckedCount: Int { file.keys.filter { $0.status == .idle }.count }

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: file.icon, tint: Theme.gold, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(file.displayName).font(.system(size: 13, weight: .bold)).foregroundColor(Theme.textPri)
                Text("\(file.keys.count) keys · \(file.service)").font(.system(size: 11)).foregroundColor(Theme.textSec)
            }
            Spacer()
            HStack(spacing: 6) {
                if validCount > 0 { Pill(text: "\(validCount) valid", tint: Theme.green) }
                if invalidCount > 0 { Pill(text: "\(invalidCount) invalid", tint: Theme.red) }
                if uncheckedCount > 0 { Pill(text: "\(uncheckedCount) new", tint: Theme.textSec) }
            }
            Button { Task { await store.checkAllKeys(in: file) } } label: {
                IconButton(symbol: "bolt.fill", tint: Theme.gold)
            }.buttonStyle(.plain)
            Button(action: onOpen) {
                HStack(spacing: 4) { Text("Open"); Image(systemName: "arrow.right") }
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.gold.opacity(0.35)))
            }.buttonStyle(.plain)
        }
        .cvCard(padding: 14, radius: Theme.rMd, fill: Theme.surface,
                stroke: hover.on ? Theme.gold.opacity(0.4) : Theme.border)
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.12), value: hover.on)
    }
}

// MARK: - Key Inspector Sheet

struct KeyInspectorSheet: View {
    @EnvironmentObject var store: AppStore
    let key: APIKey
    let file: APIKeyFile
    let onClose: () -> Void
    @StateObject private var vm = InspectorVM()

    var statusColor: Color {
        switch key.status {
        case .valid: return Theme.green
        case .invalid: return Theme.red
        case .quotaExceeded: return Theme.orange
        case .rateLimited: return Theme.yellow
        case .permissionDenied: return Theme.pink
        case .checking: return Color(hex: "3b82f6")
        case .error: return Theme.red
        case .idle: return Theme.textTer
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: file.icon, tint: statusColor, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(file.displayName).font(.system(size: 16, weight: .bold)).foregroundColor(Theme.textPri)
                        Pill(text: key.status.title, tint: statusColor)
                    }
                    if let d = key.details, let latency = d.latencyMs {
                        Text("Latency \(latency) ms · tested \(d.checkedAt.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 11)).foregroundColor(Theme.textTer)
                    }
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 18)).foregroundColor(Theme.textTer)
                }.buttonStyle(.plain)
            }
            .padding(18).background(Theme.surfaceHi)

            Rectangle().fill(Theme.border).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    keyValueCard
                    accountActionsCard
                    if let details = key.details { metadataSection(details) }
                    curlCard
                    if let raw = key.details?.rawSnippet ?? key.responseSnippet, !raw.isEmpty { rawCard(raw) }
                }
                .padding(20)
            }

            Rectangle().fill(Theme.border).frame(height: 1)

            HStack(spacing: 12) {
                Button { Task { await store.checkKey(key, in: file) } } label: {
                    FilledButton(title: "Re-check Key", systemImage: "arrow.clockwise", gradient: Theme.goldGrad, glow: Theme.gold)
                }.buttonStyle(.plain)
                Spacer()
                Button(action: onClose) { GhostButton(title: "Close") }.buttonStyle(.plain)
            }
            .padding(16).background(Theme.surfaceHi)
        }
        .frame(width: 560, height: 640)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous).stroke(Theme.borderHi, lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 34, y: 14)
    }

    private var keyValueCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "API Key String")
                Spacer()
                Button(vm.showFullKey ? "Hide" : "Reveal") { vm.showFullKey.toggle() }
                    .font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent2).buttonStyle(.plain)
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(key.value, forType: .string)
                    store.showToast("Copied API key", type: .success)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent2)
                }.buttonStyle(.plain)
            }
            Text(vm.showFullKey ? key.value : maskedKey(key.value))
                .font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.textPri)
                .textSelection(.enabled).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Theme.rSm).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.border, lineWidth: 1))
        }
    }

    private var hasDashboard: Bool { APIKeyChecker.dashboardURL(service: file.service) != nil }
    private var isWebhook: Bool { APIKeyChecker.isWebhook(service: file.service) }

    @ViewBuilder private var accountActionsCard: some View {
        if hasDashboard || isWebhook {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Interact with this Account")
                Text("Act on the \(file.displayName) account this key belongs to.")
                    .font(.system(size: 10.5)).foregroundColor(Theme.textTer)
                HStack(spacing: 10) {
                    if hasDashboard {
                        Button { store.openProviderDashboard(service: file.service) } label: {
                            GhostButton(title: "Open \(file.displayName) Dashboard", systemImage: "arrow.up.forward.app", tint: Theme.accent2)
                        }.buttonStyle(.plain)
                    }
                    if isWebhook {
                        Button { Task { await store.sendWebhookTest(key, service: file.service) } } label: {
                            GhostButton(title: "Send Test Message", systemImage: "paperplane.fill", tint: Theme.green)
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                if isWebhook {
                    Text("Posts “✅ CookieVault test message” to the connected channel.")
                        .font(.system(size: 9.5)).foregroundColor(Theme.textTer)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.rMd).fill(Theme.inset))
            .overlay(RoundedRectangle(cornerRadius: Theme.rMd).stroke(Theme.accent.opacity(0.2), lineWidth: 1))
        }
    }

    private func metadataSection(_ details: KeyDetails) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Extracted Account & Plan")
                VStack(spacing: 1) {
                    if let name = details.accountName { infoRow("Account", name, "person.fill") }
                    if let email = details.email { infoRow("Email", email, "envelope.fill") }
                    if let plan = details.planOrTier { infoRow("Plan / Tier", plan, "rosette") }
                    if let bal = details.balanceOrQuota { infoRow("Balance / Quota", bal, "creditcard.fill", tint: Theme.green) }
                    if let code = details.httpCode { infoRow("HTTP Status", "\(code)\(code == 200 ? " OK" : "")", "network") }
                    if let lat = details.latencyMs { infoRow("Latency", "\(lat) ms", "speedometer") }
                }
                .background(RoundedRectangle(cornerRadius: Theme.rMd).fill(Theme.inset))
                .overlay(RoundedRectangle(cornerRadius: Theme.rMd).stroke(Theme.border, lineWidth: 1))
            }
            if let perms = details.permissions, !perms.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Scopes & Permissions (\(perms.count))")
                    FlowTagsView(tags: perms, color: Theme.accent2)
                }
            }
            if let models = details.models, !models.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Accessible Models (\(models.count))")
                    FlowTagsView(tags: Array(models.prefix(15)), color: Theme.green)
                }
            }
        }
    }

    private var curlCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Terminal cURL Test")
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(generateCurl(key: key.value, service: file.service), forType: .string)
                    store.showToast("Copied cURL command", type: .success)
                } label: {
                    Label("Copy cURL", systemImage: "terminal.fill").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.green)
                }.buttonStyle(.plain)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(generateCurl(key: key.value, service: file.service))
                    .font(.system(size: 11, design: .monospaced)).foregroundColor(Color(hex: "A7F3D0")).padding(10)
            }
            .background(RoundedRectangle(cornerRadius: Theme.rSm).fill(Theme.inset))
            .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.border, lineWidth: 1))
        }
    }

    private func rawCard(_ raw: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Raw API Response")
                Spacer()
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(raw, forType: .string)
                    store.showToast("Copied raw response", type: .success)
                } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(Theme.textSec) }.buttonStyle(.plain)
            }
            ScrollView(.vertical) {
                Text(raw).font(.system(size: 10, design: .monospaced)).foregroundColor(Theme.textSec)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .frame(maxHeight: 140)
            .background(RoundedRectangle(cornerRadius: Theme.rSm).fill(Theme.inset))
            .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.border, lineWidth: 1))
        }
    }

    func maskedKey(_ str: String) -> String {
        guard str.count > 16 else { return str }
        return String(str.prefix(8)) + "••••••••••••••••" + String(str.suffix(6))
    }

    func infoRow(_ label: String, _ value: String, _ icon: String, tint: Color? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 11)).foregroundColor(Theme.textTer).frame(width: 16)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundColor(Theme.textSec)
            Spacer()
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundColor(tint ?? Theme.textPri)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
    }

    func generateCurl(key: String, service: String) -> String {
        switch service.lowercased() {
        case "openai", "sk_all": return "curl https://api.openai.com/v1/models -H \"Authorization: Bearer \(key)\""
        case "anthropic": return "curl https://api.anthropic.com/v1/models -H \"x-api-key: \(key)\" -H \"anthropic-version: 2023-06-01\""
        case "openrouter": return "curl https://openrouter.ai/api/v1/auth/key -H \"Authorization: Bearer \(key)\""
        case "github": return "curl -H \"Authorization: Bearer \(key)\" https://api.github.com/user"
        case "stripe": return "curl https://api.stripe.com/v1/balance -u \(key):"
        case "groq": return "curl https://api.groq.com/openai/v1/models -H \"Authorization: Bearer \(key)\""
        case "deepseek": return "curl https://api.deepseek.com/models -H \"Authorization: Bearer \(key)\""
        case "telegram_bot": return "curl https://api.telegram.org/bot\(key)/getMe"
        case "discord_bot": return "curl -H \"Authorization: Bot \(key)\" https://discord.com/api/v10/users/@me"
        default: return "curl -H \"Authorization: Bearer \(key)\" https://api.example.com/v1/user"
        }
    }
}

// MARK: - Flow Tags

struct FlowTagsView: View {
    let tags: [String]
    let color: Color
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag).font(.system(size: 10, design: .monospaced)).foregroundColor(color)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Capsule().fill(color.opacity(0.12)))
                        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 1))
                }
            }
        }
    }
}

// MARK: - Toast Banner

struct ToastBannerView: View {
    let message: String
    let type: ToastType

    var icon: String {
        switch type {
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
    var color: Color {
        switch type {
        case .success: return Theme.green
        case .error: return Theme.red
        case .warning: return Theme.amber
        case .info: return Theme.accent
        }
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .bold)).foregroundColor(color)
            Text(message).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.textPri)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Capsule().fill(Theme.surfaceHi))
        .overlay(Capsule().stroke(color.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 15, y: 6)
    }
}
