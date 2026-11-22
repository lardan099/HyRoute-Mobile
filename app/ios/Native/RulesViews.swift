import SwiftUI

struct RulesPage: View {
  @ObservedObject var client: Client
  @State private var editing: RuleDraft?
  @State private var editingChain = false

  private var routing: Routing { client.state.settings.routing }

  var body: some View {
    List {
      Section {
        Picker("Всё остальное", selection: Binding(
          get: { routing.defaultAction },
          set: { action in mutate { $0.defaultAction = action } }
        )) {
          ForEach(RouteAction.allCases) { Text($0.label).tag($0) }
        }
      }
      Section("Правила") {
        ForEach(routing.rules.indices, id: \.self) { index in
          let rule = routing.rules[index]
          Button { editing = RuleDraft(index: index, rule: rule) } label: {
            Label {
              VStack(alignment: .leading, spacing: 4) {
                Text(rule.title).lineLimit(2)
                Text(rule.profile.map(profileName) ?? rule.action.label)
                  .font(.subheadline).foregroundStyle(.secondary)
              }
            } icon: {
              Image(systemName: rule.action.symbol).foregroundStyle(Color.accentColor)
            }
          }
          .buttonStyle(.plain)
        }
        .onDelete { indices in mutate { $0.rules.remove(atOffsets: indices) } }
        .onMove { indices, offset in mutate { $0.rules.move(fromOffsets: indices, toOffset: offset) } }
        Button { editing = RuleDraft(rule: RouteRule()) } label: { Label("Добавить правило", systemImage: "plus.circle") }
      }
      Section("Профили и базы") {
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
            Image(systemName: "link")
          }
        }
        .buttonStyle(.plain)
        .disabled(client.state.profiles.count < 2)
        NavigationLink {
          GeoCatalog(client: client)
        } label: {
          Label("GeoSite и GeoIP", systemImage: "globe.europe.africa")
        }
      }
    }
    .disabled(client.busy)
    .navigationTitle("Правила")
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

  init(client: Client, draft: RuleDraft) {
    self.client = client
    self.draft = draft
    _destination = State(initialValue: draft.rule.domains?.joined(separator: "\n") ?? "")
    _ports = State(initialValue: draft.rule.ports ?? "")
    _network = State(initialValue: draft.rule.protocol ?? "")
    _action = State(initialValue: draft.rule.action)
    _profile = State(initialValue: draft.rule.profile ?? "")
  }

  private var domains: [String] {
    destination.components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  var body: some View {
    NavigationStack {
      Form {
        Section("Назначение") {
          TextEditor(text: $destination)
            .frame(minHeight: 85)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .accessibilityLabel("Домены, IP и категории по одному на строку")
          Button { choosingGeo = true } label: { Label("Выбрать GeoSite или GeoIP", systemImage: "globe.europe.africa") }
        }
        Section {
          TextField("Порт или диапазон", text: $ports)
            .keyboardType(.numbersAndPunctuation)
          Picker("Протокол", selection: $network) {
            Text("Любой").tag("")
            Text("TCP").tag("tcp")
            Text("UDP").tag("udp")
          }
          Picker("Действие", selection: $action) {
            ForEach(RouteAction.allCases) { Text($0.label).tag($0) }
          }
          if action == .tunnel {
            Picker("Профиль", selection: $profile) {
              Text("Основной профиль").tag("")
              ForEach(client.state.profiles) { Text($0.title).tag($0.id) }
              if !profile.isEmpty && !client.state.profiles.contains(where: { $0.id == profile }) {
                Text("Профиль недоступен").tag(profile)
              }
            }
          }
        }
      }
      .navigationTitle(draft.index == nil ? "Новое правило" : "Правило")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(client.busy) }
        ToolbarItem(placement: .confirmationAction) {
          Button("Сохранить") { Task { await save() } }
            .disabled(client.busy || (domains.isEmpty && ports.trimmingCharacters(in: .whitespaces).isEmpty && network.isEmpty))
        }
      }
      .sheet(isPresented: $choosingGeo) {
        NavigationStack {
          GeoCatalog(client: client, select: { tag in
            if !domains.contains(tag) { destination = (domains + [tag]).joined(separator: "\n") }
            choosingGeo = false
          })
          .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { choosingGeo = false } } }
        }
      }
    }
    .interactiveDismissDisabled(client.busy)
  }

  private func save() async {
    var routing = client.state.settings.routing
    let port = ports.trimmingCharacters(in: .whitespacesAndNewlines)
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
    if await client.saveRouting(routing) { dismiss() }
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
      ForEach(tags.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, id: \.self) { tag in
        if let select {
          Button(tag) { select(tag) }
        } else {
          Text(tag)
        }
      }
    }
    .navigationTitle("GeoSite и GeoIP")
    .navigationBarTitleDisplayMode(.inline)
    .searchable(text: $query, prompt: "Найти категорию")
    .task { await load(update: false) }
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
