import SwiftUI

struct ServerGroupsPage: View {
  @ObservedObject var client: Client
  @State private var adding = false

  private var servers: [VPNProfile] {
    var seen = Set<String>()
    if let candidates = client.state.groupServers { return candidates }
    return client.state.profiles.filter { $0.balance != true && seen.insert($0.id).inserted }
  }

  var body: some View {
    List {
      Button { adding = true } label: { Label("Создать группу", systemImage: "plus") }
        .disabled(servers.isEmpty)
        .accessibilityIdentifier("create-server-group")
      if servers.isEmpty { Text("Добавьте хотя бы один сервер.").foregroundStyle(HyStyle.muted) }
      ForEach(client.state.serverGroups ?? []) { group in
        NavigationLink {
          ServerGroupEditor(client: client, servers: servers, group: group)
        } label: {
          let reserve = group.reserve.isEmpty ? "без резерва" : "с резервом"
          HyRow(title: group.name, symbol: "server.rack", detail: "Основных: \(group.primary.count) · \(reserve)")
        }
        .accessibilityIdentifier("server-group-list-\(group.id)")
      }
    }
    .hyList()
    .navigationTitle("Группы серверов")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $adding) {
      NavigationStack { ServerGroupEditor(client: client, servers: servers) }
    }
  }
}

private struct ServerGroupEditor: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var client: Client
  let servers: [VPNProfile]
  let id: String
  @State private var name: String
  @State private var primary: Set<String>
  @State private var reserve: String
  @State private var error: String?
  @State private var confirmingDelete = false
  @State private var query = ""

  init(client: Client, servers: [VPNProfile], group: ServerGroup? = nil) {
    self.client = client
    self.servers = servers
    id = group?.id ?? ""
    _name = State(initialValue: group?.name ?? "")
    _primary = State(initialValue: Set(group?.primary ?? []).intersection(servers.map(\.id)))
    _reserve = State(initialValue: servers.contains { $0.id == group?.reserve } ? group?.reserve ?? "" : "")
  }

  var body: some View {
    Form {
      TextField("Название группы", text: $name)
        .accessibilityIdentifier("server-group-name")
      Section {
        ForEach(servers.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { server in
          Toggle(server.title, isOn: Binding(get: { primary.contains(server.id) }, set: { enabled in
            if enabled { primary.insert(server.id) } else { primary.remove(server.id) }
          }))
          .disabled(reserve == server.id)
          .accessibilityIdentifier("group-server-\(server.id)")
        }
      } header: {
        Text("Основные серверы")
      } footer: {
        Text("HyRoute выбирает доступный сервер с наименьшей задержкой.")
      }
      Picker("Резервный сервер", selection: $reserve) {
        Text("Без резерва").tag("")
        ForEach(servers.filter { !primary.contains($0.id) }) { Text($0.title).tag($0.id) }
      }
      if let error { Text(error).foregroundStyle(HyStyle.failure) }
      if !id.isEmpty {
        Button("Удалить группу", role: .destructive) { confirmingDelete = true }
      }
    }
    .hyList()
    .searchable(text: $query, prompt: "Найти основной сервер")
    .disabled(client.busy)
    .navigationTitle(id.isEmpty ? "Новая группа" : "Настройки группы")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if id.isEmpty {
        ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Сохранить") {
          let selected = servers.map(\.id).filter { primary.contains($0) }
          Task { await save(ServerGroup(name: name, primary: selected, reserve: reserve)) }
        }
        .disabled(client.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || primary.isEmpty)
        .accessibilityIdentifier("server-group-save")
      }
    }
    .confirmationDialog("Удалить группу?", isPresented: $confirmingDelete, titleVisibility: .visible) {
      Button("Удалить", role: .destructive) { Task { await save(nil) } }
    }
  }

  private func save(_ group: ServerGroup?) async {
    do {
      try await client.changeServerGroup(id: id, group: group)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

struct SplitDNSPage: View {
  @Environment(\.dismiss) private var dismiss
  @ObservedObject var client: Client
  @State private var enabled: Bool
  @State private var tunnel: String
  @State private var direct: String
  @State private var domains: String
  @State private var saveFailed = false

  init(client: Client) {
    self.client = client
    let settings = client.state.settings.splitDNS
    _enabled = State(initialValue: settings != nil)
    _tunnel = State(initialValue: settings?.tunnel ?? "https://1.1.1.1/dns-query")
    _direct = State(initialValue: settings?.direct ?? "https://8.8.8.8/dns-query")
    _domains = State(initialValue: settings?.domains.joined(separator: "\n") ?? "")
  }

  var body: some View {
    Form {
      Toggle("Включить", isOn: $enabled)
      if enabled {
        Section {
          TextField("DNS через VPN", text: $tunnel)
          TextField("DNS напрямую", text: $direct)
        } footer: {
          Text("Укажите HTTPS-адреса с IP. Сертификат сервера должен поддерживать этот IP.")
        }
        .keyboardType(.URL)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        Section {
          TextEditor(text: $domains)
            .frame(minHeight: 84)
            .accessibilityLabel("Домены для DNS напрямую")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } header: {
          Text("Домены для DNS напрямую")
        } footer: {
          Text("Один на строку. Действует и для поддоменов.")
        }
      }
      if saveFailed { Text("Проверьте адреса DNS и список доменов.").foregroundStyle(HyStyle.failure) }
    }
    .hyList()
    .disabled(client.busy)
    .navigationTitle("Раздельный DNS")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Сохранить") {
          let names = domains.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
          let settings = enabled ? SplitDNS(tunnel: tunnel, direct: direct, domains: names) : nil
          Task {
            if await client.saveSplitDNS(settings) { dismiss() }
            else { saveFailed = true }
          }
        }
        .disabled(client.busy)
      }
    }
  }
}

