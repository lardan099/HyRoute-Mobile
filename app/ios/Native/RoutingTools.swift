import SwiftUI

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
        } else {
          Text("Нет даты обновления")
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
