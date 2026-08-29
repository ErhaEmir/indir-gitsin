import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shimmer/shimmer.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'core/theme.dart';
import 'core/youtube_service.dart';
import 'core/download_service.dart';
import 'core/app_update_service.dart';
import 'core/storage_service.dart';
import 'features/player/player_page.dart';

final youtubeServiceProvider = Provider((ref) => YoutubeService());
final downloadServiceProvider = Provider((ref) => DownloadService());
final themeModeProvider = StateProvider<String>((ref) => 'system');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  await StorageService.init();
  final prefs = await SharedPreferences.getInstance();
  final savedTheme = prefs.getString('theme_mode') ?? 'system';
  final savedLang = prefs.getString('lang');
  Locale startLocale;
  if (savedLang != null) {
    startLocale = Locale(savedLang);
  } else {
    final sys = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    startLocale = sys == 'tr' ? const Locale('tr') : const Locale('en');
  }
  runApp(
    ProviderScope(
      overrides: [themeModeProvider.overrideWith((ref) => savedTheme)],
      child: EasyLocalization(
        supportedLocales: const [Locale('tr'), Locale('en')],
        path: 'assets/translations',
        fallbackLocale: const Locale('en'),
        startLocale: startLocale,
        saveLocale: true,
        child: const IndirGitsinApp(),
      ),
    ),
  );
}

class IndirGitsinApp extends ConsumerWidget {
  const IndirGitsinApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final modeStr = ref.watch(themeModeProvider);
    ThemeMode mode;
    switch (modeStr) {
      case 'light': mode = ThemeMode.light; break;
      case 'dark': mode = ThemeMode.dark; break;
      case 'amoled': mode = ThemeMode.dark; break;
      default: mode = ThemeMode.system;
    }
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        // Material You: sistem renklerini kullan, AMOLED ise siyahı zorla
        final isAmoled = modeStr == 'amoled';
        ThemeData light = AppTheme.light;
        ThemeData dark = AppTheme.dark;
        if (lightDynamic != null) {
          light = ThemeData.from(colorScheme: lightDynamic, useMaterial3: true).copyWith(textTheme: AppTheme.light.textTheme);
        }
        if (darkDynamic != null) {
          ColorScheme ds = darkDynamic;
          if (isAmoled) ds = ds.copyWith(background: Colors.black, surface: Colors.black);
          dark = ThemeData.from(colorScheme: ds, useMaterial3: true).copyWith(
            scaffoldBackgroundColor: isAmoled ? Colors.black : AppTheme.dark.scaffoldBackgroundColor,
            textTheme: AppTheme.dark.textTheme,
            cardTheme: AppTheme.dark.cardTheme.copyWith(color: isAmoled ? const Color(0xFF111111) : AppTheme.cardDark),
          );
        } else if (isAmoled) {
          dark = dark.copyWith(scaffoldBackgroundColor: Colors.black, cardTheme: dark.cardTheme.copyWith(color: const Color(0xFF111111)));
        }
        return MaterialApp(
          title: 'İndir Gitsin',
          debugShowCheckedModeBanner: false,
          theme: light,
          darkTheme: dark,
          themeMode: mode,
          localizationsDelegates: context.localizationDelegates,
          supportedLocales: context.supportedLocales,
          locale: context.locale,
          home: const MainScaffold(),
        );
      },
    );
  }
}

class MainScaffold extends ConsumerStatefulWidget {
  const MainScaffold({super.key});
  @override
  ConsumerState<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends ConsumerState<MainScaffold> {
  int _idx = 0;
  @override
  void initState() {
    super.initState();
    // Her açılışta otomatik kontrol (açık ise)
    AppUpdateService().checkAndUpdateSilently();
    // 6 saatte bir kontrol
    Timer.periodic(const Duration(hours: 6), (_) => AppUpdateService().checkAndUpdateSilently());
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      const HomeTab(),
      const FilesTab(),
      const FavoritesTab(),
      const SettingsTab(),
    ];
    return Scaffold(
      body: IndexedStack(index: _idx, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _idx,
        onDestinationSelected: (i) => setState(() => _idx = i),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.home_rounded), label: 'home'.tr()),
          NavigationDestination(icon: const Icon(Icons.folder_rounded), label: 'files'.tr()),
          NavigationDestination(icon: const Icon(Icons.favorite_rounded), label: 'favorites'.tr()),
          NavigationDestination(icon: const Icon(Icons.settings_rounded), label: 'settings'.tr()),
        ],
      ),
    );
  }
}

