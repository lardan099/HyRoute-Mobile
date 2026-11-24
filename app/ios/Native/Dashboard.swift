import NetworkExtension
import SwiftUI

struct Dashboard: View {
  @ObservedObject var client: Client
  @ObservedObject var measurements: SubscriptionMeasurements
  @State private var choosingProfile = false
  @State private var importing = false

  var body: some View {
    let selectedID = client.state.selected?.id
    return ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        connectionSummary
        if !client.state.subscriptions.isEmpty {
          LazyVStack(alignment: .leading, spacing: 10) {
            ForEach(client.state.subscriptions) { item in
              DashboardSubscription(client: client, measurements: measurements, item: item, selectedID: selectedID)
            }
          }
        }
      }
      .frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
    }
    .accessibilityIdentifier("dashboard-scroll")
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if client.state.selected != nil || client.vpnStatus.isActiveTunnel {
        Button { Task { await client.toggleVPN() } } label: {
          Label(client.vpnStatus.isActiveTunnel ? "Отключить VPN" : "Подключить VPN", systemImage: "power")
        }
        .buttonStyle(HyButton(prominent: !client.vpnStatus.isActiveTunnel))
        .disabled(client.vpnBusy || client.vpnStatus == .disconnecting)
        .accessibilityIdentifier("dashboard-vpn-button")
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .frame(maxWidth: 676)
        .frame(maxWidth: .infinity)
        .background(HyStyle.canvas)
      }
    }
    .hyScreen()
    .navigationTitle("HyRoute")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .navigationBarLeading) {
        NavigationLink {
          DashboardSettings(client: client)
        } label: {
          Image(systemName: "gearshape").accessibilityLabel("Настройки")
        }
        .accessibilityIdentifier("dashboard-settings")
      }
      ToolbarItem(placement: .primaryAction) {
        Button { importing = true } label: {
          Image(systemName: "plus").accessibilityLabel("Добавить подписку")
        }
        .accessibilityIdentifier("dashboard-import")
      }
    }
    .sheet(isPresented: $choosingProfile) { ProfilePicker(client: client) }
    .sheet(isPresented: $importing) { ImportSheet(client: client) }
  }

  private var status: String {
    if client.vpnBusy { return "Запуск VPN…" }
    switch client.vpnStatus {
    case .connected: return "VPN включён"
    case .connecting: return "Подключение…"
    case .reasserting: return "Восстанавливаем VPN…"
    case .disconnecting: return "Отключение…"
    default: return "VPN выключен"
    }
  }

  private var pending: Bool {
    client.vpnBusy || [.connecting, .disconnecting, .reasserting].contains(client.vpnStatus)
  }

  private var connectionSummary: some View {
    let active = client.vpnStatus.isActiveTunnel
    let signal = active ? HyStyle.accent : HyStyle.muted
    return VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        if pending { ProgressView().tint(signal).accessibilityHidden(true) }
        else { Circle().fill(signal).frame(width: 8, height: 8).accessibilityHidden(true) }
        Text(status).font(.subheadline)
          .foregroundStyle(signal)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("dashboard-vpn-status")
      }
      if let profile = client.state.selected {
        Button { choosingProfile = true } label: {
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
              Text(profile.displayTitle).font(.title.weight(.semibold))
                .tracking(-0.45)
                .foregroundStyle(HyStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
              Text(profile.transport).font(.footnote).foregroundStyle(HyStyle.muted)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.up.chevron.down").font(.subheadline.weight(.semibold))
              .foregroundStyle(HyStyle.accent).accessibilityHidden(true)
          }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(HyPress())
        .accessibilityLabel("Основной профиль")
        .accessibilityValue(profile.displayTitle)
        .accessibilityIdentifier("profilePicker")
      }
      if client.state.selected == nil && !active {
        Button { importing = true } label: {
          Label("Добавить подписку", systemImage: "plus")
        }
        .buttonStyle(HyButton())
        .accessibilityIdentifier("dashboard-add-first-subscription")
      }
    }
    .padding(.horizontal, 4)
    .padding(.vertical, 6)
  }
}

private struct DashboardSubscription: View {
  @ObservedObject var client: Client
  @ObservedObject var measurements: SubscriptionMeasurements
  let item: Subscription
  let selectedID: String?
  @State private var expansion: Bool?

