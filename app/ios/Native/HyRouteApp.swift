import AppIntents
import BackgroundTasks
import NetworkExtension
import SwiftUI
import UIKit

@main
@MainActor
struct HyRouteApp: App {
  @UIApplicationDelegateAdaptor(HyRouteMaintenanceDelegate.self) private var maintenanceDelegate
  @StateObject private var client = Client.shared

  var body: some Scene {
    WindowGroup {
      RootView(client: client)
    }
  }
}

final class HyRouteMaintenanceDelegate: NSObject, UIApplicationDelegate {
  private nonisolated static let identifier = "io.hyroute.hyrouteMobile.maintenance"

  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    #if targetEnvironment(simulator)
    if ProcessInfo.processInfo.environment["HYROUTE_LAYOUT_PREVIEW"] != nil { return true }
    #endif
    BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.identifier, using: nil) { task in
      Self.schedule()
      let maintenance = HyRouteNewMaintenance()
      let work = Task(priority: .utility) {
        var success = false
        do {
          _ = try await NativeCore.shared.load()
          _ = try await NativeCore.shared.autoRefresh(maintenance: maintenance)
          try Task.checkCancellation()
          let snapshot = try await NativeCore.shared.vpnState()
          success = await Task.detached(priority: .utility) {
            HyRouteUpdateGeoWithMaintenance(maintenance, snapshot)
          }.value
        } catch {}
        task.setTaskCompleted(success: success && !Task.isCancelled)
      }
      task.expirationHandler = {
        work.cancel()
        HyRouteCancelMaintenance(maintenance)
      }
    }
    HyRouteShortcuts.updateAppShortcutParameters()
    Self.schedule()
    return true
  }

  private nonisolated static func schedule() {
    BGTaskScheduler.shared.getPendingTaskRequests { requests in
      guard !requests.contains(where: { $0.identifier == Self.identifier }) else { return }
      let request = BGProcessingTaskRequest(identifier: Self.identifier)
      request.requiresNetworkConnectivity = true
      request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 60 * 60)
      try? BGTaskScheduler.shared.submit(request)
    }
  }
}

