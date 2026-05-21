/*
 *   Famedly Matrix SDK
 *   Copyright (C) 2020, 2021 Famedly GmbH
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
 *   along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

/// Workaround until [File] in dart:io and dart:html is unified
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:blurhash_dart/blurhash_dart.dart';
import 'package:image/image.dart';
import 'package:mime/mime.dart';

import 'package:matrix/matrix.dart';

class MatrixFile {
  final String name;
  final String mimeType;
  final String path;

  MatrixFile({
    required String name,
    String? mimeType,
    required this.path,
  })  : mimeType = mimeType != null && mimeType.isNotEmpty
            ? mimeType
            : lookupMimeType(name) ?? 'application/octet-stream',
        name = name.split('/').last;

  /// Encrypts this file and returns an [EncryptedFile] with metadata.
  Future<EncryptedFile> encrypt({
    NativeImplementations nativeImplementations = NativeImplementations.dummy,
  }) async =>
      nativeImplementations.encryptFile(File(path));

  /// Retrieves the stream of the file content.
  Stream<List<int>> getStream() async* {
    // Throttled stream to prevent main thread TLS encryption from starving the Flutter UI.
    // iOS SecureSocket TLS encryption on the main thread causes severe lag (100% CPU)
    // if we pump a large video file as fast as the disk/network allows.
    final stream = File(path).openRead();
    await for (final chunk in stream) {
      yield chunk;
      // Yield to the event loop for 1 millisecond after every chunk (64KB).
      // This caps the upload stream processing and gives the UI thread guaranteed time to render.
      await Future.delayed(const Duration(milliseconds: 1));
    }
  }

  /// Retrieves the file content as a single [Uint8List] byte array.
  Future<Uint8List> getBytes() => File(path).readAsBytes();

  int get size => File(path).lengthSync();

  String get msgType => msgTypeFromMime(mimeType);

  Map<String, dynamic> get info => ({
        'mimetype': mimeType,
        'size': size,
      });

  static String msgTypeFromMime(String mimeType) {
    if (mimeType.toLowerCase().startsWith('image/')) {
      return MessageTypes.Image;
    }
    if (mimeType.toLowerCase().startsWith('video/')) {
      return MessageTypes.Video;
    }
    if (mimeType.toLowerCase().startsWith('audio/')) {
      return MessageTypes.Audio;
    }
    return MessageTypes.File;
  }

  /// Derives the MIME type from the file name / extension and creates the
  /// appropriate subtype ([MatrixImageFile], [MatrixAudioFile],
  /// [MatrixVideoFile], or [MatrixFile]).
  factory MatrixFile.fromMimeType({
    required String name,
    String? mimeType,
    required String path,
  }) {
    final resolvedMime =
        mimeType ?? lookupMimeType(name) ?? 'application/octet-stream';
    final msgType = msgTypeFromMime(resolvedMime);
    if (msgType == MessageTypes.Image) {
      return MatrixImageFile(name: name, mimeType: mimeType, path: path);
    }
    if (msgType == MessageTypes.Video) {
      return MatrixVideoFile(name: name, mimeType: mimeType, path: path);
    }
    if (msgType == MessageTypes.Audio) {
      return MatrixAudioFile(name: name, mimeType: mimeType, path: path);
    }
    return MatrixFile(name: name, mimeType: mimeType, path: path);
  }
}

class MatrixImageFile extends MatrixFile {
  MatrixImageFile({
    required super.name,
    super.mimeType,
    required super.path,
    int? width,
    int? height,
    this.blurhash,
  })  : _width = width,
        _height = height;

  /// Creates a new image file, writes any re-encoded bytes back to [path],
  /// and populates width/height/blurhash metadata.
  static Future<MatrixImageFile> create({
    required String path,
    required String name,
    String? mimeType,
    NativeImplementations nativeImplementations = NativeImplementations.dummy,
  }) async {
    final bytes = await File(path).readAsBytes();
    final metaData = await nativeImplementations.calcImageMetadata(bytes);

    if (metaData != null && metaData.bytes != bytes) {
      await File(path).writeAsBytes(metaData.bytes);
    }

    return MatrixImageFile(
      path: path,
      name: name,
      mimeType: mimeType,
      width: metaData?.width,
      height: metaData?.height,
      blurhash: metaData?.blurhash,
    );
  }

  /// Builds a [MatrixImageFile] and shrinks it in order to reduce traffic.
  /// The compressed bytes are written back to [path] so that the returned
  /// file always has a valid on-disk path.
  /// If shrinking fails the original file (at [path]) is returned unchanged.
  static Future<MatrixImageFile> shrink({
    required String path,
    required String name,
    int maxDimension = 1600,
    String? mimeType,
    Future<MatrixImageFileResizedResponse?> Function(
      MatrixImageFileResizeArguments,
    )? customImageResizer,
    NativeImplementations nativeImplementations = NativeImplementations.dummy,
  }) async {
    final image = MatrixImageFile(name: name, mimeType: mimeType, path: path);

    final thumbnail = await image.generateThumbnail(
      dimension: maxDimension,
      customImageResizer: customImageResizer,
      nativeImplementations: nativeImplementations,
    );

    if (thumbnail == null) return image;

    // Write resized bytes back to the source path so encrypt() works directly.
    await File(path).writeAsBytes(await thumbnail.getBytes());
    return MatrixImageFile(
      path: path,
      name: thumbnail.name,
      mimeType: thumbnail.mimeType,
      width: thumbnail.width,
      height: thumbnail.height,
      blurhash: thumbnail.blurhash,
    );
  }

  int? _width;
  int? get width => _width;

  int? _height;
  int? get height => _height;

  void setImageSizeIfNull({required int? width, required int? height}) {
    _width ??= width;
    _height ??= height;
  }

  final String? blurhash;

  @override
  String get msgType => 'm.image';

  @override
  Map<String, dynamic> get info => ({
        ...super.info,
        if (width != null) 'w': width,
        if (height != null) 'h': height,
        if (blurhash != null) 'xyz.amorgan.blurhash': blurhash,
      });

  /// Computes a thumbnail for the image and writes it to a temporary file.
  /// Also sets height/width on the original image if they were unset.
  Future<MatrixImageFile?> generateThumbnail({
    int dimension = Client.defaultThumbnailSize,
    Future<MatrixImageFileResizedResponse?> Function(
      MatrixImageFileResizeArguments,
    )? customImageResizer,
    NativeImplementations nativeImplementations = NativeImplementations.dummy,
  }) async {
    final arguments = MatrixImageFileResizeArguments(
      bytes: await getBytes(),
      maxDimension: dimension,
      fileName: name,
      calcBlurhash: true,
    );
    final resizedData = customImageResizer != null
        ? await customImageResizer(arguments)
        : await nativeImplementations.shrinkImage(arguments);

    if (resizedData == null) return null;

    setImageSizeIfNull(
      width: resizedData.originalWidth,
      height: resizedData.originalHeight,
    );

    if (resizedData.width > dimension || resizedData.height > dimension) {
      return null;
    }

    final thumbPath =
        '${Directory.systemTemp.path}/matrix_thumb_${DateTime.now().microsecondsSinceEpoch}.jpg';
    await File(thumbPath).writeAsBytes(resizedData.bytes);

    return MatrixImageFile(
      path: thumbPath,
      name: name,
      mimeType: mimeType,
      width: resizedData.width,
      height: resizedData.height,
      blurhash: resizedData.blurhash,
    );
  }

  static MatrixImageFileResizedResponse? calcMetadataImplementation(
    Uint8List bytes,
  ) {
    final image = decodeImage(bytes);
    if (image == null) return null;

    return MatrixImageFileResizedResponse(
      bytes: bytes,
      width: image.width,
      height: image.height,
      blurhash: BlurHash.encode(image, numCompX: 4, numCompY: 3).hash,
    );
  }

  static MatrixImageFileResizedResponse? resizeImplementation(
    MatrixImageFileResizeArguments arguments,
  ) {
    final image = decodeImage(arguments.bytes);
    if (image == null) return null;

    final resized = copyResize(
      image,
      height: image.height > image.width ? arguments.maxDimension : null,
      width: image.width >= image.height ? arguments.maxDimension : null,
    );

    final encoded = encodeNamedImage(arguments.fileName, resized);
    if (encoded == null) return null;
    return MatrixImageFileResizedResponse(
      bytes: Uint8List.fromList(encoded),
      width: resized.width,
      height: resized.height,
      originalHeight: image.height,
      originalWidth: image.width,
      blurhash: arguments.calcBlurhash
          ? BlurHash.encode(resized, numCompX: 4, numCompY: 3).hash
          : null,
    );
  }
}

class MatrixImageFileResizedResponse {
  final Uint8List bytes;
  final int width;
  final int height;
  final String? blurhash;
  final int? originalHeight;
  final int? originalWidth;

  const MatrixImageFileResizedResponse({
    required this.bytes,
    required this.width,
    required this.height,
    this.originalHeight,
    this.originalWidth,
    this.blurhash,
  });

  factory MatrixImageFileResizedResponse.fromJson(Map<String, dynamic> json) =>
      MatrixImageFileResizedResponse(
        bytes: Uint8List.fromList(
          (json['bytes'] as Iterable<dynamic>).whereType<int>().toList(),
        ),
        width: json['width'],
        height: json['height'],
        originalHeight: json['originalHeight'],
        originalWidth: json['originalWidth'],
        blurhash: json['blurhash'],
      );

  Map<String, dynamic> toJson() => {
        'bytes': bytes,
        'width': width,
        'height': height,
        if (blurhash != null) 'blurhash': blurhash,
        if (originalHeight != null) 'originalHeight': originalHeight,
        if (originalWidth != null) 'originalWidth': originalWidth,
      };
}

class MatrixImageFileResizeArguments {
  final Uint8List bytes;
  final int maxDimension;
  final String fileName;
  final bool calcBlurhash;

  const MatrixImageFileResizeArguments({
    required this.bytes,
    required this.maxDimension,
    required this.fileName,
    required this.calcBlurhash,
  });

  factory MatrixImageFileResizeArguments.fromJson(Map<String, dynamic> json) =>
      MatrixImageFileResizeArguments(
        bytes: json['bytes'],
        maxDimension: json['maxDimension'],
        fileName: json['fileName'],
        calcBlurhash: json['calcBlurhash'],
      );

  Map<String, Object> toJson() => {
        'bytes': bytes,
        'maxDimension': maxDimension,
        'fileName': fileName,
        'calcBlurhash': calcBlurhash,
      };
}

class MatrixVideoFile extends MatrixFile {
  final int? width;
  final int? height;
  final int? duration;

  MatrixVideoFile({
    required super.name,
    super.mimeType,
    required super.path,
    this.width,
    this.height,
    this.duration,
  });

  @override
  String get msgType => 'm.video';

  @override
  Map<String, dynamic> get info => ({
        ...super.info,
        if (width != null) 'w': width,
        if (height != null) 'h': height,
        if (duration != null) 'duration': duration,
      });
}

class MatrixAudioFile extends MatrixFile {
  final int? duration;

  MatrixAudioFile({
    required super.name,
    super.mimeType,
    required super.path,
    this.duration,
  });

  @override
  String get msgType => 'm.audio';

  @override
  Map<String, dynamic> get info => ({
        ...super.info,
        if (duration != null) 'duration': duration,
      });
}

extension ToMatrixFile on EncryptedFile {
  MatrixFile toMatrixFile() => MatrixFile(name: 'crypt', path: path);
}
