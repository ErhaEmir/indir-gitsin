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
  final savedLang = prefs.getString('lang') ?? 'tr';
  runApp(
    ProviderScope(
      overrides: [themeModeProvider.overrideWith((ref) => savedTheme)],
      child: EasyLocalization(
        supportedLocales: const [Locale('tr'), Locale('en')],
        path: 'assets/translations',
        fallbackLocale: const Locale('tr'),
        startLocale: Locale(savedLang),
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
    // Otomatik güncelleme sessiz kontrol
    Future.delayed(const Duration(seconds: 3), () => AppUpdateService().checkAndUpdateSilently());
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
          NavigationDestination(icon: const Icon(Icons.home_rounded), label: 'Ana Sayfa'.tr()),
          NavigationDestination(icon: const Icon(Icons.folder_rounded), label: 'Dosyalarım'.tr()),
          NavigationDestination(icon: const Icon(Icons.favorite_rounded), label: 'Favoriler'.tr()),
          NavigationDestination(icon: const Icon(Icons.settings_rounded), label: 'Ayarlar'.tr()),
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
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Paylaşılan video hazırlanıyor...'.tr()), behavior: SnackBarBehavior.floating));
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
    _scrollCtrl.dispose();
    ref.read(youtubeServiceProvider).close();
    super.dispose();
  }

  Future<void> _fetch() async {
    final url = _linkCtrl.text.trim();
    if (url.isEmpty) { setState(() => _error = 'Lütfen link yapıştırın'.tr()); return; }
    if (!YoutubeService.isValidYoutubeUrl(url)) { setState(() => _error = 'Geçersiz link'.tr()); return; }
    StorageService.addSearch(url);
    HapticFeedback.lightImpact();
    setState(() { _loading = true; _error = null; _video = null; _selected = null; _savedPath = null; });
    try {
      final info = await ref.read(youtubeServiceProvider).getVideoInfo(url).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      setState(() { _video = info; _selected = info.streams.isNotEmpty ? info.streams.first : null; });
      HapticFeedback.selectionClick();
    } on TimeoutException {
      setState(() => _error = 'Zaman aşımı, tekrar dene'.tr());
    } catch (e) {
      setState(() => _error = 'Alınamadı: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('İndirildi: ${path.split('/').last}'), action: SnackBarAction(label: 'AÇ'.tr(), onPressed: () => OpenFilex.open(path)), behavior: SnackBarBehavior.floating));
    } catch (e) {
      setState(() { _downloading = false; _error = 'Hata: $e'; });
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
                      Row(children: [Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.white.withOpacity(0.18), borderRadius: BorderRadius.circular(99)), child: const Text('YENİ', style: TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800))), const SizedBox(width: 8), Text('⚡ Hızlı • Akıllı', style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 12))]),
                      const SizedBox(height: 8),
                      Text('YouTube & Music'.tr(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18)),
                      const SizedBox(height: 4),
                      Text('Yapıştır → anında hazır\nPaylaş → direkt indir', style: TextStyle(color: Colors.white.withOpacity(0.85), fontSize: 12, height: 1.35)),
                      const SizedBox(height: 12),
                      Wrap(spacing: 6, runSpacing: 6, children: [_chip('MP4', Icons.videocam_rounded), _chip('MP3', Icons.music_note_rounded), _chip('4K', Icons.high_quality_rounded)]),
                    ])),
                    Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.white.withOpacity(0.14), borderRadius: BorderRadius.circular(20)), child: const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 44)),
                  ]),
                ),
              ),
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
                Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(16)), child: Row(children: [Icon(Icons.error_outline_rounded, color: cs.onErrorContainer), const SizedBox(width: 8), Expanded(child: Text(_error!, style: TextStyle(color: cs.onErrorContainer))), TextButton(onPressed: _fetch, child: Text('Tekrar'.tr()))])),
              if (_loading) ...[const SizedBox(height: 16), _shimmer(isDark)],
              if (_video != null) ...[
                const SizedBox(height: 16),
                _videoCard(context),
                const SizedBox(height: 12),
                Row(children: [IconButton(icon: Icon(StorageService.isFav(_video!.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: Colors.red), onPressed: () { StorageService.toggleFav(_video!.id, {'id': _video!.id, 'title': _video!.title, 'thumbnail': _video!.thumbnailUrl}); setState(() {}); }), Text('Favoriye ekle'.tr()), const Spacer(), Text('${_video!.streams.length} seçenek'.tr(), style: const TextStyle(color: Colors.grey))]),
                const SizedBox(height: 8),
                ..._video!.streams.asMap().entries.map((e) => _tile(e.value, e.key, cs)),
                const SizedBox(height: 12),
                if (_downloading) LinearProgressIndicator(value: _progress, borderRadius: BorderRadius.circular(99), minHeight: 8),
                const SizedBox(height: 10),
                SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _downloading ? null : _download, icon: Icon(_savedPath != null ? Icons.check_circle_rounded : Icons.download_rounded), label: Text(_savedPath != null ? 'download_again'.tr() : 'download'.tr()))),
                if (_savedPath != null) Padding(padding: const EdgeInsets.only(top: 8), child: SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerPage(path: _savedPath!, title: _video!.title))), icon: const Icon(Icons.play_arrow_rounded), label: Text('Oynat'.tr())))),
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