private struct RootView: View {
  @ObservedObject var client: Client
  @Environment(\.scenePhase) private var scenePhase
  @State private var tab: Tab = .home
  @State private var keyboardVisible = false
  @StateObject private var measurements = SubscriptionMeasurements()

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
        VStack(spacing: 0) {
          ZStack {
            panel(.home) {
              if previewScreen == "vpn-log" { VPNJournalPage(client: client) }
              else if previewScreen == "traffic" { TrafficJournalPage(client: client) }
              else { Dashboard(client: client, measurements: measurements) }
            }
            panel(.subscriptions) {
              if previewScreen == "servers", let id = client.state.subscriptions.first?.id {
                SubscriptionPage(client: client, id: id, measurements: measurements)
              } else {
                SubscriptionsPage(client: client, measurements: measurements)
              }
            }
            panel(.rules) { RulesPage(client: client, preview: previewScreen) }
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          if !keyboardVisible {
            if client.canApplyVPNChanges || client.restartingVPN {
              ViewThatFits(in: .horizontal) {
                HStack { Text("Изменения VPN ждут применения"); Spacer(); reconnectButton }
                VStack(alignment: .leading, spacing: 8) { Text("Изменения VPN ждут применения"); reconnectButton }
              }
              .font(.subheadline)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 16).padding(.vertical, 8)
              .background(HyStyle.canvas)
            }
            if tab != .home, let message = client.vpnFailure {
              HStack(alignment: .top, spacing: 8) {
                Text(message).font(.subheadline).foregroundStyle(HyStyle.failure)
                  .fixedSize(horizontal: false, vertical: true)
                  .frame(maxWidth: .infinity, alignment: .leading)
                Button { client.vpnFailure = nil } label: {
                  Image(systemName: "xmark").frame(width: 44, height: 44)
                    .accessibilityLabel("Закрыть сообщение")
                }
              }
              .padding(.horizontal, 16).padding(.vertical, 8)
              .background(HyStyle.canvas)
            }
            tabBar
          }
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
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(HyStyle.canvas.ignoresSafeArea())
    .tint(HyStyle.accent)
    .task {
      guard !client.ready else { return }
      #if targetEnvironment(simulator)
      if previewScreen == "routes-test", await client.loadRoutingFixture() { return }
      if let previewScreen, client.loadLayoutPreview() {
        if ["servers", "subscriptions"].contains(previewScreen) { tab = .subscriptions }
        if ["rules", "routing", "chains"].contains(previewScreen) { tab = .rules }
        return
      }
      #endif
      await client.load()
    }
    .onReceive(NotificationCenter.default.publisher(for: .NEVPNStatusDidChange)) { _ in
      client.syncVPNStatus()
    }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
      keyboardVisible = true
    }
    .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
      keyboardVisible = false
    }
    .task(id: measurements.request?.token) {
      if let request = measurements.request { await measurements.run(request, using: client) }
    }
    .task(id: client.ready && scenePhase == .active) {
      guard client.ready, scenePhase == .active, previewScreen == nil else { return }
      while !Task.isCancelled {
        await client.refreshAutomatically()
        do { try await Task.sleep(for: .seconds(15 * 60)) }
        catch { return }
      }
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

  private var reconnectButton: some View {
    Button(client.restartingVPN ? "Переподключаем…" : "Применить") {
      Task { await client.reconnectVPN() }
    }
    .buttonStyle(.borderedProminent)
    .disabled(client.vpnBusy || client.restartingVPN)
    .accessibilityIdentifier("reconnectVPN")
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
              .multilineTextAlignment(.center)
              .lineLimit(2)
              .minimumScaleFactor(0.8)
              .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
          }
          .frame(maxWidth: .infinity, minHeight: 48)
          .foregroundStyle(tab == item ? HyStyle.accent : HyStyle.muted)
          .background(tab == item ? HyStyle.accent.opacity(0.10) : .clear,
                      in: RoundedRectangle(cornerRadius: 12))
          .contentShape(Rectangle())
        }
        .buttonStyle(HyPress())
        .accessibilityIdentifier("tab-\(item)")
        .accessibilityAddTraits(tab == item ? .isSelected : [])
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .background(HyStyle.surface.ignoresSafeArea(edges: .bottom))
    .overlay(alignment: .top) { Rectangle().fill(HyStyle.stroke).frame(height: 1).allowsHitTesting(false) }
  }
}

struct VPNRecoveryPage: View {
  @ObservedObject var client: Client

  var body: some View {
    Form {
      Section {
        Toggle("Автовосстановление", isOn: Binding(get: { client.autoReconnect }, set: { value in
          Task { await client.setAutoReconnect(value) }
        }))
        Toggle("Блокировка при обрыве", isOn: Binding(get: { client.blockOnDrop && client.autoReconnect }, set: {
          client.setBlockOnDrop($0)
        }))
        .disabled(!client.autoReconnect)
      } footer: {
        Text(client.canEditVPNRecovery ? "iOS восстанавливает VPN после первого подключения. Ручное отключение приостанавливает восстановление." : "Отключите VPN, чтобы изменить настройки.")
      }
      .disabled(!client.canEditVPNRecovery)
    }
    .navigationTitle("Защита VPN")
    .navigationBarTitleDisplayMode(.inline)
  }
}

struct ProfileRow: View {
  let profile: VPNProfile
  var selected = false
  @Environment(\.dynamicTypeSize) private var typeSize

