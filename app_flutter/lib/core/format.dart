// Formatação e validação usadas pelas páginas web, portadas para Dart.
import 'dart:convert';

/// 3725 -> "1 h 2 min" (mesma regra da página).
String dur(num secs) {
  final s = secs.floor();
  final d = s ~/ 86400, h = (s % 86400) ~/ 3600, m = (s % 3600) ~/ 60;
  if (d > 0) return '$d d $h h';
  if (h > 0) return '$h h $m min';
  if (m > 0) return '$m min ${s % 60} s';
  return '$s s';
}

String kb(num bytes) => '${(bytes / 1024).round()} KB';

/// Número com separador de milhar pt-BR: 12345 -> "12.345".
String nf(dynamic x) {
  final v = (x is num) ? x.round() : int.tryParse('$x') ?? 0;
  final neg = v < 0;
  final s = v.abs().toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write('.');
    b.write(s[i]);
  }
  return neg ? '-$b' : b.toString();
}

String pc(num a, num b) => b == 0 ? '-' : '${(100 * a / b).round()}%';

/// Decimal com vírgula: 1.5 -> "1,5".
String dec(num v, int digits) => v.toStringAsFixed(digits).replaceAll('.', ',');

/// "192.168.0.1" -> inteiro de 32 bits, ou null se inválido.
int? ip4(String s) {
  final m = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$').firstMatch(s);
  if (m == null) return null;
  var v = 0;
  for (var i = 1; i <= 4; i++) {
    final p = int.parse(m.group(i)!);
    if (p > 255) return null;
    v = (v << 8) | p;
  }
  return v;
}

bool isNetmask(int mask) {
  if (mask == 0) return false;
  final bits = mask.toRadixString(2).padLeft(32, '0');
  return RegExp(r'^1*0*$').hasMatch(bits);
}

/// Valida o bloco de IP fixo (igual à página). Preenche a máscara padrão.
/// [get]/[set] acessam os campos; devolve a lista de erros.
List<String> validateStaticIp(
    String Function(String) get, void Function(String, String) set) {
  final e = <String>[];
  if (get('ip_mask').trim().isEmpty) set('ip_mask', '255.255.255.0');
  final a = <String, int?>{};
  const fields = [
    ['ip_addr', 'Endereço IP', true],
    ['ip_mask', 'Máscara', true],
    ['ip_gw', 'Gateway', true],
    ['ip_dns1', 'DNS primário', false],
    ['ip_dns2', 'DNS secundário', false],
  ];
  for (final f in fields) {
    final name = f[0] as String, label = f[1] as String, req = f[2] as bool;
    final v = get(name).trim();
    set(name, v);
    if (v.isEmpty) {
      if (req) e.add('$label: obrigatório com IP fixo.');
      continue;
    }
    a[name] = ip4(v);
    if (a[name] == null) e.add('$label: use o formato 192.168.18.101.');
  }
  final ip = a['ip_addr'], mask = a['ip_mask'], gw = a['ip_gw'];
  if (a.containsKey('ip_mask') && mask != null && !isNetmask(mask)) {
    e.add('Máscara: inválida (ex.: 255.255.255.0).');
  } else if (ip != null && gw != null && mask != null) {
    if ((ip & mask) != (gw & mask)) {
      e.add('Gateway fora da rede do endereço IP (confira a máscara).');
    }
    if (ip == gw) e.add('Endereço IP igual ao do gateway.');
  }
  return e;
}

/// "AA BB:cc-0x11" -> bytes; null se não for hexadecimal de bytes inteiros.
List<int>? hexb(String s) {
  final t = s.replaceAll(RegExp(r'0x', caseSensitive: false), '').replaceAll(RegExp(r'[\s:,-]'), '');
  if (!RegExp(r'^([0-9a-fA-F]{2})*$').hasMatch(t)) return null;
  final out = <int>[];
  for (var i = 0; i < t.length; i += 2) {
    out.add(int.parse(t.substring(i, i + 2), radix: 16));
  }
  return out;
}

String hx(List<int> b, [String sep = '']) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0').toUpperCase()).join(sep);

int utf8Len(String s) => utf8.encode(s).length;

/// Nome do nó -> hostname (igual à página do nó).
String hostSlug(String n) {
  var h = n.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
  h = h.replaceAll(RegExp(r'^-+|-+$'), '');
  if (h.length > 31) h = h.substring(0, 31);
  return h.isEmpty ? 'lorawan-node' : h;
}

/// 20261104 (data local) para nomes de arquivo.
String dateStamp([DateTime? d]) {
  final t = d ?? DateTime.now();
  String p(int n) => n.toString().padLeft(2, '0');
  return '${t.year}${p(t.month)}${p(t.day)}';
}

String timeStamp([DateTime? d]) {
  final t = d ?? DateTime.now();
  String p(int n) => n.toString().padLeft(2, '0');
  return '${dateStamp(t)}-${p(t.hour)}${p(t.minute)}${p(t.second)}';
}

String clock([DateTime? d]) {
  final t = d ?? DateTime.now();
  String p(int n) => n.toString().padLeft(2, '0');
  return '${p(t.hour)}:${p(t.minute)}:${p(t.second)}';
}

/// Valor de config.json como texto ("" para null).
String sv(dynamic v) => v == null ? '' : '$v';

/// Texto com só caracteres ASCII imprimíveis (o gateway não decodifica UTF-8 no formulário).
bool isAscii(String s) => s.codeUnits.every((c) => c >= 0x20 && c < 0x7f);
