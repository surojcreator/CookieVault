import SwiftUI
import AppKit

// MARK: - View Models

final class CookieListVM: ObservableObject {
    @Published var searchText = ""
    @Published var sortOrder: SortOrder = .domain
    @Published var showExpiredOnly = false

    enum SortOrder: String, CaseIterable, Identifiable {
        case domain = "Domain", name = "Name", expiry = "Expiry"
        var id: String { rawValue }
    }
}

final class CookieDetailVM: ObservableObject {
    @Published var showFullValue = false
}

// MARK: - Cookies Main View

struct CookiesMainView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        if let folder = store.selectedCookieFolder {
            FolderOverviewView(folderName: folder, tab: .cookies)
        } else if let tier = store.selectedCookieTier {
            FolderOverviewView(folderName: tier == .premium ? "SMART_PREMIUM" : "SMART_FREE", tab: .cookies)
        } else if let file = store.selectedCookieFile {
            CookieFileDetailView(file: file)
        } else if !store.cookieFiles.isEmpty {
            FolderOverviewView(folderName: !store.premiumCookieFiles.isEmpty ? "SMART_PREMIUM" : "ALL_ACCOUNTS", tab: .cookies)
        } else {
            EmptyStateView(
                icon: "puzzlepiece.extension.fill",
                title: "No cookies imported yet",
                subtitle: "Import a Netscape (.txt) or JSON cookie file — or a whole folder or .zip — to inspect sessions and launch them in an isolated browser.",
                actionTitle: "Import Cookies",
                action: { store.chooseFolder(tab: .cookies) }
            )
        }
    }
}

// MARK: - Cookie File Detail

struct CookieFileDetailView: View {
    @EnvironmentObject var store: AppStore
    let file: CookieFile
    @StateObject private var vm = CookieListVM()

    var brand: ServiceBrand { ServiceBrandHelper.brand(for: file.serviceName ?? file.folderName ?? file.name) }
    var isPremium: Bool { file.tier == .premium }
    var validCount: Int { file.cookies.filter { !$0.isExpired }.count }
    var expiredCount: Int { file.cookies.filter { $0.isExpired }.count }

