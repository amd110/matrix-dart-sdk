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
    Uint8List? leftover;
    await for (final chunk in input) {
      final currentChunk =
          chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
      final Uint8List data;
      if (leftover == null) {
        data = currentChunk;
      } else {
        data = Uint8List(leftover.length + currentChunk.length)
          ..setAll(0, leftover)
          ..setAll(leftover.length, currentChunk);
      }

      final processLength = (data.length ~/ 16) * 16;
      if (processLength > 0) {
        yield cipher.update(
          Uint8List.view(data.buffer, data.offsetInBytes, processLength),
        );
      }

      if (data.length > processLength) {
        leftover = Uint8List.view(
          data.buffer,
          data.offsetInBytes + processLength,
          data.length - processLength,
        );
      } else {
        leftover = null;
      }
    }

    if (leftover != null && leftover.isNotEmpty) {
      yield cipher.update(leftover);
    }
  } finally {
    cipher.finalize();
  }
}


