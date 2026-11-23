import Foundation

@main
struct StateCompatibility {
  static func main() throws {
    let old = Data(#"""
      {
        "subscriptions":[{"id":"saved","canRefresh":true,"servers":[
          {"id":"server","name":"Netherlands","host":"node.example","protocol":"vless"},
          {"id":"auto","name":"⚡️ Автовыбор","protocol":"vless","balance":true,"balanceStrategy":"leastPing"}
        ]}],
        "settings":{"selected":"server","routing":{"defaultAction":"direct","defaultProfile":"server","defaultFallback":["auto"],"rules":[
          {"id":"video","name":"YouTube","action":"tunnel","domains":["geosite:youtube"],"domain":{"pattern":".youtube.com"},
           "ports":[443,"8000-8100"],"protocol":"tcp","profile":"auto","fallback":["server"],"failMode":"closed",
           "apps":[{"pattern":"com.example.video","kind":"package","inheritChildren":true}]}
        ],"viaProfiles":{"auto":"server"}}}
      }
      """#.utf8)
    let state = try JSONDecoder().decode(ClientState.self, from: old)
    precondition(state.subscriptions.first?.canRefresh == true)
    precondition(state.profiles.map(\.id) == ["auto", "server"])
    precondition(state.profiles.first?.transport == "VLESS · leastPing")
    precondition(state.selected?.id == "server")
    let encoded = try JSONEncoder().encode(state.settings)
    let decoded = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    let routing = decoded?["routing"] as? [String: Any]
    let rules = routing?["rules"] as? [[String: Any]]
    precondition(routing?["defaultAction"] as? String == "direct")
    precondition(routing?["defaultProfile"] as? String == "server")
    precondition(routing?["defaultFallback"] as? [String] == ["auto"])
    precondition(routing?["viaProfiles"] as? [String: String] == ["auto": "server"])
    precondition(rules?.first?["protocol"] as? String == "tcp")
    precondition(rules?.first?["profile"] as? String == "auto")
    precondition(rules?.first?["ports"] as? String == "443,8000-8100")
    precondition(rules?.first?["id"] as? String == "video")
    precondition(rules?.first?["name"] as? String == "YouTube")
    precondition(rules?.first?["fallback"] as? [String] == ["server"])
    precondition(rules?.first?["failMode"] as? String == "closed")
    precondition((rules?.first?["domain"] as? [String: String])?["pattern"] == ".youtube.com")
    precondition((rules?.first?["apps"] as? [[String: Any]])?.first?["inheritChildren"] as? Bool == true)
    precondition(state.settings.routing.rules.first?.destinations == ["geosite:youtube", ".youtube.com"])
    precondition(state.settings.routing.unavailableChainExits(available: ["auto", "server"]).isEmpty)
    var broken = state.settings.routing
    broken.viaProfiles["old"] = "auto"
    precondition(broken.unavailableChainExits(available: ["auto"]) == ["auto", "old"])
    broken.rules[0].profile = "old"
    precondition(broken.unavailableRuleIndices(available: ["auto", "server"]) == [0])
    broken.rules[0].enabled = false
    precondition(broken.unavailableRuleIndices(available: ["auto", "server"]).isEmpty)
    precondition(state.profileTitle("server") == "Netherlands")
    precondition(state.profileTitle("old") == "Удалённый профиль")
    let blank = try JSONDecoder().decode(ClientState.self, from: Data(#"{"subscriptions":[],"settings":{}}"#.utf8))
    precondition(blank.settings.routing.defaultAction == .tunnel)
    precondition(blank.selected == nil)
    precondition(ruleDestinations("https://example.org/path?token=test\nexample.org\ngeoip:ru\n::1") == ["example.org", "geoip:ru", "::1"])
    precondition(RuleDomainCondition.suffix.patterns("ru\n.co.uk") == [".ru", ".co.uk"])
    precondition(RuleDomainCondition.contains.patterns("pzdcflix\nkeyword:example") == ["keyword:pzdcflix", "keyword:example"])
    precondition(RuleDomainCondition.suffix.patterns(".ru не сайт") == nil)
    precondition(RuleDomainCondition.suffix.value(from: ".ru") == ".ru")
    precondition(RuleDomainCondition.contains.value(from: "keyword:pzdcflix") == "pzdcflix")
    precondition(RuleDomainCondition.summary("regexp:^demo") == "regexp:^demo")
    let events = Data(#"[{"at":0,"message":"VPN"}]"#.utf8)
    let plusFive = try VPNJournalEvent.lines(events, timeZone: TimeZone(secondsFromGMT: 5 * 3600)!)
    let minusFive = try VPNJournalEvent.lines(events, timeZone: TimeZone(secondsFromGMT: -5 * 3600)!)
    precondition(plusFive == ["01.01 05:00:00  VPN"])
    precondition(minusFive == ["31.12 19:00:00  VPN"])
  }
}
