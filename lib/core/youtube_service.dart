import 'package:youtube_explode_dart/youtube_explode_dart.dart';

class VideoInfo {
  final String id;
  final String title;
  final String author;
  final String channelId;
  final Duration? duration;
  final String thumbnailUrl;
  final String description;
  final int? viewCount;
  final DateTime? uploadDate;
  final List<StreamOption> streams;

  VideoInfo({
    required this.id,
    required this.title,
    required this.author,
    required this.channelId,
    required this.duration,
    required this.thumbnailUrl,
    required this.description,
    required this.viewCount,
    required this.uploadDate,
    required this.streams,
  });
}

class StreamOption {
  final String tag;
  final String qualityLabel;
  final String container;
  final int? bitrate;
  final String sizeLabel;
  final String type; // muxed, videoOnly, audioOnly
  final String url;
  final int? height;
  final String? audioCodec;
  final String? videoCodec;

  StreamOption({
    required this.tag,
    required this.qualityLabel,
    required this.container,
    this.bitrate,
    required this.sizeLabel,
    required this.type,
    required this.url,
    this.height,
    this.audioCodec,
    this.videoCodec,
  });
}

class YoutubeService {
  final _yt = YoutubeExplode();
  // Bellek içi cache: aynı link tekrar sorgulanınca anında döner
  final Map<String, VideoInfo> _cache = {};
  final Map<String, DateTime> _cacheAt = {};
  static const _cacheTtl = Duration(minutes: 10);

  // Desteklenen URL patternleri: youtube.com, youtu.be, music.youtube.com, m.youtube.com, shorts, live
  static final _regex = RegExp(
    r'(?:youtube\.com\/(?:watch\?v=|shorts\/|live\/)|youtu\.be\/|music\.youtube\.com\/watch\?v=|m\.youtube\.com\/watch\?v=)([A-Za-z0-9_-]{11})',
  );

  static String? extractVideoId(String url) {
    final match = _regex.firstMatch(url);
    if (match != null) return match.group(1);
    // Fallback: v parametresi ve diğer formatlar
    final uri = Uri.tryParse(url.trim());
    if (uri != null) {
      if (uri.queryParameters.containsKey('v')) {
        final v = uri.queryParameters['v']!;
        if (v.length == 11) return v;
      }
      // youtu.be path
      final seg = uri.pathSegments.isNotEmpty ? uri.pathSegments.last : '';
      if (seg.length == 11 && RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(seg)) return seg;
    }
    return null;
  }

  static bool isValidYoutubeUrl(String url) => extractVideoId(url) != null;

  Future<VideoInfo> getVideoInfo(String url) async {
    final videoId = extractVideoId(url);
    if (videoId == null) throw Exception('Geçersiz YouTube linki');
    // Cache hit?
    final cached = _cache[videoId];
    if (cached != null && DateTime.now().difference(_cacheAt[videoId]!) < _cacheTtl) {
      return cached;
    }
    // Paralel fetch: video bilgisi + manifest aynı anda (hız +%40)
    final results = await Future.wait([
      _yt.videos.get(videoId).timeout(const Duration(seconds: 8)),
      _yt.videos.streamsClient.getManifest(videoId).timeout(const Duration(seconds: 8)),
    ]);
    final video = results[0] as Video;
    final manifest = results[1] as StreamManifest;

    final streams = <StreamOption>[];

    for (final s in manifest.muxed) {
      streams.add(StreamOption(
        tag: s.tag.toString(),
        qualityLabel: s.videoQualityLabel,
        container: s.container.name,
        bitrate: s.bitrate.bitsPerSecond,
        sizeLabel: s.size.totalMegaBytes.toStringAsFixed(1) + ' MB',
        type: 'muxed',
        url: s.url.toString(),
        height: int.tryParse(s.videoQualityLabel.replaceAll(RegExp(r'[^0-9]'), '')),
        audioCodec: s.audioCodec,
        videoCodec: s.videoCodec,
      ));
    }
    for (final s in manifest.videoOnly) {
      streams.add(StreamOption(
        tag: s.tag.toString(),
        qualityLabel: '${s.videoQualityLabel} (sadece video)',
        container: s.container.name,
        bitrate: s.bitrate.bitsPerSecond,
        sizeLabel: s.size.totalMegaBytes.toStringAsFixed(1) + ' MB',
        type: 'videoOnly',
        url: s.url.toString(),
        height: int.tryParse(s.videoQualityLabel.replaceAll(RegExp(r'[^0-9]'), '')),
        videoCodec: s.videoCodec,
      ));
    }
    for (final s in manifest.audioOnly) {
      final kbps = (s.bitrate.kiloBitsPerSecond).round();
      streams.add(StreamOption(
        tag: s.tag.toString(),
        qualityLabel: '$kbps kbps ses',
        container: s.container.name,
        bitrate: s.bitrate.bitsPerSecond,
        sizeLabel: s.size.totalMegaBytes.toStringAsFixed(1) + ' MB',
        type: 'audioOnly',
        url: s.url.toString(),
        audioCodec: s.audioCodec,
      ));
    }

    // En yüksek kalite önce
    streams.sort((a, b) {
      const order = {'muxed': 0, 'videoOnly': 1, 'audioOnly': 2};
      final c = order[a.type]!.compareTo(order[b.type]!);
      if (c != 0) return c;
      return (b.height ?? b.bitrate ?? 0).compareTo(a.height ?? a.bitrate ?? 0);
    });

    final info = VideoInfo(
      id: video.id.value,
      title: video.title,
      author: video.author,
      channelId: video.channelId.value,
      duration: video.duration,
      thumbnailUrl: video.thumbnails.highResUrl,
      description: video.description,
      viewCount: video.engagement.viewCount,
      uploadDate: video.uploadDate,
      streams: streams,
    );
    _cache[videoId] = info;
    _cacheAt[videoId] = DateTime.now();
    return info;
  }

  void clearCache() {
    _cache.clear();
    _cacheAt.clear();
  }

  void close() => _yt.close();
}
