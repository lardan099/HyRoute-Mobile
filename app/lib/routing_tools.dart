import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core.dart';

class RoutingProfilesPage extends StatefulWidget {
  const RoutingProfilesPage({
    super.key,
    required this.profiles,
    required this.active,
    required this.onChange,
  });

  final List<RoutingProfile> profiles;
  final String active;
  final Future<ClientState> Function(String operation, String id, String name)
  onChange;

  @override
  State<RoutingProfilesPage> createState() => _RoutingProfilesPageState();
}

class _RoutingProfilesPageState extends State<RoutingProfilesPage> {
  late var _profiles = widget.profiles;
  late var _active = widget.active;
  bool _busy = false;
  String? _error;

  Future<void> _change(
    String operation, {
    String id = '',
    String name = '',
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final state = await widget.onChange(operation, id, name);
      if (mounted) {
        setState(() {
          _profiles = state.routingProfiles;
          _active = state.activeRoutingProfile;
        });
      }
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () =>
              _error = error.message ?? 'Не удалось сохранить профиль правил.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([RoutingProfile? profile]) async {
    var name = profile?.name ?? '';
    final result = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(profile == null ? 'Новый профиль' : 'Название профиля'),
        content: TextFormField(
          autofocus: true,
          initialValue: name,
          maxLength: 40,
          onChanged: (value) => name = value.trim(),
          decoration: const InputDecoration(labelText: 'Название профиля'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () {
              if (name.isNotEmpty) Navigator.pop(dialog, name);
            },
            child: const Text('Сохранить'),
          ),
        ],
      ),
    );
    if (mounted && result != null) {
      await _change(
        profile == null ? 'copy' : 'rename',
        id: profile?.id ?? '',
        name: result,
      );
    }
  }

  Future<void> _delete(RoutingProfile profile) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text('Удалить «${profile.name}»?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Отмена'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Удалить'),
          ),
        ],
      ),
    );
    if (mounted && confirmed == true) await _change('delete', id: profile.id);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Профили правил')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_busy) const LinearProgressIndicator(),
        for (final profile in _profiles)
          Card(
            child: ListTile(
              title: Text(profile.name),
              subtitle: Text('Правил: ${profile.ruleCount}'),
              leading: Icon(
                profile.id == _active
                    ? Icons.check_circle
                    : Icons.layers_outlined,
              ),
              selected: profile.id == _active,
              onTap: _busy || profile.id == _active
                  ? null
                  : () => _change('activate', id: profile.id),
              trailing: PopupMenuButton<String>(
                enabled: !_busy,
                onSelected: (action) {
                  if (action == 'rename') {
                    _edit(profile);
                  } else {
                    _delete(profile);
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'rename',
                    child: Text('Переименовать'),
                  ),
                  if (profile.id != 'default' && profile.id != _active)
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Удалить'),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _busy ? null : () => _edit(),
          icon: const Icon(Icons.add),
          label: const Text('Создать копию текущего'),
        ),
        if (_error case final message?)
          Text(
            message,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        const Padding(
          padding: EdgeInsets.only(top: 12),
          child: Text(
            'При активном VPN новые правила применятся после переподключения.',
          ),
        ),
      ],
    ),
  );
}

class RouteCheckPage extends StatefulWidget {
  const RouteCheckPage({
    super.key,
    required this.core,
    required this.serverName,
    this.pickApp,
  });

  final RoutingControl core;
  final String Function(String id) serverName;
  final Future<MapEntry<String, String>?> Function()? pickApp;

  @override
  State<RouteCheckPage> createState() => _RouteCheckPageState();
}

