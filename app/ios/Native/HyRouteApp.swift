import NetworkExtension
import SwiftUI

@main
@MainActor
struct HyRouteApp: App {
  @StateObject private var client = Client()

  var body: some Scene {
    WindowGroup {
      RootView(client: client)
    }
  }
}

private struct RootView: View {
  @ObservedObject var client: Client
  @State private var tab: Tab = .home

  private var previewScreen: String? {
    #if targetEnvironment(simulator)
    return ProcessInfo.processInfo.environment["HYROUTE_LAYOUT_PREVIEW"]
    #else
    return nil
    #endif
  }

  enum Tab: CaseIterable, Hashable {
    case home, subscriptions, rules

    var title: String {
      switch self {
      case .home: return "Главная"
      case .subscriptions: return "Подписки"
      case .rules: return "Правила"
      }
    }

    var icon: String {
      switch self {
      case .home: return "power"
      case .subscriptions: return "server.rack"
      case .rules: return "arrow.triangle.branch"
      }
    }
  }

  var body: some View {
    Group {
      if client.ready {
        ZStack {
          panel(.home) { Dashboard(client: client, openRules: { tab = .rules }) }
          panel(.subscriptions) {
            if previewScreen == "servers", let id = client.state.subscriptions.first?.id {
              SubscriptionPage(client: client, id: id)
            } else {
              SubscriptionsPage(client: client)
            }
          }
          panel(.rules) { RulesPage(client: client) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { tabBar }
      } else if client.busy {
        ProgressView("Открытие HyRoute")
      } else {
        VStack(spacing: 16) {
          Image(systemName: "lock.shield").font(.largeTitle)
          Button("Открыть хранилище") { Task { await client.load() } }
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(HyStyle.canvas.ignoresSafeArea())
    .tint(HyStyle.accent)
    .task {
      guard !client.ready else { return }
      #if targetEnvironment(simulator)
      if let previewScreen, client.loadLayoutPreview() {
        if previewScreen == "servers" { tab = .subscriptions }
        if previewScreen == "rules" { tab = .rules }
        return
      }
      #endif
      await client.load()
    }
    .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
      client.syncVPNStatus()
    }
    .alert("HyRoute", isPresented: Binding(
      get: { client.error != nil },
      set: { if !$0 { client.error = nil } }
    )) {
      Button("ОК", role: .cancel) { client.error = nil }
    } message: {
      Text(client.error ?? "")
    }
  }

  private func panel<Content: View>(_ item: Tab, @ViewBuilder content: () -> Content) -> some View {
    NavigationStack { content() }
      .opacity(tab == item ? 1 : 0)
      .allowsHitTesting(tab == item)
      .accessibilityHidden(tab != item)
      .zIndex(tab == item ? 1 : 0)
  }

  private var tabBar: some View {
    HStack(spacing: 8) {
      ForEach(Tab.allCases, id: \.self) { item in
        Button { tab = item } label: {
          VStack(spacing: 4) {
            Image(systemName: item.icon).font(.system(size: 18, weight: .semibold))
              .accessibilityHidden(true)
            Text(item.title).font(.caption.weight(tab == item ? .bold : .medium))
              .lineLimit(1)
          }
          .frame(maxWidth: .infinity, minHeight: 48)
          .foregroundStyle(tab == item ? HyStyle.accent : HyStyle.muted)
          .background(tab == item ? HyStyle.inset : .clear, in: RoundedRectangle(cornerRadius: 11))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == item ? .isSelected : [])
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .background(HyStyle.surface.ignoresSafeArea(edges: .bottom))
    .overlay(alignment: .top) { Rectangle().fill(HyStyle.stroke).frame(height: 1).allowsHitTesting(false) }
  }
}

private struct Dashboard: View {
  @ObservedObject var client: Client
  let openRules: () -> Void
  @State private var choosingProfile = false
  @State private var importing = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        ConnectionStatus(client: client)
        VStack(spacing: 8) {
          HyHeading(text: "Основной профиль")
          if let selected = client.state.selected {
            Button { choosingProfile = true } label: {
              HStack(spacing: 8) {
                ProfileRow(profile: selected)
                Image(systemName: "chevron.up.chevron.down")
                  .font(.footnote.weight(.semibold)).foregroundStyle(HyStyle.muted)
              }
              .hyCard()
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("profilePicker")
          } else {
            Button { importing = true } label: {
              HyRow(title: "Добавить подписку", symbol: "plus").hyCard()
            }
            .buttonStyle(.plain)
          }
        }
        VStack(spacing: 0) {
          Button(action: openRules) {
            HyRow(title: "Маршрутизация", symbol: "arrow.triangle.branch",
                  detail: "Всё остальное · \(client.state.settings.routing.defaultAction.label)")
          }
          .buttonStyle(.plain)
          Divider().overlay(HyStyle.stroke).padding(.vertical, 6)
          NavigationLink {
            VPNJournalPage(client: client)
          } label: {
            HyRow(title: "Журнал VPN", symbol: "list.bullet.rectangle")
          }
          .buttonStyle(.plain)
        }
        .hyCard(padding: 12)
      }
      .padding(16)
    }
    .hyScreen()
    .navigationTitle("HyRoute")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $choosingProfile) { ProfilePicker(client: client) }
    .sheet(isPresented: $importing) { ImportSheet(client: client) }
  }
}

private struct ConnectionStatus: View {
  @ObservedObject var client: Client

  private var isActive: Bool {
    [.connected, .connecting, .reasserting].contains(client.vpnStatus)
  }

  private var statusLabel: String {
    if client.vpnBusy { return "Запуск VPN…" }
    switch client.vpnStatus {
    case .connected: return "VPN включён"
    case .connecting, .reasserting: return "Подключение…"
    case .disconnecting: return "Отключение…"
    default: return "VPN выключен"
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 14) {
        HyIcon(symbol: "lock.shield", size: 48)
        VStack(alignment: .leading, spacing: 3) {
          Text(statusLabel).font(.title3.weight(.bold)).foregroundStyle(HyStyle.ink)
          if client.state.selected == nil && !isActive {
            Text("Добавьте подписку для подключения.")
              .font(.subheadline).foregroundStyle(HyStyle.muted)
          }
        }
        Spacer(minLength: 0)
        if client.vpnStatus == .connected {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(HyStyle.success)
            .accessibilityHidden(true)
        } else if client.vpnBusy || client.vpnStatus == .connecting || client.vpnStatus == .reasserting {
          ProgressView().tint(HyStyle.accent)
        }
      }
      Button { Task { await client.toggleVPN() } } label: {
        Label(isActive ? "Отключить" : "Подключить", systemImage: "power")
      }
      .buttonStyle(HyButton(prominent: !isActive))
      .disabled(client.vpnBusy || client.vpnStatus == .disconnecting || (client.state.selected == nil && !isActive))
    }
    .hyCard(padding: 16)
  }
}

struct ProfileRow: View {
  let profile: VPNProfile
  var selected = false

  private var displayTitle: String {
    let parts = profile.title.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    let title = parts.filter { $0.compare(profile.transport, options: .caseInsensitive) != .orderedSame }
    return title.isEmpty ? profile.title : title.joined(separator: " · ")
  }

  var body: some View {
    HStack(spacing: 12) {
      HyIcon(symbol: profile.balance == true ? "bolt.fill" : "server.rack")
      VStack(alignment: .leading, spacing: 3) {
        Text(displayTitle).font(.body.weight(.semibold))
          .foregroundStyle(HyStyle.ink).lineLimit(2)
        Text(profile.missing == true ? "Сервер недоступен" : profile.transport)
          .font(.subheadline).foregroundStyle(HyStyle.muted).lineLimit(1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .layoutPriority(1)
      if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(HyStyle.accent) }
    }
    .frame(minHeight: 44)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

struct ProfilePicker: View {
  @ObservedObject var client: Client
  var selected: String?
  var select: ((String) -> Void)?
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    NavigationStack {
      List {
        if let select {
          Button { select(""); dismiss() } label: {
            Label("Основной профиль", systemImage: "star")
          }
        }
        ForEach(client.state.profiles.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.host?.localizedCaseInsensitiveContains(query) == true }) { profile in
          Button {
            if let select {
              select(profile.id)
              dismiss()
            } else {
              Task { if await client.select(profile.id) { dismiss() } }
            }
          } label: {
            ProfileRow(profile: profile, selected: (select == nil ? client.state.selected?.id : selected) == profile.id)
          }
          .buttonStyle(.plain)
          .disabled(client.busy)
        }
      }
      .hyList()
      .searchable(text: $query, prompt: "Найти профиль")
      .navigationTitle(select == nil ? "Основной профиль" : "Профиль правила")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
    }
  }
}

private struct SubscriptionsPage: View {
  @ObservedObject var client: Client
  @State private var adding = false

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 10) {
        if client.state.subscriptions.isEmpty {
          VStack(alignment: .leading, spacing: 12) {
            HyIcon(symbol: "server.rack", size: 48)
            HyHeading(text: "Подписок пока нет")
            Text("Добавьте ссылку или конфиг VPN.").foregroundStyle(HyStyle.muted)
            Button { adding = true } label: { Label("Добавить подписку", systemImage: "plus") }
              .buttonStyle(HyButton())
          }
          .hyCard(padding: 16)
        }
        ForEach(client.state.subscriptions) { item in
          NavigationLink {
            SubscriptionPage(client: client, id: item.id)
          } label: {
            HyRow(title: item.name, symbol: "square.stack", detail: "Профилей: \(item.servers.count)")
              .hyCard(padding: 12)
          }
          .buttonStyle(.plain)
        }
      }
      .padding(16)
    }
    .hyScreen()
    .navigationTitle("Подписки")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if !client.state.subscriptions.isEmpty {
        ToolbarItem(placement: .primaryAction) {
          Button { adding = true } label: { Label("Добавить подписку", systemImage: "plus") }
        }
      }
    }
    .sheet(isPresented: $adding) { ImportSheet(client: client) }
  }
}

