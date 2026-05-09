/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2019, 2020 Famedly GmbH
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

import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'package:matrix/matrix.dart';
import 'fake_client.dart';

void main() {
  /// All Tests related to device keys
  group('Matrix File', tags: 'olm', () {
    setUpAll(() async {
      await getClient(); // To trigger vodozemac init
    });
    Logs().level = Level.error;
    test('Decrypt', () async {
      const text = 'hello world';
      final tmpFile = File('${Directory.systemTemp.path}/matrix_test_encrypt.txt');
      await tmpFile.writeAsBytes(Uint8List.fromList(text.codeUnits));
      final file = MatrixFile(name: 'file.txt', path: tmpFile.path);

      final encryptedFile = await file.encrypt();
      expect(encryptedFile.path.isNotEmpty, true);
      await tmpFile.delete();
    });

    test('Shrink', () async {
      final resp = await http.get(
        Uri.parse(
          'https://upload.wikimedia.org/wikipedia/commons/5/5f/Salagou_Lake%2C_Celles_cf01.jpg',
        ),
      );

      if (resp.statusCode == 200) {
        final tmpJpg = File('${Directory.systemTemp.path}/matrix_test_shrink.jpg');
        await tmpJpg.writeAsBytes(resp.bodyBytes);
        final file = MatrixImageFile(name: 'file.jpg', path: tmpJpg.path);
        expect((await file.getBytes()).isNotEmpty, true);
        expect(file.height, null);
        expect(file.width, null);

        final thumb = await file.generateThumbnail();

        expect(thumb != null, true);

        // and the image size where updated
        expect(file.height, 4552);
        expect(file.width, 7283);
      }
    });
  });
}
