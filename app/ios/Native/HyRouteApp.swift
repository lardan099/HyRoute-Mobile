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
  @Environment(\.colorScheme) private var colorScheme
  @State private var tab: Tab = .home

  enum Tab { case home, subscriptions, rules }

  var body: some View {
    Group {
      if client.ready {
        TabView(selection: $tab) {
          NavigationStack {
            Dashboard(client: client, openSubscriptions: { tab = .subscriptions }, openRules: { tab = .rules })
          }
          .tabItem { Label("Главная", systemImage: "house") }.tag(Tab.home)
          NavigationStack { SubscriptionsPage(client: client) }
            .tabItem { Label("Подписки", systemImage: "square.stack") }.tag(Tab.subscriptions)
          NavigationStack { RulesPage(client: client) }
            .tabItem { Label("Правила", systemImage: "arrow.triangle.branch") }.tag(Tab.rules)
        }
      } else if client.busy {
        ProgressView("Открытие HyRoute")
      } else {
        VStack(spacing: 16) {
          Image(systemName: "lock.shield").font(.largeTitle)
          Button("Открыть хранилище") { Task { await client.load() } }
        }
      }
    }
    .tint(colorScheme == .dark ? Color(red: 0.49, green: 0.88, blue: 0.73) : Color(red: 0.03, green: 0.39, blue: 0.31))
    .task { if !client.ready { await client.load() } }
    .alert("HyRoute", isPresented: Binding(
      get: { client.error != nil },
      set: { if !$0 { client.error = nil } }
    )) {
      Button("ОК", role: .cancel) { client.error = nil }
    } message: {
      Text(client.error ?? "")
    }
  }
}

private struct Dashboard: View {
  @ObservedObject var client: Client
  let openSubscriptions: () -> Void
  let openRules: () -> Void
  @State private var choosingProfile = false

  var body: some View {
    List {
      ConnectionStatus()
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowBackground(Color.clear)
      Section("Основной профиль") {
        if let selected = client.state.selected {
          Button { choosingProfile = true } label: {
            HStack {
              ProfileRow(profile: selected)
              Image(systemName: "chevron.up.chevron.down")
                .font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("profilePicker")
        } else {
          Button(action: openSubscriptions) { Label("Добавить подписку", systemImage: "plus.circle") }
        }
      }
      Section("Маршрутизация") {
        Button(action: openRules) {
          HStack(spacing: 12) {
            Label("Всё остальное", systemImage: "arrow.triangle.branch")
            Spacer(minLength: 4)
            Text(client.state.settings.routing.defaultAction.label).foregroundStyle(.secondary)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .listStyle(.insetGrouped)
    .navigationTitle("HyRoute")
    .sheet(isPresented: $choosingProfile) { ProfilePicker(client: client) }
  }
}

private struct ConnectionStatus: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Image(systemName: "power")
        .font(.system(size: 22, weight: .medium))
        .foregroundStyle(Color(red: 0.53, green: 0.92, blue: 0.77))
        .frame(width: 48, height: 48)
        .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text("VPN выключен").font(.title2.weight(.semibold))
        Text("Туннель ещё в разработке").font(.subheadline).foregroundStyle(.white.opacity(0.74))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(20)
    .foregroundStyle(.white)
    .background(
      LinearGradient(colors: [Color(red: 0.07, green: 0.20, blue: 0.17), Color(red: 0.07, green: 0.12, blue: 0.13)], startPoint: .topTrailing, endPoint: .bottomLeading),
      in: RoundedRectangle(cornerRadius: 23)
    )
    .accessibilityElement(children: .combine)
  }
}

struct ProfileRow: View {
  let profile: VPNProfile
  var selected = false

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: profile.balance == true ? "bolt.fill" : "server.rack")
        .foregroundStyle(.tint)
        .frame(width: 34, height: 34)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 4) {
        Text(profile.title).font(.body.weight(.medium))
        Text(profile.missing == true ? "Сервер недоступен" : profile.transport)
          .font(.subheadline).foregroundStyle(.secondary)
      }
      Spacer(minLength: 4)
      if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct ProfilePicker: View {
  @ObservedObject var client: Client
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    NavigationStack {
      List(client.state.profiles.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.host?.localizedCaseInsensitiveContains(query) == true }) { profile in
        Button {
          Task { if await client.select(profile.id) { dismiss() } }
        } label: {
          ProfileRow(profile: profile, selected: client.state.selected?.id == profile.id)
        }
        .buttonStyle(.plain)
        .disabled(client.busy)
      }
      .searchable(text: $query, prompt: "Найти профиль")
      .navigationTitle("Основной профиль")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
    }
  }
}

private struct SubscriptionsPage: View {
  @ObservedObject var client: Client
  @State private var adding = false

  var body: some View {
    List {
      if client.state.subscriptions.isEmpty {
        Section {
          Button { adding = true } label: { Label("Добавить подписку", systemImage: "plus.circle") }
        } footer: {
          Text("HTTPS-ссылка, конфиг Xray или ссылки Hysteria 2 и VLESS.")
        }
      }
      ForEach(client.state.subscriptions) { item in
        NavigationLink {
          SubscriptionPage(client: client, id: item.id)
        } label: {
          VStack(alignment: .leading, spacing: 4) {
            Label(item.name, systemImage: "square.stack")
            Text("Профилей: \(item.servers.count)").font(.subheadline).foregroundStyle(.secondary)
          }
          .padding(.vertical, 5)
        }
      }
    }
    .navigationTitle("Подписки")
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

private struct SubscriptionPage: View {
  @ObservedObject var client: Client
  let id: String

  var body: some View {
    if let item = client.state.subscriptions.first(where: { $0.id == id }) {
      List {
        if item.canRefresh == true {
          Section {
            Button { Task { await client.refresh(id) } } label: {
              if client.busy {
                ProgressView("Обновление подписки")
              } else {
                Label("Обновить подписку", systemImage: "arrow.clockwise")
              }
            }
            .disabled(client.busy)
          }
        }
        Section("Профили") {
          ForEach(item.servers) { profile in
            Button { Task { _ = await client.select(profile.id) } } label: {
              ProfileRow(profile: profile, selected: client.state.selected?.id == profile.id)
            }
            .buttonStyle(.plain)
            .disabled(client.busy || profile.missing == true)
          }
        }
      }
      .navigationTitle(item.name)
      .navigationBarTitleDisplayMode(.inline)
    }
  }
}

private struct ImportSheet: View {
  @ObservedObject var client: Client
  @Environment(\.dismiss) private var dismiss
  @State private var input = ""

  var body: some View {
    NavigationStack {
      Form {
        Section("Ссылка или конфиг") {
          TextEditor(text: $input)
            .frame(minHeight: 116)
            .font(.body.monospaced())
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .accessibilityLabel("Ссылка или конфиг подписки")
        }
        if client.busy { ProgressView("Импорт подписки") }
      }
      .navigationTitle("Добавить подписку")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(client.busy) }
        ToolbarItem(placement: .confirmationAction) {
          Button("Импортировать") { Task { if await client.importSubscription(input) { dismiss() } } }
            .disabled(client.busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
    }
    .interactiveDismissDisabled(client.busy)
  }
}
