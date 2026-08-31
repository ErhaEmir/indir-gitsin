import 'package:youtube_explode_dart/youtube_explode_dart.dart';
import 'package:dio/dio.dart';

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
  final _dio = Dio();
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

  static bool isValidYoutubeUrl(String url) => extractVideoId(url) != null || isPlaylistUrl(url);

  // Playlist desteği
  static final _playlistRegex = RegExp(r'[?&]list=([A-Za-z0-9_-]+)');
  static String? extractPlaylistId(String url) {
    final m = _playlistRegex.firstMatch(url);
    return m?.group(1);
  }
  static bool isPlaylistUrl(String url) => extractPlaylistId(url) != null;

  Future<List<VideoInfo>> getPlaylistVideos(String playlistUrl) async {
    final pid = extractPlaylistId(playlistUrl);
    if (pid == null) throw Exception('Geçersiz playlist');
    await _yt.playlists.get(pid).timeout(const Duration(seconds: 8));
    final videos = await _yt.playlists.getVideos(pid).take(12).toList(); // 20->12 hız için
    // Paralel çek — 4'lü batch ile (sıralı 12× beklemek yerine ~3× süre)
    final out = <VideoInfo>[];
    for (int i = 0; i < videos.length; i += 4) {
      final batch = videos.skip(i).take(4).toList();
      final results = await Future.wait(batch.map((v) async {
        try { return await getVideoInfo('https://www.youtube.com/watch?v=${v.id.value}').timeout(const Duration(seconds: 8)); } catch (_) { return null; }
      }));
      for (final r in results) { if (r != null) out.add(r); }
    }
    return out;
  }

  // Arama — hafif mod: search sonucundan direkt VideoInfo üret (getVideoInfo çağrısı yok, hızlı & stabil)
  Future<List<VideoInfo>> search(String query) async {
    final res = await _yt.search.search(query).timeout(const Duration(seconds: 8));
    final out = <VideoInfo>[];
    for (final e in res) {
      if (e is Video) {
        if (out.length >= 10) break;
        // Search sonucundan direkt kur — manifest çekmeden, anında döner
        out.add(VideoInfo(
          id: e.id.value,
          title: e.title,
          author: e.author,
          channelId: e.channelId.value,
          duration: e.duration,
          thumbnailUrl: e.thumbnails.highResUrl,
          description: e.description,
          viewCount: e.engagement.viewCount,
          uploadDate: e.uploadDate,
          streams: [], // detay için tıklayınca _fetch -> getVideoInfo çağrılacak
        ));
      }
    }
    return out;
  }

  // Altyazı
  Future<List<String>> getCaptionTracks(String videoId) async {
    try {
      final trackManifest = await _yt.videos.closedCaptions.getManifest(videoId);
      return trackManifest.tracks.map((t) => '${t.language.code} - ${t.language.name}').toList();
    } catch (_) { return []; }
  }

  // Piped fallback - MP3/WEBM için çoklu mirror (kavin.rocks tek nokta hatasını önler)
  static const _pipedMirrors = [
    'https://pipedapi.kavin.rocks',
    'https://pipedapi.adminforge.de',
    'https://pipedapi.syncpundit.io',
    'https://pipedapi.leptun.org',
  ];

  Future<List<StreamOption>> _getPipedStreams(String videoId) async {
    for (final mirror in _pipedMirrors) {
      try {
        final r = await _dio.get('$mirror/streams/$videoId', options: Options(headers: {'User-Agent': 'Mozilla/5.0'}, receiveTimeout: const Duration(seconds: 5), sendTimeout: const Duration(seconds: 5)));
        if (r.statusCode == 200) {
          final data = r.data as Map<String, dynamic>;
          final out = <StreamOption>[];
          final audioStreams = data['audioStreams'] as List? ?? [];
          for (final s in audioStreams) {
            final m = s as Map<String, dynamic>;
            final url = m['url'] as String?;
            if (url == null) continue;
            final bitrate = (m['bitrate'] as int? ?? 128000);
            out.add(StreamOption(tag: 'piped-a-${m['itag']}', qualityLabel: '${bitrate ~/ 1000} kbps MP3', container: 'mp3', bitrate: bitrate, sizeLabel: '', type: 'audioOnly', url: url));
          }
          final videoStreams = data['videoStreams'] as List? ?? [];
          for (final s in videoStreams) {
            final m = s as Map<String, dynamic>;
            final url = m['url'] as String?;
            if (url == null) continue;
            final q = m['quality'] as String? ?? '720p';
            final mime = m['mimeType'] as String? ?? '';
            final cont = mime.contains('webm') ? 'webm' : 'mp4';
            out.add(StreamOption(tag: 'piped-v-${m['itag']}', qualityLabel: q, container: cont, bitrate: m['bitrate'] as int?, sizeLabel: '', type: 'muxed', url: url, height: int.tryParse(q.replaceAll(RegExp(r'[^0-9]'), ''))));
          }
          if (out.isNotEmpty) return out;
        }
      } catch (_) { continue; }
    }
    return [];
  }

  // Trend (Keşfet) - YouTube Music Top 100 için Piped + youtube_explode fallback
  Future<List<Map<String, dynamic>>> getTrending() async => getTrendingMusic();

  // Trending cache — 15 dk içinde tekrar çağrılırsa anında döner
  static List<Map<String, dynamic>>? _trendingCache;
  static DateTime? _trendingCacheAt;
  static const _trendingTtl = Duration(minutes: 15);

  Future<List<Map<String, dynamic>>> getTrendingMusic() async {
    if (_trendingCache != null && _trendingCacheAt != null && DateTime.now().difference(_trendingCacheAt!) < _trendingTtl) {
      return _trendingCache!;
    }
    // Paralel mirror dene — ilk dönen kazanır (sıralı 4×5s yerine ~3s)
    final endpoints = _pipedMirrors.take(3).map((m) => '$m/trending?region=TR').toList();
    final futures = endpoints.map((ep) async {
      try {
        final r = await _dio.get(ep, options: Options(headers: {'User-Agent': 'Mozilla/5.0'}, receiveTimeout: const Duration(seconds: 4)));
        if (r.statusCode == 200) {
          final data = r.data;
          final list = data is List ? data : (data is Map ? data['videos'] as List? ?? [] : []);
          var filtered = list.where((e)=> (e['category']?.toString().toLowerCase().contains('music') ?? false)).toList();
          if (filtered.isEmpty) filtered = list;
          if (filtered.isNotEmpty) {
            return filtered.take(100).map((e) => {
              'id': (e['url']?.toString().split('v=').last ?? e['id']?.toString() ?? '').split('&').first,
              'title': e['title'] ?? '',
              'thumbnail': e['thumbnail'] ?? e['thumbnailUrl'] ?? '',
              'author': e['uploaderName'] ?? e['uploader'] ?? '',
              'views': e['views'] ?? 0,
            }).where((m)=> (m['id'] as String).length==11).toList();
          }
        }
      } catch (_) {}
      return <Map<String, dynamic>>[];
    }).toList();
    // İlk başarılı sonuç
    for (final f in futures) {
      try {
        final res = await f.timeout(const Duration(seconds: 5));
        if (res.isNotEmpty) {
          _trendingCache = res;
          _trendingCacheAt = DateTime.now();
          return res;
        }
      } catch (_) {}
    }
    // Hiçbiri dönmediyse sırayla tek tek dene (fallback)
    for (final ep in endpoints) {
      try {
        final r = await _dio.get(ep, options: Options(headers: {'User-Agent': 'Mozilla/5.0'}, receiveTimeout: const Duration(seconds: 4)));
        if (r.statusCode == 200) {
          final data = r.data;
          final list = data is List ? data : (data is Map ? data['videos'] as List? ?? [] : []);
          var filtered = list.where((e)=> (e['category']?.toString().toLowerCase().contains('music') ?? false)).toList();
          if (filtered.isEmpty) filtered = list;
          if (filtered.isNotEmpty) {
            final res = filtered.take(100).map((e) => {
              'id': (e['url']?.toString().split('v=').last ?? e['id']?.toString() ?? '').split('&').first,
              'title': e['title'] ?? '',
              'thumbnail': e['thumbnail'] ?? e['thumbnailUrl'] ?? '',
              'author': e['uploaderName'] ?? e['uploader'] ?? '',
              'views': e['views'] ?? 0,
            }).where((m)=> (m['id'] as String).length==11).toList();
            if (res.isNotEmpty) {
              _trendingCache = res;
              _trendingCacheAt = DateTime.now();
              return res;
            }
          }
        }
      } catch (_) { continue; }
    }
    // Fallback: youtube_explode search ile Top 100 Music
    try {
      final res = await _yt.search.search('Top 100 Turkey Music 2024').timeout(const Duration(seconds: 6));
      final out = <Map<String,dynamic>>[];
      for (final e in res.take(40)) {
        if (e is Video) {
          out.add({'id': e.id.value, 'title': e.title, 'thumbnail': e.thumbnails.highResUrl, 'author': e.author, 'views': e.engagement.viewCount ?? 0});
        }
      }
      if (out.isNotEmpty) {
        _trendingCache = out;
        _trendingCacheAt = DateTime.now();
        return out;
      }
    } catch (_){}
    // Cache varsa onu dön (eski veri bile boş ekrandan iyidir)
    if (_trendingCache != null && _trendingCache!.isNotEmpty) return _trendingCache!;
    return [];
  }

  Future<VideoInfo> getVideoInfo(String url) async {
    final videoId = extractVideoId(url);
    if (videoId == null) throw Exception('Geçersiz YouTube linki. Linki kontrol edin (youtu.be, youtube.com, music.youtube.com, shorts desteklenir)');
    // Cache hit?
    final cached = _cache[videoId];
    if (cached != null && DateTime.now().difference(_cacheAt[videoId]!) < _cacheTtl) {
      return cached;
    }
    // Kendi videoların ve Music için retry + daha uzun timeout + detaylı hata
    Video? video;
    StreamManifest? manifest;
    String? lastErr;
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        final results = await Future.wait([
          _yt.videos.get(videoId).timeout(const Duration(seconds: 15)),
          _yt.videos.streamsClient.getManifest(videoId).timeout(const Duration(seconds: 15)),
        ]);
        video = results[0] as Video;
        manifest = results[1] as StreamManifest;
        break;
      } catch (e) {
        lastErr = e.toString();
        if (e.toString().contains('TimeoutException') || e.toString().contains('SocketException') || e.toString().contains('ClientException')) {
          // ağ hatası, tekrar dene
          await Future.delayed(Duration(milliseconds: 700 * (attempt+1)));
          continue;
        }
        if (url.contains('music.youtube.com') && attempt == 0) {
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
        if (attempt < 2) await Future.delayed(Duration(milliseconds: 600 * (attempt+1)));
      }
    }
    if (video == null || manifest == null) {
      if (lastErr != null && lastErr.contains('VideoUnavailable')) throw Exception('Video bulunamadı veya gizli. Kendi videon ise gizlilik ayarını Herkese Açık yapıp tekrar dene.');
      if (lastErr != null && lastErr.contains('Requires login')) throw Exception('Bu video giriş gerektiriyor. YouTube Music/özel videolarda bazen olur, herkese açık bir link dene.');
      if (lastErr != null && (lastErr.contains('Timeout') || lastErr.contains('Socket'))) throw Exception('Bağlantı yavaş, tekrar dene (sunucu yoğun olabilir). Farklı kalite seçmeyi dene.');
      throw Exception(lastErr ?? 'Video bilgisi alınamadı - interneti kontrol et ve tekrar dene');
    }

    final streams = <StreamOption>[];

    for (final s in manifest!.muxed) {
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
    for (final s in manifest!.videoOnly) {
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
    for (final s in manifest!.audioOnly) {
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

    // Lisans / DRM kontrolü - hiç stream yoksa
    if (streams.isEmpty) {
      // Video açıklaması veya başlıkta lisans ipucu var mı kontrol et
      final desc = video.description.toLowerCase();
      if (desc.contains('lisans') || desc.contains('copyright') || video.title.toLowerCase().contains('official')) {
        // yine de deneyelim, belki sadece manifest boş
      }
      throw Exception('Bu video indirilemiyor (lisans korumalı, canlı yayın veya bölge kısıtlaması olabilir). Farklı bir video deneyin.');
    }

    // MP3 için sentetik seçenek ekle - en iyi audioOnly'yi MP3 olarak sun
    final audioOnly = streams.where((s)=> s.type=='audioOnly').toList();
    if (audioOnly.isNotEmpty) {
      final bestAudio = audioOnly.reduce((a,b)=> (a.bitrate??0) > (b.bitrate??0) ? a : b);
      final mp3Exists = streams.any((s)=> s.type=='audioOnly' && s.container.toLowerCase()=='mp3');
      if (!mp3Exists) {
        streams.add(StreamOption(
          tag: bestAudio.tag,
          qualityLabel: '${(bestAudio.bitrate ?? 128000) ~/ 1000} kbps MP3',
          container: 'mp3',
          bitrate: bestAudio.bitrate,
          sizeLabel: bestAudio.sizeLabel,
          type: 'audioOnly',
          url: bestAudio.url,
          audioCodec: 'mp3',
        ));
      }
    }

    // En yüksek kalite önce
    streams.sort((a, b) {
      const order = {'muxed': 0, 'videoOnly': 1, 'audioOnly': 2};
      final c = order[a.type]!.compareTo(order[b.type]!);
      if (c != 0) return c;
      return (b.height ?? b.bitrate ?? 0).compareTo(a.height ?? a.bitrate ?? 0);
    });

    // MP3/WEBM eksikse Piped ile tamamla (Notube tarzı)
    final hasMp3 = streams.any((s) => s.container == 'mp3');
    final hasWebm = streams.any((s) => s.container == 'webm');
    if (!hasMp3 || !hasWebm || streams.length < 4) {
      final piped = await _getPipedStreams(videoId);
      for (final p in piped) {
        if (!streams.any((s) => s.tag == p.tag)) streams.add(p);
      }
      // Tekrar sırala
      streams.sort((a, b) {
        const order = {'muxed': 0, 'videoOnly': 1, 'audioOnly': 2};
        final c = order[a.type]!.compareTo(order[b.type]!);
        if (c != 0) return c;
        return (b.height ?? b.bitrate ?? 0).compareTo(a.height ?? a.bitrate ?? 0);
      });
    }
    if (streams.isEmpty) throw Exception('Bu video indirilemiyor (lisans korumalı, canlı yayın veya bölge kısıtlaması).');

    final info = VideoInfo(
      id: video!.id.value,
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
