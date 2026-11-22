import XCTest

final class SubscriptionAndRulesTests: XCTestCase {
  private func launch() -> XCUIApplication {
    continueAfterFailure = false
    let app = XCUIApplication()
    app.launchEnvironment["HYROUTE_LAYOUT_PREVIEW"] = "home"
    app.launchEnvironment["HYROUTE_UI_TEST"] = "1"
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
    let save = app.buttons["Сохранить"]
    XCTAssertFalse(save.isEnabled)
    tap(app.buttons["replace-broken-chain-auto"])
    tap(app.buttons["🇫🇮 Хельсинки · Северный узел | Hysteria 2"].firstMatch)
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
}
