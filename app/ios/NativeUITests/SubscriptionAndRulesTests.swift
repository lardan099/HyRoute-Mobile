import XCTest

private func revealDashboardDetails(_ button: XCUIElement, in app: XCUIApplication) {
  let home = app.scrollViews["dashboard-scroll"]
  XCTAssertTrue(home.waitForExistence(timeout: 10))
  let navigation = app.buttons["tab-home"]
  XCTAssertLessThanOrEqual(home.frame.maxY, navigation.frame.minY)
  for _ in 0..<7 {
    if button.isHittable && button.frame.maxY <= home.frame.maxY { return }
    home.swipeUp()
  }
  XCTAssertTrue(button.isHittable)
  XCTAssertLessThanOrEqual(button.frame.maxY, home.frame.maxY)
}

final class SubscriptionAndRulesTests: XCTestCase {
  private func launch(screen: String = "home", slowProbe: Bool = false, traffic: Bool = false) -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["HYROUTE_LAYOUT_PREVIEW"] = screen
    app.launchEnvironment["HYROUTE_UI_TEST"] = "1"
    if slowProbe { app.launchEnvironment["HYROUTE_SLOW_PROBE"] = "1" }
    if traffic { app.launchEnvironment["HYROUTE_TEST_LOGS"] = "1" }
    app.launch()
    return app
  }

  private func tap(_ button: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(button.waitForExistence(timeout: 10), "Button \(button.identifier) is absent", file: file, line: line)
    button.tap()
  }

  func testCheckAllAndSingleServerStayOnTheSubscription() {
    let app = launch()
    tap(app.buttons["tab-subscriptions"])
    tap(app.buttons["subscription-preview"])

    let checkAll = app.buttons["subscription-check-all"]
    tap(checkAll)
    let result = app.staticTexts["subscription-result-fi"]
    XCTAssertTrue(result.waitForExistence(timeout: 10))
    XCTAssertEqual(result.label, "42 мс")
    XCTAssertTrue(app.navigationBars["Серверы"].exists)
    XCTAssertTrue(checkAll.exists)

    tap(app.buttons["subscription-check-fi"])
    let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "33 мс"), object: result)
    XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 10), .completed)
    XCTAssertTrue(app.navigationBars["Серверы"].exists)

    tap(app.buttons["subscription-check-auto"])
    XCTAssertTrue(app.staticTexts["node2.example.test"].waitForExistence(timeout: 10))
    XCTAssertTrue(checkAll.exists)
  }

  func testRulesExposeRepairBeforeLongListAndSettingsInTheirOwnPane() {
    let app = launch()
    tap(app.buttons["tab-rules"])
    tap(app.buttons["rules-repair"])
    tap(app.buttons["geosite:telegram"].firstMatch)
    XCTAssertTrue(app.navigationBars["Правило"].waitForExistence(timeout: 10))
    tap(app.buttons["Отмена"])

    tap(app.segmentedControls.buttons["Настройки"].firstMatch)
    XCTAssertFalse(app.buttons["rule-row-0"].exists)
    tap(app.buttons["rules-chains"])
    XCTAssertTrue(app.navigationBars["Цепочки"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Недоступные связи"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["remove-broken-chain-auto"].isHittable)
    tap(app.buttons["replace-broken-chain-auto"])
    XCTAssertTrue(app.navigationBars["Изменить цепочку"].waitForExistence(timeout: 10))
    let save = app.buttons["chain-save"]
    XCTAssertFalse(save.isEnabled)
    tap(app.buttons["chain-entry"])
    tap(app.buttons["picker-profile-fi"])
    let canSave = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
    XCTAssertEqual(XCTWaiter.wait(for: [canSave], timeout: 10), .completed)
  }

  func testGeoSourcesOpenFromRoutingSettings() {
    let app = launch()
    tap(app.buttons["tab-rules"])
    tap(app.segmentedControls.buttons["Настройки"].firstMatch)
    tap(app.buttons["rules-geo"])
    tap(app.buttons["geo-source-site"])
    XCTAssertTrue(app.buttons["Импортировать файл"].exists)
    tap(app.buttons["Указать ссылку"])
    XCTAssertTrue(app.navigationBars["geosite.dat"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.textFields["geo-source-address"].exists)
    XCTAssertTrue(app.buttons["Вернуть runetfreedom"].exists)
  }

  func testOpensTrafficJournalFromHome() {
    let app = launch()
    tap(app.buttons["dashboard-settings"])
    tap(app.buttons["traffic-journal"])
    XCTAssertTrue(app.navigationBars["Журнал подключений"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.switches["trafficLogging"].exists)
    XCTAssertTrue(app.buttons["traffic-only-errors"].exists)
  }

  func testTrafficFilterAndClearRequireConfirmation() {
    let app = launch(traffic: true)
    tap(app.buttons["dashboard-settings"])
    tap(app.buttons["traffic-journal"])
    let good = app.staticTexts["www.example.test"]
    let failed = app.staticTexts["api.example.test"]
    XCTAssertTrue(good.waitForExistence(timeout: 10))
    XCTAssertTrue(failed.exists)
    let filter = app.buttons["traffic-only-errors"]
    tap(filter)
    XCTAssertFalse(good.exists)
    XCTAssertTrue(failed.exists)
    tap(app.buttons["traffic-menu"])
    tap(app.buttons["Очистить журнал"])
    tap(app.buttons["Отмена"])
    XCTAssertTrue(failed.exists)
    tap(app.buttons["traffic-menu"])
    tap(app.buttons["Очистить журнал"])
    tap(app.buttons["Очистить"])
    XCTAssertTrue(app.staticTexts["traffic-empty"].waitForExistence(timeout: 10))
    XCTAssertFalse(failed.exists)
  }

  func testVPNJournalShowsEventsAndCopyAction() {
    let app = launch(screen: "vpn-log")
    XCTAssertTrue(app.staticTexts["Запуск передан iOS"].waitForExistence(timeout: 10))
    let copy = app.buttons["vpn-journal-copy"]
    XCTAssertTrue(copy.isEnabled)
    tap(copy)
    XCTAssertTrue(app.navigationBars["Журнал VPN"].exists)
  }

  func testCancellingProbeRestoresLastMeasuredResult() {
    let app = launch(slowProbe: true)
    tap(app.buttons["tab-subscriptions"])
    tap(app.buttons["subscription-preview"])
    let button = app.buttons["subscription-check-all"]
    tap(button)
    let result = app.staticTexts["subscription-result-fi"]
    XCTAssertTrue(result.waitForExistence(timeout: 10))
    XCTAssertEqual(result.label, "42 мс")
    let single = app.buttons["subscription-check-fi"]
    tap(single)
    XCTAssertTrue(button.label.contains("Остановить"))
    tap(button)
    XCTAssertTrue(result.waitForExistence(timeout: 10))
    XCTAssertEqual(result.label, "42 мс")
    tap(single)
    let updated = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "33 мс"), object: result)
    XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 12), .completed)
  }

  func testSelectsServerFromSubscriptionOnHome() {
    let app = launch(screen: "routes-test")
    let status = app.staticTexts["dashboard-vpn-status"]
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    XCTAssertEqual(status.label, "VPN выключен")
    XCTAssertTrue(app.buttons["dashboard-vpn-button"].isHittable)

    let server = app.buttons["dashboard-profile-demo-entry"]
    XCTAssertTrue(server.isHittable)
    tap(app.buttons["dashboard-subscription-demo"])
    XCTAssertFalse(server.exists)
    tap(app.buttons["dashboard-subscription-demo"])
    tap(server)

    let picker = app.buttons["profilePicker"]
    let selection = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", "Запасной сервер"), object: picker)
    XCTAssertEqual(XCTWaiter.wait(for: [selection], timeout: 10), .completed)
    XCTAssertTrue(app.navigationBars["HyRoute"].exists)
  }

  func testDeletesSavedChainAndKeepsItsServers() {
    let app = launch(screen: "routes-test")
    tap(app.buttons["tab-rules"])
    tap(app.segmentedControls.buttons["Настройки"].firstMatch)
    tap(app.buttons["rules-chains"])
    let saved = app.buttons["saved-chain-demo-node"]
    tap(saved)
    XCTAssertTrue(app.navigationBars["Изменить цепочку"].waitForExistence(timeout: 10))
    tap(app.buttons["remove-saved-chain"])
    tap(app.buttons["Удалить"])
    let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: saved)
    XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 10), .completed)
    tap(app.buttons["Закрыть"])
    tap(app.buttons["rules-chains"])
    XCTAssertTrue(app.navigationBars["Цепочки"].waitForExistence(timeout: 10))
    XCTAssertFalse(saved.exists)
    tap(app.buttons["Закрыть"])
    tap(app.buttons["tab-home"])
    tap(app.buttons["profilePicker"])
    XCTAssertTrue(app.buttons["picker-profile-demo-node"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["picker-profile-demo-entry"].exists)
  }

  func testCreatesGroupWithOnePrimaryAndNoReserve() {
    let app = launch(screen: "routes-test")
    tap(app.buttons["tab-subscriptions"])
    tap(app.buttons["manage-server-groups"])
    tap(app.buttons["create-server-group"])
    let name = app.textFields["server-group-name"]
    tap(name)
    name.typeText("Work\n")
    let primary = app.descendants(matching: .any)["group-server-demo-node"].firstMatch
    XCTAssertTrue(primary.waitForExistence(timeout: 10), "Primary server is missing")
    primary.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    let save = app.buttons["server-group-save"]
    let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: save)
    XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 10), .completed, "Adding only a primary must enable saving")
    tap(save)
    let group = app.descendants(matching: .any)
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", "server-group-list-")).firstMatch
    XCTAssertTrue(group.waitForExistence(timeout: 10), "The saved group is absent")
    XCTAssertTrue(group.label.contains("Work"))
  }

  func testChecksSavedRouteAndShowsSubscriptionTraffic() {
    let app = launch(screen: "routes-test")
    tap(app.buttons["tab-subscriptions"])
    tap(app.buttons["subscription-demo"])
    XCTAssertTrue(app.staticTexts["subscription-traffic"].waitForExistence(timeout: 10))
    tap(app.buttons["tab-rules"])
    tap(app.buttons["route-check"])
    let address = app.textFields["route-check-address"]
    tap(address)
    address.typeText("example.org")
    tap(app.buttons["route-check-submit"])
    let rule = app.staticTexts["route-check-rule"]
    XCTAssertTrue(rule.waitForExistence(timeout: 10))
    XCTAssertEqual(rule.label, "Сайт без VPN")
  }

  func testRoutesYouTubeDomainToItsOwnProfile() {
    let app = launch(screen: "routes-test")
    tap(app.buttons["tab-rules"])
    tap(app.buttons["route-check"])
    let address = app.textFields["route-check-address"]
    tap(address)
    address.typeText("m.youtube.com")
    tap(app.buttons["route-check-submit"])
    let rule = app.staticTexts["route-check-rule"]
    XCTAssertTrue(rule.waitForExistence(timeout: 10))
    let rerouted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "YouTube через запасной"), object: rule)
    XCTAssertEqual(XCTWaiter.wait(for: [rerouted], timeout: 10), .completed)
    XCTAssertTrue(app.staticTexts["Запасной сервер"].exists)
  }

  func testCopiesAndSwitchesNamedRoutingProfiles() {
    let app = launch(screen: "routes-test")
    tap(app.buttons["tab-rules"])
    tap(app.buttons["rule-sets"])
    XCTAssertTrue(app.navigationBars["Профили правил"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["route-check-submit"].isHittable)
    tap(app.buttons["routing-profile-copy"])
    let name = app.textFields["routing-profile-name"]
    tap(name)
    name.typeText("Work")
    tap(app.buttons["Сохранить"])
    let copied = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                  "routing-profile-", "Work")).firstMatch
    XCTAssertTrue(copied.waitForExistence(timeout: 10))
    XCTAssertTrue(copied.isSelected)
    let original = app.buttons["routing-profile-default"]
    tap(original)
    let selection = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: original)
    XCTAssertEqual(XCTWaiter.wait(for: [selection], timeout: 10), .completed)
  }

  func testOpensSubscriptionFromHomeAndReturnsToOpenList() {
    let app = launch(screen: "routes-test")
    let servers = app.buttons["dashboard-server-details-demo"]
    revealDashboardDetails(servers, in: app)
    tap(servers)
    let details = app.navigationBars["Тестовая подписка"]
    XCTAssertTrue(details.waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["subscription-check-all"].isHittable)
    tap(details.buttons.firstMatch)
    XCTAssertTrue(app.buttons["dashboard-profile-demo-entry"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["dashboard-profile-demo-entry"].isHittable)
  }

  func testChecksSubscriptionOnHomeAndSharesResultsWithServerDetails() {
    let app = launch()
    tap(app.buttons["dashboard-subscription-preview"])
    tap(app.buttons["dashboard-probe-preview"])
    let server = app.buttons["dashboard-profile-fi"]
    let measured = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "42 мс"), object: server)
    XCTAssertEqual(XCTWaiter.wait(for: [measured], timeout: 10), .completed)
    XCTAssertTrue(app.navigationBars["HyRoute"].exists)
    let details = app.buttons["dashboard-server-details-preview"]
    revealDashboardDetails(details, in: app)
    tap(details)
    XCTAssertTrue(app.navigationBars["Серверы"].waitForExistence(timeout: 10))
    let result = app.staticTexts["subscription-result-fi"]
    XCTAssertTrue(result.waitForExistence(timeout: 10))
    XCTAssertEqual(result.label, "42 мс")
  }

  func testInvalidImportKeepsInputAndShowsErrorNextToSubmit() {
    let app = launch()
    tap(app.buttons["dashboard-import"])
    let submit = app.buttons["import-submit"]
    XCTAssertFalse(submit.isEnabled)
    let input = app.textViews["import-input"]
    tap(input)
    input.typeText("invalid-subscription")
    tap(submit)
    let error = app.staticTexts["import-error"]
    XCTAssertTrue(error.waitForExistence(timeout: 10))
    XCTAssertTrue(error.isHittable)
    XCTAssertEqual(input.value as? String, "invalid-subscription")
    tap(app.buttons["Отмена"])
    XCTAssertTrue(app.buttons["dashboard-import"].waitForExistence(timeout: 10))
  }

  func testRuleValidationAndDomainSuffixRouting() {
    let app = launch(screen: "routes-test")
    tap(app.buttons["tab-rules"])
    tap(app.buttons["rules-add"])
    let save = app.buttons["rule-save"]
    tap(save)
    let error = app.staticTexts["rule-error"]
    XCTAssertTrue(error.waitForExistence(timeout: 10))
    XCTAssertTrue(error.isHittable)
    let destination = app.descendants(matching: .any)["rule-destination"].firstMatch
    tap(destination)
    destination.typeText(".ru")
    XCTAssertFalse(error.exists)
    let direct = app.buttons["rule-action-direct"]
    for _ in 0..<4 where !direct.isHittable { app.scrollViews.firstMatch.swipeUp() }
    tap(direct)
    tap(save)
    tap(app.buttons["route-check"])
    let address = app.textFields["route-check-address"]
    tap(address)
    address.typeText("mail.example.ru")
    tap(app.buttons["route-check-submit"])
    let result = app.descendants(matching: .any)["route-check-action"].firstMatch
    XCTAssertTrue(result.waitForExistence(timeout: 10))
    XCTAssertEqual(result.label, "Напрямую")
    address.tap()
    if let old = address.value as? String { address.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
    address.typeText("m.youtube.com")
    tap(app.buttons["route-check-submit"])
    XCTAssertTrue(app.staticTexts["YouTube через запасной"].waitForExistence(timeout: 10))
  }

  func testNewChainRejectsACycleAndKeepsDraft() {
    let app = launch(screen: "routes-test")
    tap(app.buttons["tab-rules"])
    tap(app.segmentedControls.buttons["Настройки"].firstMatch)
    tap(app.buttons["rules-chains"])
    tap(app.buttons["new-chain"])
    let save = app.buttons["chain-save"]
    XCTAssertFalse(save.isEnabled)
    tap(app.buttons["chain-entry"])
    tap(app.buttons["picker-profile-demo-node"])
    tap(app.buttons["chain-exit"])
    XCTAssertFalse(app.buttons["picker-profile-demo-node"].exists)
    tap(app.buttons["picker-profile-demo-entry"])
    tap(save)
    let error = app.staticTexts["chain-save-error"]
    XCTAssertTrue(error.waitForExistence(timeout: 10))
    XCTAssertTrue(error.label.contains("Цепочка замыкается"))
    XCTAssertTrue(app.navigationBars["Новая цепочка"].exists)
  }

  func testNewChainCanUseAnEntireServerGroup() {
    let app = launch(screen: "routes-test")
    tap(app.buttons["tab-subscriptions"])
    tap(app.buttons["manage-server-groups"])
    tap(app.buttons["create-server-group"])
    let name = app.textFields["server-group-name"]
    tap(name)
    name.typeText("Work\n")
    let primary = app.descendants(matching: .any)["group-server-demo-entry"].firstMatch
    XCTAssertTrue(primary.waitForExistence(timeout: 10))
    primary.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    let saveGroup = app.buttons["server-group-save"]
    let canSave = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: saveGroup)
    XCTAssertEqual(XCTWaiter.wait(for: [canSave], timeout: 10), .completed)
    tap(saveGroup)
    XCTAssertTrue(app.navigationBars["Группы серверов"].waitForExistence(timeout: 10))

    tap(app.buttons["tab-rules"])
    tap(app.segmentedControls.buttons["Настройки"].firstMatch)
    tap(app.buttons["rules-chains"])
    tap(app.buttons["new-chain"])
    tap(app.buttons["chain-entry"])
    let group = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
      "picker-profile-", "Work")).firstMatch
    tap(group)
    tap(app.buttons["chain-exit"])
    tap(app.buttons["picker-profile-demo-third"])
    tap(app.buttons["chain-save"])
    let saved = app.buttons["saved-chain-demo-third"]
    XCTAssertTrue(saved.waitForExistence(timeout: 10))
    XCTAssertTrue(saved.label.contains("Work"))
  }
}