    func filtered() -> [Cookie] {
        var c = file.cookies
        if !vm.searchText.isEmpty {
            let q = vm.searchText.lowercased()
            c = c.filter { $0.domain.lowercased().contains(q) || $0.name.lowercased().contains(q) || $0.value.lowercased().contains(q) }
        }
        if vm.showExpiredOnly { c = c.filter { $0.isExpired } }
        switch vm.sortOrder {
        case .domain: return c.sorted { $0.domain < $1.domain }
        case .name:   return c.sorted { $0.name < $1.name }
        case .expiry: return c.sorted { ($0.expiry ?? .distantFuture) < ($1.expiry ?? .distantFuture) }
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                hero.padding(18)
                Rectangle().fill(Theme.border).frame(height: 1)
                toolbar
                Rectangle().fill(Theme.border).frame(height: 1)
                columnHeader
                Rectangle().fill(Theme.border).frame(height: 1)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered()) { cookie in
                            CookieRow(cookie: cookie, isSelected: store.selectedCookie?.id == cookie.id,
                                      action: { store.selectedCookie = cookie },
                                      onCopyValue: {
                                          NSPasteboard.general.clearContents()
                                          NSPasteboard.general.setString(cookie.value, forType: .string)
                                          store.showToast("Copied cookie value", type: .success)
                                      },
                                      onDelete: { store.deleteCookie(cookie, from: file) })
                            Rectangle().fill(Theme.border.opacity(0.5)).frame(height: 1)
                        }
                    }
                }
                .background(Theme.bg0)
            }
            .frame(minWidth: 520)

            if let cookie = store.selectedCookie {
                CookieDetailPanel(cookie: cookie, file: file).frame(minWidth: 330, maxWidth: 400)
            }
        }
        .background(Theme.bg0)
    }

    // Hero card: identity + launch
    private var hero: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Button {
                    store.selectedCookieFolder = file.folderName ?? "ALL_ACCOUNTS"
                    store.selectedCookieFile = nil
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left")
                        Text(file.folderName ?? "All Accounts")
                    }
                    .font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.accent2)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(Capsule().fill(Theme.accent.opacity(0.14)))
                }
                .buttonStyle(.plain)

                Pill(text: file.format.rawValue, tint: Theme.textSec)
                Spacer()
                Button { store.toggleSaved(file) } label: {
                    GhostButton(title: file.saved ? "Saved" : "Save",
                                systemImage: file.saved ? "star.fill" : "star",
                                tint: file.saved ? Theme.gold : Theme.textSec)
                }.buttonStyle(.plain)
                Button { copyNetscape() } label: { GhostButton(title: "Copy Netscape", systemImage: "doc.on.doc") }.buttonStyle(.plain)
                Button { exportCookiesJSON() } label: { IconButton(symbol: "square.and.arrow.up") }.buttonStyle(.plain)
                Button { store.deleteCookieFileConfirmed(file) } label: { IconButton(symbol: "trash", tint: Theme.red) }.buttonStyle(.plain).help("Delete this account")
            }

            HStack(spacing: 16) {
                IconTile(symbol: brand.icon, tint: Color(hex: brand.colorHex), size: 54, filled: true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(file.accountEmail ?? file.name)
                            .font(.system(size: 17, weight: .bold)).foregroundColor(Theme.textPri).lineLimit(1)
                        if file.accountEmail != nil {
                            Button {
                                copy(file.accountEmail!, label: "email")
                            } label: {
                                Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(Theme.textTer)
                            }.buttonStyle(.plain)
                        }
                        TierBadge(tier: file.tier, plan: file.planName)
                        if let s = store.state(for: file).label {
                            Pill(text: s, systemImage: "exclamationmark.circle.fill", tint: Theme.amber)
                        }
                    }
                    HStack(spacing: 10) {
                        StatusDot(ok: validCount > 0, okText: "Active session", badText: "Session expired")
                        Text("·").foregroundColor(Theme.textTer)
                        Text("\(file.cookies.count) cookies").font(.system(size: 11)).foregroundColor(Theme.textSec)
                        if let domain = file.cookies.first?.domain {
                            Text("·").foregroundColor(Theme.textTer)
                            Text(domain).font(.system(size: 11)).foregroundColor(Theme.accent2).lineLimit(1)
                        }
                    }
                }
                Spacer()
                if file.cookies.first != nil {
                    Button { launch() } label: {
                        FilledButton(title: store.isLaunching ? "Launching…" : "Launch Session",
                                     systemImage: store.isLaunching ? nil : "safari.fill",
                                     gradient: isPremium ? Theme.goldGrad : Theme.accentGrad,
                                     glow: isPremium ? Theme.gold : Theme.accent)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isLaunching)
                    .opacity(store.isLaunching ? 0.7 : 1)
                }
            }
        }
        .cvCard(padding: 18, radius: Theme.rLg, fill: Theme.surface)
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            CVSearchBar(text: Binding(get: { vm.searchText }, set: { vm.searchText = $0 }),
                        placeholder: "Search cookies by name, domain, or value…")
                .frame(maxWidth: 340)
            Spacer()
            statChip("Valid", validCount, Theme.green)
            statChip("Expired", expiredCount, Theme.red)
            Rectangle().fill(Theme.border).frame(width: 1, height: 18)
            Picker("", selection: Binding(get: { vm.sortOrder }, set: { vm.sortOrder = $0 })) {
                ForEach(CookieListVM.SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu).frame(width: 96).tint(Theme.accent2)
            Toggle("Expired only", isOn: Binding(get: { vm.showExpiredOnly }, set: { vm.showExpiredOnly = $0 }))
                .toggleStyle(.switch).controlSize(.mini)
                .font(.system(size: 11)).foregroundColor(Theme.textSec)
        }
        .padding(.horizontal, 16).padding(.vertical, 10).background(Theme.bg1)
    }

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Domain").frame(width: 170, alignment: .leading)
            Text("Name").frame(width: 160, alignment: .leading)
            Text("Value").frame(maxWidth: .infinity, alignment: .leading)
            Text("Security").frame(width: 72, alignment: .center)
            Text("Status").frame(width: 66, alignment: .center)
        }
        .font(.system(size: 9.5, weight: .bold)).foregroundColor(Theme.textTer).tracking(0.6)
        .padding(.horizontal, 14).padding(.vertical, 8).background(Theme.bg1)
    }

    func statChip(_ label: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(count) \(label)").font(.system(size: 11)).foregroundColor(Theme.textSec)
        }
    }

    // Actions
    private func launch() {
        if let c = file.cookies.first { store.openInBrowser(cookie: c, file: file) }
    }
    private func copy(_ s: String, label: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        store.showToast("Copied \(label)", type: .success)
    }
    func copyNetscape() {
        let str = file.cookies.map { c -> String in
            let exp = c.expiry.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            return "\(c.domain)\t\(c.flag ? "TRUE" : "FALSE")\t\(c.path)\t\(c.secure ? "TRUE" : "FALSE")\t\(exp)\t\(c.name)\t\(c.value)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(str, forType: .string)
        store.showToast("Copied Netscape cookies", type: .success)
    }
    func exportCookiesJSON() {
        let arr = file.cookies.map { c -> [String: Any] in
            var d: [String: Any] = ["domain": c.domain, "name": c.name, "value": c.value,
                                    "path": c.path, "secure": c.secure, "httpOnly": c.flag]
            if let exp = c.expiry { d["expirationDate"] = exp.timeIntervalSince1970 }
            return d
        }
        guard let data = try? JSONSerialization.data(withJSONObject: arr, options: [.prettyPrinted]),
              let str = String(data: data, encoding: .utf8) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(file.name)_cookies.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            try? str.write(to: url, atomically: true, encoding: .utf8)
            store.showToast("Exported cookies to JSON", type: .success)
        }
    }
}

