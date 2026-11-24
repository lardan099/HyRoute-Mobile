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
                HStack { Text("Настройки изменились"); Spacer(); reconnectButton }
                VStack(alignment: .leading, spacing: 8) { Text("Настройки изменились"); reconnectButton }
              }
              .font(.subheadline)
              .frame(maxWidth: .infinity, alignment: .leading)
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
        if previewScreen == "servers" { tab = .subscriptions }
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
    Button(client.restartingVPN ? "Переподключаем…" : "Переподключить") {
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
          }
          .frame(maxWidth: .infinity, minHeight: 48)
          .foregroundStyle(tab == item ? HyStyle.accent : HyStyle.muted)
          .background(tab == item ? HyStyle.inset : .clear, in: RoundedRectangle(cornerRadius: 11))
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
      HyIcon(symbol: profile.balance == true ? "bolt.fill" : "server.rack")
      VStack(alignment: .leading, spacing: 3) {
        Text(profile.displayTitle).font(.body.weight(.semibold))
          .foregroundStyle(HyStyle.ink).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
          .fixedSize(horizontal: false, vertical: true)
        Text(profile.missing == true ? "Сервер недоступен" : profile.transport)
          .font(.subheadline).foregroundStyle(HyStyle.muted)
          .fixedSize(horizontal: false, vertical: true)
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

  var body: some View {
    List {
      Section {
        NavigationLink {
          ServerGroupsPage(client: client)
        } label: {
          let count = client.state.serverGroups?.count ?? 0
          HyRow(title: "Группы серверов", symbol: "square.stack.3d.up",
                detail: count > 0 ? "Групп: \(count)" : nil, disclosure: false)
        }
        .accessibilityIdentifier("manage-server-groups")
        .listRowBackground(HyStyle.surface)
      }

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
      } else {
        Section("Мои подписки") {
          ForEach(client.state.subscriptions) { item in
            NavigationLink {
              SubscriptionPage(client: client, id: item.id, measurements: measurements)
            } label: {
              HyRow(title: item.name, symbol: "link",
                    detail: "Серверов: \(item.servers.filter { $0.missing != true }.count)", disclosure: false)
            }
            .accessibilityIdentifier("subscription-\(item.id)")
            .listRowBackground(HyStyle.surface)
          }
        }
      }
    }
    .hyList()
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

  private var runningHere: Bool { measurements.request?.subscriptionID == id }

  var body: some View {
    if let item = client.state.subscriptions.first(where: { $0.id == id }) {
      ScrollView {
        VStack(alignment: .leading, spacing: 12) {
          if item.hasMetadata {
            SubscriptionDetails(item: item)
          }
          if item.servers.isEmpty {
            Text("В подписке пока нет серверов.").foregroundStyle(HyStyle.muted)
              .frame(maxWidth: .infinity, alignment: .leading)
          } else {
            LazyVStack(spacing: 0) {
              ForEach(item.servers) { profile in
                serverRow(profile, in: item)
                if profile.id != item.servers.last?.id {
                  Divider().overlay(HyStyle.stroke).padding(.leading, 52)
                }
              }
            }
            .background(HyStyle.surface, in: RoundedRectangle(cornerRadius: 14))
          }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
      }
      .safeAreaInset(edge: .top, spacing: 0) {
        probeControls(item)
      }
      .hyScreen()
      .navigationTitle(item.name)
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        if item.canRefresh == true {
          ToolbarItem(placement: .primaryAction) {
            Button { Task { await client.refresh(id) } } label: {
              if client.busy { ProgressView().tint(HyStyle.accent) }
              else { Label("Обновить подписку", systemImage: "arrow.clockwise") }
            }
            .disabled(client.busy || runningHere)
            .accessibilityIdentifier("subscription-refresh")
          }
        }
      }
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
      Button {
        if runningHere { measurements.cancel() }
        else { measurements.start(item) }
      } label: {
        Label(runningHere ? "Остановить" : "Проверить все",
              systemImage: runningHere ? "stop.circle" : "speedometer")
      }
      .buttonStyle(HyButton(prominent: !runningHere))
      .accessibilityIdentifier("subscription-check-all")
      .disabled(!runningHere && (client.busy || measurements.request != nil || !item.servers.contains { $0.missing != true }))
      if measurements.failedSubscription == id {
        Text("Не удалось выполнить замер").font(.subheadline).foregroundStyle(HyStyle.failure)
          .accessibilityIdentifier("subscription-probe-error")
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 6)
    .background(HyStyle.canvas)
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
        .padding(.leading, 48)
      } else if let row = rows.first {
        Text(row.label).font(.subheadline.monospacedDigit())
          .foregroundStyle(row.ms == nil ? HyStyle.muted : HyStyle.success)
          .padding(.leading, 48)
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
            PasteButton(payloadType: String.self) { values in
              if let first = values.first { input = first; error = nil }
            }
            .accessibilityLabel("Вставить подписку")
          }
          .hyCard()
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
    .interactiveDismissDisabled(client.busy)
  }
}
