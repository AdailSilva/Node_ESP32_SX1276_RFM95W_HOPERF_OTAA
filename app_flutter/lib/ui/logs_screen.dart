// Logs ao vivo (mesma lógica da página /logs): GET /logs_data?from=<n>,
// cabeçalhos X-Log-Start / X-Log-Next, até 3000 linhas na tela.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../core/device_api.dart';
import '../core/file_io.dart';
import '../core/format.dart';
import 'term_view.dart';
import 'theme.dart';
import 'widgets.dart';

/// Cores das linhas e nomes dos arquivos (diferem entre gateway e nó).
class LogStyle {
  const LogStyle({
    required this.err,
    required this.warn,
    required this.ok,
    this.info,
    required this.filterHint,
    required this.deviceDownloadLabel,
    required this.sessionPrefix,
    required this.defaultDownloadName,
  });

  final RegExp err;
  final RegExp warn;
  final RegExp ok;
  final RegExp? info;
  final String filterHint;
  final String deviceDownloadLabel;
  final String sessionPrefix;
  final String defaultDownloadName;

  Color? colorOf(String l) {
    if (err.hasMatch(l)) return AppColors.termErr;
    if (warn.hasMatch(l)) return AppColors.termWarn;
    if (info != null && info!.hasMatch(l)) return AppColors.termInfo;
    if (ok.hasMatch(l)) return AppColors.termOk;
    return null;
  }
}

class LogsView extends StatefulWidget {
  const LogsView({super.key, required this.api, required this.active, required this.style});

  final DeviceApi api;
  final bool active;
  final LogStyle style;

  @override
  State<LogsView> createState() => _LogsViewState();
}

class _LogsViewState extends State<LogsView> {
  final List<String> _lines = [];
  String _part = '';
  int _from = 0;
  bool _paused = false;
  bool _auto = true;
  String _filter = '';
  String _status = 'conectando…';
  Timer? _timer;
  int _gen = 0;
  bool _running = false;
  final ScrollController _scroll = ScrollController();
  final TextEditingController _flt = TextEditingController();

  static final RegExp _ansi = RegExp(r'\x1b\[[0-9;]*[A-Za-z]');

  @override
  void initState() {
    super.initState();
    if (widget.active) _start();
  }

  @override
  void didUpdateWidget(LogsView old) {
    super.didUpdateWidget(old);
    if (widget.active != old.active) {
      widget.active ? _start() : _stop();
    }
  }

  @override
  void dispose() {
    _stop();
    _scroll.dispose();
    _flt.dispose();
    super.dispose();
  }

  void _start() {
    _gen++;
    _running = true;
    _timer?.cancel();
    _poll(_gen);
  }

  void _stop() {
    _running = false;
    _gen++;
    _timer?.cancel();
  }

  void _schedule(int gen, Duration d) {
    if (!_running || gen != _gen) return;
    _timer?.cancel();
    _timer = Timer(d, () => _poll(gen));
  }

  Future<void> _poll(int gen) async {
    if (!_running || gen != _gen || !mounted) return;
    if (_paused) {
      _schedule(gen, const Duration(seconds: 1));
      return;
    }
    try {
      final r = await widget.api.get('/logs_data', query: {'from': '$_from'});
      if (gen != _gen || !mounted) return;
      final start = int.tryParse(r.header('x-log-start') ?? '') ?? 0;
      final next = int.tryParse(r.header('x-log-next') ?? '') ?? _from;
      if (_from != 0 && start > _from) {
        _add('\n[… ${start - _from} bytes antigos descartados …]\n');
      }
      _from = next;
      final t = r.text;
      if (t.isNotEmpty) _add(t);
      setState(() => _status = 'atualizado ${clock()}');
      _schedule(gen, t.length >= 4000 ? const Duration(milliseconds: 100) : const Duration(milliseconds: 1500));
    } on ApiException catch (e) {
      if (gen != _gen || !mounted) return;
      setState(() => _status = e.unauthorized ? 'login recusado' : 'sem conexão, tentando…');
      _schedule(gen, const Duration(seconds: 3));
    } catch (_) {
      if (gen != _gen || !mounted) return;
      setState(() => _status = 'sem conexão, tentando…');
      _schedule(gen, const Duration(seconds: 3));
    }
  }

