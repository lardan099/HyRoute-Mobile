import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core.dart';

class ServerGroupsPage extends StatefulWidget {
  const ServerGroupsPage({
    super.key,
    required this.groups,
    required this.servers,
    required this.save,
  });

  final List<ServerGroup> groups;
  final List<Server> servers;
  final Future<List<ServerGroup>> Function(String id, ServerGroup? group) save;

  @override
  State<ServerGroupsPage> createState() => _ServerGroupsPageState();
}

class _ServerGroupsPageState extends State<ServerGroupsPage> {
  late var _groups = widget.groups;

  Future<void> _edit(ServerGroup? group) async {
    final changed = await Navigator.of(context).push<List<ServerGroup>>(
      MaterialPageRoute(
        builder: (_) => _ServerGroupEditor(
          group: group,
          servers: widget.servers,
          save: widget.save,
        ),
      ),
    );
    if (mounted && changed != null) setState(() => _groups = changed);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Группы серверов')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        FilledButton.icon(
          onPressed: widget.servers.isEmpty ? null : () => _edit(null),
          icon: const Icon(Icons.add),
          label: const Text('Создать группу'),
        ),
        if (widget.servers.isEmpty)
          const ListTile(title: Text('Добавьте хотя бы один сервер.')),
        for (final group in _groups)
          ListTile(
            title: Text(group.name),
            subtitle: Text(
              'Основных: ${group.primary.length} · '
              '${group.reserve.isEmpty ? 'без резерва' : 'с резервом'}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _edit(group),
          ),
      ],
    ),
  );
}

class _ServerGroupEditor extends StatefulWidget {
  const _ServerGroupEditor({
    required this.group,
    required this.servers,
    required this.save,
  });

  final ServerGroup? group;
  final List<Server> servers;
  final Future<List<ServerGroup>> Function(String, ServerGroup?) save;

  @override
  State<_ServerGroupEditor> createState() => _ServerGroupEditorState();
}

class _ServerGroupEditorState extends State<_ServerGroupEditor> {
  late final _name = TextEditingController(text: widget.group?.name);
  late final _primary = {...?widget.group?.primary}
    ..removeWhere((id) => !widget.servers.any((server) => server.id == id));
  late String _reserve =
      widget.servers.any((server) => server.id == widget.group?.reserve)
      ? widget.group!.reserve
      : '';
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save(ServerGroup? group) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final groups = await widget.save(widget.group?.id ?? '', group);
      if (mounted) Navigator.pop(context, groups);
    } on PlatformException catch (failure) {
      if (mounted) {
        setState(
          () => _error = failure.message ?? 'Не удалось сохранить группу.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.group == null ? 'Новая группа' : 'Настройки группы'),
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _name,
          maxLength: 80,
          decoration: const InputDecoration(labelText: 'Название'),
        ),
        const ListTile(
          title: Text('Основные серверы'),
          subtitle: Text(
            'HyRoute выбирает доступный сервер с наименьшей задержкой.',
          ),
        ),
        for (final server in widget.servers)
          CheckboxListTile(
            title: Text(server.name),
            subtitle: Text(server.protocol),
            value: _primary.contains(server.id),
            onChanged: _busy || _reserve == server.id
                ? null
                : (value) {
                    setState(() {
                      if (value == true) {
                        _primary.add(server.id);
                      } else {
                        _primary.remove(server.id);
                      }
                    });
                  },
          ),
        DropdownButtonFormField<String>(
          initialValue: _reserve,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Резервный сервер'),
          items: [
            const DropdownMenuItem(value: '', child: Text('Без резерва')),
            for (final server in widget.servers)
              if (!_primary.contains(server.id))
                DropdownMenuItem(
                  value: server.id,
                  child: Text(server.name, overflow: TextOverflow.ellipsis),
                ),
          ],
          onChanged: _busy
              ? null
              : (value) => setState(() => _reserve = value ?? ''),
        ),
        if (_error case final message?) ListTile(title: Text(message)),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy || _primary.isEmpty
              ? null
              : () => _save(
                  ServerGroup('', _name.text, _primary.toList(), _reserve),
                ),
          child: const Text('Сохранить'),
        ),
        if (widget.group != null)
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Удалить группу?'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('Отмена'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('Удалить'),
                          ),
                        ],
                      ),
                    );
                    if (mounted && confirmed == true) await _save(null);
                  },
            child: const Text('Удалить группу'),
          ),
      ],
    ),
  );
}

class SplitDnsPage extends StatefulWidget {
  const SplitDnsPage({super.key, required this.settings, required this.save});

  final SplitDns? settings;
  final Future<String?> Function(SplitDns?) save;

  @override
  State<SplitDnsPage> createState() => _SplitDnsPageState();
}

class _SplitDnsPageState extends State<SplitDnsPage> {
  late var _enabled = widget.settings != null;
  late final _tunnel = TextEditingController(
    text: widget.settings?.tunnel ?? 'https://1.1.1.1/dns-query',
  );
  late final _direct = TextEditingController(
    text: widget.settings?.direct ?? 'https://8.8.8.8/dns-query',
  );
  late final _domains = TextEditingController(
    text: widget.settings?.domains.join('\n'),
  );
  var _busy = false;
  String? _error;

  @override
  void dispose() {
    _tunnel.dispose();
    _direct.dispose();
    _domains.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final failure = await widget.save(
      _enabled
          ? SplitDns(
              _tunnel.text.trim(),
              _direct.text.trim(),
              _domains.text
                  .split('\n')
                  .map((domain) => domain.trim())
                  .where((domain) => domain.isNotEmpty)
                  .toList(),
            )
          : null,
    );
    if (!mounted) return;
    if (failure == null) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = false;
      _error = failure;
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Раздельный DNS')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        SwitchListTile(
          title: const Text('Включить'),
          value: _enabled,
          onChanged: _busy
              ? null
              : (enabled) => setState(() => _enabled = enabled),
        ),
        if (_enabled) ...[
          TextField(
            controller: _tunnel,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'DNS через VPN'),
          ),
          TextField(
            controller: _direct,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'DNS напрямую'),
          ),
          const ListTile(
            title: Text(
              'Укажите HTTPS-адреса с IP. Сертификат сервера должен поддерживать этот IP.',
            ),
          ),
          TextField(
            controller: _domains,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'Домены для DNS напрямую',
              hintText: 'example.org',
              helperText: 'Один на строку. Действует и для поддоменов.',
            ),
          ),
        ],
        if (_error case final message?) ListTile(title: Text(message)),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: const Text('Сохранить'),
        ),
      ],
    ),
  );
}