  var body: some View {
    HStack(spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text(profile.displayTitle).font(.body.weight(selected ? .medium : .regular))
          .foregroundStyle(HyStyle.ink).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
          .fixedSize(horizontal: false, vertical: true)
        Text(profile.missing == true ? "Сервер недоступен" : profile.transport)
          .font(.footnote).foregroundStyle(HyStyle.muted)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .layoutPriority(1)
      if selected { Image(systemName: "checkmark").font(.footnote.weight(.semibold)).foregroundStyle(HyStyle.accent) }
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
  var candidates: [VPNProfile]?
  var pickerTitle: String?
  var offerMainProfile = true
  @Environment(\.dismiss) private var dismiss
  @State private var query = ""

  var body: some View {
    NavigationStack {
      List {
        if let select, offerMainProfile {
          Button { select(""); dismiss() } label: {
            Label("Основной профиль", systemImage: "star")
          }
        }
        ForEach((candidates ?? client.state.profiles).filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.host?.localizedCaseInsensitiveContains(query) == true }) { profile in
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
          .accessibilityIdentifier("picker-profile-\(profile.id)")
        }
      }
      .hyList()
      .searchable(text: $query, prompt: "Найти профиль")
      .navigationTitle(pickerTitle ?? (select == nil ? "Основной профиль" : "Профиль правила"))
      .navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Закрыть") { dismiss() } } }
    }
  }
}

private struct SubscriptionsPage: View {
  @ObservedObject var client: Client
  @ObservedObject var measurements: SubscriptionMeasurements
  @State private var adding = false
  @State private var query = ""

  var body: some View {
    let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let visible = client.state.subscriptions.filter { item in
      search.isEmpty || item.name.localizedCaseInsensitiveContains(search) ||
        item.servers.contains { $0.displayTitle.localizedCaseInsensitiveContains(search) }
    }
    return List {
      if client.state.subscriptions.isEmpty {
        Section {
          VStack(alignment: .leading, spacing: 12) {
            HyHeading(text: "Подписок пока нет")
            Text("Добавьте ссылку или конфиг VPN.").foregroundStyle(HyStyle.muted)
            Button { adding = true } label: { Label("Добавить подписку", systemImage: "plus") }
              .buttonStyle(HyButton())
          }
          .padding(.vertical, 6)
        }
        .listRowBackground(HyStyle.surface)
      } else if visible.isEmpty {
        Text("Серверы и подписки не найдены.").foregroundStyle(HyStyle.muted)
          .listRowBackground(HyStyle.canvas)
      } else {
        Section {
          ForEach(visible) { item in
            NavigationLink {
              SubscriptionPage(
                client: client, id: item.id, measurements: measurements,
                initialQuery: item.name.localizedCaseInsensitiveContains(search) ? "" : search
              )
            } label: {
              VStack(alignment: .leading, spacing: 5) {
                Text(item.name).font(.headline).foregroundStyle(HyStyle.ink)
                Text("Серверов: \(item.servers.filter { $0.missing != true }.count)")
                  .font(.footnote).foregroundStyle(HyStyle.muted)
                if client.refreshFailed(item) {
                  Text("Обновление не удалось").font(.footnote).foregroundStyle(HyStyle.failure)
                }
              }
              .fixedSize(horizontal: false, vertical: true)
              .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
              .padding(.vertical, 4)
            }
            .accessibilityIdentifier("subscription-\(item.id)")
            .listRowBackground(HyStyle.surface)
          }
        }
      }
      Section {
        NavigationLink {
          ServerGroupsPage(client: client)
        } label: {
          HyRow(title: "Группы серверов", symbol: "square.stack.3d.up", disclosure: false)
        }
        .accessibilityIdentifier("manage-server-groups")
        .listRowBackground(HyStyle.surface)
      }
    }
    .hyList()
    .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                prompt: "Найти сервер или подписку")
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

struct SubscriptionPage: View {
  @ObservedObject var client: Client
  let id: String
  @ObservedObject var measurements: SubscriptionMeasurements
  @State private var expandedGroups: Set<String> = []
  @State private var query: String

  init(client: Client, id: String, measurements: SubscriptionMeasurements, initialQuery: String = "") {
    self.client = client
    self.id = id
    self.measurements = measurements
    _query = State(initialValue: initialQuery)
  }

  private var runningHere: Bool { measurements.request?.subscriptionID == id }

