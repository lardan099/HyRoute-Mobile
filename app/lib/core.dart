import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class ClientCore {
  bool get supportsAndroidRules;
  Future<ClientState> loadState();
  Future<ClientState> importSubscription(String input);
  Future<ClientState> refreshSubscription(String id);
  Future<void> saveSettings(ClientSettings settings);
  Future<List<String>> geoTags();
  Future<void> updateGeo();
  Future<Map<String, String>> launchableApps();
}

abstract interface class VPNControl {
  bool get vpnAvailable;
  Future<String> vpnStatus();
  Future<void> startVpn();
  Future<void> stopVpn();
}

abstract interface class VPNSystemSettings {
  Future<void> openVpnSettings();
}

abstract interface class ServerGroupControl {
  Future<ClientState> changeServerGroup(String id, ServerGroup? group);
}

abstract interface class MaintenanceControl {
  Future<ClientState> refreshDue();
  Future<Map<String, String>> geoSources();
  Future<void> setGeoSource(String kind, String address);
  Future<bool> importGeoFile(String kind);
}

abstract interface class RoutingControl {
  Future<ClientState> changeRoutingProfile(
    String operation, {
    String id = '',
    String name = '',
  });
  Future<CheckedRoute> checkRoute(
    String address, {
    required String ip,
    required String protocol,
    required String packageID,
  });
}

abstract interface class DiagnosticsControl {
  Future<List<String>> vpnJournal();
  Future<ProbeSnapshot> startProbe(String scope, String id);
  Future<ProbeSnapshot> probeStatus();
  Future<void> cancelProbe();
}

List<String> formatVpnJournal(String raw) {
  String twoDigits(int value) => value.toString().padLeft(2, '0');

  return (jsonDecode(raw) as List<dynamic>).map((entry) {
    final event = entry as Map<String, dynamic>;
    final local = DateTime.fromMillisecondsSinceEpoch(event['at'] as int);
    final day = '${twoDigits(local.day)}.${twoDigits(local.month)}';
    final clock =
        '${twoDigits(local.hour)}:${twoDigits(local.minute)}:${twoDigits(local.second)}';
    return '$day $clock  ${event['message']}';
  }).toList();
}

class ProbeSnapshot {
  const ProbeSnapshot(this.done, this.results);

  factory ProbeSnapshot.decode(String? raw) {
    if (raw == null) throw const FormatException('Missing probe snapshot');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return ProbeSnapshot(
      json['done'] as bool,
      (json['results'] as List<dynamic>).cast<Map<String, dynamic>>(),
    );
  }

  final bool done;
  final List<Map<String, dynamic>> results;
}

