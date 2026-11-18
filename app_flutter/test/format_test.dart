// Testes das regras portadas da página web (formatação e validação).
import 'package:flutter_test/flutter_test.dart';
import 'package:lorawan_node_otaa_app/core/format.dart';
import 'package:lorawan_node_otaa_app/core/html_text.dart';

void main() {
  test('dur igual à página', () {
    expect(dur(42), '42 s');
    expect(dur(125), '2 min 5 s');
    expect(dur(3725), '1 h 2 min');
    expect(dur(90061), '1 d 1 h');
  });

  test('nf com separador pt-BR', () {
    expect(nf(0), '0');
    expect(nf(1234567), '1.234.567');
  });

  test('hexadecimal', () {
    expect(hexb('AA bb:cc-01'), [0xAA, 0xBB, 0xCC, 0x01]);
    expect(hexb('ABC'), isNull);
    expect(hx([0x0a, 0xff], ' '), '0A FF');
  });

  test('IPv4 e máscara', () {
    expect(ip4('192.168.18.101'), isNotNull);
    expect(ip4('300.1.1.1'), isNull);
    expect(isNetmask(ip4('255.255.255.0')!), isTrue);
    expect(isNetmask(ip4('255.0.255.0')!), isFalse);
  });

  test('página "Configuração salva"', () {
    final p = parseSimplePage("<div><h2>Configuração salva</h2><p>As configurações já foram aplicadas.</p>"
        "<p class='dev'>X · Desenvolvido por <b>AdailSilva</b></p></div>");
    expect(p.title, 'Configuração salva');
    expect(p.paragraphs, ['As configurações já foram aplicadas.']);
    expect(p.isError, isFalse);
  });
}
