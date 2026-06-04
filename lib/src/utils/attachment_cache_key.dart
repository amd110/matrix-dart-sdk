import 'package:mime/mime.dart';

/// Builds the local cache key used for attachment playback.
Uri attachmentCacheKey(
  Uri mxcUrl, {
  required bool encrypted,
  String? mimeType,
}) {
  final ext = mimeType == null ? null : extensionFromMime(mimeType);
  if (!encrypted && ext == null) return mxcUrl;

  return mxcUrl.replace(
    queryParameters: {
      if (encrypted) 'decrypted': '1',
      if (ext != null) 'ext': ext,
    },
  );
}
