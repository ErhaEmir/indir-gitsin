import 'dart:io';
import 'package:dio/dio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:path/path.dart' as p;

class DownloadService {
  final Dio _dio = Dio();
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

  Future<String> getDownloadPath() async {
    if (Platform.isAndroid) {
      // /storage/emulated/0/Download/IndirGitsin
      final dir = Directory('/storage/emulated/0/Download/IndirGitsin');
      if (!await dir.exists()) await dir.create(recursive: true);
      return dir.path;
    } else {
      final dir = await getApplicationDocumentsDirectory();
      final sub = Directory(p.join(dir.path, 'IndirGitsin'));
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
  }) async {
    final ok = await requestPermission();
    if (!ok) throw Exception('Depolama izni verilmedi');

    final dir = await getDownloadPath();
    final safe = sanitize(fileName);
    final path = p.join(dir, '$safe.$ext');
    _cancelToken = CancelToken();
    await _dio.download(
      url,
      path,
      cancelToken: _cancelToken,
      onReceiveProgress: onProgress,
      options: Options(headers: {'User-Agent': 'Mozilla/5.0'}),
    );
    return path;
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