class PlatformCore
    implements
        ClientCore,
        VPNControl,
        VPNSystemSettings,
        ServerGroupControl,
        DiagnosticsControl,
        MaintenanceControl,
        RoutingControl {
  const PlatformCore();

  static const _channel = MethodChannel('io.hyroute/core');

  @override
  bool get supportsAndroidRules =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  bool get vpnAvailable => supportsAndroidRules;

  @override
  Future<String> vpnStatus() async =>
      await _channel.invokeMethod<String>('vpnStatus') ?? 'off';

  @override
  Future<void> startVpn() => _channel.invokeMethod<void>('startVpn');

  @override
  Future<void> stopVpn() => _channel.invokeMethod<void>('stopVpn');

  @override
  Future<void> openVpnSettings() =>
      _channel.invokeMethod<void>('openVpnSettings');

  @override
  Future<ClientState> changeServerGroup(String id, ServerGroup? group) async =>
      ClientState.decode(
        await _channel.invokeMethod<String>('changeServerGroup', {
          'id': id,
          'definition': group == null ? '' : jsonEncode(group.toJson()),
        }),
      );

  @override
  Future<List<String>> vpnJournal() async {
    final raw = await _channel.invokeMethod<String>('vpnJournal');
    return formatVpnJournal(raw ?? '[]');
  }

  @override
  Future<ProbeSnapshot> startProbe(String scope, String id) async =>
      ProbeSnapshot.decode(
        await _channel.invokeMethod<String>('probeStart', {
          'scope': scope,
          'id': id,
        }),
      );

  @override
  Future<ProbeSnapshot> probeStatus() async =>
      ProbeSnapshot.decode(await _channel.invokeMethod<String>('probeStatus'));

  @override
  Future<void> cancelProbe() => _channel.invokeMethod<void>('probeCancel');

  @override
  Future<ClientState> loadState() async {
    if (kIsWeb) return const ClientState();
    final result = await _channel.invokeMethod<String>('loadState');
    return ClientState.decode(result);
  }

  @override
  Future<ClientState> importSubscription(String input) async {
    final uri = Uri.tryParse(input);
    final result = await _channel.invokeMethod<String>('importSubscription', {
      'input': input,
      'fromUrl': uri?.scheme == 'https' && !input.contains(RegExp(r'\s')),
    });
    return ClientState.decode(result);
  }

  @override
  Future<ClientState> refreshSubscription(String id) async {
    final result = await _channel.invokeMethod<String>('refreshSubscription', {
      'id': id,
    });
    return ClientState.decode(result);
  }

  @override
  Future<void> saveSettings(ClientSettings settings) async {
    if (kIsWeb) return;
    await _channel.invokeMethod<void>('saveSettings', {
      'settings': jsonEncode(settings.toJson()),
    });
  }

  @override
  Future<ClientState> changeRoutingProfile(
    String operation, {
    String id = '',
    String name = '',
  }) async => ClientState.decode(
    await _channel.invokeMethod<String>('changeRoutingProfile', {
      'operation': operation,
      'id': id,
      'name': name,
    }),
  );

  @override
  Future<CheckedRoute> checkRoute(
    String address, {
    required String ip,
    required String protocol,
    required String packageID,
  }) async {
    final result = await _channel.invokeMethod<String>('checkRoute', {
      'address': address,
      'ip': ip,
      'protocol': protocol,
      'package': packageID,
    });
    if (result == null) throw const FormatException('Missing route');
    return CheckedRoute.fromJson(jsonDecode(result) as Map<String, dynamic>);
  }

  @override
  Future<List<String>> geoTags() async {
    final raw = await _channel.invokeMethod<String>('geoTags');
    if (raw == null) throw const FormatException('Missing geodata');
    return (jsonDecode(raw) as List<dynamic>).cast<String>();
  }

  @override
  Future<void> updateGeo() => _channel.invokeMethod<void>('updateGeo');

  @override
  Future<ClientState> refreshDue() async =>
      ClientState.decode(await _channel.invokeMethod<String>('refreshDue'));

  @override
  Future<Map<String, String>> geoSources() async =>
      await _channel.invokeMapMethod<String, String>('geoSources') ?? {};

  @override
  Future<void> setGeoSource(String kind, String address) => _channel
      .invokeMethod<void>('setGeoSource', {'kind': kind, 'address': address});

  @override
  Future<bool> importGeoFile(String kind) async =>
      await _channel.invokeMethod<bool>('importGeoFile', {'kind': kind}) ??
      false;

  @override
  Future<Map<String, String>> launchableApps() async =>
      await _channel.invokeMapMethod<String, String>('launchableApps') ?? {};
}

class Server {
  const Server({
    required this.id,
    required this.name,
    required this.protocol,
    this.host = '',
    this.missing = false,
    this.balance = false,
  });

  factory Server.fromJson(Map<String, dynamic> json) {
    final host = json['host'] as String? ?? '';
    final name = json['name'] as String? ?? '';
    return Server(
      id: json['id'] as String,
      name: name.isNotEmpty ? name : host,
      host: host,
      protocol: switch ((json['protocol'], json['balance'])) {
        ('group', _) => 'Группа серверов',
        ('vless', true) => 'VLESS · ${json['balanceStrategy'] ?? 'leastLoad'}',
        ('vless', _) => 'VLESS',
        _ => 'Hysteria 2',
      },
      missing: json['missing'] == true,
      balance: json['balance'] == true,
    );
  }

  final String id;
  final String name;
  final String host;
  final String protocol;
  final bool missing;
  final bool balance;
}

class Subscription {
  const Subscription({
    required this.id,
    required this.servers,
    this.title = '',
    this.canRefresh = false,
    this.usedBytes,
    this.limitBytes,
    this.expiresAt,
    this.refreshedAt,
    this.attemptedAt,
    this.refreshFailed = false,
  });

  factory Subscription.fromJson(Map<String, dynamic> json) {
    final servers = (json['servers'] as List<dynamic>)
        .map((server) => Server.fromJson(server as Map<String, dynamic>))
        .toList(growable: false);
    if (servers.isEmpty) throw const FormatException('Missing servers');
    return Subscription(
      id: json['id'] as String,
      servers: servers,
      title: json['title'] as String? ?? '',
      canRefresh: json['canRefresh'] == true,
      usedBytes: json['usedBytes'] as int?,
      limitBytes: json['limitBytes'] as int?,
      expiresAt: json['expiresAt'] as int?,
      refreshedAt: json['refreshedAt'] as int?,
      attemptedAt: json['attemptedAt'] as int?,
      refreshFailed: json['refreshFailed'] == true,
    );
  }

  final List<Server> servers;
  final String id;
  final String title;
  final bool canRefresh;
  final int? usedBytes;
  final int? limitBytes;
  final int? expiresAt;
  final int? refreshedAt;
  final int? attemptedAt;
  final bool refreshFailed;
}

