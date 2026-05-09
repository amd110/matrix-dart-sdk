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

import 'dart:math';
import 'dart:typed_data';

import 'package:vodozemac_plus/vodozemac_plus.dart';

Uint8List secureRandomBytes(int len) {
  final rng = Random.secure();
  final list = Uint8List(len);
  list.setAll(0, Iterable.generate(list.length, (i) => rng.nextInt(256)));
  return list;
}

Stream<List<int>> streamAesCtr({
  required Stream<List<int>> input,
  required Uint8List key,
  required Uint8List iv,
}) async* {
  final cipher = Aes256Ctr(key: key, iv: iv);

  try {
    final buffer = <int>[];
    await for (final chunk in input) {
      buffer.addAll(chunk);

      // AES block size is 16 bytes. Some native bindings or CTR state machines
      // discard the unused portion of a keystream block if updated with non-aligned chunks.
      // To guarantee identical ciphertext/plaintext, we buffer and only update in multiples of 16 bytes.
      if (buffer.length >= 16) {
        final processLength = (buffer.length ~/ 16) * 16;
        final processChunk = Uint8List.fromList(buffer.sublist(0, processLength));
        buffer.removeRange(0, processLength);

        yield cipher.update(processChunk);
      }
    }

    // Process any remaining bytes (the final chunk can be unaligned)
    if (buffer.isNotEmpty) {
      yield cipher.update(Uint8List.fromList(buffer));
    }
  } finally {
    cipher.finalize();
  }
}


