import SwiftUI
import UniformTypeIdentifiers

struct RulesPage: View {
  @ObservedObject var client: Client
  @Environment(\.dynamicTypeSize) private var typeSize
  @State private var editing: RuleDraft?
  @State private var editingChain: Bool
  @State private var pane: Pane
  @State private var editMode = EditMode.inactive

  private enum Pane: String, CaseIterable, Hashable { case rules = "Список", settings = "Настройки" }

  init(client: Client, preview: String? = nil) {
    self.client = client
    _pane = State(initialValue: preview == "routing" || preview == "chains" ? .settings : .rules)
    _editingChain = State(initialValue: preview == "chains")
  }

  private var routing: Routing { client.state.settings.routing }
  private var available: Set<String> { Set(client.state.profiles.map(\.id)) }
  private var brokenRules: [Int] { routing.unavailableRuleIndices(available: available) }
  private var brokenChains: [String] { routing.unavailableChainExits(available: available) }

  var body: some View {
    VStack(spacing: 0) {
      sectionPicker
      if pane == .rules { ruleList }
      else { settings }
    }
    .disabled(client.busy)
    .hyScreen()
    .navigationTitle("Правила")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      if pane == .rules {
        ToolbarItem(placement: .primaryAction) {
          Button { editing = RuleDraft(rule: RouteRule()) } label: {
            Label("Добавить правило", systemImage: "plus")
          }
          .accessibilityIdentifier("rules-add")
        }
        if !routing.rules.isEmpty {
          ToolbarItem(placement: .primaryAction) { EditButton().accessibilityIdentifier("rules-edit") }
        }
      }
    }
    .environment(\.editMode, $editMode)
    .onChange(of: pane) { _ in editMode = .inactive }
    .sheet(item: $editing) { RuleEditor(client: client, draft: $0) }
    .sheet(isPresented: $editingChain) { ChainEditor(client: client) }
  }

  private var sectionPicker: some View {
    Picker("Раздел правил", selection: $pane) {
      ForEach(Pane.allCases, id: \.self) { item in Text(item.rawValue).tag(item) }
    }
    .pickerStyle(.segmented)
    .accessibilityIdentifier("rules-sections")
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
  }

  private var ruleTools: some View {
    VStack(alignment: .leading, spacing: 8) {
      ViewThatFits(in: .horizontal) {
        HStack { ruleSetLink.fixedSize(); routeCheckLink.fixedSize() }
        VStack(alignment: .leading) { ruleSetLink; routeCheckLink }
      }
      if !brokenRules.isEmpty || !brokenChains.isEmpty {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 10) { repairLabel.fixedSize(); Spacer(minLength: 0); repairMenu.fixedSize() }
          VStack(alignment: .leading, spacing: 0) { repairLabel; repairMenu }
        }
        .padding(.horizontal, 12)
        .background(HyStyle.surface, in: RoundedRectangle(cornerRadius: 10))
      }
    }
    .padding(.vertical, 8)
  }

  private var repairLabel: some View {
    Label("Недоступные профили · \(brokenRules.count + brokenChains.count)", systemImage: "exclamationmark.circle")
      .font(.subheadline.weight(.semibold)).foregroundStyle(HyStyle.failure)
      .fixedSize(horizontal: false, vertical: true)
      .padding(.vertical, 4)
  }

  private var repairMenu: some View {
    Menu("Исправить") {
      ForEach(brokenRules, id: \.self) { index in
        Button(routing.rules[index].title) { editRule(index) }
      }
      if !brokenChains.isEmpty {
        Button("Цепочки профилей") { editingChain = true }
      }
    }
    .font(.subheadline.weight(.semibold))
    .accessibilityIdentifier("rules-repair")
    .frame(minHeight: 44)
  }

  private var ruleSetLink: some View {
    NavigationLink {
      RoutingProfilesPage(client: client)
    } label: {
      Label(client.state.activeRuleSet?.name ?? "Профили правил", systemImage: "square.stack")
        .lineLimit(2)
    }
    .buttonStyle(.bordered)
    .accessibilityIdentifier("rule-sets")
  }

  private var routeCheckLink: some View {
    NavigationLink {
      RouteCheckPage(client: client)
    } label: {
      Label("Проверить адрес", systemImage: "magnifyingglass")
    }
    .buttonStyle(.bordered)
    .accessibilityIdentifier("route-check")
  }

  private var ruleList: some View {
    List {
      ruleTools
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .listRowBackground(HyStyle.canvas)
        .listRowSeparator(.hidden)
      if routing.rules.isEmpty {
        Button { editing = RuleDraft(rule: RouteRule()) } label: {
          HyRow(title: "Добавить первое правило", symbol: "plus", disclosure: false)
        }
        .buttonStyle(.plain)
        .listRowBackground(HyStyle.canvas)
      }
      ForEach(routing.rules.indices, id: \.self) { index in
        let rule = routing.rules[index]
        let unavailable = rule.hasUnavailableProfile(available: available)
        Button { editRule(index) } label: {
          HStack(spacing: 10) {
            HyIcon(symbol: unavailable ? "exclamationmark.triangle" : rule.action.symbol, size: 32)
            VStack(alignment: .leading, spacing: 3) {
              Text(rule.title).font(.body.weight(.semibold)).foregroundStyle(HyStyle.ink)
                .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)
                .fixedSize(horizontal: false, vertical: true)
              Text(rule.profile.map(client.state.profileTitle) ?? rule.action.label)
                .font(.subheadline).foregroundStyle(unavailable ? HyStyle.failure : HyStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
              .font(.caption.weight(.semibold)).foregroundStyle(HyStyle.muted)
              .accessibilityHidden(true)
          }
          .frame(minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("rule-row-\(index)")
        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
        .listRowBackground(HyStyle.canvas)
        .listRowSeparatorTint(HyStyle.stroke)
      }
      .onDelete { indices in mutate { $0.rules.remove(atOffsets: indices) } }
      .onMove { indices, offset in mutate { $0.rules.move(fromOffsets: indices, toOffset: offset) } }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
  }

  private var settings: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        ruleTools
        Menu {
          ForEach(RouteAction.allCases) { action in
            Button { mutate { $0.defaultAction = action } } label: {
              Label(action.label, systemImage: action == routing.defaultAction ? "checkmark" : action.symbol)
            }
          }
        } label: {
          HyRow(title: "Трафик без правила", symbol: routing.defaultAction.symbol, detail: routing.defaultAction.label)
            .hyCard(padding: 12)
        }
        .buttonStyle(.plain)

        Button { editingChain = true } label: {
          HyRow(title: "Цепочки профилей", symbol: "link", detail: chainSummary)
            .hyCard(padding: 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("rules-chains")
        .disabled(client.state.chainProfiles.count < 2 && routing.viaProfiles.isEmpty)

        NavigationLink {
          GeoCatalog(client: client)
        } label: {
          HyRow(title: "Базы правил", symbol: "globe.europe.africa", detail: "GeoSite и GeoIP")
            .hyCard(padding: 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("rules-geo")

        NavigationLink {
          SplitDNSPage(client: client)
        } label: {
          HyRow(title: "Раздельный DNS", symbol: "arrow.triangle.branch",
                detail: client.state.settings.splitDNS == nil ? "Выключен" : "Включён")
            .hyCard(padding: 12)
        }
        .buttonStyle(.plain)
      }
      .padding(16)
    }
  }

  private var chainSummary: String {
    if !brokenChains.isEmpty { return "Недоступных связей: \(brokenChains.count)" }
    if routing.viaProfiles.isEmpty { return client.state.chainProfiles.count < 2 ? "Нужно два VPN-профиля" : "Цепочки не настроены" }
    return "Связей: \(routing.viaProfiles.count)"
  }

  private func editRule(_ index: Int) {
    guard routing.rules.indices.contains(index) else { return }
    editing = RuleDraft(index: index, rule: routing.rules[index])
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
  @State private var conditions: [RuleDomainCondition: String]
  @State private var expandedConditions: Set<RuleDomainCondition>
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
    let stored = draft.rule.domains ?? []
    let values = Dictionary(uniqueKeysWithValues: RuleDomainCondition.allCases.map { kind in
      (kind, stored.compactMap { kind.value(from: $0) }.joined(separator: "\n"))
    })
    _conditions = State(initialValue: values)
    _expandedConditions = State(initialValue: Set(values.keys.filter { values[$0]?.isEmpty == false }))
    _destination = State(initialValue: stored.filter { item in
      !RuleDomainCondition.allCases.contains { $0.value(from: item) != nil }
    }.joined(separator: "\n"))
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
              .accessibilityIdentifier("rule-destination")
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
            ForEach(RuleDomainCondition.allCases, id: \.self) { kind in
              conditionEditor(kind)
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
              .accessibilityIdentifier("rule-action-\(option.rawValue)")
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
        }
        .padding(16)
      }
      .scrollDismissesKeyboard(.interactively)
      .hyScreen()
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          if let error {
            Text(error).font(.subheadline).foregroundStyle(HyStyle.failure)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("rule-error")
          }
          Button("Сохранить правило") { Task { await save() } }
            .buttonStyle(HyButton())
            .disabled(client.busy)
            .accessibilityIdentifier("rule-save")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(HyStyle.canvas)
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

  private func conditionEditor(_ kind: RuleDomainCondition) -> some View {
    let expanded = Binding(get: { expandedConditions.contains(kind) }, set: { show in
      if show { expandedConditions.insert(kind) } else { expandedConditions.remove(kind) }
    })
    let input = Binding(get: { conditions[kind, default: ""] }, set: {
      conditions[kind] = $0
      error = nil
    })
    return DisclosureGroup(kind.label, isExpanded: expanded) {
      VStack(alignment: .leading, spacing: 6) {
        TextField(kind.label, text: input, prompt: Text(kind.example), axis: .vertical)
          .accessibilityLabel(kind.label)
          .textInputAutocapitalization(.never)
          .autocorrectionDisabled()
          .lineLimit(1...4)
          .padding(10)
          .background(HyStyle.inset, in: RoundedRectangle(cornerRadius: 10))
        Text(kind.exampleMatch).font(.footnote).foregroundStyle(HyStyle.muted)
      }
      .padding(.top, 6)
    }
    .frame(minHeight: 44)
    .accessibilityIdentifier("rule-condition-\(kind)")
  }

  private func save() async {
    var routing = client.state.settings.routing
    var destinations = domains
    for kind in RuleDomainCondition.allCases {
      guard let patterns = kind.patterns(conditions[kind, default: ""]) else {
        error = "Проверьте условие «\(kind.label)». Пример \(kind.example)."
        return
      }
      destinations.append(contentsOf: patterns)
    }
    let savedDomains = ruleDestinations(destinations.joined(separator: "\n"))
    let port = ports.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !savedDomains.isEmpty || !port.isEmpty || !network.isEmpty else {
      error = "Укажите сайт, IP или условие для домена."
      return
    }
    error = nil
    let next = RouteRule(
      action: action, domains: savedDomains.isEmpty ? nil : savedDomains,
      ports: port.isEmpty ? nil : port, protocol: network.isEmpty ? nil : network,
      profile: action == .tunnel && !profile.isEmpty ? profile : nil,
      enabled: draft.rule.enabled
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

private struct ChainDraft: Hashable {
  let exit: String
  let entry: String

  var isNew: Bool { exit.isEmpty }
}

private struct ChainEditor: View {
  @ObservedObject var client: Client
  @Environment(\.dismiss) private var dismiss
  @State private var removing: String?
  @State private var error: String?

  private var routing: Routing { client.state.settings.routing }
  private var unavailable: Set<String> {
    Set(routing.unavailableChainExits(available: Set(client.state.profiles.map(\.id))))
  }
  private var drafts: [ChainDraft] {
    routing.viaProfiles.map { ChainDraft(exit: $0.key, entry: $0.value) }
      .sorted { client.state.profileTitle($0.exit).localizedStandardCompare(client.state.profileTitle($1.exit)) == .orderedAscending }
  }

  var body: some View {
    let broken = unavailable
    let all = drafts
    let invalid = all.filter { broken.contains($0.exit) }
    let saved = all.filter { !broken.contains($0.exit) }
    let hasFreeExit = client.state.chainProfiles.contains { routing.viaProfiles[$0.id] == nil }
    NavigationStack {
      List {
        Section {
          NavigationLink(value: ChainDraft(exit: "", entry: "")) {
            Label("Новая цепочка", systemImage: "plus")
              .font(.body.weight(.semibold))
              .frame(minHeight: 44)
          }
          .accessibilityIdentifier("new-chain")
          .disabled(!hasFreeExit || client.state.profiles.count < 2)
          .listRowBackground(HyStyle.surface)
        } footer: {
          if client.state.profiles.count < 2 { Text("Для цепочки нужны два VPN-профиля.") }
          else if !hasFreeExit { Text("У каждого выходного профиля уже есть цепочка.") }
        }
        if let error {
          Text(error).foregroundStyle(HyStyle.failure)
            .accessibilityIdentifier("chain-save-error")
        }
        if !saved.isEmpty {
          Section("Сохранённые связи") {
            ForEach(saved, id: \.exit) { draft in
              NavigationLink(value: draft) {
                HyRow(title: client.state.profileTitle(draft.exit), symbol: "link",
                      detail: "Через \(client.state.profileTitle(draft.entry))", disclosure: false)
              }
              .accessibilityIdentifier("saved-chain-\(draft.exit)")
              .swipeActions(allowsFullSwipe: false) {
                Button("Удалить", role: .destructive) { removing = draft.exit }
              }
              .listRowBackground(HyStyle.surface)
            }
          }
        }
        if !invalid.isEmpty {
          Section("Недоступные связи") {
            ForEach(invalid, id: \.exit) { draft in
              VStack(alignment: .leading, spacing: 4) {
                Text(client.state.profileTitle(draft.exit)).font(.headline)
                Text("Через \(client.state.profileTitle(draft.entry))")
                  .font(.subheadline).foregroundStyle(HyStyle.failure)
                if client.state.chainProfiles.contains(where: { $0.id == draft.exit }) {
                  NavigationLink("Заменить промежуточный профиль", value: draft)
                    .frame(minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("replace-broken-chain-\(draft.exit)")
                }
                Button("Удалить связь", role: .destructive) { removing = draft.exit }
                  .buttonStyle(.borderless)
                  .frame(minHeight: 44, alignment: .leading)
                  .accessibilityIdentifier("remove-broken-chain-\(draft.exit)")
              }
              .padding(.vertical, 5)
              .listRowBackground(HyStyle.surface)
            }
          }
        }
      }
      .hyList()
      .navigationTitle("Цепочки")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: ChainDraft.self) { ChainForm(client: client, draft: $0) }
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() }.disabled(client.busy) }
      }
      .confirmationDialog("Удалить связь?", isPresented: Binding(
        get: { removing != nil }, set: { if !$0 { removing = nil } }
      ), titleVisibility: .visible, presenting: removing) { id in
        Button("Удалить", role: .destructive) { Task { await removeLink(id) } }
      }
      .disabled(client.busy)
    }
  }

  private func removeLink(_ id: String) async {
    error = nil
    do { try await client.saveChain(exit: id, entry: nil) }
    catch { self.error = error.localizedDescription }
  }
}

private struct ChainForm: View {
  @ObservedObject var client: Client
  let draft: ChainDraft
  @Environment(\.dismiss) private var dismiss
  @State private var exit: String
  @State private var entry: String
  @State private var picker: Endpoint?
  @State private var confirmingDelete = false
  @State private var error: String?

  private enum Endpoint: String, Identifiable {
    case entry, exit

    var id: Self { self }
    var title: String { self == .entry ? "Первый профиль или группа" : "Выходной профиль" }
  }

  init(client: Client, draft: ChainDraft) {
    self.client = client
    self.draft = draft
    _exit = State(initialValue: draft.exit)
    _entry = State(initialValue: draft.entry)
  }

  private var canSave: Bool {
    !client.busy && entry != exit && !entry.isEmpty && !exit.isEmpty &&
      client.state.profiles.contains { $0.id == entry } &&
      client.state.chainProfiles.contains { $0.id == exit } &&
      (draft.isNew || entry != draft.entry)
  }

  var body: some View {
    List {
      Section {
        endpointRow(.entry, value: entry)
        if draft.isNew {
          endpointRow(.exit, value: exit)
        } else {
          HyRow(title: "2. Выходной профиль", symbol: "arrow.up.right",
                detail: client.state.profileTitle(exit), disclosure: false)
        }
      } footer: {
        Text("Трафик сначала идёт через первый профиль, затем через выходной.")
      }
      .listRowBackground(HyStyle.surface)
      if let error {
        Text(error).foregroundStyle(HyStyle.failure)
          .accessibilityIdentifier("chain-save-error")
          .listRowBackground(HyStyle.surface)
      }
      if !draft.isNew {
        Button("Удалить связь", role: .destructive) { confirmingDelete = true }
          .accessibilityIdentifier("remove-saved-chain")
          .listRowBackground(HyStyle.surface)
      }
    }
    .hyList()
    .navigationTitle(draft.isNew ? "Новая цепочка" : "Изменить цепочку")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .confirmationAction) {
        Button("Сохранить") { Task { await save(entry: entry) } }
          .disabled(!canSave)
          .accessibilityIdentifier("chain-save")
      }
    }
    .sheet(item: $picker) { endpoint in
      let candidates = endpoint == .entry
        ? client.state.profiles.filter { $0.id != exit }
        : client.state.chainProfiles.filter { $0.id != entry && client.state.settings.routing.viaProfiles[$0.id] == nil }
      ProfilePicker(client: client, selected: endpoint == .entry ? entry : exit, select: { id in
        if endpoint == .entry { entry = id } else { exit = id }
        error = nil
      }, candidates: candidates, pickerTitle: endpoint.title, offerMainProfile: false)
    }
    .confirmationDialog("Удалить связь?", isPresented: $confirmingDelete, titleVisibility: .visible) {
      Button("Удалить", role: .destructive) { Task { await save(entry: nil) } }
    }
    .disabled(client.busy)
  }

  private func endpointRow(_ endpoint: Endpoint, value: String) -> some View {
    Button { picker = endpoint } label: {
      HyRow(title: "\(endpoint == .entry ? 1 : 2). \(endpoint.title)",
            symbol: endpoint == .entry ? "arrow.right" : "arrow.up.right",
            detail: value.isEmpty ? "Выбрать" : client.state.profileTitle(value))
    }
    .buttonStyle(.plain)
    .accessibilityIdentifier("chain-\(endpoint.rawValue)")
    .accessibilityValue(value.isEmpty ? "Не выбран" : client.state.profileTitle(value))
  }

  private func save(entry: String?) async {
    error = nil
    do {
      try await client.saveChain(exit: exit, entry: entry)
      dismiss()
    } catch { self.error = error.localizedDescription }
  }
}

private enum GeoDatabase: String, CaseIterable, Identifiable {
  case site, ip

  var id: Self { self }
  var kind: String { self == .site ? "geosite" : "geoip" }
  var filename: String { kind + ".dat" }
}

private struct GeoCatalog: View {
  @ObservedObject var client: Client
  var select: ((String) -> Void)?
  @State private var tags: [String] = []
  @State private var query = ""
  @State private var busy = false
  @State private var error: String?
  @State private var sources: [String: String] = [:]
  @State private var importKind: GeoDatabase?
  @State private var importingFile = false
  @State private var editingSource: GeoDatabase?

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
        if select == nil { Text("Базы и подписки по ссылкам проверяются раз в сутки.") }
      }
      if select == nil {
        Section("Источники") {
          ForEach(GeoDatabase.allCases) { kind in
            Menu {
              Button {
                importKind = kind
                importingFile = true
              } label: { Label("Импортировать файл", systemImage: "doc") }
              Button { editingSource = kind } label: { Label("Указать ссылку", systemImage: "link") }
            } label: {
              HyRow(title: kind.filename, symbol: "doc", detail: sourceLabel(kind))
            }
            .disabled(busy)
            .accessibilityIdentifier("geo-source-\(kind.rawValue)")
          }
        }
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
    .fileImporter(isPresented: $importingFile, allowedContentTypes: [.data]) { result in
      guard let kind = importKind else { return }
      switch result {
      case .success(let url):
        Task {
          busy = true
          let installed = await client.importGeoFile(kind.kind, file: url)
          busy = false
          if installed { await load(update: false) }
          else { error = "Не удалось импортировать \(kind.filename). Проверьте тип файла." }
        }
      case .failure:
        error = "Не удалось открыть файл базы."
      }
    }
    .sheet(item: $editingSource, onDismiss: { Task { await load(update: false) } }) { kind in
      GeoSourceEditor(client: client, database: kind, source: sources[kind.rawValue] ?? "")
    }
  }

  private func sourceLabel(_ kind: GeoDatabase) -> String {
    switch sources[kind.rawValue] ?? "" {
    case "": return "runetfreedom"
    case "file": return "Импортированный файл"
    default: return "Своя ссылка HTTPS"
    }
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
      if select == nil { sources = try await client.geoSources() }
    } catch {
      self.error = update ? "Не удалось обновить базы. Проверьте источник и наличие используемых категорий." : "Не удалось прочитать базы правил."
    }
  }
}

private struct GeoSourceEditor: View {
  @ObservedObject var client: Client
  let database: GeoDatabase
  @Environment(\.dismiss) private var dismiss
  @State private var address: String
  @State private var error: String?
  @State private var busy = false

  init(client: Client, database: GeoDatabase, source: String) {
    self.client = client
    self.database = database
    _address = State(initialValue: source == "file" ? "" : source)
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Ссылка на файл") {
          TextField("https://…", text: $address)
            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityIdentifier("geo-source-address")
          if let error { Text(error).foregroundStyle(HyStyle.failure) }
          Button("Сохранить и скачать") { Task { await save(address) } }
            .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          Button("Вернуть runetfreedom") { Task { await save("") } }
        }
      }
      .hyList()
      .disabled(busy)
      .navigationTitle(database.filename)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
    }
    .interactiveDismissDisabled(busy)
  }

  private func save(_ source: String) async {
    busy = true
    defer { busy = false }
    guard await client.saveGeoSource(database.kind, address: source) else {
      error = "Укажите ссылку HTTPS на файл базы."
      return
    }
    do {
      _ = try await client.geoTags(update: true)
      dismiss()
    } catch {
      self.error = "Источник сохранён. Скачать базы пока не удалось."
    }
  }
}
