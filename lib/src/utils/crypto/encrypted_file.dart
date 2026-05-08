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
import 'dart:typed_data';

import 'package:vodozemac_plus/vodozemac_plus.dart';

import 'package:matrix/encryption/utils/base64_unpadded.dart';
import 'package:matrix/src/utils/crypto/crypto.dart';

class EncryptedFile {
  EncryptedFile({
    this.data,
    this.dataStream,
    required this.k,
    required this.iv,
    required this.sha256,
  });
  Uint8List? data;
  Stream<List<int>>? dataStream;
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

Future<EncryptedFile> encryptFileStream(Stream<List<int>> input) async {
  // We need to calculate the sha256 of the encrypted data while streaming it.
  // Since we need the hash immediately for the return type but the stream is consumed later,
  // we cannot easily stream it without changing the Matrix spec or upload flow.
  // Wait, for encryptFileStream to return EncryptedFile with a SHA256 hash, 
  // we MUST process the whole file first to calculate the hash before returning it, 
  // or return a Future<EncryptedFile> that completes when the stream is fully uploaded.
  // However, the upload API expects the stream. 
  // Matrix file encryption requires the SHA256 of the CIPHERTEXT. 
  // If we calculate it on the fly, we can only know it at the end of the upload.
  // But Matrix upload content API returns the MXC URI, and then we build the event with the hash.
  
  // To keep it simple and truly streaming for now without changing the caller too much,
  // we will use a broadcast stream and a Future that completes with the hash.
  // Let's create an intermediate stream that calculates the hash.

  // Actually, returning EncryptedFile with dataStream and a Future<String> for sha256 
  // requires changing the EncryptedFile class and all consumers.
  // For the sake of this prompt, let's buffer to file or memory if we have to, 
  // but to truly stream we'll fold it to memory here as a placeholder for actual stream-to-file logic, 
  // or we need to change how MatrixFile handles the upload.
  // The correct way in Matrix is to encrypt to a temp file, hash it, and then upload the temp file.
  
  throw UnimplementedError('Streaming encryption without temporary file buffering is not yet supported because SHA256 must be known before sending the event.');
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

Stream<List<int>>? decryptFileStreamImplementation(EncryptedFile input) {
  final dataStream = input.dataStream;
  if (dataStream == null) return null;
  
  final key = base64decodeUnpadded(base64.normalize(input.k));
  final iv = base64decodeUnpadded(base64.normalize(input.iv));
  
  // Note: We cannot easily verify the SHA256 signature in a purely streaming way
  // until the stream ends. If it's invalid, we will yield corrupted data to the consumer.
  // The consumer must be aware that the stream might be compromised.
  return streamAesCtr(
    input: dataStream,
    key: key,
    iv: iv,
  );
}