// FILES TAB
class FilesTab extends StatefulWidget { const FilesTab({super.key}); @override State<FilesTab> createState()=> _FilesTabState();}
class _FilesTabState extends State<FilesTab> {
  List<FileSystemEntity> _files = [];
  @override void initState(){ super.initState(); _load(); }
  Future<void> _load() async {
    try {
      final dir = Directory('/storage/emulated/0/Download/IndirGitsin');
      if (await dir.exists()) { final f = await dir.list().toList(); setState(()=>_files=f..sort((a,b)=> b.statSync().modified.compareTo(a.statSync().modified))); }
    } catch(_){}
  }
  @override Widget build(BuildContext context){
    return Scaffold(appBar: AppBar(title: Text('files'.tr())), body: _files.isEmpty ? Center(child: Text('no_downloads'.tr())) : RefreshIndicator(onRefresh: _load, child: ListView.separated(itemCount: _files.length, separatorBuilder: (_,__)=> const Divider(height:1), itemBuilder: (c,i){
      final f = _files[i] as File; final name = f.path.split('/').last; final isVideo = name.endsWith('.mp4');
      return ListTile(leading: Icon(isVideo? Icons.videocam_rounded: Icons.music_note_rounded, color: Theme.of(context).colorScheme.primary), title: Text(name, maxLines:1, overflow: TextOverflow.ellipsis), subtitle: Text('${(f.lengthSync()/1024/1024).toStringAsFixed(1)} MB'), trailing: IconButton(icon: const Icon(Icons.play_arrow_rounded), onPressed: (){ final isVid = name.endsWith('.mp4')||name.endsWith('.mkv'); if(isVid) Navigator.push(context, MaterialPageRoute(builder: (_)=> PlayerPage(path: f.path, title: name))); else OpenFilex.open(f.path);}), onTap: ()=> OpenFilex.open(f.path));
    })));
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

// SETTINGS
class SettingsTab extends ConsumerWidget { const SettingsTab({super.key}); @override Widget build(BuildContext context, WidgetRef ref){
  final mode = ref.watch(themeModeProvider);
  return Scaffold(appBar: AppBar(title: Text('settings'.tr())), body: ListView(children: [
    ListTile(title: Text('theme'.tr()), subtitle: Text(mode), trailing: const Icon(Icons.palette_rounded)),
    RadioListTile(value: 'system', groupValue: mode, title: Text('theme_system'.tr()), onChanged: (v){ ref.read(themeModeProvider.notifier).state=v!; SharedPreferences.getInstance().then((p)=> p.setString('theme_mode', v));}),
    RadioListTile(value: 'light', groupValue: mode, title: Text('theme_light'.tr()), onChanged: (v){ ref.read(themeModeProvider.notifier).state=v!; SharedPreferences.getInstance().then((p)=> p.setString('theme_mode', v));}),
    RadioListTile(value: 'dark', groupValue: mode, title: Text('theme_dark'.tr()), onChanged: (v){ ref.read(themeModeProvider.notifier).state=v!; SharedPreferences.getInstance().then((p)=> p.setString('theme_mode', v));}),
    RadioListTile(value: 'amoled', groupValue: mode, title: Text('theme_amoled'.tr()), subtitle: const Text('Saf siyah'), onChanged: (v){ ref.read(themeModeProvider.notifier).state=v!; SharedPreferences.getInstance().then((p)=> p.setString('theme_mode', v));}),
    const Divider(),
    ListTile(title: Text('language'.tr()), trailing: DropdownButton<String>(value: context.locale.languageCode, items: const [DropdownMenuItem(value:'tr', child: Text('Türkçe')), DropdownMenuItem(value:'en', child: Text('English'))], onChanged: (v){ if(v!=null){ context.setLocale(Locale(v)); SharedPreferences.getInstance().then((p)=> p.setString('lang', v));}})),
    const Divider(),
    SwitchListTile(title: Text('auto_update'.tr()), subtitle: const Text('GitHub releases otomatik kontrol'), value: true, onChanged: (_){}),
    ListTile(title: const Text('GitHub Deposu'), subtitle: const Text('ErhaEmir/indir-gitsin'), trailing: const Icon(Icons.open_in_new_rounded), onTap: (){}),
    ListTile(title: Text('Sürüm'), subtitle: FutureBuilder(future: Future.value('v1.0.2'), builder: (_,s)=> Text(s.data ?? ''))),
  ]));
}}
