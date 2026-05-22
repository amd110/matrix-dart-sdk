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

import 'package:crypto/crypto.dart' as dart_crypto;
import 'package:path/path.dart';
import 'package:random_string/random_string.dart';

import 'package:matrix/encryption/utils/base64_unpadded.dart';
import 'package:matrix/src/utils/crypto/crypto.dart';

/// Holds encryption metadata and the path to the encrypted file on disk.
class EncryptedFile {
  EncryptedFile({
    required this.path,
    required this.k,
    required this.iv,
    required this.sha256,
  });

  /// Path to the encrypted file on disk.
  String path;

  /// Base64url-encoded AES-256-CTR key (no padding).
  String k;

  /// Base64-encoded initialization vector (no padding).
  String iv;

  /// Base64-encoded SHA-256 hash of the encrypted bytes (no padding).
  String sha256;
}

/// Encrypts [input] to a temporary file and returns metadata.
///
/// The caller owns the temporary file and is responsible for deleting it.
Future<EncryptedFile> encryptFile(
  File input, {
  Directory? tempDir,
}) async {
  final key = secureRandomBytes(32);
  final iv = secureRandomBytes(16);

  final encryptedStream = streamAesCtr(input: input.openRead(), key: key, iv: iv);

  final actualTempDir = tempDir ?? Directory.systemTemp;
  final tempFile = File(
    join(actualTempDir.path, 'matrix_encrypt_${randomAlphaNumeric(10)}.tmp'),
  );
  final sink = tempFile.openWrite();

  dart_crypto.Digest? finalDigest;
  final sha256Sink = dart_crypto.sha256.startChunkedConversion(
    ChunkedConversionSink<dart_crypto.Digest>.withCallback((digests) {
      finalDigest = digests.single;
    }),
  );

  try {
    await sink.addStream(
      encryptedStream.map((chunk) {
        sha256Sink.add(chunk);
        return chunk;
      }),
    );
    await sink.close();
    sha256Sink.close();

    if (finalDigest == null) throw Exception('Failed to calculate SHA256 digest');

    return EncryptedFile(
      path: tempFile.path,
      k: base64Url.encode(key).replaceAll('=', ''),
      iv: base64.encode(iv).replaceAll('=', ''),
      sha256: base64.encode(finalDigest!.bytes).replaceAll('=', ''),
    );
  } catch (e) {
    try {
      await sink.close();
    } catch (_) {}
    try {
      await tempFile.delete();
    } catch (_) {}
    rethrow;
  }
}

/// Decrypts [input] to a temporary file and returns it.
///
/// Throws if the SHA-256 hash does not match (integrity check failed).
/// The caller owns the temporary file and is responsible for deleting it.
Future<File> decryptFile(
  EncryptedFile input, {
  Directory? tempDir,
}) async {
  final key = base64decodeUnpadded(base64.normalize(input.k));
  final iv = base64decodeUnpadded(base64.normalize(input.iv));
  final expectedHash = base64.normalize(input.sha256);

  dart_crypto.Digest? finalDigest;
  final sha256Sink = dart_crypto.sha256.startChunkedConversion(
    ChunkedConversionSink<dart_crypto.Digest>.withCallback((digests) {
      finalDigest = digests.single;
    }),
  );

  // Stream encrypted bytes through SHA256 and cipher in a single pass,
  // avoiding loading the entire file into memory.
  final encryptedStream = File(input.path).openRead().map((chunk) {
    sha256Sink.add(chunk);
    return chunk;
  });

  final decryptedStream = streamAesCtr(input: encryptedStream, key: key, iv: iv);

  final actualTempDir = tempDir ?? Directory.systemTemp;
  final tempFile = File(
    join(actualTempDir.path, 'matrix_decrypt_${randomAlphaNumeric(10)}.tmp'),
  );
  final sink = tempFile.openWrite();

  try {
    await sink.addStream(decryptedStream);
    await sink.close();
    sha256Sink.close();

    if (finalDigest == null) throw Exception('Failed to calculate SHA256 digest');

    final actualHash = base64.encode(finalDigest!.bytes);
    if (actualHash != expectedHash) {
      throw Exception('Encrypted file integrity check failed: SHA-256 mismatch');
    }

    return tempFile;
  } catch (e) {
    try {
      await sink.close();
    } catch (_) {}
    try {
      await tempFile.delete();
    } catch (_) {}
    rethrow;
  }
}
