// As respostas de "Salvar", "Reiniciar" e "Padrão de fábrica" do firmware são
// páginas HTML pequenas. Aqui o app extrai o título (<h2>) e os parágrafos.

class SimplePage {
  SimplePage(this.title, this.paragraphs);

  final String title;
  final List<String> paragraphs;

  String get body => paragraphs.join('\n\n');

  bool get isError =>
      title.startsWith('Nada foi salvo') ||
      title.startsWith('Falha') ||
      title.startsWith('Não foi possível');
}

String unescapeHtml(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&');

String stripTags(String s) =>
    unescapeHtml(s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
        .replaceAll(RegExp(r'<[^>]+>'), ''))
        .trim();

SimplePage parseSimplePage(String html) {
  final h2 = RegExp(r'<h2[^>]*>(.*?)</h2>', dotAll: true, caseSensitive: false)
      .firstMatch(html);
  final title = h2 == null ? '' : stripTags(h2.group(1)!);
  final ps = <String>[];
  for (final m in RegExp(r'<p([^>]*)>(.*?)</p>', dotAll: true, caseSensitive: false)
      .allMatches(html)) {
    final attrs = m.group(1) ?? '';
    final text = stripTags(m.group(2)!);
    if (text.isEmpty) continue;
    if (attrs.contains("class='dev'") || attrs.contains('class="dev"')) continue;
    if (text.contains('Desenvolvido por')) continue;
    if (text.startsWith('Se o navegador')) continue;
    ps.add(text);
  }
  return SimplePage(title, ps);
}

/// Conteúdo de "<pre>...</pre>" (JSON dos planos de frequência do gateway).
String preContent(String html) {
  final m = RegExp(r'<pre>(.*)</pre>', dotAll: true).firstMatch(html);
  return (m == null ? html : m.group(1)!).trim();
}