private struct SubscriptionProbe: Hashable {
  let scope: String
  let id: String
}

private struct SubscriptionPage: View {
  @ObservedObject var client: Client
  let id: String

  var body: some View {
    if let item = client.state.subscriptions.first(where: { $0.id == id }) {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          HStack(spacing: 10) {
            NavigationLink(value: SubscriptionProbe(scope: "subscription", id: id)) {
              Label("Проверить все", systemImage: "speedometer")
            }
            .buttonStyle(HyButton())
            .disabled(!item.servers.contains { $0.missing != true })
            if item.canRefresh == true {
              Button { Task { await client.refresh(id) } } label: {
                Group {
                  if client.busy { ProgressView().tint(HyStyle.accent) }
                  else { Image(systemName: "arrow.clockwise").font(.body.weight(.semibold)) }
                }
                .foregroundStyle(HyStyle.accent)
                .frame(width: 48, height: 48)
                .background(HyStyle.inset, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Обновить подписку")
              .disabled(client.busy)
            }
          }
          HyHeading(text: "Серверы")
          LazyVStack(spacing: 0) {
            ForEach(item.servers) { profile in
              HStack(spacing: 6) {
                Button { Task { _ = await client.select(profile.id) } } label: {
                  ProfileRow(profile: profile, selected: client.state.selected?.id == profile.id)
                }
                .buttonStyle(.plain)
                .disabled(client.busy || profile.missing == true)
                if profile.missing != true {
                  NavigationLink(value: SubscriptionProbe(scope: "profile", id: profile.id)) {
                    Image(systemName: "speedometer")
                      .font(.body.weight(.semibold))
                      .foregroundStyle(HyStyle.accent)
                      .frame(width: 44, height: 44)
                      .background(HyStyle.inset, in: RoundedRectangle(cornerRadius: 10))
                      .contentShape(Rectangle())
                  }
                  .buttonStyle(.plain)
                  .fixedSize(horizontal: true, vertical: false)
                  .accessibilityLabel(profile.balance == true ? "Проверить узлы группы" : "Проверить задержку")
                }
              }
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              if profile.id != item.servers.last?.id {
                Divider().overlay(HyStyle.stroke).padding(.leading, 60)
              }
            }
          }
          .hyCard(padding: 0)
        }
        .padding(16)
      }
      .hyScreen()
      .navigationTitle(item.name)
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: SubscriptionProbe.self) { probe in
        ProbePage(client: client, scope: probe.scope, id: probe.id)
      }
    }
  }
}