// HOME TAB - paylaşınca direkt hazırlama + hızlı çözümleme
class HomeTab extends ConsumerStatefulWidget {
  const HomeTab({super.key});
  @override
  ConsumerState<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends ConsumerState<HomeTab> with TickerProviderStateMixin {
  final _linkCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  VideoInfo? _video;
  List<VideoInfo> _playlist = [];
  List<VideoInfo> _searchResults = [];
  bool _loading = false;
  bool _searching = false;
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
    _heroCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
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
      _debounce = Timer(const Duration(milliseconds: 500), _fetch);
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
    // Direkt hazırlanma: paylaşınca otomatik çözümlenir
    ReceiveSharingIntent.instance.getInitialMedia().then((List<SharedMediaFile> media) {
      if (media.isNotEmpty) {
        final text = media.first.path;
        if (YoutubeService.isValidYoutubeUrl(text)) {
          _linkCtrl.text = text;
          // Direkt hazırla
          Future.delayed(const Duration(milliseconds: 300), _fetch);
        }
      }
    });
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> media) {
      if (media.isNotEmpty) {
        final text = media.first.path;
        if (YoutubeService.isValidYoutubeUrl(text)) {
          _linkCtrl.text = text;
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('share_preparing'.tr()), behavior: SnackBarBehavior.floating));
          }
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
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    ref.read(youtubeServiceProvider).close();
    super.dispose();
  }

  Future<void> _fetch() async {
    final url = _linkCtrl.text.trim();
    if (url.isEmpty) { setState(() => _error = 'please_paste'.tr()); return; }
    if (YoutubeService.isPlaylistUrl(url)) { await _fetchPlaylist(url); return; }
    if (!YoutubeService.isValidYoutubeUrl(url)) { setState(() => _error = 'invalid_link'.tr()); return; }
    StorageService.addSearch(url);
    HapticFeedback.lightImpact();
    setState(() { _loading = true; _error = null; _video = null; _selected = null; _savedPath = null; });
    try {
      final info = await ref.read(youtubeServiceProvider).getVideoInfo(url).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      setState(() { _video = info; _selected = info.streams.isNotEmpty ? info.streams.first : null; });
      HapticFeedback.selectionClick();
    } on TimeoutException {
      setState(() => _error = 'timeout'.tr());
    } catch (e) {
      setState(() => _error = '${'failed'.tr()}: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _search() async {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return;
    setState(() { _searching = true; _error = null; });
    try {
      final res = await ref.read(youtubeServiceProvider).search(q).timeout(const Duration(seconds: 10));
      setState(() { _searchResults = res; });
    } catch (e) { setState(() => _error = 'Arama hatası: $e'); }
    finally { setState(() => _searching = false); }
  }

  Future<void> _fetchPlaylist(String url) async {
    setState(() { _loading = true; _error = null; _playlist = []; });
    try {
      final list = await ref.read(youtubeServiceProvider).getPlaylistVideos(url).timeout(const Duration(seconds: 15));
      setState(() { _playlist = list; });
      if (list.isNotEmpty) { _linkCtrl.text = 'https://www.youtube.com/watch?v=${list.first.id}'; await _fetch(); }
    } catch (e) { setState(() => _error = 'Playlist alınamadı: $e'); }
    finally { setState(() => _loading = false); }
  }

  Future<void> _downloadAllPlaylist() async {
    for (final v in _playlist) {
      try {
        final svc = ref.read(downloadServiceProvider);
        final info = v;
        final stream = info.streams.firstWhere((s) => s.type=='muxed', orElse: ()=> info.streams.first);
        await svc.download(url: stream.url, fileName: info.title, ext: stream.type=='audioOnly'?'m4a':'mp4', videoId: info.id, streamTag: stream.tag, onProgress: (_, __){});
        StorageService.addHistory({'id': info.id, 'title': info.title, 'thumbnail': info.thumbnailUrl, 'url': 'https://www.youtube.com/watch?v=${info.id}', 'path': '', 'date': DateTime.now().toIso8601String()});
      } catch (_) {}
    }
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Playlist indirildi (${_playlist.length})'), behavior: SnackBarBehavior.floating));
  }

  void _applyProfile(String p) {
    if (_video == null) return;
    if (p == 'mp3') {
      final s = _video!.streams.where((e)=> e.type=='audioOnly').toList()..sort((a,b)=> (b.bitrate??0).compareTo(a.bitrate??0));
      if(s.isNotEmpty) setState(()=> _selected = s.first);
    } else if (p == 'best') {
      final s = _video!.streams.where((e)=> e.type=='muxed').toList()..sort((a,b)=> (b.height??0).compareTo(a.height??0));
      if(s.isNotEmpty) setState(()=> _selected = s.first);
    } else if (p == '4k') {
      final s = _video!.streams.where((e)=> e.height!=null && e.height!>=2160).toList();
      if(s.isNotEmpty) setState(()=> _selected = s.first);
    }
    HapticFeedback.selectionClick();
  }

  Future<void> _downloadSubtitle() async {
    if (_video==null) return;
    final caps = await ref.read(youtubeServiceProvider).getCaptionTracks(_video!.id);
    if (caps.isEmpty) { if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Altyazı bulunamadı'))); return;}
    // İlk altyazıyı indir (demo)
    if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Altyazı seçenekleri: ${caps.join(', ')}'), behavior: SnackBarBehavior.floating));
  }

  Future<void> _download() async {
    if (_video == null || _selected == null) return;
    HapticFeedback.mediumImpact();
    setState(() { _downloading = true; _progress = 0; _error = null; });
    try {
      final svc = ref.read(downloadServiceProvider);
      final ext = _selected!.container == 'mp4' ? 'mp4' : _selected!.container;
      final path = await svc.download(
        url: _selected!.url, fileName: _video!.title, ext: _selected!.type == 'audioOnly' ? 'm4a' : ext,
        videoId: _video!.id, streamTag: _selected!.tag,
        onProgress: (rx, total) { if (total > 0 && mounted) setState(() => _progress = rx / total); },
      );
      StorageService.addHistory({'id': _video!.id, 'title': _video!.title, 'thumbnail': _video!.thumbnailUrl, 'url': 'https://www.youtube.com/watch?v=${_video!.id}', 'path': path, 'date': DateTime.now().toIso8601String()});
      setState(() { _savedPath = path; _downloading = false; _progress = 1; });
      HapticFeedback.heavyImpact();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${'downloaded'.tr()}: ${path.split('/').last}'), action: SnackBarAction(label: 'open'.tr(), onPressed: () => OpenFilex.open(path)), behavior: SnackBarBehavior.floating));
    } catch (e) {
      setState(() { _downloading = false; _error = '${'error'.tr()}: $e'; });
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null) { _linkCtrl.text = data!.text!; _fetch(); }
  }

  void _clear() => setState(() { _linkCtrl.clear(); _video = null; _error = null; _savedPath = null; });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(gradient: LinearGradient(colors: [cs.primary, cs.primary.withOpacity(0.8)]), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 18)),
          const SizedBox(width: 8),
          Text('İndir Gitsin'.tr(), style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
      ),
      body: CustomScrollView(
        controller: _scrollCtrl,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
            sliver: SliverList.list(children: [
              ScaleTransition(
                scale: _heroAnim,
                child: Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [cs.primary, const Color(0xFF7B0000)]), borderRadius: BorderRadius.circular(28), boxShadow: [BoxShadow(color: cs.primary.withOpacity(0.25), blurRadius: 20, offset: const Offset(0, 8))]),
                  child: Row(children: [
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.white.withOpacity(0.18), borderRadius: BorderRadius.circular(99)), child: Text('new'.tr(), style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800))), const SizedBox(width: 8), Text('fast_smart'.tr(), style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 12))]),
                      const SizedBox(height: 8),
                      Text('subtitle'.tr(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18)),
                      const SizedBox(height: 4),
                      Text('hero_desc'.tr(), style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 12, height: 1.35)),
                      const SizedBox(height: 12),
                      Wrap(spacing: 6, runSpacing: 6, children: [_chip('MP4', Icons.videocam_rounded), _chip('MP3', Icons.music_note_rounded), _chip('4K', Icons.high_quality_rounded)]),
                    ])),
                    Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.white.withOpacity(0.14), borderRadius: BorderRadius.circular(20)), child: const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 44)),
                  ]),
                ),
              ),
              // Arama (in-app YouTube search)
              const SizedBox(height: 12),
              TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: 'YouTube\'de ara...',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: IconButton(icon: const Icon(Icons.send_rounded), onPressed: _search),
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                ),
                onSubmitted: (_) => _search(),
              ),
              if (_searching) const Padding(padding: EdgeInsets.only(top: 6), child: LinearProgressIndicator()),
              if (_searchResults.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text('Arama sonuçları', style: TextStyle(fontWeight: FontWeight.w800)),
                const SizedBox(height: 6),
                ..._searchResults.map((v) => Card(child: ListTile(leading: ClipRRect(borderRadius: BorderRadius.circular(8), child: CachedNetworkImage(imageUrl: v.thumbnailUrl, width: 80, height: 45, fit: BoxFit.cover)), title: Text(v.title, maxLines: 1, style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)), subtitle: Text(v.author, style: TextStyle(fontSize: 11)), onTap: () { _linkCtrl.text = 'https://www.youtube.com/watch?v=${v.id}'; setState(()=> _searchResults=[]); _fetch(); }))),
              ],
              if (_playlist.isNotEmpty) ...[
                const SizedBox(height: 12),
                Card(color: Theme.of(context).colorScheme.secondaryContainer, child: Padding(padding: const EdgeInsets.all(12), child: Column(children: [Row(children: [const Icon(Icons.playlist_play_rounded), const SizedBox(width: 8), Text('Playlist • ${_playlist.length} video', style: const TextStyle(fontWeight: FontWeight.w800)), const Spacer(), FilledButton.icon(onPressed: _downloadAllPlaylist, icon: const Icon(Icons.download_rounded), label: const Text('Tümünü indir'))]), const SizedBox(height: 8), SizedBox(height: 120, child: ListView.builder(scrollDirection: Axis.horizontal, itemCount: _playlist.length, itemBuilder: (_, i) { final v = _playlist[i]; return Container(width: 160, margin: const EdgeInsets.only(right: 8), child: Column(children: [ClipRRect(borderRadius: BorderRadius.circular(8), child: CachedNetworkImage(imageUrl: v.thumbnailUrl, height: 80, width: 160, fit: BoxFit.cover)), const SizedBox(height: 4), Text(v.title, maxLines: 2, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600))])); }))]))),
              ],
              const SizedBox(height: 18),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(color: isDark ? const Color(0xFF1F1F23) : Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: _linkCtrl.text.isNotEmpty && YoutubeService.isValidYoutubeUrl(_linkCtrl.text) ? cs.primary.withOpacity(0.5) : Colors.transparent, width: 1.2), boxShadow: [BoxShadow(color: Colors.black.withOpacity(isDark ? 0.15 : 0.05), blurRadius: 16, offset: const Offset(0, 4))]),
                child: TextField(
                  controller: _linkCtrl,
                  decoration: InputDecoration(
                    hintText: 'hint_link'.tr(),
                    prefixIcon: Icon(Icons.link_rounded, color: cs.primary),
                    suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (_linkCtrl.text.isNotEmpty) IconButton(icon: const Icon(Icons.clear_rounded, size: 20), onPressed: _clear),
                      IconButton(icon: const Icon(Icons.content_paste_rounded), onPressed: _paste),
                      Padding(padding: const EdgeInsets.only(right: 8), child: FilledButton.icon(onPressed: _loading ? null : _fetch, icon: _loading ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Icon(Icons.bolt_rounded, size: 18), label: Text('fetch'.tr()))),
                    ]),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(20), borderSide: BorderSide.none),
                  ),
                  onSubmitted: (_) => _fetch(),
                  onChanged: (_) => setState(() {}),
                ),
              ),
              if (StorageService.getSearchHistory().isNotEmpty) ...[
                const SizedBox(height: 10),
                SizedBox(height: 32, child: ListView.separated(scrollDirection: Axis.horizontal, itemCount: StorageService.getSearchHistory().take(5).length, separatorBuilder: (_, __) => const SizedBox(width: 8), itemBuilder: (c, i) {
                  final u = StorageService.getSearchHistory()[i];
                  final id = YoutubeService.extractVideoId(u) ?? u;
                  return ActionChip(label: Text(id, style: const TextStyle(fontSize: 12)), avatar: const Icon(Icons.history_rounded, size: 16), onPressed: () { _linkCtrl.text = u; _fetch(); });
                })),
              ],
              const SizedBox(height: 10),
              if (_error != null)
                Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(16)), child: Row(children: [Icon(Icons.error_outline_rounded, color: cs.onErrorContainer), const SizedBox(width: 8), Expanded(child: Text(_error!, style: TextStyle(color: cs.onErrorContainer))), TextButton(onPressed: _fetch, child: Text('retry'.tr()))])),
              if (_loading) ...[const SizedBox(height: 16), _shimmer(isDark)],
              if (_video != null) ...[
                const SizedBox(height: 16),
                _videoCard(context),
                const SizedBox(height: 12),
                Row(children: [IconButton(icon: Icon(StorageService.isFav(_video!.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: Colors.red), onPressed: () { StorageService.toggleFav(_video!.id, {'id': _video!.id, 'title': _video!.title, 'thumbnail': _video!.thumbnailUrl}); setState(() {}); }), Text('add_favorite'.tr()), const Spacer(), Text('options_count'.tr(namedArgs: {'count': '${_video!.streams.length}'}), style: const TextStyle(color: Colors.grey))]),
                const SizedBox(height: 8),
                // Hızlı profiller
                Wrap(spacing: 8, runSpacing: 6, children: [
                  ActionChip(label: Text('En iyi MP4'), avatar: const Icon(Icons.hd_rounded, size:16), onPressed: ()=> _applyProfile('best')),
                  ActionChip(label: const Text('MP3 256k'), avatar: const Icon(Icons.music_note_rounded, size:16), onPressed: ()=> _applyProfile('mp3')),
                  ActionChip(label: const Text('4K'), avatar: const Icon(Icons.high_quality_rounded, size:16), onPressed: ()=> _applyProfile('4k')),
                  ActionChip(label: Text('Altyazı'), avatar: const Icon(Icons.subtitles_rounded, size:16), onPressed: _downloadSubtitle),
                ]),
                const SizedBox(height: 8),
                ..._video!.streams.asMap().entries.map((e) => _tile(e.value, e.key, cs)),
                const SizedBox(height: 12),
                if (_downloading) LinearProgressIndicator(value: _progress, borderRadius: BorderRadius.circular(99), minHeight: 8),
                const SizedBox(height: 10),
                SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _downloading ? null : _download, icon: Icon(_savedPath != null ? Icons.check_circle_rounded : Icons.download_rounded), label: Text(_savedPath != null ? 'download_again'.tr() : 'download'.tr()))),
                if (_savedPath != null) Padding(padding: const EdgeInsets.only(top: 8), child: SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerPage(path: _savedPath!, title: _video!.title))), icon: const Icon(Icons.play_arrow_rounded), label: Text('play'.tr())))),
              ],
              if (!_loading && _video == null && _error == null) ...[const SizedBox(height: 20), _empty(context)],
            ]),
          ),
        ],
      ),
    );
  }

  Widget _chip(String t, IconData i) => Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), decoration: BoxDecoration(color: Colors.white.withOpacity(0.14), borderRadius: BorderRadius.circular(99)), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(i, size: 12, color: Colors.white), const SizedBox(width: 4), Text(t, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800))]));
  Widget _videoCard(BuildContext c) {
    final v = _video!; final dur = v.duration != null ? '${v.duration!.inMinutes}:${(v.duration!.inSeconds%60).toString().padLeft(2,'0')}' : '';
    return Card(child: Column(children: [Stack(children: [ClipRRect(borderRadius: const BorderRadius.vertical(top: Radius.circular(24)), child: CachedNetworkImage(imageUrl: v.thumbnailUrl, height: 200, width: double.infinity, fit: BoxFit.cover)), Positioned(bottom: 8, right: 8, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)), child: Text(dur, style: const TextStyle(color: Colors.white, fontSize: 12))))]), Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(v.title, style: const TextStyle(fontWeight: FontWeight.w800), maxLines: 2), const SizedBox(height: 6), Text(v.author, style: TextStyle(color: Colors.grey[600], fontSize: 13))]))]));
  }
  Widget _tile(StreamOption s, int idx, ColorScheme cs) {
    final sel = _selected?.tag == s.tag && _selected?.type == s.type;
    Color col; String badge;
    if (s.type == 'muxed') { col = cs.primary; badge = 'Video+Ses'; } else if (s.type == 'videoOnly') { col = Colors.orange; badge = 'Sadece Video'; } else { col = Colors.green; badge = 'Sadece Ses'; }
    return AnimatedContainer(duration: Duration(milliseconds: 200+idx*20), margin: const EdgeInsets.only(bottom: 8), decoration: BoxDecoration(border: Border.all(color: sel ? cs.primary : Colors.grey.withOpacity(0.2)), borderRadius: BorderRadius.circular(16), color: sel ? cs.primaryContainer.withOpacity(0.5) : Theme.of(context).cardColor), child: RadioListTile(value: s, groupValue: _selected, onChanged: (v)=>setState(()=>_selected=v), title: Text(s.qualityLabel, style: const TextStyle(fontWeight: FontWeight.w700)), subtitle: Text('${s.container.toUpperCase()} • ${s.sizeLabel} • $badge'), activeColor: col));
  }
  Widget _shimmer(bool d) => Shimmer.fromColors(baseColor: d? const Color(0xFF1A1A1E): Colors.grey[200]!, highlightColor: d? const Color(0xFF2A2A30): Colors.grey[100]!, child: Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [Container(height: 14, color: Colors.white), const SizedBox(height: 8), Container(height: 14, width: 180, color: Colors.white)]))));
  Widget _empty(BuildContext c) => Column(children: [Icon(Icons.download_for_offline_rounded, size: 64, color: Theme.of(c).colorScheme.primary.withOpacity(0.3)), const SizedBox(height: 10), Text('ready'.tr(), style: const TextStyle(fontWeight: FontWeight.w800)), Text('empty_hint'.tr(), textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[600])), const SizedBox(height: 12), Wrap(spacing: 8, children: [ActionChip(label: Text('Demo'), onPressed: (){ _linkCtrl.text='https://www.youtube.com/watch?v=jNQXAC9IVRw'; _fetch();}), ActionChip(label: Text('Music'), onPressed: (){ _linkCtrl.text='https://music.youtube.com/watch?v=jNQXAC9IVRw'; _fetch();})])]);
}

