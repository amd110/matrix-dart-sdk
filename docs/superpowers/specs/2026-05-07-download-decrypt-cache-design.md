# Design: Streaming Download & Decrypted File Cache

**Date:** 2026-05-07  
**Scope:** `lib/src/event.dart`, `lib/src/database/database_api.dart`, `lib/src/database/database_file_storage_io.dart`, `lib/src/database/database_file_storage_stub.dart`

## Goals

1. Cache the **decrypted** content of encrypted attachments in the database so subsequent calls skip decryption entirely.
2. During download, write response bytes to a **temporary file** on disk (IO platforms) instead of accumulating all chunks in memory, reducing peak memory usage for large files.

## Non-Goals

- Streaming decryption (AES-CTR still requires full bytes in memory).
- Changing the public `downloadCallback` parameter signature.
- Web platform streaming (falls back to in-memory collection).

---

## Design

### 1. Decrypted Content Cache Key

For encrypted attachments, use a derived cache key to store and retrieve the decrypted content:

```dart
final cacheKey = isEncrypted
    ? mxcUrl.replace(queryParameters: {'decrypted': '1'})
    : mxcUrl;
```

| Event type    | Cache read key | Cache write key         | What is stored    |
|---------------|----------------|-------------------------|-------------------|
| Non-encrypted | `mxcUrl`       | `mxcUrl`                | Raw bytes         |
| Encrypted     | `cacheKey`     | `cacheKey`              | Decrypted bytes   |

**Cache hit:** If `getFile(cacheKey)` returns non-null, skip download and decryption entirely and go straight to building `MatrixFile`.

**Old encrypted-raw cache:** Previously `storeFile(mxcUrl, encryptedBytes)` was called. Under the new scheme encrypted events no longer write raw bytes to the cache. Existing stale raw-byte entries with the old key will be ignored (never hit for `isEncrypted == true`) and will be cleaned up naturally by `deleteOldFiles`.

---

### 2. New DatabaseApi Method: `downloadToMemoryViaStream`

```dart
// database_api.dart
Future<Uint8List> downloadToMemoryViaStream(
  Stream<List<int>> stream, {
  void Function(int)? onProgress,
  CancellationToken? cancellationToken,
});
```

#### IO implementation (`database_file_storage_io.dart` mixin)

1. Create a temp file alongside stored files: `<fileStorageLocation>/<uuid>.tmp`.
2. Open `IOSink` via `file.openWrite()`.
3. Iterate stream chunks:
   - On each chunk: check `cancellationToken`, write chunk to sink, call `onProgress`.
   - On cancellation: close sink, delete temp file, throw `DownloadCancelledException`.
4. Close sink.
5. `readAsBytes()` to load into memory (needed for decryption).
6. Delete temp file in `finally` block.

If `fileStorageLocation == null` (IO but storage not configured), fall back to the stub/web behavior.

#### Stub/Web implementation (`database_file_storage_stub.dart`)

Falls back to the existing in-memory chunk collection (same as current `toBytesWithProgress` behavior). `onProgress` and `cancellationToken` are wired through identically.

---

### 3. `downloadAndDecryptAttachment` Control Flow

```
1. Non-sent event → try local send cache (_getCachedFile). Return if found.

2. Resolve mxcUrl; determine isEncrypted.

3. Build cacheKey:
     encrypted  → mxcUrl.replace(queryParameters: {'decrypted': '1'})
     plain      → mxcUrl

4. If storeable: uint8list = await database.getFile(cacheKey)
   Cache hit → jump to step 8.

5. Check cancellationToken before downloading.

6. Download:
   - downloadCallback != null (caller-supplied):
       uint8list = await downloadCallback(downloadUri)   // existing path, unchanged
   - downloadCallback == null (default):
       send HTTP GET, get StreamedResponse
       uint8list = await database.downloadToMemoryViaStream(
         response.stream,
         onProgress: onDownloadProgress,
         cancellationToken: cancellationToken,
       )

7. Write cache:
   - Non-encrypted: storeFile(mxcUrl, uint8list)  (unchanged)
   - Encrypted:     do NOT write raw bytes

8. Check cancellationToken before decryption.

9. Decrypt (encrypted events only):
   - decryptedBytes = await nativeImplementations.decryptFile(encryptedFile)
   - storeFile(cacheKey, decryptedBytes)   ← new: cache decrypted content
   - uint8list = decryptedBytes

10. Build and return MatrixFile(bytes: uint8list, ...).
```

---

## Files Changed

| File | Change |
|------|--------|
| `lib/src/database/database_api.dart` | Add abstract `downloadToMemoryViaStream` method |
| `lib/src/database/database_file_storage_io.dart` | Implement `downloadToMemoryViaStream` with temp-file streaming |
| `lib/src/database/database_file_storage_stub.dart` | Implement `downloadToMemoryViaStream` with in-memory fallback |
| `lib/src/event.dart` | Update `downloadAndDecryptAttachment` per control flow above |

Any other `DatabaseApi` subclasses/implementors in the repo must also implement `downloadToMemoryViaStream` (check `matrix_sdk_database.dart`).

---

## Error Handling

- `cancellationToken` checked before download and before decryption (unchanged points); also checked per-chunk in IO streaming path.
- Temp file deleted in `finally` regardless of success or error.
- If `decryptFile` returns null, throw as before (`'Unable to decrypt file'`).

## Testing

- Existing tests for `downloadAndDecryptAttachment` should continue to pass (non-streaming path is exercised when `downloadCallback` is supplied).
- New unit tests: stub `downloadToMemoryViaStream` to verify decrypted cache key is written and read correctly.