class _RouteCheckPageState extends State<RouteCheckPage> {
  final _address = TextEditingController();
  final _ip = TextEditingController();
  String _protocol = 'tcp';
  MapEntry<String, String>? _app;
  CheckedRoute? _result;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _address.dispose();
    _ip.dispose();
    super.dispose();
  }

  void _clear() => setState(() {
    _error = null;
    _result = null;
  });

  Future<void> _check() async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _result = null;
      _error = null;
    });
    try {
      final checked = await widget.core.checkRoute(
        _address.text,
        ip: _ip.text,
        protocol: _protocol,
        packageID: _app?.key ?? '',
      );
      if (mounted) setState(() => _result = checked);
    } on PlatformException catch (error) {
      if (mounted) {
        setState(
          () => _error = error.message ?? 'Не удалось проверить маршрут.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Проверить адрес')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _address,
          enabled: !_busy,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Сайт, ссылка или IP'),
          onChanged: (_) => _clear(),
        ),
        ExpansionTile(
          title: Text(_app?.value ?? 'IP и протокол'),
          children: [
            TextField(
              controller: _ip,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'IP сайта, если известен',
              ),
              onChanged: (_) => _clear(),
            ),
            DropdownButton<String>(
              value: _protocol,
              items: const [
                DropdownMenuItem(value: 'tcp', child: Text('TCP')),
                DropdownMenuItem(value: 'udp', child: Text('UDP')),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      _protocol = value ?? 'tcp';
                      _clear();
                    },
            ),
            if (widget.pickApp case final pick?)
              ListTile(
                title: Text(_app?.value ?? 'Выбрать приложение'),
                onTap: _busy
                    ? null
                    : () async {
                        final app = await pick();
                        if (mounted && app != null) {
                          _app = app;
                          _clear();
                        }
                      },
                trailing: _app == null
                    ? null
                    : IconButton(
                        tooltip: 'Очистить приложение',
                        icon: const Icon(Icons.clear),
                        onPressed: _busy
                            ? null
                            : () {
                                _app = null;
                                _clear();
                              },
                      ),
              ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: _busy || _address.text.trim().isEmpty ? null : _check,
          child: Text(_busy ? 'Проверяем…' : 'Проверить'),
        ),
        if (_error case final message?)
          Text(
            message,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_result case final route?)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    route.action.label,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(route.target),
                  if (route.rule.isNotEmpty)
                    Text(
                      route.rule == 'default'
                          ? 'Правило по умолчанию'
                          : route.rule,
                    ),
                  for (final (i, hop) in route.chain.indexed)
                    Text(
                      route.chain.length == 1
                          ? widget.serverName(hop)
                          : '${i + 1}. ${widget.serverName(hop)}',
                    ),
                  for (final note in route.notes)
                    Text(note, style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}

class SubscriptionDetails extends StatelessWidget {
  const SubscriptionDetails({super.key, required this.subscription});
  final Subscription subscription;

  static String _bytes(int value) {
    const units = ['Б', 'КиБ', 'МиБ', 'ГиБ', 'ТиБ', 'ПиБ', 'ЭиБ'];
    var unit = 0;
    var amount = value.toDouble();
    while (amount >= 1024 && unit + 1 < units.length) {
      amount /= 1024;
      unit++;
    }
    final digits = amount.truncateToDouble() == amount || amount >= 100 ? 0 : 1;
    return '${amount.toStringAsFixed(digits).replaceAll('.', ',')} ${units[unit]}';
  }

  @override
  Widget build(BuildContext context) {
    final item = subscription;
    final used = item.usedBytes;
    final limit = item.limitBytes;
    if (!item.canRefresh &&
        used == null &&
        limit == null &&
        item.expiresAt == null) {
      return const SizedBox.shrink();
    }
    final local = MaterialLocalizations.of(context);
    DateTime? date(int? epoch) => epoch == null || epoch <= 0
        ? null
        : DateTime.fromMillisecondsSinceEpoch(epoch * 1000);
    String timestamp(DateTime value) =>
        '${local.formatCompactDate(value)} ${local.formatTimeOfDay(TimeOfDay.fromDateTime(value))}';
    final expiry = date(item.expiresAt);
    final refreshed = date(item.refreshedAt);
    final attempted = date(item.attemptedAt);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (used != null && limit != null && limit > 0) ...[
            Text('${_bytes(used)} из ${_bytes(limit)}'),
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: (used / limit).clamp(0.0, 1.0).toDouble(),
            ),
          ] else if (used != null)
            Text('Трафик ${_bytes(used)}${limit == 0 ? ' · без лимита' : ''}')
          else if (limit != null)
            Text(limit == 0 ? 'Без лимита трафика' : 'Лимит ${_bytes(limit)}'),
          if (expiry != null)
            Text(
              '${expiry.isBefore(DateTime.now()) ? 'Истекла' : 'Действует до'} ${local.formatCompactDate(expiry)}',
            ),
          if (item.canRefresh) ...[
            if (item.refreshFailed)
              Text(
                attempted == null
                    ? 'Обновление не удалось'
                    : 'Обновление не удалось · ${timestamp(attempted)}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Text(
              refreshed == null
                  ? 'Нет даты обновления'
                  : 'Обновлена ${timestamp(refreshed)}',
            ),
          ],
        ],
      ),
    );
  }
}
