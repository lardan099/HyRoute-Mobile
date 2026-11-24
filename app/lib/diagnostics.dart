import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core.dart';

Future<void> pollProbe(
  DiagnosticsControl core,
  String scope,
  String id, {
  required bool Function() active,
  required void Function(ProbeSnapshot) report,
}) async {
  var snapshot = await core.startProbe(scope, id);
  while (active()) {
    report(snapshot);
    if (snapshot.done) return;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (!active()) return;
    snapshot = await core.probeStatus();
  }
}

String probeRowLabel(Map<String, dynamic> row) => switch (row['status']) {
  'ok' => '${row['ms']} мс',
  'running' => 'Проверка…',
  'pending' => 'В очереди',
  'timeout' => 'Тайм-аут',
  'dns' => 'Ошибка DNS',
  'configuration' => 'Ошибка профиля',
  'response' => 'Ответ не 204',
  'cancelled' => 'Отменено',
  _ => 'Нет соединения',
};

class VPNJournalPage extends StatefulWidget {
  const VPNJournalPage({super.key, required this.core});

  final DiagnosticsControl core;

  @override
  State<VPNJournalPage> createState() => _VPNJournalPageState();
}

class _VPNJournalPageState extends State<VPNJournalPage> {
  List<String> _lines = const [];
  bool _loading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final lines = await widget.core.vpnJournal();
      if (mounted) {
        setState(() {
          _lines = lines;
          _failed = false;
        });
      }
    } on Exception {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Журнал VPN'),
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Обновить',
          onPressed: _load,
        ),
        IconButton(
          icon: const Icon(Icons.copy),
          tooltip: 'Копировать журнал',
          onPressed: _lines.isEmpty
              ? null
              : () => Clipboard.setData(ClipboardData(text: _lines.join('\n'))),
        ),
      ],
    ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : _failed || _lines.isEmpty
        ? Center(
            child: Text(
              _failed ? 'Не удалось прочитать журнал' : 'Событий пока нет',
            ),
          )
        : RefreshIndicator(
            onRefresh: _load,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: _lines.length,
              separatorBuilder: (_, _) => const Divider(height: 20),
              itemBuilder: (_, index) => SelectableText(_lines[index]),
            ),
          ),
  );
}

class ProbePage extends StatefulWidget {
  const ProbePage({
    super.key,
    required this.core,
    required this.scope,
    required this.id,
  });

  final DiagnosticsControl core;
  final String scope;
  final String id;

  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> {
  ProbeSnapshot? _snapshot;
  bool _running = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _failed = false;
      _snapshot = null;
    });
    try {
      await pollProbe(
        widget.core,
        widget.scope,
        widget.id,
        active: () => mounted,
        report: (snapshot) => setState(() => _snapshot = snapshot),
      );
    } on Exception {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<void> _cancel() async {
    try {
      await widget.core.cancelProbe();
    } on Exception {
      /* The page may have lost its native channel. */
    }
  }

  @override
  void dispose() {
    unawaited(_cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final results = _snapshot?.results ?? const [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Задержка серверов'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Повторить замер',
            onPressed: _running ? null : _run,
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_running) const LinearProgressIndicator(),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('HTTPS-запрос через каждый сервер'),
          ),
          if (_failed)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('Не удалось проверить выбранные серверы'),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: results.length,
              itemBuilder: (context, index) {
                final row = results[index];
                final label = probeRowLabel(row);
                return ListTile(
                  title: Text(row['name'] as String),
                  subtitle: Text(
                    [
                      if (row['host'] case final String host) host,
                      label,
                    ].join(' · '),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