struct RoutingProfilesPage: View {
  @ObservedObject var client: Client
  @State private var editing: ProfileNameDraft?
  @State private var deleting: RoutingProfile?
  @State private var message: String?

  var body: some View {
    List {
      Section {
        ForEach(client.state.ruleSets) { profile in
          let active = client.state.activeRuleSet?.id == profile.id
          HStack {
            Button {
              Task { await change("activate", id: profile.id) }
            } label: {
              HyRow(title: profile.name, symbol: active ? "checkmark.circle.fill" : "square.stack",
                    detail: "Правил: \(profile.ruleCount)", disclosure: false)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier("routing-profile-\(profile.id)")
            .accessibilityAddTraits(active ? .isSelected : [])
            Menu {
              Button("Переименовать") { editing = ProfileNameDraft(profile: profile) }
              if !active && profile.id != "default" {
                Button("Удалить", role: .destructive) { deleting = profile }
              }
            } label: {
              Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Действия профиля \(profile.name)")
          }
        }
      } footer: {
        Text("При активном VPN новые правила применятся после переподключения.")
      }
      Button {
        editing = ProfileNameDraft()
      } label: {
        Label("Создать копию текущего", systemImage: "plus")
      }
      .accessibilityIdentifier("routing-profile-copy")
      if let message {
        Text(message).foregroundStyle(HyStyle.failure)
      }
    }
    .disabled(client.busy)
    .hyList()
    .navigationTitle("Профили правил")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $editing) { draft in
      RoutingProfileNameEditor(client: client, draft: draft)
    }
    .confirmationDialog("Удалить профиль правил?", isPresented: Binding(
      get: { deleting != nil }, set: { if !$0 { deleting = nil } }
    ), presenting: deleting) { profile in
      Button("Удалить \(profile.name)", role: .destructive) {
        Task { await change("delete", id: profile.id) }
      }
    }
  }

  private func change(_ operation: String, id: String) async {
    message = nil
    do { try await client.changeRoutingProfile(operation, id: id) }
    catch { message = error.localizedDescription }
  }
}

private struct ProfileNameDraft: Identifiable {
  let id = UUID()
  var profile: RoutingProfile?
}

private struct RoutingProfileNameEditor: View {
  @ObservedObject var client: Client
  @Environment(\.dismiss) private var dismiss
  let draft: ProfileNameDraft
  @State private var name: String
  @State private var message: String?

  init(client: Client, draft: ProfileNameDraft) {
    self.client = client
    self.draft = draft
    _name = State(initialValue: draft.profile?.name ?? "")
  }

  var body: some View {
    NavigationStack {
      Form {
        TextField("Название профиля", text: $name)
          .accessibilityIdentifier("routing-profile-name")
        if let message { Text(message).foregroundStyle(HyStyle.failure) }
      }
      .hyList()
      .navigationTitle(draft.profile == nil ? "Новый профиль" : "Название профиля")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("Сохранить") { Task { await save() } }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || client.busy)
        }
      }
    }
    .interactiveDismissDisabled(client.busy)
  }

  private func save() async {
    do {
      try await client.changeRoutingProfile(draft.profile == nil ? "copy" : "rename",
                                            id: draft.profile?.id ?? "", name: name)
      dismiss()
    } catch { message = error.localizedDescription }
  }
}

