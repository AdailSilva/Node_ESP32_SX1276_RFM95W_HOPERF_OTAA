// Cliente HTTP do dispositivo (gateway ESP32_SX1302 ou nó LoRaWAN).
//
// Usa os MESMOS endpoints da página web do firmware, com HTTP Basic.
// Uma única instância por sessão: o HttpClient mantém a conexão aberta
// (keep-alive) e limita a 2 conexões simultâneas, para não pesar no ESP32.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class ApiException implements Exception {
  ApiException(this.message, {this.status});

  final String message;
  final int? status;

  bool get unauthorized => status == 401;

  @override
  String toString() => message;
}

class HttpResult {
  HttpResult(this.status, this.bytes, this.headers);

  final int status;
  final Uint8List bytes;
  final HttpHeaders headers;

  String get text => utf8.decode(bytes, allowMalformed: true);

  bool get ok => status >= 200 && status < 300;

  Map<String, dynamic> get json {
    final v = jsonDecode(text);
    if (v is Map<String, dynamic>) return v;
    throw ApiException('Resposta inesperada do dispositivo (JSON inválido).');
  }

  String? header(String name) => headers.value(name);
}

/// Cancela uma requisição em andamento (usado nos diagnósticos e na varredura).
class CancelToken {
  HttpClientRequest? _request;
  bool _cancelled = false;

  bool get cancelled => _cancelled;

  void cancel() {
    _cancelled = true;
    try {
      _request?.abort();
    } catch (_) {}
  }
}

class DeviceApi {
  DeviceApi({
    required this.host,
    this.port = 80,
    required this.user,
    required this.password,
  }) : _client = HttpClient()
          ..connectionTimeout = const Duration(seconds: 6)
          ..idleTimeout = const Duration(seconds: 15)
          ..maxConnectionsPerHost = 2;

  final String host;
  final int port;
  String user;
  String password;
  final HttpClient _client;

  /// Chamado em toda resposta 401 (a sessão usa para voltar ao login de
  /// qualquer aba: Logs, Diagnósticos, Salvar... e não só no Status).
  void Function()? onUnauthorized;

  static const Duration defaultTimeout = Duration(seconds: 15);

  String get baseUrl => port == 80 ? 'http://$host/' : 'http://$host:$port/';

  String get _authHeader =>
      'Basic ${base64Encode(utf8.encode('$user:$password'))}';

  Uri uri(String path, [Map<String, String>? query]) => Uri(
        scheme: 'http',
        host: host,
        port: port,
        path: path,
        queryParameters: (query == null || query.isEmpty) ? null : query,
      );

  void close() => _client.close(force: true);

  /// Envia uma requisição e lê a resposta inteira.
  Future<HttpResult> send(
    String method,
    String path, {
    Map<String, String>? query,
    List<int>? body,
    String? contentType,
    bool auth = true,
    Duration timeout = defaultTimeout,
    CancelToken? cancel,
  }) async {
    try {
      return await _send(method, path,
              query: query,
              body: body,
              contentType: contentType,
              auth: auth,
              cancel: cancel)
          .timeout(timeout);
    } on ApiException {
      rethrow;
    } on TimeoutException {
      cancel?.cancel();
      throw ApiException(
          'Tempo esgotado esperando o dispositivo. Ele pode estar ocupado '
          '(teste de diagnóstico, reinício) ou fora da rede.');
    } on SocketException catch (e) {
      throw ApiException(_socketMessage(e));
    } on HttpException catch (e) {
      if (cancel?.cancelled ?? false) {
        throw ApiException('Interrompido.');
      }
      throw ApiException('Falha na conexão HTTP: ${e.message}');
    } on HandshakeException {
      throw ApiException('Falha na conexão (o dispositivo usa http://, sem TLS).');
    }
  }

  Future<HttpResult> _send(
    String method,
    String path, {
    Map<String, String>? query,
    List<int>? body,
    String? contentType,
    required bool auth,
    CancelToken? cancel,
  }) async {
    final usedAuth = _authHeader;
    final req = await _client.openUrl(method, uri(path, query));
    cancel?._request = req;
    req.followRedirects = false;
    req.persistentConnection = true;
    req.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    if (auth) req.headers.set(HttpHeaders.authorizationHeader, usedAuth);
    if (body != null) {
      if (contentType != null) {
        // valor exato, sem "; charset=...": o WebServer do Arduino compara o início
        req.headers.set(HttpHeaders.contentTypeHeader, contentType);
      }
      req.contentLength = body.length;
      req.add(body);
    } else if (method == 'POST') {
      req.contentLength = 0;
    }
    final res = await req.close();
    final builder = BytesBuilder(copy: false);
    await for (final chunk in res) {
      builder.add(chunk);
    }
    final result = HttpResult(res.statusCode, builder.takeBytes(), res.headers);
    if (result.status == 401) {
      // um pedido que saiu com o login antigo (trocado agora em "Acesso") não derruba a sessão
      if (auth && usedAuth == _authHeader) onUnauthorized?.call();
      throw ApiException('Usuário ou senha incorretos.', status: 401);
    }
    return result;
  }