final class CompactLayoutTests: XCTestCase {
  private func launch() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["HYROUTE_LAYOUT_PREVIEW"] = "home"
    app.launchEnvironment["HYROUTE_UI_TEST"] = "1"
    app.launch()
    return app
  }

  func testLargeTextHomeAndSubscriptionControlsRemainReachable() {
    let app = launch()
    let status = app.staticTexts["dashboard-vpn-status"]
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    XCTAssertGreaterThan(status.frame.height, 24, "Expected accessibility content size")
    XCTAssertTrue(app.buttons["dashboard-vpn-button"].isHittable)
    let details = app.buttons["dashboard-server-details-preview"]
    let connect = app.buttons["dashboard-vpn-button"]
    let pinnedPosition = connect.frame.minY
    revealDashboardDetails(details, in: app)
    XCTAssertTrue(details.isHittable)
    XCTAssertTrue(connect.isHittable)
    XCTAssertEqual(connect.frame.minY, pinnedPosition, accuracy: 2)
    details.tap()
    XCTAssertTrue(app.buttons["subscription-check-all"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["subscription-check-all"].isHittable)
    XCTAssertLessThanOrEqual(app.buttons["subscription-check-all"].frame.maxX, app.frame.maxX)
  }

  func testLargeTextRulesCanScrollPastRepairControls() {
    let app = launch()
    let tab = app.buttons["tab-rules"]
    XCTAssertTrue(tab.waitForExistence(timeout: 10))
    tab.tap()
    let lastRule = app.buttons["rule-row-7"]
    for _ in 0..<10 where !lastRule.isHittable { app.swipeUp() }
    XCTAssertTrue(lastRule.isHittable)
    lastRule.tap()
    XCTAssertTrue(app.buttons["rule-save"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["rule-save"].isHittable)
  }
}