// FILES TAB - dosya yönetimi + depolama seçici
class FilesTab extends StatefulWidget { const FilesTab({super.key}); @override State<FilesTab> createState()=> _FilesTabState();}
class _FilesTabState extends State<FilesTab> {
  List<FileSystemEntity> _files = [];
  String _sort = 'date'; // date / size / name
  @override void initState(){ super.initState(); _load(); }
  Future<Directory> _getDir() async {
    final prefs = await SharedPreferences.getInstance();
    final custom = prefs.getString('custom_download_path');
    if (custom != null && custom.isNotEmpty) return Directory(custom);
    return Directory('/storage/emulated/0/Download/IndirGitsin');
  }
  Future<void> _load() async {
    try {
      final dir = await _getDir();
      if (await dir.exists()) { 
        final f = await dir.list().toList(); 
        f.sort((a,b){
          if (_sort=='name') return a.path.compareTo(b.path);
          if (_sort=='size') return (b as File).lengthSync().compareTo((a as File).lengthSync());
          return b.statSync().modified.compareTo(a.statSync().modified);
        });
        setState(()=>_files=f); 
      } else { setState(()=>_files=[]); }
    } catch(_){}
  }
  Future<void> _rename(File f) async {
    final ctrl = TextEditingController(text: f.path.split('/').last);
    final ok = await showDialog<bool>(context: context, builder: (c)=> AlertDialog(title: Text('Yeniden adlandır'), content: TextField(controller: ctrl), actions: [TextButton(onPressed: ()=> Navigator.pop(c,false), child: const Text('İptal')), FilledButton(onPressed: ()=> Navigator.pop(c,true), child: const Text('Kaydet'))]));
    if (ok==true && ctrl.text.isNotEmpty) { final dir = (await _getDir()).path; await f.rename('$dir/${ctrl.text}'); _load(); }
  }
  Future<void> _delete(File f) async {
    final ok = await showDialog<bool>(context: context, builder: (c)=> AlertDialog(title: const Text('Silinsin mi?'), content: Text(f.path.split('/').last), actions: [TextButton(onPressed: ()=> Navigator.pop(c,false), child: const Text('İptal')), FilledButton(onPressed: ()=> Navigator.pop(c,true), child: const Text('Sil'))]));
    if (ok==true) { await f.delete(); _load(); }
  }
  Future<void> _pickStorage() async {
    final ctrl = TextEditingController(text: (await _getDir()).path);
    final ok = await showDialog<bool>(context: context, builder: (c)=> AlertDialog(title: const Text('Depolama Yeri'), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: ctrl, decoration: const InputDecoration(hintText: '/storage/emulated/0/Download/IndirGitsin')), const SizedBox(height:8), const Text('SD kart yolu girebilirsin', style: TextStyle(fontSize:11, color: Colors.grey))]), actions: [TextButton(onPressed: ()=> Navigator.pop(c,false), child: const Text('İptal')), FilledButton(onPressed: ()=> Navigator.pop(c,true), child: const Text('Kaydet'))]));
    if (ok==true) { final p=await SharedPreferences.getInstance(); await p.setString('custom_download_path', ctrl.text.trim()); _load(); }
  }
  @override Widget build(BuildContext context){
    return Scaffold(
      appBar: AppBar(title: Text('files'.tr()), actions: [
        PopupMenuButton<String>(onSelected: (v){ if(v=='storage') _pickStorage(); else { setState(()=> _sort=v); _load(); }}, itemBuilder: (_)=> [
          const PopupMenuItem(value:'date', child: Text('Tarihe göre')),
          const PopupMenuItem(value:'size', child: Text('Boyuta göre')),
          const PopupMenuItem(value:'name', child: Text('İsme göre')),
          const PopupMenuDivider(),
          const PopupMenuItem(value:'storage', child: Row(children: [Icon(Icons.folder_open_rounded, size:16), SizedBox(width:8), Text('Depolama yeri seç')])),
        ]),
      ]),
      body: _files.isEmpty ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.folder_rounded, size:48, color: Colors.grey[400]), const SizedBox(height:8), Text('no_downloads'.tr()), TextButton(onPressed: _load, child: const Text('Yenile'))])) : RefreshIndicator(onRefresh: _load, child: ListView.separated(itemCount: _files.length, separatorBuilder: (_,__)=> const Divider(height:1), itemBuilder: (c,i){
        final f = _files[i] as File; final name = f.path.split('/').last; final isVideo = name.endsWith('.mp4') || name.endsWith('.mkv');
        return ListTile(
          leading: Icon(isVideo? Icons.videocam_rounded: Icons.music_note_rounded, color: Theme.of(context).colorScheme.primary),
          title: Text(name, maxLines:1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${(f.lengthSync()/1024/1024).toStringAsFixed(1)} MB • ${f.statSync().modified.toString().substring(0,16)}'),
          trailing: PopupMenuButton<String>(onSelected: (v) async {
            if(v=='play'){ if(isVideo) Navigator.push(context, MaterialPageRoute(builder: (_)=> PlayerPage(path: f.path, title: name))); else OpenFilex.open(f.path); }
            else if(v=='share'){ await Share.shareXFiles([XFile(f.path)]); }
            else if(v=='rename') await _rename(f);
            else if(v=='delete') await _delete(f);
          }, itemBuilder: (_)=> [const PopupMenuItem(value:'play', child: Text('Oynat/Aç')), const PopupMenuItem(value:'share', child: Text('Paylaş')), const PopupMenuItem(value:'rename', child: Text('Yeniden adlandır')), const PopupMenuItem(value:'delete', child: Text('Sil'))]),
          onTap: ()=> isVideo ? Navigator.push(context, MaterialPageRoute(builder: (_)=> PlayerPage(path: f.path, title: name))) : OpenFilex.open(f.path),
          onLongPress: ()=> showModalBottomSheet(context: context, builder: (_)=> Wrap(children: [ListTile(leading: const Icon(Icons.edit_rounded), title: const Text('Yeniden adlandır'), onTap: (){ Navigator.pop(context); _rename(f);}), ListTile(leading: const Icon(Icons.share_rounded), title: const Text('Paylaş'), onTap: ()async{ Navigator.pop(context); await Share.shareXFiles([XFile(f.path)]);}), ListTile(leading: const Icon(Icons.delete_rounded, color: Colors.red), title: const Text('Sil', style: TextStyle(color: Colors.red)), onTap: (){ Navigator.pop(context); _delete(f);})])),
        );
      })),
    );
  }
}

