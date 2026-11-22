import Foundation
import SwiftUI

private enum CoreError: Error { case invalidResult }

private actor NativeCore {
  private let store = ClientStore()

  func load() throws -> ClientState {
    let folder = try store.prepareDirectory()
    HyRouteConfigureGeo(folder.appendingPathComponent("geo", isDirectory: true).path)
    return try view(store.read())
  }

  func importSubscription(_ input: String) throws -> ClientState {
    let url = URLComponents(string: input)
    let fromURL = url?.scheme?.lowercased() == "https" &&
      !(url?.host?.isEmpty ?? true) && input.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    return try persist(HyRouteAddSubscription(try store.read(), input, fromURL))
  }

  func refresh(_ id: String) throws -> ClientState {
    try persist(HyRouteRefreshSubscription(try store.read(), id))
  }

  func save(_ settings: ClientSettings) throws -> ClientState {
    let raw = String(decoding: try JSONEncoder().encode(settings), as: UTF8.self)
    return try persist(HyRouteSaveSettings(try store.read(), raw))
  }

  func geoTags(update: Bool) throws -> [String] {
    if update && !HyRouteUpdateGeo() { throw CoreError.invalidResult }
    guard let tags = HyRouteGeoTags() else { throw CoreError.invalidResult }
    return try JSONDecoder().decode([String].self, from: Data(tags.utf8))
  }

  private func persist(_ raw: String?) throws -> ClientState {
    guard let raw else { throw CoreError.invalidResult }
    let state = try view(raw)
    try store.write(raw)
    return state
  }

  private func view(_ raw: String) throws -> ClientState {
    guard let sanitized = HyRouteStateView(raw) else { throw CoreError.invalidResult }
    return try JSONDecoder().decode(ClientState.self, from: Data(sanitized.utf8))
  }
}

@MainActor
final class Client: ObservableObject {
  private let core = NativeCore()
  @Published private(set) var state = ClientState()
  @Published private(set) var ready = false
  @Published private(set) var busy = false
  @Published var error: String?

  func load() async {
    if await change("Не удалось открыть хранилище HyRoute.", { try await self.core.load() }) {
      ready = true
    }
  }

  func importSubscription(_ input: String) async -> Bool {
    await change("Не удалось импортировать подписку. Проверьте ссылку или формат.") {
      try await self.core.importSubscription(input.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  func refresh(_ id: String) async {
    _ = await change("Не удалось обновить подписку. Сохранён предыдущий список.") {
      try await self.core.refresh(id)
    }
  }

  func select(_ id: String) async -> Bool {
    var next = state.settings
    next.selected = id
    return await save(next)
  }

  func saveRouting(_ routing: Routing) async -> Bool {
    var next = state.settings
    next.routing = routing
    next.selected = state.selected?.id
    return await save(next)
  }

  func geoTags(update: Bool) async throws -> [String] {
    try await core.geoTags(update: update)
  }

  private func save(_ settings: ClientSettings) async -> Bool {
    await change("Не удалось сохранить. Проверьте адреса, порты и цепочки профилей.") {
      try await self.core.save(settings)
    }
  }

  private func change(_ failure: String, _ operation: () async throws -> ClientState) async -> Bool {
    guard !busy else { return false }
    busy = true
    defer { busy = false }
    do {
      state = try await operation()
      return true
    } catch {
      self.error = failure
      return false
    }
  }
}