  var body: some View {
    if let item = client.state.subscriptions.first(where: { $0.id == id }) {
      let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
      let visible = item.servers.filter { profile in
        search.isEmpty || profile.displayTitle.localizedCaseInsensitiveContains(search)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          probeControls(item)
          if item.hasMetadata {
            SubscriptionDetails(item: item, showRefreshFailure: false)
          }
          if visible.isEmpty {
            Text(item.servers.isEmpty ? "В подписке пока нет серверов." : "Серверы не найдены.")
              .foregroundStyle(HyStyle.muted)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            LazyVStack(spacing: 0) {
              ForEach(visible) { profile in
                serverRow(profile, in: item)
                if profile.id != visible.last?.id {
                  Divider().overlay(HyStyle.stroke).padding(.horizontal, 12)
                }
              }
            }
            .background(HyStyle.surface, in: RoundedRectangle(cornerRadius: 14))
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
      }
      .hyScreen()
      .searchable(text: $query, prompt: "Найти сервер")
      .navigationTitle(item.name)
      .navigationBarTitleDisplayMode(.inline)
    } else {
      Text("Подписка недоступна").foregroundStyle(HyStyle.muted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hyScreen()
        .navigationTitle("Подписка")
    }
  }

  private func probeControls(_ item: Subscription) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if runningHere {
        ProgressView().tint(HyStyle.accent).accessibilityLabel("Идёт замер задержки")
      }
      ViewThatFits(in: .horizontal) {
        HStack(spacing: 8) { subscriptionActions(item, singleLine: true) }
        VStack(spacing: 8) { subscriptionActions(item, singleLine: false) }
      }
      if client.refreshFailed(item) {
        Text("Обновление не удалось. Список сохранён.")
          .font(.subheadline).foregroundStyle(HyStyle.failure)
          .accessibilityIdentifier("subscription-refresh-error")
      }
      if measurements.failedSubscription == id {
        Text("Не удалось выполнить замер").font(.subheadline).foregroundStyle(HyStyle.failure)
          .accessibilityIdentifier("subscription-probe-error")
      }
    }
  }

  @ViewBuilder private func subscriptionActions(_ item: Subscription, singleLine: Bool) -> some View {
    if item.canRefresh == true {
      Button { Task { await client.refresh(id) } } label: {
        if client.refreshingSubscription == id { ProgressView().tint(HyStyle.accent) }
        else {
          Label("Обновить", systemImage: "arrow.clockwise")
            .fixedSize(horizontal: singleLine, vertical: true)
        }
      }
      .buttonStyle(HyButton(prominent: false))
      .disabled(client.busy || runningHere)
      .accessibilityIdentifier("subscription-refresh")
    }
    Button {
      if runningHere { measurements.cancel() }
      else { measurements.start(item) }
    } label: {
      Label(runningHere ? "Остановить" : "Проверить все",
            systemImage: runningHere ? "stop.circle" : "speedometer")
        .fixedSize(horizontal: singleLine, vertical: true)
    }
    .buttonStyle(HyButton(prominent: false))
    .accessibilityIdentifier("subscription-check-all")
    .disabled(!runningHere && (client.busy || measurements.request != nil || !item.servers.contains { $0.missing != true }))
  }