// FAVORITES + HISTORY
class FavoritesTab extends StatelessWidget { const FavoritesTab({super.key}); @override Widget build(BuildContext c){
  final fav = StorageService.fav.values.toList().cast<Map>();
  final hist = StorageService.history.values.toList().cast<Map>().reversed.toList();
  return DefaultTabController(length: 2, child: Scaffold(appBar: AppBar(title: Text('favorites'.tr()), bottom: TabBar(tabs: [Tab(text: 'favorites'.tr()), Tab(text: 'history'.tr())])), body: TabBarView(children: [
    fav.isEmpty? Center(child: Text('no_downloads'.tr())): ListView.builder(itemCount: fav.length, itemBuilder: (_,i){ final m=fav[i]; return ListTile(leading: ClipRRect(borderRadius: BorderRadius.circular(8), child: CachedNetworkImage(imageUrl: m['thumbnail']??'', width:56, height:56, fit: BoxFit.cover)), title: Text(m['title']??'', maxLines:1), subtitle: Text(m['id']??''), trailing: IconButton(icon: const Icon(Icons.delete_rounded), onPressed: ()=> StorageService.fav.delete(m['id'])));}),
    hist.isEmpty? Center(child: Text('no_downloads'.tr())): ListView.builder(itemCount: hist.length, itemBuilder: (_,i){ final m=hist[i]; return ListTile(leading: ClipRRect(borderRadius: BorderRadius.circular(8), child: CachedNetworkImage(imageUrl: m['thumbnail']??'', width:56, height:56, fit: BoxFit.cover)), title: Text(m['title']??'', maxLines:1), subtitle: Text(m['path']?.toString().split('/').last ?? ''), trailing: IconButton(icon: const Icon(Icons.open_in_new_rounded), onPressed: ()=> OpenFilex.open(m['path'])));}),
  ])));
}}

