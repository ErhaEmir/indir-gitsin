import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shimmer/shimmer.dart';
import 'core/theme.dart';
import 'core/youtube_service.dart';
import 'core/download_service.dart';

final youtubeServiceProvider = Provider((ref) => YoutubeService());
final downloadServiceProvider = Provider((ref) => DownloadService());

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: IndirGitsinApp()));
}

class IndirGitsinApp extends StatelessWidget {
  const IndirGitsinApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'İndir Gitsin',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      home: const HomePage(),
    );
  }
}

class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});
  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> with TickerProviderStateMixin {
  final _linkCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  VideoInfo? _video;
  bool _loading = false;
  String? _error;
  StreamSubscription? _intentSub;
  double _progress = 0;
  bool _downloading = false;
  String? _savedPath;
  StreamOption? _selected;
  Timer? _debounce;
  late AnimationController _heroCtrl;
  late Animation<double> _heroAnim;

  @override
  void initState() {
    super.initState();
    _heroCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));
    _heroAnim = CurvedAnimation(parent: _heroCtrl, curve: Curves.easeOutCubic);
    _heroCtrl.forward();
    _listenShareIntent();
    _checkClipboard();
    _linkCtrl.addListener(_onLinkChanged);
  }

  void _onLinkChanged() {
    _debounce?.cancel();
    final t = _linkCtrl.text.trim();
    if (YoutubeService.isValidYoutubeUrl(t) && _video == null && !_loading) {
      _debounce = Timer(const Duration(milliseconds: 600), _fetch);
    }
  }

  Future<void> _checkClipboard() async {
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text ?? '';
      if (YoutubeService.isValidYoutubeUrl(text)) {
        _linkCtrl.text = text;
        _fetch();
      }
    } catch (_) {}
  }

  void _listenShareIntent() {
    ReceiveSharingIntent.instance.getInitialMedia().then((List<SharedMediaFile> media) {
      if (media.isNotEmpty) {
        final text = media.first.path;
        if (YoutubeService.isValidYoutubeUrl(text)) {
          _linkCtrl.text = text;
          _fetch();
        }
      }
    });
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> media) {
      if (media.isNotEmpty) {
        final text = media.first.path;
        if (YoutubeService.isValidYoutubeUrl(text)) {
          _linkCtrl.text = text;
          _fetch();
        }
      }
    }, onError: (e) => debugPrint('intent error $e'));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _heroCtrl.dispose();
    _intentSub?.cancel();
    _linkCtrl.dispose();
    _scrollCtrl.dispose();
    ref.read(youtubeServiceProvider).close();
    super.dispose();
  }

  Future<void> _fetch() async {
    final url = _linkCtrl.text.trim();
    if (url.isEmpty) {
      setState(() => _error = 'Lütfen bir YouTube linki yapıştırın');
      return;
    }
    if (!YoutubeService.isValidYoutubeUrl(url)) {
      setState(() => _error = 'Geçersiz YouTube / YouTube Music linki');
      return;
    }
    HapticFeedback.lightImpact();
    setState(() {
      _loading = true;
      _error = null;
      _video = null;
      _selected = null;
      _savedPath = null;
    });
    final sw = Stopwatch()..start();
    try {
      final info = await ref.read(youtubeServiceProvider).getVideoInfo(url).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      setState(() {
        _video = info;
        _selected = info.streams.isNotEmpty ? info.streams.first : null;
      });
      debugPrint('resolve ${sw.elapsedMilliseconds}ms');
      HapticFeedback.selectionClick();
    } on TimeoutException {
      setState(() => _error = 'Çözümleme zaman aşımı — internetini kontrol et ve tekrar dene');
    } catch (e) {
      setState(() => _error = 'Video bilgisi alınamadı: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _download() async {
    if (_video == null || _selected == null) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _downloading = true;
      _progress = 0;
      _error = null;
    });
    try {
      final svc = ref.read(downloadServiceProvider);
      final ext = _selected!.container == 'mp4' ? 'mp4' : _selected!.container;
      final title = _video!.title;
      final path = await svc.download(
        url: _selected!.url,
        fileName: title,
        ext: _selected!.type == 'audioOnly' ? 'm4a' : ext,
        onProgress: (rx, total) {
          if (total > 0 && mounted) setState(() => _progress = rx / total);
        },
      );
      setState(() {
        _savedPath = path;
        _downloading = false;
        _progress = 1;
      });
      HapticFeedback.heavyImpact();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('İndirildi: ${path.split('/').last}'),
            action: SnackBarAction(label: 'AÇ', onPressed: () => OpenFilex.open(path)),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
        );
      }
    } catch (e) {
      setState(() {
        _downloading = false;
        _error = 'İndirme hatası: $e';
      });
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null) {
      _linkCtrl.text = data!.text!;
      _fetch();
    }
  }

  void _clear() {
    _linkCtrl.clear();
    setState(() { _video = null; _error = null; _savedPath = null; });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [cs.primary, cs.primary.withOpacity(0.85)]),
              borderRadius: BorderRadius.circular(12),
              boxShadow: [BoxShadow(color: cs.primary.withOpacity(0.25), blurRadius: 12, offset: const Offset(0, 4))],
            ),
            child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          const Text('İndir Gitsin', style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -0.5)),
        ]),
        actions: [
          IconButton(icon: const Icon(Icons.history_rounded), onPressed: () => _showHistory(), tooltip: 'Geçmiş'),
          const SizedBox(width: 4),
        ],
      ),
      body: CustomScrollView(
        controller: _scrollCtrl,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
            sliver: SliverList.list(children: [
              // Hero - glass + gradient
              ScaleTransition(
                scale: _heroAnim,
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft, end: Alignment.bottomRight,
                      colors: [cs.primary, const Color(0xFF9B0000)],
                    ),
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [BoxShadow(color: cs.primary.withOpacity(0.3), blurRadius: 20, offset: const Offset(0, 8))],
                  ),
                  child: Row(children: [
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.white.withOpacity(0.18), borderRadius: BorderRadius.circular(99)), child: const Text('YENİ', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: 1))),
                          const SizedBox(width: 8),
                          Text('⚡ 40% daha hızlı', style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 12, fontWeight: FontWeight.w600)),
                        ]),
                        const SizedBox(height: 8),
                        const Text('YouTube & Music', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18, letterSpacing: -0.5)),
                        const SizedBox(height: 4),
                        Text('Linki yapıştır → anında çözümlenir\nPaylaş → İndir Gitsin', style: TextStyle(color: Colors.white.withOpacity(0.88), fontSize: 12, height: 1.35)),
                        const SizedBox(height: 14),
                        Row(children: [
                          _chip('MP4', Icons.videocam_rounded),
                          const SizedBox(width: 6),
                          _chip('MP3', Icons.music_note_rounded),
                          const SizedBox(width: 6),
                          _chip('4K', Icons.high_quality_rounded),
                          const SizedBox(width: 6),
                          _chip('60FPS', Icons.speed_rounded),
                        ]),
                      ]),
                    ),
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), borderRadius: BorderRadius.circular(20), border: Border.all(color: Colors.white.withOpacity(0.2))),
                      child: const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 48),
                    ),
                  ]),
                ),
              ),
              const SizedBox(height: 18),
              // Input - neomorfik
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1F1F23) : Colors.white,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _linkCtrl.text.isNotEmpty && YoutubeService.isValidYoutubeUrl(_linkCtrl.text) ? cs.primary.withOpacity(0.5) : Colors.transparent, width: 1.2),
                  boxShadow: [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.2 : 0.05), blurRadius: 16, offset: const Offset(0, 4))],
                ),
                child: TextField(
                  controller: _linkCtrl,
                  decoration: InputDecoration(
                    hintText: 'https://www.youtube.com/watch?v=...',
                    hintStyle: TextStyle(color: Colors.grey.withOpacity(0.8), fontSize: 14),
                    prefixIcon: Icon(Icons.link_rounded, color: cs.primary),
                    suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (_linkCtrl.text.isNotEmpty)
                        IconButton(icon: const Icon(Icons.clear_rounded, size: 20), onPressed: _clear, tooltip: 'Temizle'),
                      IconButton(icon: const Icon(Icons.content_paste_rounded), onPressed: _paste, tooltip: 'Yapıştır'),
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilledButton.icon(
                          onPressed: _loading ? null : _fetch,
                          icon: _loading
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.bolt_rounded, size: 18),
                          label: Text(_loading ? '...' : 'Getir'),
                          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
                        ),
                      ),
                    ]),
                    filled: false,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) => _fetch(),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              const SizedBox(height: 10),
              // Hız notu
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(14)),
                child: Row(children: [
                  Container(padding: const EdgeInsets.all(6), decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(8)), child: const Icon(Icons.flash_on_rounded, size: 14, color: Colors.white)),
                  const SizedBox(width: 8),
                  Expanded(child: Text('Anında çözümleme · önbellekli · shorts/live/music destekli', style: TextStyle(fontSize: 12, color: cs.onSecondaryContainer, fontWeight: FontWeight.w600))),
                  Icon(Icons.verified_rounded, size: 16, color: cs.primary),
                ]),
              ),
              const SizedBox(height: 16),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: _error != null
                    ? Container(
                        key: ValueKey(_error),
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(16), border: Border.all(color: cs.error.withOpacity(0.15))),
                        child: Row(children: [
                          Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: cs.error, borderRadius: BorderRadius.circular(10)), child: Icon(Icons.error_outline_rounded, color: cs.onError, size: 18)),
                          const SizedBox(width: 10),
                          Expanded(child: Text(_error!, style: TextStyle(color: cs.onErrorContainer, fontWeight: FontWeight.w600))),
                          TextButton(onPressed: _fetch, child: const Text('Tekrar dene')),
                        ]),
                      )
                    : const SizedBox.shrink(),
              ),
              if (_loading) ...[
                const SizedBox(height: 16),
                _shimmerCard(isDark),
              ],
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 400),
                child: _video != null
                    ? Column(key: ValueKey(_video!.id), crossAxisAlignment: CrossAxisAlignment.start, children: [
                        const SizedBox(height: 8),
                        _videoCard(context),
                        const SizedBox(height: 18),
                        Row(children: [
                          Text('İndirme Seçenekleri', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800, letterSpacing: -0.3)),
                          const Spacer(),
                          Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: Colors.green.withOpacity(0.12), borderRadius: BorderRadius.circular(99)), child: Row(children: [Container(width: 8, height: 8, decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle)), const SizedBox(width: 6), Text('${_video!.streams.length} seçenek', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.green))])),
                        ]),
                        const SizedBox(height: 6),
                        Text('Paralel çözümleme · önbellekli · en iyi kalite önce', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.grey)),
                        const SizedBox(height: 12),
                        ..._video!.streams.asMap().entries.map((e) => _streamTile(e.value, e.key, cs)),
                        const SizedBox(height: 16),
                        if (_downloading)
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(color: cs.primaryContainer.withOpacity(0.5), borderRadius: BorderRadius.circular(16)),
                            child: Column(children: [
                              Row(children: [Icon(Icons.download_rounded, color: cs.primary, size: 18), const SizedBox(width: 8), Text('İndiriliyor', style: TextStyle(fontWeight: FontWeight.w700, color: cs.onPrimaryContainer)), const Spacer(), Text('%${(_progress * 100).toStringAsFixed(0)}', style: TextStyle(fontWeight: FontWeight.w800, color: cs.primary))]),
                              const SizedBox(height: 10),
                              ClipRRect(borderRadius: BorderRadius.circular(99), child: LinearProgressIndicator(value: _progress, minHeight: 8, backgroundColor: cs.primary.withOpacity(0.15))),
                            ]),
                          ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton.icon(
                            onPressed: _downloading ? null : _download,
                            icon: AnimatedSwitcher(duration: const Duration(milliseconds: 200), child: Icon(_savedPath != null ? Icons.check_circle_rounded : Icons.download_rounded, key: ValueKey(_savedPath))),
                            label: Text(_savedPath != null ? 'Tekrar İndir' : 'Seçili Kaliteyi İndir', style: const TextStyle(fontWeight: FontWeight.w800)),
                            style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 18)),
                          ),
                        ),
                        if (_savedPath != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 10),
                            child: SizedBox(
                              width: double.infinity,
                              child: OutlinedButton.icon(
                                onPressed: () => OpenFilex.open(_savedPath!),
                                icon: const Icon(Icons.play_arrow_rounded),
                                label: Text('Aç: ${_savedPath!.split('/').last}', overflow: TextOverflow.ellipsis),
                                style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                              ),
                            ),
                          ),
                      ])
                    : const SizedBox.shrink(),
              ),
              if (!_loading && _video == null && _error == null) ...[
                const SizedBox(height: 22),
                _emptyState(context),
              ],
            ]),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Text('İndir Gitsin • /Download/IndirGitsin • önbellek ${_video != null ? 'aktif' : 'hazır'} • v1.0.1',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.grey)),
        ),
      ),
    );
  }

  Widget _chip(String t, IconData i) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.16), borderRadius: BorderRadius.circular(99), border: Border.all(color: Colors.white.withOpacity(0.12))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, size: 12, color: Colors.white),
          const SizedBox(width: 4),
          Text(t, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.2)),
        ]),
      );

  Widget _videoCard(BuildContext context) {
    final v = _video!;
    final dur = v.duration != null ? _fmtDur(v.duration!) : '';
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 20, offset: const Offset(0, 8))],
      ),
      child: Card(
        margin: EdgeInsets.zero,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Stack(children: [
            ClipRRect(
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              child: CachedNetworkImage(imageUrl: v.thumbnailUrl, height: 210, width: double.infinity, fit: BoxFit.cover, placeholder: (_, __) => Container(height: 210, color: Colors.grey[200]), errorWidget: (_, __, ___) => Container(height: 210, color: Colors.grey[300], child: const Icon(Icons.broken_image_rounded))),
            ),
            Positioned(
              bottom: 10, right: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: Colors.black.withOpacity(0.82), borderRadius: BorderRadius.circular(10), border: Border.all(color: Colors.white.withOpacity(0.15))),
                child: Text(dur, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
              ),
            ),
            Positioned(
              top: 10, left: 10,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(99)),
                child: const Text('YOUTUBE', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.5)),
              ),
            ),
          ]),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(v.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15, height: 1.25), maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 10),
              Row(children: [
                Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(10)), child: Icon(Icons.person_rounded, size: 16, color: Theme.of(context).colorScheme.primary)),
                const SizedBox(width: 8),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(v.author, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.grey[800])), if (v.viewCount != null) Text(_fmtViews(v.viewCount!), style: const TextStyle(fontSize: 11, color: Colors.grey))])),
                Container(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), decoration: BoxDecoration(color: Colors.grey.withOpacity(0.1), borderRadius: BorderRadius.circular(99)), child: Text(dur.isEmpty ? '—' : dur, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700))),
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _streamTile(StreamOption s, int idx, ColorScheme cs) {
    final selected = _selected?.tag == s.tag && _selected?.type == s.type;
    IconData icon; Color col; String badge;
    if (s.type == 'muxed') { icon = Icons.hd_rounded; col = cs.primary; badge = 'Video+Ses'; }
    else if (s.type == 'videoOnly') { icon = Icons.videocam_outlined; col = Colors.orange; badge = 'Sadece Video'; }
    else { icon = Icons.music_note_rounded; col = Colors.green; badge = 'Sadece Ses'; }
    return AnimatedContainer(
      duration: Duration(milliseconds: 200 + idx * 30),
      curve: Curves.easeOutCubic,
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border.all(color: selected ? cs.primary : Colors.grey.withOpacity(0.14), width: selected ? 1.6 : 1),
        borderRadius: BorderRadius.circular(18),
        color: selected ? cs.primaryContainer.withOpacity(0.55) : Theme.of(context).cardColor,
        boxShadow: selected ? [BoxShadow(color: cs.primary.withOpacity(0.12), blurRadius: 12, offset: const Offset(0, 4))] : [],
      ),
      child: InkWell(
        onTap: () => setState(() => _selected = s),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: col.withOpacity(selected ? 0.16 : 0.10), borderRadius: BorderRadius.circular(14)),
              child: Icon(icon, color: col, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.qualityLabel, style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14, color: selected ? cs.onPrimaryContainer : null)),
              const SizedBox(height: 4),
              Row(children: [
                Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(99)), child: Text(badge, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800))),
                const SizedBox(width: 6),
                Text('${s.container.toUpperCase()} • ${s.sizeLabel}', style: TextStyle(fontSize: 12, color: Colors.grey[600], fontWeight: FontWeight.w600)),
              ]),
            ])),
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 26, height: 26,
              decoration: BoxDecoration(shape: BoxShape.circle, color: selected ? cs.primary : Colors.transparent, border: Border.all(color: selected ? cs.primary : Colors.grey.withOpacity(0.4), width: 1.6)),
              child: selected ? const Icon(Icons.check_rounded, size: 16, color: Colors.white) : null,
            ),
          ]),
        ),
      ),
    );
  }

  Widget _shimmerCard(bool isDark) => Shimmer.fromColors(
        baseColor: isDark ? const Color(0xFF1A1A1E) : Colors.grey[200]!,
        highlightColor: isDark ? const Color(0xFF2A2A30) : Colors.grey[100]!,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              Container(height: 14, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8))),
              const SizedBox(height: 10),
              Container(height: 14, width: 180, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8))),
              const SizedBox(height: 16),
              Row(children: [Expanded(child: Container(height: 44, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)))), const SizedBox(width: 10), Expanded(child: Container(height: 44, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12))))]),
            ]),
          ),
        ),
      );

  Widget _emptyState(BuildContext context) => Column(children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary.withOpacity(0.08), shape: BoxShape.circle),
          child: Icon(Icons.download_for_offline_rounded, size: 56, color: Theme.of(context).colorScheme.primary.withOpacity(0.9)),
        ),
        const SizedBox(height: 14),
        Text('Hazır!', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        Text('YouTube / Music linkini yapıştır,\nveya YouTube\'dan Paylaş → İndir Gitsin', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[600], fontSize: 13, height: 1.4)),
        const SizedBox(height: 18),
        Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
          ActionChip(label: const Text('Demo YouTube'), avatar: const Icon(Icons.play_arrow_rounded, size: 18), onPressed: () { _linkCtrl.text = 'https://www.youtube.com/watch?v=jNQXAC9IVRw'; _fetch(); }),
          ActionChip(label: const Text('Demo Music'), avatar: const Icon(Icons.music_note_rounded, size: 18), onPressed: () { _linkCtrl.text = 'https://music.youtube.com/watch?v=jNQXAC9IVRw'; _fetch(); }),
          ActionChip(label: const Text('Shorts'), avatar: const Icon(Icons.movie_rounded, size: 18), onPressed: () { _linkCtrl.text = 'https://www.youtube.com/shorts/jNQXAC9IVRw'; _fetch(); }),
        ]),
      ]);

  void _showHistory() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('İndirme Geçmişi', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 12),
          if (_savedPath == null) const Padding(padding: EdgeInsets.all(24), child: Text('Henüz indirme yok', style: TextStyle(color: Colors.grey)))
          else ListTile(leading: const Icon(Icons.video_file_rounded), title: Text(_savedPath!.split('/').last), subtitle: Text(_savedPath!), trailing: IconButton(icon: const Icon(Icons.open_in_new_rounded), onPressed: () => OpenFilex.open(_savedPath!))),
        ]),
      ),
    );
  }

  String _fmtDur(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  String _fmtViews(int v) {
    if (v >= 1000000) return '${(v / 1000000).toStringAsFixed(1)}M';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(1)}B';
    return '$v';
  }
}