  private func serverRow(_ profile: VPNProfile, in item: Subscription) -> some View {
    let rows = measurements.results[profile.id] ?? []
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 6) {
        Button { Task { _ = await client.select(profile.id) } } label: {
          ProfileRow(profile: profile, selected: client.state.selected?.id == profile.id)
        }
        .buttonStyle(.plain)
        .disabled(client.busy || profile.missing == true)
        .accessibilityIdentifier("subscription-profile-\(profile.id)")
        if profile.missing != true {
          Button {
            if profile.balance == true { expandedGroups.insert(profile.id) }
            measurements.start(item, profile: profile)
          } label: {
            Image(systemName: "speedometer")
              .font(.body.weight(.semibold))
              .foregroundStyle(HyStyle.accent)
              .frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(client.busy || measurements.request != nil)
          .accessibilityLabel(profile.balance == true ? "Проверить узлы группы" : "Проверить задержку")
          .accessibilityIdentifier("subscription-check-\(profile.id)")
        }
      }
      if profile.balance == true && !rows.isEmpty {
        DisclosureGroup(isExpanded: Binding(get: { expandedGroups.contains(profile.id) }, set: { expanded in
          if expanded { expandedGroups.insert(profile.id) } else { expandedGroups.remove(profile.id) }
        })) {
          ForEach(rows.indices, id: \.self) { index in
            let host = rows[index].host ?? "Узел \(index + 1)"
            let delay = Text(rows[index].label).monospacedDigit()
              .foregroundStyle(rows[index].ms == nil ? HyStyle.muted : HyStyle.success)
            ViewThatFits(in: .horizontal) {
              HStack { Text(host).fixedSize(); Spacer(minLength: 6); delay.fixedSize() }
              VStack(alignment: .leading, spacing: 2) { Text(host); delay }
            }
            .padding(.vertical, 4)
          }
        } label: {
          Text(ProbeSnapshot.groupLabel(rows)).accessibilityIdentifier("subscription-result-\(profile.id)")
        }
        .font(.subheadline)
        .foregroundStyle(HyStyle.muted)
      } else if let row = rows.first {
        Text(row.label).font(.subheadline.monospacedDigit())
          .foregroundStyle(row.ms == nil ? HyStyle.muted : HyStyle.success)
          .accessibilityIdentifier("subscription-result-\(profile.id)")
      }
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }
}

struct ImportSheet: View {
  @ObservedObject var client: Client
  @Environment(\.dismiss) private var dismiss
  @State private var input = ""
  @State private var error: String?
  @State private var offeredClipboard = false

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
              .accessibilityIdentifier("import-input")
              .onChange(of: input) { _ in error = nil }
          }
        }
        .padding(16)
      }
      .safeAreaInset(edge: .bottom, spacing: 0) {
        VStack(alignment: .leading, spacing: 8) {
          if let error {
            Text(error).font(.subheadline).foregroundStyle(HyStyle.failure)
              .fixedSize(horizontal: false, vertical: true)
              .accessibilityIdentifier("import-error")
          }
          Button {
            Task {
              error = nil
              do {
                try await client.importSubscription(input)
                dismiss()
              } catch let failure as LocalizedError {
                self.error = failure.errorDescription ?? "Не удалось импортировать подписку."
              } catch {
                self.error = "Не удалось сохранить подписку."
              }
            }
          } label: {
            if client.busy {
              HStack { ProgressView().tint(HyStyle.onFill); Text("Импортируем…") }
            } else { Label("Импортировать", systemImage: "arrow.down") }
          }
          .buttonStyle(HyButton())
          .disabled(client.busy || input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .accessibilityIdentifier("import-submit")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(HyStyle.canvas)
      }
      .hyScreen()
      .scrollDismissesKeyboard(.interactively)
      .navigationTitle("Добавить подписку")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(client.busy) }
      }
    }
    .task {
      guard !offeredClipboard else { return }
      offeredClipboard = true
      let pasteboard = UIPasteboard.general
      let revision = pasteboard.changeCount
      if !pasteboard.hasURLs {
        guard pasteboard.hasStrings else { return }
        let matches = try? await pasteboard.detectedPatterns(for: [\.probableWebURL, \.links])
        guard matches?.isEmpty == false else { return }
      }
      guard !Task.isCancelled, input.isEmpty, revision == pasteboard.changeCount else { return }
      let text = pasteboard.hasStrings ? pasteboard.string : pasteboard.url?.absoluteString
      if let value = text?.trimmingCharacters(in: .whitespacesAndNewlines),
         value.split(whereSeparator: \.isNewline).contains(where: isSubscriptionLink) {
        input = value
      }
    }
    .interactiveDismissDisabled(client.busy)
  }

  private func isSubscriptionLink(_ line: Substring) -> Bool {
    guard let url = URLComponents(string: line.trimmingCharacters(in: .whitespaces)),
          url.host?.isEmpty == false, let scheme = url.scheme?.lowercased() else { return false }
    return ["https", "vless", "hysteria2", "hy2"].contains(scheme)
  }
}