// SETTINGS - portatif ve kullanıcı dostu
class SettingsTab extends ConsumerStatefulWidget { const SettingsTab({super.key}); @override ConsumerState<SettingsTab> createState()=> _SettingsTabState();}
class _SettingsTabState extends ConsumerState<SettingsTab> {
  bool _autoUpdate = true;
  bool _checking = false;
  String? _status;
  @override void initState(){ super.initState(); _load(); }
  Future<void> _load() async { final p=await SharedPreferences.getInstance(); setState(()=> _autoUpdate = p.getBool('auto_update_enabled') ?? true); }
  Future<void> _toggleAuto(bool v) async { setState(()=> _autoUpdate=v); final p=await SharedPreferences.getInstance(); await p.setBool('auto_update_enabled', v); }
  Future<void> _manualCheck() async {
    setState(()=> _checking=true);
    try {
      final res = await AppUpdateService().checkForUpdateManual();
      if(!mounted) return;
      if(res==null){ setState(()=> _status='Hata: kontrol edilemedi'); return; }
      final hasUpdate = res['hasUpdate'] as bool;
      final current = res['current'];
      final latest = res['latest'];
      if(!hasUpdate){
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Zaten güncelsin ($current)'.tr()), behavior: SnackBarBehavior.floating));
        setState(()=> _status='Güncelsin ($current)');
      } else {
        final ok = await showDialog<bool>(context: context, builder: (c)=> AlertDialog(
          title: Text('Güncelleme algılandı'.tr()),
          content: Text('Yeni sürüm $latest bulundu (mevcut $current). Yüklensin mi?'),
          actions: [TextButton(onPressed: ()=> Navigator.pop(c,false), child: Text('Vazgeç'.tr())), FilledButton(onPressed: ()=> Navigator.pop(c,true), child: Text('Yükle'.tr()))],
        ));
        if(ok==true){
          if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('İndiriliyor...'.tr()), behavior: SnackBarBehavior.floating));
          final tag = latest as String;
          await AppUpdateService().downloadAndInstall(tag, onProgress: (rx,total){});
          setState(()=> _status='İndirildi, kurulum başlatıldı');
        } else { setState(()=> _status='İptal edildi'); }
      }
    } catch(e){ setState(()=> _status='Hata: $e'); }
    finally { if(mounted) setState(()=> _checking=false); Future.delayed(const Duration(seconds: 4), ()=> setState(()=> _status=null));}
  }
  Future<void> _openUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }
  @override Widget build(BuildContext context){
    final mode = ref.watch(themeModeProvider);
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text('settings'.tr())),
      body: ListView(padding: const EdgeInsets.fromLTRB(16,12,16,24), children: [
        // Tema kartı
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: cs.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(12)), child: Icon(Icons.palette_rounded, color: cs.primary)), const SizedBox(width: 10), Text('theme'.tr(), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))]),
          const SizedBox(height: 12),
          Wrap(spacing: 8, runSpacing: 8, children: [
            ChoiceChip(label: Text('theme_system'.tr()), selected: mode=='system', onSelected: (_){ ref.read(themeModeProvider.notifier).state='system'; SharedPreferences.getInstance().then((p)=> p.setString('theme_mode','system'));}),
            ChoiceChip(label: Text('theme_light'.tr()), selected: mode=='light', onSelected: (_){ ref.read(themeModeProvider.notifier).state='light'; SharedPreferences.getInstance().then((p)=> p.setString('theme_mode','light'));}),
            ChoiceChip(label: Text('theme_dark'.tr()), selected: mode=='dark', onSelected: (_){ ref.read(themeModeProvider.notifier).state='dark'; SharedPreferences.getInstance().then((p)=> p.setString('theme_mode','dark'));}),
            ChoiceChip(label: Text('theme_amoled'.tr()), selected: mode=='amoled', avatar: const Icon(Icons.contrast_rounded, size:16), onSelected: (_){ ref.read(themeModeProvider.notifier).state='amoled'; SharedPreferences.getInstance().then((p)=> p.setString('theme_mode','amoled'));}),
          ]),
          const SizedBox(height: 8),
          Text('material_desc'.tr(), style: TextStyle(color: Colors.grey[600], fontSize: 12)),
        ]))),
        const SizedBox(height: 12),
        // Dil
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: cs.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(12)), child: Icon(Icons.language_rounded, color: cs.primary)), const SizedBox(width: 10), Text('language'.tr(), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))]),
          const SizedBox(height: 12),
          SegmentedButton<String>(segments: const [ButtonSegment(value:'tr', label: Text('Türkçe'), icon: Icon(Icons.flag_rounded)), ButtonSegment(value:'en', label: Text('English'), icon: Icon(Icons.flag_outlined))], selected: {context.locale.languageCode}, onSelectionChanged: (s){ final v=s.first; context.setLocale(Locale(v)); SharedPreferences.getInstance().then((p)=> p.setString('lang', v));}),
        ]))),
        const SizedBox(height: 12),
        // Güncelleme kartı
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.green.withOpacity(0.12), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.system_update_rounded, color: Colors.green)), const SizedBox(width: 10), Text('auto_update'.tr(), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))]),
          const SizedBox(height: 4),
          Text('auto_update_desc'.tr(), style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          const SizedBox(height: 12),
          SwitchListTile(value: _autoUpdate, title: Text(_autoUpdate ? 'auto_on'.tr() : 'auto_off'.tr()), subtitle: Text(_autoUpdate ? 'auto_on_desc'.tr() : 'auto_off_desc'.tr()), onChanged: _toggleAuto, contentPadding: EdgeInsets.zero),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _checking ? null : _manualCheck, icon: _checking ? const SizedBox(width:16,height:16, child: CircularProgressIndicator(strokeWidth:2, color:Colors.white)) : const Icon(Icons.refresh_rounded), label: Text('check_updates'.tr()))),
          if(_status!=null) Padding(padding: const EdgeInsets.only(top:8), child: Text(_status!, style: TextStyle(color: cs.primary, fontSize:12, fontWeight: FontWeight.w600))),
        ]))),
        const SizedBox(height: 12),
        // Hakkında - portatif kullanıcı dostu
        Card(
          color: cs.primaryContainer.withOpacity(0.4),
          child: Padding(padding: const EdgeInsets.all(18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(14)), child: const Icon(Icons.info_rounded, color: Colors.white)), const SizedBox(width: 12), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('about'.tr(), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)), Text('app_name'.tr(), style: TextStyle(color: Colors.grey[700], fontSize: 12))])]),
            const SizedBox(height: 14),
            Row(children: [CircleAvatar(radius: 28, backgroundColor: cs.primary, child: const Icon(Icons.person_rounded, color: Colors.white, size: 28)), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('developer_name'.tr(), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)), const SizedBox(height:2), Text('developer'.tr(), style: TextStyle(color: Colors.grey[600], fontSize: 12)), const SizedBox(height:6), InkWell(onTap: ()=> _openUrl('https://github.com/ErhaEmir'), child: Row(children: [Icon(Icons.link_rounded, size:14, color: cs.primary), const SizedBox(width:4), Text('github_dev_sub'.tr(), style: TextStyle(color: cs.primary, fontWeight: FontWeight.w700, fontSize:12))]))]))]),
            const SizedBox(height: 14),
            Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Theme.of(context).cardColor, borderRadius: BorderRadius.circular(14)), child: Column(children: [
              InkWell(onTap: ()=> _openUrl('https://github.com/ErhaEmir/indir-gitsin'), child: Row(children: [Icon(Icons.code_rounded, color: cs.primary), const SizedBox(width:8), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('github_repo'.tr(), style: const TextStyle(fontWeight: FontWeight.w700)), Text('github_repo_sub'.tr(), style: TextStyle(color: Colors.grey[600], fontSize:12))])), Icon(Icons.open_in_new_rounded, size:18, color: Colors.grey[600])])),
              const Divider(height:16),
              InkWell(onTap: ()=> _openUrl('https://github.com/ErhaEmir'), child: Row(children: [Icon(Icons.person_rounded, color: cs.primary), const SizedBox(width:8), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('github_dev'.tr(), style: const TextStyle(fontWeight: FontWeight.w700)), Text('github_dev_sub'.tr(), style: TextStyle(color: Colors.grey[600], fontSize:12))])), Icon(Icons.open_in_new_rounded, size:18, color: Colors.grey[600])])),
            ])),
            const SizedBox(height: 12),
            FutureBuilder<PackageInfo>(future: PackageInfo.fromPlatform(), builder: (c,s){ final v=s.data; return Text(v==null? 'Yükleniyor...': 'Sürüm ${v.version}+${v.buildNumber} • ${v.appName}', style: TextStyle(color: Colors.grey[600], fontSize:11), textAlign: TextAlign.center);}),
          ])),
        ),
      ]),
    );
  }
}
