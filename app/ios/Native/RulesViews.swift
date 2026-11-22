import SwiftUI

struct RulesPage: View {
  @ObservedObject var client: Client
  @State private var editing: RuleDraft?
  @State private var editingChain = false

  private var routing: Routing { client.state.settings.routing }

  var body: some View {
    List {
      Section {
        Button { editing = RuleDraft(rule: RouteRule()) } label: { Label("Добавить правило", systemImage: "plus") }
          .buttonStyle(HyButton())
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
      }
      if !routing.rules.isEmpty {
        Section {
          ForEach(routing.rules.indices, id: \.self) { index in
            let rule = routing.rules[index]
            Button { editing = RuleDraft(index: index, rule: rule) } label: {
              HyRow(title: rule.title, symbol: rule.action.symbol,
                    detail: rule.profile.map(profileName) ?? rule.action.label)
                .lineLimit(2)
            }
            .buttonStyle(.plain)
          }
          .onDelete { indices in mutate { $0.rules.remove(atOffsets: indices) } }
          .onMove { indices, offset in mutate { $0.rules.move(fromOffsets: indices, toOffset: offset) } }
        } header: {
          Text("Правила по порядку")
        } footer: {
          if routing.rules.count > 1 { Text("Срабатывает первое подходящее правило сверху.") }
        }
      }
      Section("Остальной трафик и профили") {
        Picker("Всё остальное", selection: Binding(
          get: { routing.defaultAction },
          set: { action in mutate { $0.defaultAction = action } }
        )) {
          ForEach(RouteAction.allCases) { Text($0.label).tag($0) }
        }
        Button { editingChain = true } label: {
          Label {
            VStack(alignment: .leading, spacing: 4) {
              Text("Профиль через профиль")
              if routing.viaProfiles.isEmpty {
                Text(client.state.profiles.count < 2 ? "Нужно два VPN-профиля" : "Цепочки не настроены")
                  .font(.subheadline).foregroundStyle(.secondary)
              } else {
                ForEach(routing.viaProfiles.keys.sorted(), id: \.self) { exit in
                  if let entry = routing.viaProfiles[exit] {
                    Text("\(profileName(exit)) через \(profileName(entry))")
                      .font(.subheadline).foregroundStyle(.secondary)
                  }
                }
              }
            }
          } icon: {
            HyIcon(symbol: "link")
          }
        }
        .buttonStyle(.plain)
        .disabled(client.state.profiles.count < 2)
        NavigationLink {
          GeoCatalog(client: client)
        } label: {
          HyRow(title: "Базы правил", symbol: "globe.europe.africa", detail: "GeoSite и GeoIP", disclosure: false)
        }
      }
    }
    .disabled(client.busy)
    .hyList()
    .navigationTitle("Правила")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if !routing.rules.isEmpty { ToolbarItem(placement: .primaryAction) { EditButton() } }
    }
    .sheet(item: $editing) { RuleEditor(client: client, draft: $0) }
    .sheet(isPresented: $editingChain) { ChainEditor(client: client) }
  }

  private func profileName(_ id: String) -> String {
    client.state.profiles.first { $0.id == id }?.title ?? "Профиль недоступен"
  }

  private func mutate(_ edit: (inout Routing) -> Void) {
    var next = routing
    edit(&next)
    Task { _ = await client.saveRouting(next) }
  }
}

private struct RuleDraft: Identifiable {
  let id = UUID()
  var index: Int?
  let rule: RouteRule
}

private struct RuleEditor: View {
  @ObservedObject var client: Client
  let draft: RuleDraft
  @Environment(\.dismiss) private var dismiss
  @State private var destination: String
  @State private var ports: String
  @State private var network: String
  @State private var action: RouteAction
  @State private var profile: String
  @State private var choosingGeo = false
  @State private var choosingProfile = false
  @State private var advanced: Bool
  @State private var error: String?

  init(client: Client, draft: RuleDraft) {
    self.client = client
    self.draft = draft
    _destination = State(initialValue: draft.rule.domains?.joined(separator: "\n") ?? "")
    _ports = State(initialValue: draft.rule.ports ?? "")
    _network = State(initialValue: draft.rule.protocol ?? "")
    _action = State(initialValue: draft.rule.action)
    _profile = State(initialValue: draft.rule.profile ?? "")
    _advanced = State(initialValue: !(draft.rule.ports?.isEmpty ?? true) || !(draft.rule.protocol?.isEmpty ?? true))
  }

