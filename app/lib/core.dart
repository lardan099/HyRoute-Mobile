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

class PlatformCore implements ClientCore {
  const PlatformCore();

  static const _channel = MethodChannel('io.hyroute/core');

  @override
  bool get supportsAndroidRules =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

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
  Future<List<String>> geoTags() async {
    final raw = await _channel.invokeMethod<String>('geoTags');
    if (raw == null) throw const FormatException('Missing geodata');
    return (jsonDecode(raw) as List<dynamic>).cast<String>();
  }

  @override
  Future<void> updateGeo() => _channel.invokeMethod<void>('updateGeo');

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
    );
  }

  final List<Server> servers;
  final String id;
  final String title;
  final bool canRefresh;
}

class ClientState {
  const ClientState({
    this.subscriptions = const [],
    this.settings = const ClientSettings(),
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
    );
  }

  final List<Subscription> subscriptions;
  final ClientSettings settings;
}

class ClientSettings {
  const ClientSettings({
    this.selected,
    this.rules = const [],
    this.defaultAction = RouteAction.tunnel,
    this.via = const {},
    this.scope = AppScope.all,
    this.packages = const [],
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
    );
  }

  final String? selected;
  final List<RouteRule> rules;
  final RouteAction defaultAction;
  final Map<String, String> via;
  final AppScope scope;
  final List<String> packages;

  Map<String, Object> toJson() => {
    'selected': ?selected,
    'routing': {
      'defaultAction': defaultAction.value,
      'rules': rules.map((rule) => rule.toJson()).toList(),
      'viaProfiles': via,
    },
    'appScope': scope.name,
    'appPackages': packages,
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
    if (destination.isNotEmpty) destination.replaceAll('\n', ', '),
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