  var body: some View {
    let available = item.servers.filter { $0.missing != true }
    let expanded = expansion ?? available.contains { $0.id == selectedID }
    let measuring = measurements.request?.subscriptionID == item.id
    return LazyVStack(alignment: .leading, spacing: 0) {
      Divider().overlay(HyStyle.stroke)
      HStack(spacing: 8) {
        Button { expansion = !expanded } label: {
          HStack(spacing: 10) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .font(.caption.weight(.semibold)).frame(width: 15)
              .foregroundStyle(HyStyle.muted).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
              Text(item.name).font(.headline).foregroundStyle(HyStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
              Text("Доступно \(available.count)").font(.caption).foregroundStyle(HyStyle.muted)
            }
            Spacer(minLength: 0)
          }
          .frame(minHeight: 46).contentShape(Rectangle())
        }
        .buttonStyle(HyPress())
        .accessibilityIdentifier("dashboard-subscription-\(item.id)")
        .accessibilityValue(expanded ? "Развёрнута" : "Свёрнута")
        if item.canRefresh == true {
          Button { Task { await client.refresh(item.id) } } label: {
            Image(systemName: "arrow.clockwise").font(.subheadline.weight(.semibold))
              .foregroundStyle(HyStyle.accent).frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(HyPress())
          .disabled(client.busy || measuring)
          .accessibilityLabel("Обновить подписку \(item.name)")
        }
        Button {
          if measuring { measurements.cancel() }
          else {
            expansion = true
            measurements.start(item)
          }
        } label: {
          Image(systemName: measuring ? "stop.circle" : "speedometer").font(.subheadline.weight(.semibold))
            .foregroundStyle(HyStyle.accent).frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(HyPress())
        .disabled(!measuring && (client.busy || measurements.request != nil || available.isEmpty))
        .accessibilityLabel(measuring ? "Остановить замер" : "Проверить серверы \(item.name)")
        .accessibilityIdentifier("dashboard-probe-\(item.id)")
      }
      .padding(.vertical, 5)
      if expanded {
        Divider().overlay(HyStyle.stroke)
        if measuring {
          ProgressView().tint(HyStyle.accent).accessibilityLabel("Идёт замер задержки")
            .padding(.horizontal, 15).padding(.vertical, 8)
        }
        if measurements.failedSubscription == item.id {
          Text("Не удалось выполнить замер").font(.subheadline).foregroundStyle(HyStyle.failure)
            .padding(.horizontal, 15).padding(.vertical, 8)
        }
        if item.hasMetadata {
          SubscriptionDetails(item: item, embedded: true)
            .padding(.horizontal, 15).padding(.vertical, 10)
          Divider().overlay(HyStyle.stroke).padding(.horizontal, 15)
        }
        ForEach(available) { profile in
          profileRow(profile)
          Divider().overlay(HyStyle.stroke).padding(.horizontal, 15)
        }
        NavigationLink {
          SubscriptionPage(client: client, id: item.id, measurements: measurements)
        } label: {
          HStack(spacing: 8) {
            Text("Серверы и отдельные замеры").font(.subheadline.weight(.medium))
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).accessibilityHidden(true)
          }
          .foregroundStyle(HyStyle.accent)
          .frame(minHeight: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(HyPress())
        .accessibilityIdentifier("dashboard-server-details-\(item.id)")
        .padding(.horizontal, 15)
      }
    }
  }

  private func profileRow(_ profile: VPNProfile) -> some View {
    let rows = measurements.results[profile.id] ?? []
    let delay = profile.balance == true && !rows.isEmpty ? ProbeSnapshot.groupLabel(rows) : rows.first?.label
    let selected = selectedID == profile.id
    return Button { Task { _ = await client.select(profile.id) } } label: {
      HStack(spacing: 10) {
        VStack(alignment: .leading, spacing: 3) {
          Text(profile.displayTitle).font(.body.weight(selected ? .medium : .regular))
            .foregroundStyle(HyStyle.ink).fixedSize(horizontal: false, vertical: true)
          Text(profile.transport).font(.footnote).foregroundStyle(HyStyle.muted)
        }
        .layoutPriority(1)
        Spacer(minLength: 2)
        if let delay {
          Text(delay).font(.footnote.monospacedDigit())
            .foregroundStyle(rows.contains { $0.ms != nil } ? HyStyle.success : HyStyle.muted)
            .accessibilityHidden(true)
        }
        if selected {
          Image(systemName: "checkmark.circle.fill").foregroundStyle(HyStyle.success)
            .accessibilityHidden(true)
        }
      }
      .frame(minHeight: 49).contentShape(Rectangle())
      .padding(.horizontal, 15)
      .background(selected ? HyStyle.accent.opacity(0.08) : .clear)
    }
    .buttonStyle(HyPress())
    .disabled(client.busy)
    .accessibilityAddTraits(selected ? .isSelected : [])
    .accessibilityIdentifier("dashboard-profile-\(profile.id)")
    .accessibilityValue(delay ?? "")
  }
}

private struct DashboardSettings: View {
  @ObservedObject var client: Client

  var body: some View {
    List {
      Section("Подключение") {
        NavigationLink {
          VPNRecoveryPage(client: client)
        } label: {
          HyRow(title: "Защита VPN", symbol: "shield",
                detail: client.autoReconnect ? "Автовосстановление включено" : "Автовосстановление выключено",
                disclosure: false)
        }
      }
      .listRowBackground(HyStyle.surface)
      Section("Диагностика") {
        NavigationLink {
          VPNJournalPage(client: client)
        } label: {
          HyRow(title: "Журнал VPN", symbol: "list.bullet.rectangle",
                detail: "Запуски, остановки и сбои туннеля", disclosure: false)
        }
        .accessibilityIdentifier("vpn-journal")
        NavigationLink {
          TrafficJournalPage(client: client)
        } label: {
          HyRow(title: "Журнал подключений", symbol: "waveform.path",
                detail: "Адреса, маршруты и ошибки", disclosure: false)
        }
        .accessibilityIdentifier("traffic-journal")
      }
      .listRowBackground(HyStyle.surface)
    }
    .hyList()
    .navigationTitle("Настройки")
    .navigationBarTitleDisplayMode(.inline)
  }
}
