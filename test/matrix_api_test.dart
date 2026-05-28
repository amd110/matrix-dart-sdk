import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart';
import 'package:matrix/matrix_api_lite/generated/api.dart';
import 'package:test/test.dart';

/// 最小 HTTP mock，对 sync 请求返回固定 JSON 响应。
class _SyncHttpClient extends BaseClient {
  final String responseBody;
  _SyncHttpClient(this.responseBody);

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    final bytes = utf8.encode(responseBody);
    return StreamedResponse(
      Stream.value(bytes),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

void main() {
  const minimalSyncJson = '{"next_batch":"s1","rooms":{},"account_data":{}}';

  group('Api.asyncJsonDecoder', () {
    test('asyncJsonDecoder 为 null 时使用同步 jsonDecode（默认行为）', () async {
      final api = Api(
        httpClient: _SyncHttpClient(minimalSyncJson),
        baseUri: Uri.parse('https://example.com'),
        bearerToken: 'token',
      );

      final result = await api.sync();
      expect(result.nextBatch, equals('s1'));
    });

    test('asyncJsonDecoder 非 null 时被调用替代 jsonDecode', () async {
      var decoderCalled = false;

      final api = Api(
        httpClient: _SyncHttpClient(minimalSyncJson),
        baseUri: Uri.parse('https://example.com'),
        bearerToken: 'token',
      );
      api.asyncJsonDecoder = (raw) async {
        decoderCalled = true;
        return jsonDecode(raw);
      };

      final result = await api.sync();
      expect(decoderCalled, isTrue);
      expect(result.nextBatch, equals('s1'));
    });

    test('asyncJsonDecoder 返回值被正确传入 SyncUpdate.fromJson', () async {
      final api = Api(
        httpClient: _SyncHttpClient(minimalSyncJson),
        baseUri: Uri.parse('https://example.com'),
        bearerToken: 'token',
      );
      api.asyncJsonDecoder = (raw) async => jsonDecode(raw);

      final result = await api.sync();
      expect(result.nextBatch, equals('s1'));
    });
  });
}
