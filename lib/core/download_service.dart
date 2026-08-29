import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class DownloadService {
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 60),
    sendTimeout: const Duration(seconds: 15),
    followRedirects: true,
    maxRedirects: 5,
    headers: {
      'User-Agent': 'com.google.android.youtube/19.09.37 (Linux; U; Android 14) gzip',
      'Accept': '*/*',
      'Accept-Language': 'en-US,en;q=0.9',
      'Referer': 'https://www.youtube.com/',
    },
  ));
  CancelToken? _cancelToken;

  Future<bool> requestPermission() async {
    if (Platform.isAndroid) {
      final androidInfo = await DeviceInfoPlugin().androidInfo;
      final sdk = androidInfo.version.sdkInt;
      if (sdk >= 33) {
        // Android 13+ : medya izinleri veya MANAGE_EXTERNAL_STORAGE gerekmez, app-specific dizin kullanıyoruz
        return true;
      }
      if (sdk >= 30) {
        // Android 11+ için manageExternalStorage gerekebilir ama Download klasörü için alternatif kullan
        final status = await Permission.manageExternalStorage.status;
        if (status.isGranted) return true;
        final r = await Permission.manageExternalStorage.request();
        return r.isGranted;
      } else {
        final status = await Permission.storage.request();
        return status.isGranted;
      }
    }
    return true;
  }

  Future<String> getDownloadPath({String? ext}) async {
    String subFolder = '';
    if (ext == 'mp3' || ext == 'm4a') subFolder = 'Muzikler';
    else if (ext == 'mp4' || ext == 'webm' || ext == 'mkv') subFolder = 'Videolar';
    if (Platform.isAndroid) {
      final base = '/storage/emulated/0/Download/IndirGitsin';
      final path = subFolder.isEmpty ? base : '$base/$subFolder';
      final dir = Directory(path);
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir.path;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      final sub = Directory(p.join(dir.path, 'IndirGitsin', subFolder));
      if (!await sub.exists()) await sub.create(recursive: true);
      return sub.path;
    }
  }

  String sanitize(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<String> download({
    required String url,
    required String fileName,
    required String ext,
    required void Function(int received, int total) onProgress,
    String? videoId,
    String? streamTag,
  }) async {
    final ok = await requestPermission();
    if (!ok) throw Exception('Depolama izni verilmedi');

    final dir = await getDownloadPath(ext: ext);
    final safe = sanitize(fileName);
    final path = p.join(dir, '$safe.$ext');
    _cancelToken = CancelToken();

    // MP3/WEBM için direkt explode fallback daha güvenilir (YouTube audio throttling)
    if ((ext == 'mp3' || ext == 'webm') && videoId != null && streamTag != null) {
      try {
        return await _downloadViaExplode(videoId: videoId, streamTag: streamTag, fileName: fileName, ext: ext, onProgress: onProgress);
      } catch (e) {
        debugPrint('MP3/WEBM explode ilk deneme hata, dio fallback: $e');
      }
    }

    // DioException 403/429 için yeniden deneme + taze URL alma
    String currentUrl = url;
    DioException? lastError;
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        await _dio.download(
          currentUrl,
          path,
          cancelToken: _cancelToken,
          onReceiveProgress: onProgress,
          deleteOnError: true,
          options: Options(
            headers: {
              'User-Agent': 'com.google.android.youtube/19.09.37 (Linux; U; Android 14) gzip',
              'Accept': '*/*',
              'Referer': 'https://www.youtube.com/watch?v=${videoId ?? ''}',
              'Origin': 'https://www.youtube.com',
              'Connection': 'keep-alive',
            },
            followRedirects: true,
            validateStatus: (s) => s != null && s < 400,
          ),
        );
        // Dosya oluştu mu kontrol et
        final f = File(path);
        if (await f.exists() && await f.length() > 1024) return path;
        throw Exception('İndirilen dosya çok küçük - tekrar deneniyor');
      } on DioException catch (e) {
        lastError = e;
        final code = e.response?.statusCode;
        final isRetryable = code == 403 || code == 429 || code == 500 || code == 502 || code == 503 || e.type == DioExceptionType.connectionTimeout || e.type == DioExceptionType.receiveTimeout;
        if (!isRetryable || attempt == 2) break;
        // 403 ise taze URL almayı dene
        if (code == 403 && videoId != null && streamTag != null) {
          final fresh = await _resolveFreshUrl(videoId, streamTag);
          if (fresh != null && fresh != currentUrl) {
            currentUrl = fresh;
            debugPrint('403 -> taze URL alindi, yeniden deneniyor');
          }
        }
        await Future.delayed(Duration(milliseconds: 800 * (1 << attempt)));
        // progress'i sıfırla
        onProgress(0, 0);
      }
    }

    // Dio ile olmadiysa youtube_explode stream ile fallback dene
    if (videoId != null && streamTag != null) {
      try {
        return await _downloadViaExplode(videoId: videoId, streamTag: streamTag, fileName: fileName, ext: ext, onProgress: onProgress);
      } catch (e) {
        debugPrint('Explode fallback da hata: $e');
      }
    }

    // Hata mesajını kullanıcı dostu yap - nedenini açıkla
    if (lastError != null) {
      final code = lastError.response?.statusCode;
      if (code == 403) {
        if (ext == 'mp3') throw Exception('MP3 indirilemedi (403): YouTube bu videoda MP3 koruması uyguluyor olabilir. MP4 deneyin veya farklı bir video deneyin.');
        if (ext == 'webm') throw Exception('WEBM indirilemedi (403): Bu formatta lisans/bölge kısıtlaması var. MP4 deneyin.');
        throw Exception('YouTube erişimi reddedildi (403). Lisans korumalı veya bölge kısıtlı olabilir. MP4 ile tekrar deneyin.');
      }
      if (code == 404) throw Exception('Stream bulunamadı (404). Video silinmiş veya format desteklenmiyor.');
      if (lastError.type == DioExceptionType.connectionTimeout) throw Exception('Bağlantı zaman aşımı. İnternetini kontrol et.');
      throw Exception('İndirme hatası (${code ?? lastError.type}): ${lastError.message}');
    }
    throw Exception('İndirme başarısız - lisans korumalı olabilir, MP4 ile deneyin');
  }

  Future<String?> _resolveFreshUrl(String videoId, String tag) async {
    try {
      final yt = YoutubeExplode();
      final manifest = await yt.videos.streamsClient.getManifest(videoId).timeout(const Duration(seconds: 8));
      // tag eşleşen stream'i bul
      for (final s in [...manifest.muxed, ...manifest.audioOnly, ...manifest.videoOnly]) {
        if (s.tag.toString() == tag) return s.url.toString();
      }
      // fallback ilk muxed
      if (manifest.muxed.isNotEmpty) return manifest.muxed.first.url.toString();
      yt.close();
    } catch (_) {}
    return null;
  }

  Future<String> _downloadViaExplode({
    required String videoId,
    required String streamTag,
    required String fileName,
    required String ext,
    required void Function(int, int) onProgress,
  }) async {
    final yt = YoutubeExplode();
    try {
      final manifest = await yt.videos.streamsClient.getManifest(videoId);
      dynamic target;
      for (final s in manifest.muxed) { if (s.tag.toString() == streamTag) { target = s; break; } }
      target ??= manifest.audioOnly.cast<dynamic>().firstWhere((s) => s.tag.toString() == streamTag, orElse: () => null);
      target ??= manifest.videoOnly.cast<dynamic>().firstWhere((s) => s.tag.toString() == streamTag, orElse: () => null);
      target ??= manifest.muxed.isNotEmpty ? manifest.muxed.first : manifest.audioOnly.first;
      final stream = yt.videos.streamsClient.get(target);
      final dir = await getDownloadPath(ext: ext);
      final path = p.join(dir, '${sanitize(fileName)}.$ext');
      final file = File(path);
      final sink = file.openWrite();
      int received = 0;
      final total = target.size.totalBytes;
      await for (final chunk in stream) {
        if (_cancelToken?.isCancelled ?? false) break;
        sink.add(chunk);
        received += chunk.length;
        onProgress(received, total);
      }
      await sink.close();
      yt.close();
      return path;
    } catch (e) {
      yt.close();
      rethrow;
    }
  }

  void cancel() => _cancelToken?.cancel('İptal edildi');

  Future<int> getFreeSpace() async {
    try {
      final dir = await getDownloadPath();
      final stat = await FileStat.stat(dir);
      return stat.size;
    } catch (_) {
      return 0;
    }
  }
}
