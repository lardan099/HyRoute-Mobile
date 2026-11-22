import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

abstract interface class ClientCore {
  bool get supportsAndroidRules;
  Future<Subscription> importSubscription(String input);
  Future<void> validateRouting(String configuration, String? selectedServer);
}

class PlatformCore implements ClientCore {
  const PlatformCore();

  static const _channel = MethodChannel('io.hyroute/core');

  @override
  bool get supportsAndroidRules =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<Subscription> importSubscription(String input) async {
    final uri = Uri.tryParse(input);
    final result = await _channel.invokeMethod<String>('importSubscription', {
      'input': input,
      'fromUrl': uri?.scheme == 'https' && !input.contains(RegExp(r'\s')),
    });
    if (result == null) throw const FormatException('Missing subscription');
    return Subscription.fromJson(jsonDecode(result) as Map<String, dynamic>);
  }

  @override
  Future<void> validateRouting(
    String configuration,
    String? selectedServer,
  ) async {
    if (kIsWeb) return;
    await _channel.invokeMethod<void>('validateRouting', {
      'configuration': configuration,
      'selectedServer': selectedServer ?? '',
    });
  }
}

class Server {
  const Server({
    required this.id,
    required this.name,
    required this.protocol,
    this.host = '',
    this.missing = false,
  });

  factory Server.fromJson(Map<String, dynamic> json) {
    final host = json['host'] as String? ?? '';
    final name = json['name'] as String? ?? '';
    return Server(
      id: json['id'] as String,
      name: name.isNotEmpty ? name : host,
      host: host,
      protocol: switch ((json['protocol'], json['balance'])) {
        ('vless', true) => 'VLESS · leastLoad',
        ('vless', _) => 'VLESS',
        _ => 'Hysteria 2',
      },
      missing: json['missing'] == true,
    );
  }

  final String id;
  final String name;
  final String host;
  final String protocol;
  final bool missing;
}

class Subscription {
  const Subscription({required this.servers, this.title = ''});

  factory Subscription.fromJson(Map<String, dynamic> json) {
    final servers = (json['servers'] as List<dynamic>)
        .map((server) => Server.fromJson(server as Map<String, dynamic>))
        .toList(growable: false);
    if (servers.isEmpty) throw const FormatException('Missing servers');
    return Subscription(
      servers: servers,
      title: json['title'] as String? ?? '',
    );
  }

  final List<Server> servers;
  final String title;
}

enum RouteAction {
  tunnel('Через VPN', 'tunnel'),
  direct('Напрямую', 'direct'),
  block('Блокировать', 'block');

  const RouteAction(this.label, this.value);
  final String label;
  final String value;
}

class RouteRule {
  const RouteRule({
    required this.action,
    this.destination = '',
    this.port = '',
    this.package = '',
    this.server = '',
  });

  final RouteAction action;
  final String destination;
  final String port;
  final String package;
  final String server;

  String get title => [
    if (destination.isNotEmpty) destination,
    if (package.isNotEmpty) package,
    if (port.isNotEmpty) 'Порт $port',
  ].join(' · ');

  Map<String, Object> toJson() => {
    'action': action.value,
    if (destination.isNotEmpty) 'domains': [destination],
    if (port.isNotEmpty) 'ports': port,
    if (package.isNotEmpty)
      'apps': [
        {'kind': 'package', 'pattern': package},
      ],
    if (action == RouteAction.tunnel && server.isNotEmpty) 'profile': server,
  };
}

enum AppScope {
  all('Все приложения'),
  only('Только выбранные'),
  except('Все кроме выбранных');

  const AppScope(this.label);
  final String label;
}
