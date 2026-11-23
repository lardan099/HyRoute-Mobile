import NetworkExtension
import SwiftUI

struct Dashboard: View {
  @ObservedObject var client: Client
  @State private var choosingProfile = false
  @State private var importing = false

  var body: some View {
    let selectedID = client.state.selected?.id
    return ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        connectionCard
        if !client.state.subscriptions.isEmpty {
          LazyVStack(alignment: .leading, spacing: 10) {
            Text("Подписки").font(.title2.weight(.semibold))
              .foregroundStyle(HyStyle.ink)
              .accessibilityAddTraits(.isHeader)
              .padding(.bottom, 3)
            ForEach(client.state.subscriptions) { item in
              DashboardSubscription(client: client, item: item, selectedID: selectedID)
            }
          }
        }
      }
      .frame(maxWidth: 640)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 18)
      .padding(.vertical, 12)
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

  private var connectionCard: some View {
    let active = client.vpnStatus.isActiveTunnel
    return VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 8) {
        if pending { ProgressView().tint(HyStyle.accent).accessibilityHidden(true) }
        else {
          Circle().fill(active ? HyStyle.success : HyStyle.muted).frame(width: 8, height: 8)
            .accessibilityHidden(true)
        }
        Text(status).font(.subheadline.weight(.semibold))
          .foregroundStyle(active ? HyStyle.success : HyStyle.muted)
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityIdentifier("dashboard-vpn-status")
      }
      if let profile = client.state.selected {
        Button { choosingProfile = true } label: {
          HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
              Text(profile.displayTitle).font(.title2.weight(.semibold))
                .foregroundStyle(HyStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
              Text(profile.transport).font(.caption).foregroundStyle(HyStyle.muted)
            }
            Spacer(minLength: 8)
            Image(systemName: "arrow.up.arrow.down").font(.subheadline.weight(.semibold))
              .foregroundStyle(HyStyle.accent).accessibilityHidden(true)
          }
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
      } else {
        Button { Task { await client.toggleVPN() } } label: {
          Label(active ? "Отключить VPN" : "Подключить VPN", systemImage: "power")
        }
        .buttonStyle(HyButton(prominent: !active))
        .disabled(client.vpnBusy || client.vpnStatus == .disconnecting)
        .accessibilityIdentifier("dashboard-vpn-button")
      }
    }
    .padding(16)
    .background {
      RoundedRectangle(cornerRadius: 18).fill(HyStyle.surface)
    }
  }
}

private struct DashboardSubscription: View {
  @ObservedObject var client: Client
  let item: Subscription
  let selectedID: String?
  @State private var expansion: Bool?

  var body: some View {
    let available = item.servers.filter { $0.missing != true }
    let expanded = expansion ?? available.contains { $0.id == selectedID }
    return LazyVStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Button { expansion = !expanded } label: {
          HStack(spacing: 10) {
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
              .font(.caption.weight(.semibold)).frame(width: 15)
              .foregroundStyle(HyStyle.muted).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
              Text(item.name).font(.body.weight(.semibold)).foregroundStyle(HyStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
              Text("Доступно \(available.count)").font(.caption).foregroundStyle(HyStyle.muted)
            }
            Spacer(minLength: 0)
          }
          .frame(minHeight: 46).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dashboard-subscription-\(item.id)")
        .accessibilityValue(expanded ? "Развёрнута" : "Свёрнута")
        if item.canRefresh == true {
          Button { Task { await client.refresh(item.id) } } label: {
            Image(systemName: "arrow.clockwise").font(.subheadline.weight(.semibold))
              .foregroundStyle(HyStyle.accent).frame(width: 44, height: 44)
              .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(client.busy)
          .accessibilityLabel("Обновить подписку \(item.name)")
        }
        NavigationLink {
          SubscriptionPage(client: client, id: item.id)
        } label: {
          Image(systemName: "speedometer").font(.subheadline.weight(.semibold))
            .foregroundStyle(HyStyle.accent).frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Задержка серверов \(item.name)")
        .accessibilityIdentifier("dashboard-server-details-\(item.id)")
      }
      .padding(.horizontal, 12).padding(.vertical, 5)
      if expanded {
        Divider().overlay(HyStyle.stroke)
        if let used = item.usedBytes, let limit = item.limitBytes, limit > 0 {
          VStack(alignment: .leading, spacing: 6) {
            Text("\(bytes(used)) из \(bytes(limit))")
              .font(.caption.monospacedDigit()).foregroundStyle(HyStyle.muted)
            ProgressView(value: min(max(Double(used) / Double(limit), 0), 1))
              .accessibilityLabel("Трафик подписки")
          }
          .padding(.horizontal, 15).padding(.vertical, 12)
        }
        ForEach(available) { profile in
          Button { Task { _ = await client.select(profile.id) } } label: {
            HStack(spacing: 10) {
              VStack(alignment: .leading, spacing: 3) {
                Text(profile.displayTitle).font(.subheadline.weight(.semibold))
                  .foregroundStyle(HyStyle.ink).fixedSize(horizontal: false, vertical: true)
                Text(profile.transport).font(.caption).foregroundStyle(HyStyle.muted)
              }
              Spacer(minLength: 0)
              if selectedID == profile.id {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(HyStyle.success)
                  .accessibilityHidden(true)
              }
            }
            .frame(minHeight: 49).contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(client.busy)
          .accessibilityAddTraits(selectedID == profile.id ? .isSelected : [])
          .accessibilityIdentifier("dashboard-profile-\(profile.id)")
          .padding(.horizontal, 15)
          if profile.id != available.last?.id {
            Divider().overlay(HyStyle.stroke).padding(.horizontal, 15)
          }
        }
      }
    }
    .background(HyStyle.surface, in: RoundedRectangle(cornerRadius: 16))
  }

  private func bytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .binary)
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