  private var domains: [String] {
    ruleDestinations(destination)
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 10) {
            HyHeading(text: "Что направить")
            TextField("Сайт, ссылка или IP", text: $destination, axis: .vertical)
              .lineLimit(2...5)
              .textInputAutocapitalization(.never).autocorrectionDisabled()
              .onChange(of: destination) { _ in error = nil }
              .padding(12)
              .background(HyStyle.inset, in: RoundedRectangle(cornerRadius: 10))
            if destination.localizedCaseInsensitiveContains("http://") || destination.localizedCaseInsensitiveContains("https://") {
              Text("В правило попадёт \(domains.joined(separator: ", "))")
                .font(.footnote).foregroundStyle(HyStyle.muted)
            }
            ViewThatFits(in: .horizontal) {
              HStack { pasteDestination; geoButton }
              VStack(alignment: .leading) { pasteDestination; geoButton }
            }
          }
          .hyCard()

          VStack(alignment: .leading, spacing: 8) {
            HyHeading(text: "Куда направить")
            ForEach(RouteAction.allCases) { option in
              Button { action = option } label: {
                HStack(spacing: 10) {
                  Image(systemName: option.symbol).frame(width: 22).accessibilityHidden(true)
                  Text(option.label).font(.body.weight(action == option ? .semibold : .regular))
                  Spacer(minLength: 0)
                  if action == option { Image(systemName: "checkmark.circle.fill").accessibilityHidden(true) }
                }
                .foregroundStyle(action == option ? HyStyle.accent : HyStyle.ink)
                .padding(.horizontal, 10)
                .frame(minHeight: 44)
                .background(action == option ? HyStyle.inset : .clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
              .accessibilityAddTraits(action == option ? .isSelected : [])
            }
            if action == .tunnel {
              Divider()
              Button { choosingProfile = true } label: {
                HyRow(title: "VPN-профиль", symbol: "server.rack", detail: profile.isEmpty ? "Основной профиль" :
                  (client.state.profiles.first { $0.id == profile }?.title ?? "Профиль недоступен"))
              }
              .buttonStyle(.plain)
            }
          }
          .hyCard()

          DisclosureGroup("Порт и протокол", isExpanded: $advanced) {
            VStack(spacing: 10) {
              TextField("Порт или диапазон", text: $ports)
                .keyboardType(.numbersAndPunctuation)
                .padding(10)
                .background(HyStyle.inset, in: RoundedRectangle(cornerRadius: 9))
              Picker("Протокол", selection: $network) {
                Text("Любой").tag("")
                Text("TCP").tag("tcp")
                Text("UDP").tag("udp")
              }
              .pickerStyle(.segmented)
            }
            .padding(.top, 10)
          }
          .hyCard()
          if let error { Text(error).foregroundStyle(HyStyle.failure) }
        }
        .padding(16)
      }
      .scrollDismissesKeyboard(.interactively)
      .hyScreen()
      .safeAreaInset(edge: .bottom, spacing: 0) {
        Button("Сохранить правило") { Task { await save() } }
          .buttonStyle(HyButton())
          .disabled(client.busy)
          .padding(16)
          .background(HyStyle.canvas.ignoresSafeArea(edges: .bottom))
      }
      .navigationTitle(draft.index == nil ? "Новое правило" : "Правило")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(client.busy) }
      }
      .sheet(isPresented: $choosingGeo) {
        NavigationStack {
          GeoCatalog(client: client, select: { tag in
            appendDestination(tag)
            choosingGeo = false
          })
          .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { choosingGeo = false } } }
        }
      }
      .sheet(isPresented: $choosingProfile) {
        ProfilePicker(client: client, selected: profile, select: { profile = $0 })
      }
    }
    .interactiveDismissDisabled(client.busy)
  }

  private var pasteDestination: some View {
    PasteButton(payloadType: String.self) { values in
      if let value = values.first { appendDestination(value) }
    }
    .accessibilityLabel("Вставить сайт или ссылку")
  }

  private var geoButton: some View {
    Button { choosingGeo = true } label: { Label("Готовый список", systemImage: "globe.europe.africa") }
      .buttonStyle(.bordered)
  }

  private func save() async {
    var routing = client.state.settings.routing
    let port = ports.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !domains.isEmpty || !port.isEmpty || !network.isEmpty else {
      error = "Введите сайт или выберите готовый список."
      return
    }
    error = nil
    let next = RouteRule(
      action: action, domains: domains.isEmpty ? nil : domains,
      ports: port.isEmpty ? nil : port, protocol: network.isEmpty ? nil : network,
      profile: action == .tunnel && !profile.isEmpty ? profile : nil
    )
    if let index = draft.index {
      guard routing.rules.indices.contains(index) else { return }
      routing.rules[index] = next
    } else {
      routing.rules.append(next)
    }
    if await client.saveRouting(routing, reportError: false) { dismiss() }
    else { error = "Проверьте сайт, IP и порт. Для готового списка нужны базы правил." }
  }

  private func appendDestination(_ value: String) {
    destination = ruleDestinations(destination + "\n" + value).joined(separator: "\n")
    error = nil
  }
}