struct RouteCheckPage: View {
  @ObservedObject var client: Client
  @State private var address = ""
  @State private var ip = ""
  @State private var transport = "tcp"
  @State private var result: CheckedRoute?
  @State private var message: String?
  @State private var checking = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        TextField("Сайт, ссылка или IP", text: $address)
          .textContentType(.URL).keyboardType(.URL)
          .textInputAutocapitalization(.never).autocorrectionDisabled()
          .accessibilityIdentifier("route-check-address")
          .hyCard(padding: 12)
        DisclosureGroup("IP и протокол") {
          VStack(spacing: 8) {
            TextField("IP сайта, если известен", text: $ip)
              .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            Picker("Протокол", selection: $transport) {
              Text("TCP").tag("tcp")
              Text("UDP").tag("udp")
            }
            .pickerStyle(.segmented)
          }
          .padding(.top, 8)
        }
        .hyCard(padding: 12)
        Button("Проверить") { Task { await check() } }
          .buttonStyle(HyButton())
          .disabled(checking || address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("route-check-submit")
        if let message { Text(message).foregroundStyle(HyStyle.failure) }
        if let result {
          VStack(alignment: .leading, spacing: 8) {
            Label(result.action.label, systemImage: result.action.symbol)
              .font(.title3.bold()).accessibilityIdentifier("route-check-action")
            Text(result.target).font(.subheadline).foregroundStyle(HyStyle.muted)
            if !result.rule.isEmpty {
              Text(result.rule == "default" ? "Правило по умолчанию" : result.rule)
                .accessibilityIdentifier("route-check-rule")
            }
            let chain = result.chain ?? []
            ForEach(Array(chain.enumerated()), id: \.offset) { hop in
              Text(chain.count == 1
                   ? client.state.profileTitle(hop.element)
                   : "\(hop.offset + 1). \(client.state.profileTitle(hop.element))")
            }
            ForEach(result.notes ?? [], id: \.self) { Text($0).font(.footnote).foregroundStyle(HyStyle.muted) }
          }
          .hyCard(padding: 14)
        }
      }
      .disabled(checking)
      .padding(16)
    }
    .hyScreen()
    .navigationTitle("Проверить адрес")
    .navigationBarTitleDisplayMode(.inline)
    .onChange(of: address) { _ in clear() }
    .onChange(of: ip) { _ in clear() }
    .onChange(of: transport) { _ in clear() }
  }

  private func clear() {
    result = nil
    message = nil
  }

  private func check() async {
    clear()
    checking = true
    defer { checking = false }
    do { result = try await client.checkRoute(address, ip: ip, transport: transport) }
    catch { message = error.localizedDescription }
  }
}

struct SubscriptionDetails: View {
  let item: Subscription

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      if let limit = item.limitBytes, limit > 0, let used = item.usedBytes {
        Text("\(bytes(used)) из \(bytes(limit))").accessibilityIdentifier("subscription-traffic")
        ProgressView(value: min(Double(used) / Double(limit), 1))
      } else if let used = item.usedBytes {
        Text(item.limitBytes == 0 ? "Трафик \(bytes(used)) · без лимита" : "Трафик \(bytes(used))")
          .accessibilityIdentifier("subscription-traffic")
      } else if let limit = item.limitBytes {
        Text(limit == 0 ? "Без лимита трафика" : "Лимит \(bytes(limit))")
      }
      if let expiry = date(item.expiresAt) {
        let label = expiry < Date.now ? "Истекла" : "Действует до"
        Text("\(label) \(expiry.formatted(date: .abbreviated, time: .omitted))")
      }
      if item.canRefresh == true {
        if item.refreshFailed == true {
          Label("Обновление не удалось", systemImage: "exclamationmark.circle")
            .foregroundStyle(HyStyle.failure)
          if let attempted = date(item.attemptedAt) {
            Text("Попытка \(attempted.formatted(date: .abbreviated, time: .shortened))")
          }
        }
        if let updated = date(item.refreshedAt) {
          Text("Обновлена \(updated.formatted(date: .abbreviated, time: .shortened))")
        }
      }
    }
    .font(.subheadline)
    .foregroundStyle(HyStyle.muted)
    .hyCard(padding: 12)
  }

  private func date(_ epoch: Int64?) -> Date? {
    guard let epoch, epoch > 0 else { return nil }
    return Date(timeIntervalSince1970: TimeInterval(epoch))
  }

  private func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
  }
}
