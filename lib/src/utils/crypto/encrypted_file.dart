/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2019, 2020, 2021 Famedly GmbH
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU Affero General Public License as
 *   published by the Free Software Foundation, either version 3 of the
 *   License, or (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 *   GNU Affero General Public License for more details.
 *
 *   You should have received a copy of the GNU Affero General Public License
 *   along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:path/path.dart';
import 'package:random_string/random_string.dart';
import 'package:vodozemac_plus/vodozemac_plus.dart';

import 'package:matrix/encryption/utils/base64_unpadded.dart';
import 'package:matrix/src/utils/crypto/crypto.dart';

class EncryptedFile {
  EncryptedFile({
    this.data,
    this.dataStream,
    this.path,
    required this.k,
    required this.iv,
    required this.sha256,
  });
  Uint8List? data;
  Stream<List<int>>? dataStream;
  String? path;
  String k;
  String iv;
  String sha256;
}

Future<EncryptedFile> encryptFile(Uint8List input) async {
  final key = secureRandomBytes(32);
  final iv = secureRandomBytes(16);
  final data = CryptoUtils.aesCtr(input: input, key: key, iv: iv);
  final hash = CryptoUtils.sha256(input: data);
  return EncryptedFile(
    data: data,
    k: base64Url.encode(key).replaceAll('=', ''),
    iv: base64.encode(iv).replaceAll('=', ''),
    sha256: base64.encode(hash).replaceAll('=', ''),
  );
}

/// Encrypts a stream of data to a temporary file and calculates SHA256 on the fly.
/// This prevents memory exhaustion for large files.
/// The caller is responsible for deleting the temporary file if needed, 
/// though it's typically used immediately for upload.
Future<EncryptedFile> encryptFileStream(
  Stream<List<int>> input, {
  String? path,
  Directory? tempDir,
}) async {
  final key = secureRandomBytes(32);
  final iv = secureRandomBytes(16);
  
  // If path is provided, we can read directly from it, ignoring the input stream
  // This is crucial for isolate execution where streams cannot cross the boundary
  final effectiveStream = path != null ? File(path).openRead() : input;
  
  final encryptedStream = streamAesCtr(input: effectiveStream, key: key, iv: iv);

  final actualTempDir = tempDir ?? Directory.systemTemp;
  final tempFile = File(
    join(actualTempDir.path, 'matrix_encrypt_${randomAlphaNumeric(10)}.tmp'),
  );
  final ios = tempFile.openWrite();

  dart_crypto.Digest? finalDigest;
  final sha256Sink = dart_crypto.sha256.startChunkedConversion(
    ChunkedConversionSink<dart_crypto.Digest>.withCallback((digests) {
      finalDigest = digests.single;
    }),
  );

  try {
    await for (final chunk in encryptedStream) {
      sha256Sink.add(chunk);
      ios.add(chunk);
    }
    await ios.close();
    sha256Sink.close();

    if (finalDigest == null) {
      throw Exception('Failed to calculate SHA256 digest');
    }

    return EncryptedFile(
      path: tempFile.path,
      k: base64Url.encode(key).replaceAll('=', ''),
      iv: base64.encode(iv).replaceAll('=', ''),
      sha256: base64.encode(finalDigest!.bytes).replaceAll('=', ''),
    );
  } catch (e) {
    await ios.close().catchError((_) {});
    try {
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
    } catch (_) {}
    rethrow;
  }
}

/// you would likely want to use [NativeImplementations] and
/// [Client.nativeImplementations] instead
Future<Uint8List?> decryptFileImplementation(EncryptedFile input) async {
  final data = input.data;
  if (data == null) return null;
  if (base64.encode(CryptoUtils.sha256(input: data)) !=
      base64.normalize(input.sha256)) {
    return null;
  }

  final key = base64decodeUnpadded(base64.normalize(input.k));
  final iv = base64decodeUnpadded(base64.normalize(input.iv));
  return CryptoUtils.aesCtr(input: data, key: key, iv: iv);
}

Stream<List<int>>? decryptFileStreamImplementation(EncryptedFile input, {String? path}) {
  final targetPath = input.path ?? path;
  final dataStream = targetPath != null ? File(targetPath).openRead() : input.dataStream;
  if (dataStream == null) return null;

  final key = base64decodeUnpadded(base64.normalize(input.k));
  final iv = base64decodeUnpadded(base64.normalize(input.iv));

  return streamAesCtr(
    input: dataStream,
    key: key,
    iv: iv,
  );
}