class RoutingProfile {
  const RoutingProfile(this.id, this.name, this.ruleCount);

  factory RoutingProfile.fromJson(Map<String, dynamic> json) => RoutingProfile(
    json['id'] as String,
    json['name'] as String,
    json['ruleCount'] as int,
  );

  final String id;
  final String name;
  final int ruleCount;
}

class CheckedRoute {
  const CheckedRoute({
    required this.target,
    required this.action,
    required this.rule,
    this.chain = const [],
    this.notes = const [],
  });

  factory CheckedRoute.fromJson(Map<String, dynamic> json) => CheckedRoute(
    target: json['target'] as String,
    action: RouteAction.fromValue(json['action']),
    rule: json['rule'] as String,
    chain: (json['chain'] as List<dynamic>? ?? const []).cast<String>(),
    notes: (json['notes'] as List<dynamic>? ?? const []).cast<String>(),
  );

  final String target;
  final RouteAction action;
  final String rule;
  final List<String> chain;
  final List<String> notes;
}

class ClientState {
  const ClientState({
    this.subscriptions = const [],
    this.settings = const ClientSettings(),
    this.routingProfiles = const [],
    this.serverGroups = const [],
    this.activeRoutingProfile = 'default',
  });

  factory ClientState.decode(String? raw) {
    if (raw == null) throw const FormatException('Missing client state');
    final json = jsonDecode(raw) as Map<String, dynamic>;
    return ClientState(
      subscriptions: (json['subscriptions'] as List<dynamic>)
          .map((item) => Subscription.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      settings: ClientSettings.fromJson(
        json['settings'] as Map<String, dynamic>,
      ),
      routingProfiles: (json['routingProfiles'] as List<dynamic>? ?? const [])
          .map((item) => RoutingProfile.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      serverGroups: (json['serverGroups'] as List<dynamic>? ?? const [])
          .map((item) => ServerGroup.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      activeRoutingProfile:
          json['activeRoutingProfile'] as String? ?? 'default',
    );
  }

  final List<Subscription> subscriptions;
  final ClientSettings settings;
  final List<RoutingProfile> routingProfiles;
  final List<ServerGroup> serverGroups;
  final String activeRoutingProfile;
}

class ServerGroup {
  const ServerGroup(this.id, this.name, this.primary, this.reserve);

  factory ServerGroup.fromJson(Map<String, dynamic> json) => ServerGroup(
    json['id'] as String,
    json['name'] as String,
    (json['primary'] as List<dynamic>).cast<String>(),
    json['reserve'] as String,
  );

  final String id;
  final String name;
  final List<String> primary;
  final String reserve;

  Map<String, Object> toJson() => {
    'name': name,
    'primary': primary,
    'reserve': reserve,
  };
}

class SplitDns {
  const SplitDns(this.tunnel, this.direct, this.domains);

  factory SplitDns.fromJson(Map<String, dynamic> json) => SplitDns(
    json['tunnel'] as String,
    json['direct'] as String,
    (json['domains'] as List<dynamic>).cast<String>(),
  );

  final String tunnel;
  final String direct;
  final List<String> domains;

  Map<String, Object> toJson() => {
    'tunnel': tunnel,
    'direct': direct,
    'domains': domains,
  };
}

class ClientSettings {
  const ClientSettings({
    this.selected,
    this.rules = const [],
    this.defaultAction = RouteAction.tunnel,
    this.via = const {},
    this.scope = AppScope.all,
    this.packages = const [],
    this.splitDns,
  });

  factory ClientSettings.fromJson(Map<String, dynamic> json) {
    final routing = json['routing'] as Map<String, dynamic>? ?? const {};
    return ClientSettings(
      selected: json['selected'] as String?,
      rules: (routing['rules'] as List<dynamic>? ?? const [])
          .map((item) => RouteRule.fromJson(item as Map<String, dynamic>))
          .toList(growable: false),
      defaultAction: RouteAction.fromValue(routing['defaultAction']),
      via: (routing['viaProfiles'] as Map<String, dynamic>? ?? const {})
          .cast<String, String>(),
      scope: AppScope.values.firstWhere(
        (value) => value.name == json['appScope'],
        orElse: () => AppScope.all,
      ),
      packages: (json['appPackages'] as List<dynamic>? ?? const [])
          .cast<String>(),
      splitDns: switch (json['splitDNS']) {
        final Map<String, dynamic> settings => SplitDns.fromJson(settings),
        _ => null,
      },
    );
  }

  final String? selected;
  final List<RouteRule> rules;
  final RouteAction defaultAction;
  final Map<String, String> via;
  final AppScope scope;
  final List<String> packages;
  final SplitDns? splitDns;

  Map<String, Object> toJson() => {
    'selected': ?selected,
    'routing': {
      'defaultAction': defaultAction.value,
      'rules': rules.map((rule) => rule.toJson()).toList(),
      'viaProfiles': via,
    },
    'appScope': scope.name,
    'appPackages': packages,
    if (splitDns case final settings?) 'splitDNS': settings.toJson(),
  };
}

enum RouteAction {
  tunnel('Через VPN', 'tunnel'),
  direct('Напрямую', 'direct'),
  block('Блокировать', 'block');

  const RouteAction(this.label, this.value);
  static RouteAction fromValue(Object? value) => values.firstWhere(
    (action) => action.value == value,
    orElse: () => tunnel,
  );
  String get help => switch (this) {
    tunnel => 'Отправлять через выбранный VPN-профиль.',
    direct => 'Подключаться без VPN.',
    block => 'Запрещать подключение.',
  };
  final String label;
  final String value;
}

List<String> ruleDestinations(String input) => input
    .split('\n')
    .map((line) {
      final value = line.trim();
      final url = Uri.tryParse(value);
      if (url != null &&
          (url.scheme == 'http' || url.scheme == 'https') &&
          url.host.isNotEmpty) {
        return url.host;
      }
      return value;
    })
    .where((item) => item.isNotEmpty)
    .toSet()
    .toList();

enum RuleDomainCondition {
  suffix(
    'Домен заканчивается на',
    '.ru',
    'Например, .ru подходит для mail.yandex.ru.',
  ),
  contains(
    'В домене есть',
    'video',
    'Например, video подходит для cdn-video.example.org.',
  );

  const RuleDomainCondition(this.label, this.example, this.exampleMatch);
  final String label;
  final String example;
  final String exampleMatch;

  String? valueFrom(String pattern) {
    return switch (this) {
      suffix when pattern.startsWith('.') && pattern.length > 1 => pattern,
      contains
          when pattern.toLowerCase().startsWith('keyword:') &&
              pattern.length > 8 =>
        pattern.substring(8),
      _ => null,
    };
  }

  List<String>? patterns(String input) {
    final result = <String>[];
    final invalid = RegExp(r'[\s/:*?#]');
    for (final item in ruleDestinations(input)) {
      var text = valueFrom(item) ?? item;
      if (this == suffix && text.startsWith('*.')) text = text.substring(2);
      if (this == suffix && text.startsWith('.')) text = text.substring(1);
      if (text.isEmpty ||
          invalid.hasMatch(text) ||
          (this == suffix && (text.startsWith('.') || text.contains('..')))) {
        return null;
      }
      result.add('${this == suffix ? '.' : 'keyword:'}$text');
    }
    return result;
  }

  static String summary(String pattern) {
    if (suffix.valueFrom(pattern) case final value?) return 'Окончание $value';
    if (contains.valueFrom(pattern) case final value?) {
      return 'Содержит «$value»';
    }
    return pattern;
  }
}

class RouteRule {
  const RouteRule({
    required this.action,
    this.destination = '',
    this.port = '',
    this.package = '',
    this.appName = '',
    this.server = '',
    this.protocol = '',
  });

  factory RouteRule.fromJson(Map<String, dynamic> json) {
    final apps = json['apps'] as List<dynamic>? ?? const [];
    return RouteRule(
      action: RouteAction.fromValue(json['action']),
      destination: (json['domains'] as List<dynamic>? ?? const []).join('\n'),
      port: json['ports'] as String? ?? '',
      package: apps.isEmpty ? '' : apps.first['pattern'] as String,
      appName: apps.isEmpty ? '' : json['name'] as String? ?? '',
      server: json['profile'] as String? ?? '',
      protocol: json['protocol'] as String? ?? '',
    );
  }

  final RouteAction action;
  final String destination;
  final String port;
  final String package;
  final String appName;
  final String server;
  final String protocol;

  String get title => [
    if (destination.isNotEmpty)
      destination.split('\n').map(RuleDomainCondition.summary).join(', '),
    if (package.isNotEmpty) appName.isEmpty ? package : appName,
    if (port.isNotEmpty) 'Порт $port',
    if (protocol.isNotEmpty) protocol.toUpperCase(),
  ].join(' · ');

  Map<String, Object> toJson() => {
    'action': action.value,
    if (package.isNotEmpty && appName.isNotEmpty) 'name': appName,
    if (destination.isNotEmpty)
      'domains': destination
          .split('\n')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList(),
    if (port.isNotEmpty) 'ports': port,
    if (package.isNotEmpty)
      'apps': [
        {'kind': 'package', 'pattern': package},
      ],
    if (action == RouteAction.tunnel && server.isNotEmpty) 'profile': server,
    if (protocol.isNotEmpty) 'protocol': protocol,
  };
}

enum AppScope {
  all('Все приложения'),
  only('Только выбранные'),
  except('Все кроме выбранных');

  const AppScope(this.label);
  final String label;
}