  static String _socketMessage(SocketException e) {
    final os = e.osError?.message ?? e.message;
    return 'Sem resposta do dispositivo. Confira se o celular está na mesma rede '
        'Wi-Fi (ou no Soft AP) e se o endereço está certo. ($os)';
  }

  /// GET que devolve JSON (lança ApiException se o status não for 2xx).
  Future<Map<String, dynamic>> getJson(String path,
      {Map<String, String>? query, bool auth = true, Duration? timeout}) async {
    final r = await send('GET', path,
        query: query, auth: auth, timeout: timeout ?? defaultTimeout);
    if (!r.ok) {
      throw ApiException('O dispositivo respondeu HTTP ${r.status} em $path.',
          status: r.status);
    }
    return r.json;
  }

  /// GET de texto (logs, JSON do plano...).
  Future<HttpResult> get(String path,
          {Map<String, String>? query, Duration? timeout}) =>
      send('GET', path, query: query, timeout: timeout ?? defaultTimeout);

  /// POST application/x-www-form-urlencoded, igual ao formulário da página.
  Future<HttpResult> postForm(String path, Map<String, String> fields,
      {Duration? timeout}) {
    return send('POST', path,
        body: utf8.encode(encodeForm(fields)),
        contentType: 'application/x-www-form-urlencoded',
        timeout: timeout ?? const Duration(seconds: 20));
  }

  /// POST com corpo de texto (certificados PEM do gateway).
  Future<HttpResult> postText(String path, String text,
      {Map<String, String>? query}) {
    return send('POST', path,
        query: query,
        body: utf8.encode(text),
        contentType: 'text/plain; charset=utf-8',
        timeout: const Duration(seconds: 25));
  }

  /// POST sem corpo que reinicia o dispositivo: a conexão pode cair antes da
  /// resposta completa, o que aqui não é erro.
  Future<String?> postRestart(String path) async {
    try {
      final r = await send('POST', path, timeout: const Duration(seconds: 8));
      return r.text;
    } on ApiException catch (e) {
      if (e.unauthorized) rethrow;
      return null;
    }
  }

  /// GET com o corpo entregue em pedaços, à medida que chega (diagnósticos).
  Stream<String> streamText(String path,
      {Map<String, String>? query, CancelToken? cancel}) async* {
    final usedAuth = _authHeader;
    HttpClientResponse res;
    try {
      final req = await _client.openUrl('GET', uri(path, query));
      cancel?._request = req;
      req.headers.set(HttpHeaders.authorizationHeader, usedAuth);
      req.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      res = await req.close().timeout(const Duration(seconds: 30));
    } on TimeoutException {
      cancel?.cancel();
      throw ApiException('Tempo esgotado esperando o dispositivo.');
    } on SocketException catch (e) {
      if (cancel?.cancelled ?? false) throw ApiException('Interrompido.');
      throw ApiException(_socketMessage(e));
    } on HttpException {
      if (cancel?.cancelled ?? false) throw ApiException('Interrompido.');
      rethrow;
    }
    if (res.statusCode == 401) {
      await res.drain<void>();
      if (usedAuth == _authHeader) onUnauthorized?.call();
      throw ApiException('Usuário ou senha incorretos.', status: 401);
    }
    if (res.statusCode != 200) {
      final body = await utf8.decoder.bind(res).join();
      throw ApiException(body.trim().isEmpty
          ? 'O dispositivo respondeu HTTP ${res.statusCode}.'
          : body.trim());
    }
    try {
      yield* utf8.decoder.bind(res);
    } on HttpException {
      if (cancel?.cancelled ?? false) throw ApiException('Interrompido.');
      rethrow;
    } on SocketException {
      if (cancel?.cancelled ?? false) throw ApiException('Interrompido.');
      rethrow;
    }
  }

  static String encodeForm(Map<String, String> fields) => fields.entries
      .map((e) =>
          '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
      .join('&');

  /// Lê o GET /info sem login. null = não é um dispositivo deste projeto
  /// (ou é um firmware antigo, sem /info).
  static Future<Map<String, dynamic>?> probeInfo(String host,
      {int port = 80,
      Duration timeout = const Duration(milliseconds: 1500),
      HttpClient? client}) async {
    final c = client ?? (HttpClient()..connectionTimeout = timeout);
    try {
      final req = await c
          .getUrl(Uri(scheme: 'http', host: host, port: port, path: '/info'))
          .timeout(timeout);
      req.followRedirects = false;
      final res = await req.close().timeout(timeout);
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      final body = await utf8.decoder
          .bind(res)
          .join()
          .timeout(timeout + const Duration(seconds: 1));
      if (body.length > 2048) return null;
      final v = jsonDecode(body);
      if (v is Map<String, dynamic> && v['type'] is String) return v;
      return null;
    } catch (_) {
      return null;
    } finally {
      if (client == null) c.close(force: true);
    }
  }
}