  void _add(String text) {
    final t = _part + text.replaceAll(_ansi, '').replaceAll('\r', '');
    final a = t.split('\n');
    _part = a.removeLast();
    _lines.addAll(a);
    if (_lines.length > 3000) _lines.removeRange(0, _lines.length - 3000);
    if (_auto) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  List<String> get _visible {
    final f = _filter.toLowerCase();
    if (f.isEmpty) return _lines;
    return _lines.where((l) => l.toLowerCase().contains(f)).toList();
  }

  Future<void> _downloadDevice() async {
    try {
      final r = await widget.api.get('/logs_download', timeout: const Duration(seconds: 40));
      var name = widget.style.defaultDownloadName;
      final cd = r.header('content-disposition') ?? '';
      final m = RegExp(r'filename="([^"]+)"').firstMatch(cd);
      if (m != null) name = m.group(1)!;
      final path = await FileIO.saveBytes(name, Uint8List.fromList(r.bytes));
      if (mounted && path != null) snack(context, 'Salvo: $name');
    } on ApiException catch (e) {
      if (mounted && !e.unauthorized) snack(context, e.message);
    } catch (e) {
      if (mounted) snack(context, 'Não foi possível salvar: $e');
    }
  }

  Future<void> _downloadSession() async {
    final text = '${_lines.join('\n')}${_part.isNotEmpty ? '\n$_part' : ''}\n';
    try {
      final name = '${widget.style.sessionPrefix}_${timeStamp()}.log';
      final path = await FileIO.saveText(name, text);
      if (mounted && path != null) snack(context, 'Salvo: $name');
    } catch (e) {
      if (mounted) snack(context, 'Não foi possível salvar: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final lines = _visible;
    final cs = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          child: Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.tonalIcon(
                onPressed: () => setState(() => _paused = !_paused),
                icon: Icon(_paused ? Icons.play_arrow : Icons.pause),
                label: Text(_paused ? 'Continuar' : 'Pausar'),
              ),
              OutlinedButton.icon(
                onPressed: () => setState(() {
                  _lines.clear();
                  _part = '';
                }),
                icon: const Icon(Icons.clear_all),
                label: const Text('Limpar tela'),
              ),
              PopupMenuButton<String>(
                tooltip: 'Baixar',
                onSelected: (v) => v == 'dev' ? _downloadDevice() : _downloadSession(),
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'dev', child: Text(widget.style.deviceDownloadLabel)),
                  const PopupMenuItem(value: 'ses', child: Text('Baixar sessão (o que o app recebeu)')),
                ],
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.download),
                    SizedBox(width: 4),
                    Text('Baixar'),
                  ]),
                ),
              ),
              Row(mainAxisSize: MainAxisSize.min, children: [
                Switch(value: _auto, onChanged: (v) => setState(() => _auto = v)),
                const Text('Rolar automático', style: TextStyle(fontSize: 13)),
              ]),
            ],
          ),
        ),
        // filtro com a largura toda (o exemplo do placeholder cabe inteiro) e o estado embaixo
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _flt,
                onChanged: (v) => setState(() => _filter = v),
                decoration: fieldDecoration(context,
                    hint: widget.style.filterHint,
                    suffix: _filter.isEmpty
                        ? const Icon(Icons.filter_alt_outlined)
                        : IconButton(
                            tooltip: 'Limpar filtro',
                            icon: const Icon(Icons.close),
                            onPressed: () => setState(() {
                              _flt.clear();
                              _filter = '';
                            }),
                          )),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 2),
                child: Text(
                  '${_paused ? 'pausado · ' : ''}$_status'
                  '${_filter.isEmpty ? '' : ' · ${lines.length} de ${_lines.length} linhas'}',
                  style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: AppColors.term, borderRadius: BorderRadius.circular(10)),
            // sem quebra de linha: linhas longas rolam para o lado
            child: SelectionArea(
              child: TermLines(
                lines: lines,
                controller: _scroll,
                colorOf: widget.style.colorOf,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