private struct ChainEditor: View {
  @ObservedObject var client: Client
  @Environment(\.dismiss) private var dismiss
  @State private var exit = ""
  @State private var entry = ""

  var body: some View {
    NavigationStack {
      Form {
        Picker("Выходной профиль", selection: $exit) {
          ForEach(client.state.profiles) { Text($0.title).tag($0.id) }
        }
        .onChange(of: exit) { id in entry = client.state.settings.routing.viaProfiles[id] ?? "" }
        Picker("Через профиль", selection: $entry) {
          Text("Без промежуточного профиля").tag("")
          ForEach(client.state.profiles.filter { $0.id != exit }) { Text($0.title).tag($0.id) }
        }
      }
      .hyList()
      .navigationTitle("Цепочка профилей")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(client.busy) }
        ToolbarItem(placement: .confirmationAction) {
          Button("Сохранить") {
            var routing = client.state.settings.routing
            routing.viaProfiles[exit] = entry.isEmpty ? nil : entry
            Task { if await client.saveRouting(routing) { dismiss() } }
          }
          .disabled(exit.isEmpty || client.busy)
        }
      }
    }
    .onAppear {
      exit = client.state.selected?.id ?? client.state.profiles.first?.id ?? ""
      entry = client.state.settings.routing.viaProfiles[exit] ?? ""
    }
  }
}

private struct GeoCatalog: View {
  @ObservedObject var client: Client
  var select: ((String) -> Void)?
  @State private var tags: [String] = []
  @State private var query = ""
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    List {
      Section {
        Button { Task { await load(update: true) } } label: {
          if busy { ProgressView() }
          else { Label(tags.isEmpty ? "Скачать базы" : "Обновить базы", systemImage: "arrow.down.circle") }
        }
        .disabled(busy)
        if let error { Text(error).foregroundStyle(.secondary) }
      } footer: {
        Text("runetfreedom · около 90 МБ")
      }
      ForEach(tags.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) || name($0).localizedCaseInsensitiveContains(query) }, id: \.self) { tag in
        if let select {
          Button { select(tag) } label: { row(tag) }
        } else {
          row(tag)
        }
      }
    }
    .hyList()
    .navigationTitle(select == nil ? "GeoSite и GeoIP" : "Готовые списки")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $query, prompt: "Найти категорию")
    .task { await load(update: false) }
  }

  private func row(_ tag: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text(name(tag))
      if name(tag) != tag { Text(tag).font(.footnote).foregroundStyle(.secondary) }
    }
  }

  private func name(_ tag: String) -> String {
    switch tag {
    case "geosite:youtube": return "YouTube"
    case "geosite:telegram": return "Telegram"
    case "geosite:discord": return "Discord"
    case "geosite:category-ads-all": return "Реклама"
    case "geoip:ru": return "IP России"
    case "geoip:private": return "Локальная сеть"
    default: return tag
    }
  }

  private func load(update: Bool) async {
    guard !busy else { return }
    busy = true
    error = nil
    defer { busy = false }
    do {
      tags = try await client.geoTags(update: update)
    } catch {
      self.error = update ? "Не удалось скачать базы. Проверьте интернет." : "Не удалось прочитать базы правил."
    }
  }
}
