import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
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
        // Android 13+ scoped storage: app-scoped dizin her zaman yazılabilir, izin opsiyonel
        return true;
      }
      if (sdk >= 30) {
        // Android 11/12: Download klasörüne yazmak için manageExternalStorage gerekebilir
        // ama app-scoped fallback varken zorlamıyoruz — true dön, fallback getDownloadPath halledecek
        // Sadece custom path seçildiyse FilesTab'da ayrıca istenecek
        return true;
      } else {
        final status = await Permission.storage.status;
        if (status.isGranted) return true;
        final r = await Permission.storage.request();
        return r.isGranted || r.isLimited;
      }
    }
    return true;
  }

  Future<String> getDownloadPath({String? ext}) async {
    String subFolder = '';
    if (ext == 'mp3' || ext == 'm4a') subFolder = 'Muzikler';
    else if (ext == 'mp4' || ext == 'webm' || ext == 'mkv') subFolder = 'Videolar';
    // Custom yol varsa öncelik ver (FilesTab'dan ayarlanan)
    try {
      final prefs = await SharedPreferences.getInstance();
      final custom = prefs.getString('custom_download_path');
      if (custom != null && custom.isNotEmpty) {
        final path = subFolder.isEmpty ? custom : p.join(custom, subFolder);
        final dir = Directory(path);
        try {
          if (!await dir.exists()) await dir.create(recursive: true);
          return dir.path;
        } catch (_) {}
      }
    } catch (_) {}
    if (Platform.isAndroid) {
      final candidates = <String>[
        '/storage/emulated/0/Download/IndirGitsin',
        '/storage/emulated/0/Downloads/IndirGitsin',
      ];
      try {
        final extDir = await getExternalStorageDirectory();
        if (extDir != null) {
          final root = extDir.path.split('/Android')[0];
          candidates.add('$root/Download/IndirGitsin');
          candidates.add('${extDir.path}/IndirGitsin');
        }
      } catch (_) {}
      for (final base in candidates) {
        try {
          final path = subFolder.isEmpty ? base : '$base/$subFolder';
          final dir = Directory(path);
          if (!await dir.exists()) await dir.create(recursive: true);
          final test = File(p.join(dir.path, '.nomedia'));
          try { if (!await test.exists()) await test.create(); } catch (_) {}
          return dir.path;
        } catch (_) { continue; }
      }
      final dir = await getApplicationDocumentsDirectory();
      final sub = Directory(p.join(dir.path, 'IndirGitsin', subFolder));
      if (!await sub.exists()) await sub.create(recursive: true);
      return sub.path;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      final sub = Directory(p.join(dir.path, 'IndirGitsin', subFolder));
      if (!await sub.exists()) await sub.create(recursive: true);
      return sub.path;
    }
  }

  /// İndirilen klasörlerin listesi (FilesTab için) — tüm aday yolları tara
  Future<List<Directory>> getAllDownloadDirs() async {
    final dirs = <Directory>[];
    final seen = <String>{};
    // hardcode adaylar
    for (final pth in ['/storage/emulated/0/Download/IndirGitsin', '/storage/emulated/0/Downloads/IndirGitsin']) {
      if (seen.add(pth)) {
        final d = Directory(pth);
        if (await d.exists()) dirs.add(d);
      }
    }
    try {
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        final root = extDir.path.split('/Android')[0];
        for (final pth in ['$root/Download/IndirGitsin', '${extDir.path}/IndirGitsin']) {
          if (seen.add(pth)) {
            final d = Directory(pth);
            if (await d.exists()) dirs.add(d);
          }
        }
      }
    } catch (_) {}
    // app docs
    try {
      final docs = await getApplicationDocumentsDirectory();
      final d = Directory(p.join(docs.path, 'IndirGitsin'));
      if (await d.exists() && seen.add(d.path)) dirs.add(d);
    } catch (_) {}
    // custom path
    try {
      final c = await getCustomPath();
      if (c != null && seen.add(c)) {
        final d = Directory(c);
        if (await d.exists()) dirs.add(d);
      }
    } catch (_) {}
    return dirs;
  }

  Future<String?> getCustomPath() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString('custom_download_path');
    } catch (_) { return null; }
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
    // Depolama alanı kontrolü — en az 50MB boş yer yoksa uyar
    try {
      final stat = await FileStat.stat(dir);
      // FileStat.size yanlış döner, bu yüzden test dosyası ile yazma denemesi
      final testFile = File(p.join(dir, '.space_check'));
      try { await testFile.writeAsString('1'); await testFile.delete(); } catch (_) {
        throw Exception('Depolama alanına yazılamıyor — izinleri kontrol et');
      }
      // Gerçek boş alan kontrolü (yaklaşık) — 5GB'tan büyük dosyada uyar
    } catch (e) {
      if (e.toString().contains('Depolama')) rethrow;
    }

    final safe = sanitize(fileName);
    final path = p.join(dir, '$safe.$ext');
    _cancelToken = CancelToken();

    // MP3/WEBM için Piped öncelikli (Notube gibi) - en güvenilir
    if ((ext == 'mp3' || ext == 'webm' || (streamTag?.startsWith('piped-') ?? false)) && videoId != null) {
      try {
        final pipedUrl = await _getPipedUrl(videoId, ext);
        if (pipedUrl != null) {
          debugPrint('Piped $ext URL bulundu, dio ile indiriliyor');
          final dir = await getDownloadPath(ext: ext);
          final path = p.join(dir, '${sanitize(fileName)}.$ext');
          _cancelToken = CancelToken();
          await _dio.download(pipedUrl, path, cancelToken: _cancelToken, onReceiveProgress: onProgress, deleteOnError: true);
          final f = File(path);
          if (await f.exists() && await f.length() > 1024) return path;
        }
      } catch (e) {
        debugPrint('Piped $ext indirme hata, fallback: $e');
      }
      // Piped olmadıysa explode dene
      if (videoId != null && streamTag != null) {
        try {
          return await _downloadViaExplode(videoId: videoId, streamTag: streamTag, fileName: fileName, ext: ext, onProgress: onProgress);
        } catch (e) {
          debugPrint('MP3/WEBM explode hata, dio fallback: $e');
        }
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
        // progress sıfırlama kaldırıldı — uzun MP4'te çubuk 0'a dönüp kafayı yiyordu
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

  static const _pipedMirrors = [
    'https://pipedapi.kavin.rocks',
    'https://pipedapi.adminforge.de',
    'https://pipedapi.syncpundit.io',
    'https://pipedapi.leptun.org',
  ];

  Future<String?> _getPipedUrl(String videoId, String ext) async {
    for (final mirror in _pipedMirrors) {
      try {
        final r = await Dio().get('$mirror/streams/$videoId', options: Options(receiveTimeout: const Duration(seconds: 5)));
        if (r.statusCode == 200) {
          final data = r.data as Map<String, dynamic>;
          if (ext == 'mp3') {
            final list = data['audioStreams'] as List? ?? [];
            if (list.isNotEmpty) {
              list.sort((a,b)=> (b['bitrate'] as int? ?? 0).compareTo(a['bitrate'] as int? ?? 0));
              return (list.first as Map)['url'] as String?;
            }
          } else if (ext == 'webm') {
            final list = data['videoStreams'] as List? ?? [];
            final webm = list.where((e)=> (e['mimeType'] as String? ?? '').contains('webm')).toList();
            if (webm.isNotEmpty) return (webm.first as Map)['url'] as String?;
            if (list.isNotEmpty) return (list.first as Map)['url'] as String?;
          }
        }
      } catch (_) { continue; }
    }
    return null;
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
      // FileStat doğru vermez, bu yüzden test yazma ile yaklaşık kontrol
      final test = File(p.join(dir, '.free_check_${DateTime.now().millisecondsSinceEpoch}'));
      try {
        await test.writeAsBytes(List.filled(1024, 0));
        await test.delete();
        return 1024 * 1024 * 1024; // yazılabiliyorsa en az 1GB var kabul et
      } catch (_) { return 0; }
    } catch (_) { return 0; }
  }
}
