import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppUpdateService {
  static const repo = 'ErhaEmir/indir-gitsin';
  static const checkInterval = Duration(hours: 6);
  final Dio _dio = Dio();

  // Her açılışta kontrol için: interval kontrolü atlanabilir, force ile — sessiz, kullanıcıyı rahatsız etmez
  Future<void> checkAndUpdateSilently({bool force = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('auto_update_enabled') ?? true;
      if (!enabled && !force) return;
      final last = prefs.getInt('last_update_check') ?? 0;
      // interval dakika bazlı (yeni) — eski saat key'i ile uyumlu
      int intervalMin = prefs.getInt('update_interval_minutes') ?? (prefs.getInt('update_interval_hours') ?? 6) * 60;
      final intervalMs = intervalMin * 60000;
      if (!force && DateTime.now().millisecondsSinceEpoch - last < intervalMs) return;
      await prefs.setInt('last_update_check', DateTime.now().millisecondsSinceEpoch);

      final info = await PackageInfo.fromPlatform();
      final current = info.version; // 1.0.2
      final latest = await _fetchLatestTag();
      if (latest == null) return;
      // tag v1.0.2-21 -> version 1.0.2
      final latestVersion = latest.replaceFirst('v', '').split('-').first;
      if (_isNewer(latestVersion, current)) {
        debugPrint('Güncelleme var: $current -> $latestVersion ($latest)');
        final apkUrl = await _fetchApkUrl(latest);
        if (apkUrl != null) {
          final path = await _downloadApk(apkUrl, latest);
          if (path != null) {
            // Sessiz: direkt installer'ı aç, sistem kullanıcıya sorar ama biz sormadan başlattık
            await OpenFilex.open(path);
          }
        }
      }
    } catch (e) {
      debugPrint('auto update hata: $e');
    }
  }

  Future<String?> _fetchLatestTag() async {
    // Rate-limit dostu: hata olursa null dön, retry için cache kullan
    try {
      final r = await _dio.get('https://api.github.com/repos/$repo/releases/latest',
          options: Options(headers: {'Accept': 'application/vnd.github.v3+json'}, receiveTimeout: const Duration(seconds: 8), sendTimeout: const Duration(seconds: 5)));
      if (r.statusCode == 200) {
        final tag = r.data['tag_name'] as String?;
        if (tag != null) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('cached_latest_tag', tag);
          await prefs.setInt('cached_tag_time', DateTime.now().millisecondsSinceEpoch);
        }
        return tag;
      }
      // 403 rate-limit ise cache dön
      if (r.statusCode == 403) {
        final prefs = await SharedPreferences.getInstance();
        return prefs.getString('cached_latest_tag');
      }
    } on DioException catch (e) {
      if (e.response?.statusCode == 403) {
        try { final prefs = await SharedPreferences.getInstance(); return prefs.getString('cached_latest_tag'); } catch (_) {}
      }
      // 1 saat içinde rate-limit yediysek sessiz kal
      try {
        final prefs = await SharedPreferences.getInstance();
        final cachedTime = prefs.getInt('cached_tag_time') ?? 0;
        if (DateTime.now().millisecondsSinceEpoch - cachedTime < 3600000) return prefs.getString('cached_latest_tag');
      } catch (_) {}
    } catch (_) {}
    return null;
  }

  // Manuel kontrol için: güncelleme var mı, varsa dialog ile sor
  Future<Map<String, dynamic>?> checkForUpdateManual() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final current = info.version;
      final latest = await _fetchLatestTag();
      if (latest == null) return {'hasUpdate': false, 'current': current};
      final latestVersion = latest.replaceFirst('v', '').split('-').first;
      final hasUpdate = _isNewer(latestVersion, current);
      return {'hasUpdate': hasUpdate, 'current': current, 'latest': latest, 'latestVersion': latestVersion};
    } catch (e) {
      return null;
    }
  }

  Future<String?> downloadAndInstall(String tag, {void Function(int, int)? onProgress}) async {
    final apkUrl = await _fetchApkUrl(tag);
    if (apkUrl == null) return null;
    final path = await _downloadApk(apkUrl, tag, onProgress: onProgress);
    if (path != null) await OpenFilex.open(path);
    return path;
  }

  Future<String?> _fetchApkUrl(String tag) async {
    final r = await _dio.get('https://api.github.com/repos/$repo/releases/tags/$tag');
    if (r.statusCode == 200) {
      final assets = r.data['assets'] as List;
      for (final a in assets) {
        final name = a['name'] as String;
        if (name == 'app-release.apk') return a['browser_download_url'] as String;
      }
      if (assets.isNotEmpty) return assets.first['browser_download_url'] as String;
    }
    return null;
  }

  Future<String?> _downloadApk(String url, String tag, {void Function(int, int)? onProgress}) async {
    final dir = await getTemporaryDirectory();
    final path = '${dir.path}/indir-gitsin-$tag.apk';
    await _dio.download(url, path, onReceiveProgress: onProgress, options: Options(headers: {'User-Agent': 'IndirGitsin-Updater'}));
    final f = File(path);
    if (await f.exists() && await f.length() > 1000000) return path;
    return null;
  }

  bool _isNewer(String latest, String current) {
    List<int> parse(String v) => v.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final l = parse(latest), c = parse(current);
    for (int i = 0; i < 3; i++) {
      final lv = l.length > i ? l[i] : 0;
      final cv = c.length > i ? c[i] : 0;
      if (lv > cv) return true;
      if (lv < cv) return false;
    }
    // aynı version ama tag farklı olabilir (build numarası) - yine güncelle
    return latest != current;
  }
}