// MARK: - Cookie Row

final class RowHover: ObservableObject { @Published var on = false }

struct CookieRow: View {
    let cookie: Cookie
    let isSelected: Bool
    let action: () -> Void
    var onCopyValue: () -> Void = {}
    var onDelete: () -> Void = {}
    @StateObject private var hover = RowHover()

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(domainColor).frame(width: 7, height: 7)
                    Text(cookie.domain).lineLimit(1)
                }
                .frame(width: 170, alignment: .leading)

                Text(cookie.name).lineLimit(1)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .frame(width: 160, alignment: .leading)

                Text(maskedValue).lineLimit(1).foregroundColor(Theme.textTer)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    if cookie.secure { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundColor(Theme.green) }
                    if cookie.flag { Image(systemName: "shield.fill").font(.system(size: 9)).foregroundColor(Theme.accent2) }
                }
                .frame(width: 72, alignment: .center)

                statusBadge.frame(width: 66, alignment: .center)
            }
            .font(.system(size: 12, design: .monospaced))
            .foregroundColor(isSelected ? Theme.textPri : Theme.textSec)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(isSelected ? Theme.accent.opacity(0.16) : (hover.on ? Color.white.opacity(0.03) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover.on = $0 }
        .animation(.easeOut(duration: 0.1), value: hover.on)
        .contextMenu {
            Button { onCopyValue() } label: { Label("Copy Value", systemImage: "doc.on.doc") }
            Divider()
            Button(role: .destructive) { onDelete() } label: { Label("Delete Cookie", systemImage: "trash") }
        }
    }

    var maskedValue: String {
        let v = cookie.value; guard v.count > 16 else { return v }
        return String(v.prefix(8)) + "••••" + String(v.suffix(4))
    }
    var domainColor: Color {
        let p: [Color] = [Theme.accent, Theme.green, Theme.gold, Color(hex: "3b82f6"), Theme.red, Theme.pink, Color(hex: "06b6d4"), Theme.accent2]
        // Safe modulo — abs(hashValue) can trap when hashValue == Int.min.
        return p[((cookie.domain.hashValue % p.count) + p.count) % p.count]
    }
    var statusBadge: some View {
        Pill(text: cookie.isExpired ? "Expired" : "Valid", tint: cookie.isExpired ? Theme.red : Theme.green)
    }
}

// MARK: - Cookie Detail Panel

