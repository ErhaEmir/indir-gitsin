import 'package:flutter_test/flutter_test.dart';
import 'package:indir_gitsin/core/youtube_service.dart';

void main() {
  group('YoutubeService URL parsing', () {
    test('standart youtube.com', () {
      expect(YoutubeService.extractVideoId('https://www.youtube.com/watch?v=jNQXAC9IVRw'), 'jNQXAC9IVRw');
    });
    test('youtu.be kısa', () {
      expect(YoutubeService.extractVideoId('https://youtu.be/jNQXAC9IVRw'), 'jNQXAC9IVRw');
    });
    test('music.youtube.com', () {
      expect(YoutubeService.extractVideoId('https://music.youtube.com/watch?v=jNQXAC9IVRw'), 'jNQXAC9IVRw');
    });
    test('m.youtube.com', () {
      expect(YoutubeService.extractVideoId('https://m.youtube.com/watch?v=jNQXAC9IVRw'), 'jNQXAC9IVRw');
    });
    test('geçersiz', () {
      expect(YoutubeService.extractVideoId('https://example.com'), isNull);
      expect(YoutubeService.isValidYoutubeUrl('https://example.com'), isFalse);
    });
    test('isValid true', () {
      expect(YoutubeService.isValidYoutubeUrl('https://www.youtube.com/watch?v=jNQXAC9IVRw&t=10s'), isTrue);
    });
  });
}
