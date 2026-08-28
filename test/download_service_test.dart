import 'package:flutter_test/flutter_test.dart';
import 'package:indir_gitsin/core/download_service.dart';

void main() {
  test('sanitize dosya adı', () {
    final s = DownloadService();
    expect(s.sanitize('video: test?*'), 'video_ test__');
    expect(s.sanitize('  çok   boşluk  '), 'çok boşluk');
  });
}