struct CookieDetailPanel: View {
    @EnvironmentObject var store: AppStore
    let cookie: Cookie
    let file: CookieFile
    @StateObject private var vm = CookieDetailVM()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        IconTile(symbol: "puzzlepiece.extension.fill", tint: Theme.accent, size: 40, filled: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cookie.name).font(.system(size: 15, weight: .bold)).foregroundColor(Theme.textPri).lineLimit(1)
                            Text(cookie.domain).font(.system(size: 12)).foregroundColor(Theme.accent2).lineLimit(1)
                        }
                    }
                    Button { store.openInBrowser(cookie: cookie, file: file) } label: {
                        FilledButton(title: store.isLaunching ? "Launching…" : "Launch with this cookie",
                                     systemImage: store.isLaunching ? nil : "safari.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain).disabled(store.isLaunching)
                }
                .padding(18).background(Theme.surface)

                Rectangle().fill(Theme.border).frame(height: 1)

                VStack(spacing: 1) {
                    detailRow("Name", cookie.name, mono: true, copy: true)
                    detailRow("Domain", cookie.domain, mono: true, copy: true)
                    detailRow("Path", cookie.path, mono: false, copy: false)
                    detailRow("Secure", cookie.secure ? "Yes" : "No", mono: false, copy: false)
                    detailRow("HttpOnly", cookie.flag ? "Yes" : "No", mono: false, copy: false)
                    if let exp = cookie.expiry {
                        detailRow("Expires", exp.formatted(date: .abbreviated, time: .standard), mono: false, copy: false,
                                  color: cookie.isExpired ? Theme.red : Theme.green)
                    } else {
                        detailRow("Expires", "Session cookie", mono: false, copy: false)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionLabel(text: "Cookie Value")
                            Spacer()
                            Button(vm.showFullValue ? "Hide" : "Reveal") { vm.showFullValue.toggle() }
                                .font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent2).buttonStyle(.plain)
                            Button {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cookie.value, forType: .string)
                                store.showToast("Copied cookie value", type: .success)
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc").labelStyle(.titleAndIcon)
                                    .font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent2)
                            }.buttonStyle(.plain)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            Text(vm.showFullValue ? cookie.value : maskedFull)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(Theme.textPri).textSelection(.enabled)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: Theme.rSm).fill(Theme.inset))
                        .overlay(RoundedRectangle(cornerRadius: Theme.rSm).stroke(Theme.border, lineWidth: 1))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12).background(Theme.surface)
                }
                Spacer(minLength: 20)
            }
        }
        .background(Theme.surface)
    }

    var maskedFull: String {
        let v = cookie.value; guard v.count > 24 else { return v }
        return String(v.prefix(12)) + " ••••••••••••••••• " + String(v.suffix(6))
    }

    func detailRow(_ label: String, _ value: String, mono: Bool, copy: Bool, color: Color = Theme.textPri) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.textTer)
                .frame(width: 66, alignment: .leading)
            Text(value).font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundColor(color).lineLimit(1).textSelection(.enabled)
            Spacer()
            if copy {
                Button {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
                    store.showToast("Copied \(label)", type: .success)
                } label: { Image(systemName: "doc.on.doc").font(.system(size: 10)).foregroundColor(Theme.textTer) }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10).background(Theme.surface)
    }
}

// MARK: - Search Bar

final class SearchBoxVM: ObservableObject { @Published var focused = false }

struct CVSearchBar: View {
    @Binding var text: String
    let placeholder: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12))
                .foregroundColor(focused ? Theme.accent2 : Theme.textTer)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(.system(size: 13))
                .foregroundColor(Theme.textPri).tint(Theme.accent)
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundColor(Theme.textTer)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.rSm).fill(Theme.inset))
        .overlay(RoundedRectangle(cornerRadius: Theme.rSm)
            .stroke(focused ? Theme.accent.opacity(0.55) : Theme.border, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String
    let actionTitle: String
    let action: () -> Void
    @StateObject private var hover = Hover()

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.10)).frame(width: 92, height: 92)
                Circle().stroke(Theme.accent.opacity(0.25), lineWidth: 1).frame(width: 92, height: 92)
                Image(systemName: icon).font(.system(size: 34))
                    .foregroundStyle(Theme.accentGrad)
            }
            VStack(spacing: 8) {
                Text(title).font(.system(size: 19, weight: .bold)).foregroundColor(Theme.textPri)
                Text(subtitle).font(.system(size: 13)).foregroundColor(Theme.textSec)
                    .multilineTextAlignment(.center).frame(maxWidth: 420).lineSpacing(2)
            }
            Button(action: action) {
                FilledButton(title: actionTitle, systemImage: "plus")
                    .scaleEffect(hover.on ? 1.03 : 1)
            }
            .buttonStyle(.plain)
            .onHover { hover.on = $0 }
            .animation(.spring(response: 0.25), value: hover.on)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg0)
    }
}