private struct ImportSheet: View {
  @ObservedObject var client: Client
  @Environment(\.dismiss) private var dismiss
  @State private var input = ""
  @State private var error: String?

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 10) {
            HyHeading(text: "Ссылка или конфиг")
            TextEditor(text: $input)
              .frame(minHeight: 136)
              .font(.body.monospaced())
              .textInputAutocapitalization(.never)
              .autocorrectionDisabled()
              .scrollContentBackground(.hidden)
              .padding(8)
              .background(HyStyle.inset, in: RoundedRectangle(cornerRadius: 10))
              .accessibilityLabel("Ссылка или конфиг подписки")
            PasteButton(payloadType: String.self) { values in
              if let first = values.first { input = first; error = nil }
            }
            .accessibilityLabel("Вставить подписку")
          }
          .hyCard()
          if let error { Text(error).foregroundStyle(HyStyle.failure) }
          Button {
            Task {
              error = nil
              if await client.importSubscription(input, reportError: false) { dismiss() }
              else { error = "Не удалось импортировать. Проверьте ссылку или формат конфига." }
            }
          } label: {
            if client.busy { ProgressView().tint(.white) }
            else { Label("Импортировать", systemImage: "arrow.down") }
          }
          .buttonStyle(HyButton())
          .disabled(client.busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
      }
      .hyScreen()
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle("Добавить подписку")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(client.busy) }
      }
    }
    .interactiveDismissDisabled(client.busy)
  }
}
