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
import 'package:permission_handler/permission_handler.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'core/theme.dart';
import 'core/youtube_service.dart';
import 'core/download_service.dart';
import 'core/app_update_service.dart';
import 'core/storage_service.dart';
import 'core/notification_service.dart';
import 'features/player/player_page.dart';
import 'features/player/network_player_page.dart';
import 'features/explore/explore_page.dart';

final youtubeServiceProvider = Provider((ref) => YoutubeService());
final downloadServiceProvider = Provider((ref) => DownloadService());
final themeModeProvider = StateProvider<String>((ref) => 'system');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  await StorageService.init();
  await NotificationService.init();
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
  final _filesKey = GlobalKey<FilesTabState>();
  final _homeKey = GlobalKey<HomeTabState>();
  @override
  void initState() {
    super.initState();
    _firstLaunchCheck();
    // Her açılışta güncelleme tara - varsa dialog ile sor
    Future.delayed(const Duration(seconds: 2), () async {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('auto_update_enabled') ?? true;
      if (!enabled) return;
      // Aralığa göre kontrol et
      final intervalHours = prefs.getInt('update_interval_hours') ?? 6;
      final last = prefs.getInt('last_update_check') ?? 0;
      final hoursPassed = (DateTime.now().millisecondsSinceEpoch - last) / (1000*3600);
      if (hoursPassed < intervalHours) return;
      final res = await AppUpdateService().checkForUpdateManual();
      if (res!=null && res['hasUpdate']==true && mounted) {
        final current = res['current'];
        final latest = res['latest'];
        showDialog(context: context, builder: (c)=> AlertDialog(
          title: Row(children: [Icon(Icons.system_update_rounded, color: Theme.of(c).colorScheme.primary), const SizedBox(width:8), Text('update_available'.tr())]),
          content: Text('Güncelleme var! $current → $latest güncellensin mi?'),
          actions: [
            TextButton(onPressed: ()=> Navigator.pop(c), child: Text('Daha sonra'.tr())),
            FilledButton(onPressed: () async {
              Navigator.pop(c);
              // Direkt ayarlara götür (5 sekme: 0 Home,1 Keşfet,2 Dosyalar,3 Favoriler,4 Ayarlar)
              setState(()=> _idx=4);
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ayarlar > Güncellemeleri denetle ile yükleyebilirsin'), behavior: SnackBarBehavior.floating));
            }, child: Text('Güncelle'.tr())),
          ],
        ));
      }
    });
    // Periyodik kontrol - ayardaki aralığa göre
    Timer.periodic(const Duration(hours: 1), (_) async {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool('auto_update_enabled') ?? true;
      if (!enabled) return;
      final intervalHours = prefs.getInt('update_interval_hours') ?? 6;
      final last = prefs.getInt('last_update_check') ?? 0;
      final hoursPassed = (DateTime.now().millisecondsSinceEpoch - last) / (1000*3600);
      if (hoursPassed >= intervalHours) AppUpdateService().checkAndUpdateSilently();
    });
  }

  Future<bool> _hasStoragePermission() async {
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.version.sdkInt >= 33) {
        final photos = await Permission.photos.status;
        final videos = await Permission.videos.status;
        return photos.isGranted || videos.isGranted;
      }
      return (await Permission.storage.status).isGranted;
    }
    return true;
  }

  Future<void> _firstLaunchCheck() async {
    final prefs = await SharedPreferences.getInstance();
    final done = prefs.getBool('first_launch_done') ?? false;
    final hasStorage = await _hasStoragePermission();
    final hasNotif = await Permission.notification.isGranted;
    // Her açılışta denetle, eksikse tekrar göster
    if (done && hasStorage && hasNotif) return;
    if (!mounted) return;
    final isFirst = !done;
    await showDialog(context: context, barrierDismissible: false, builder: (c)=> AlertDialog(
      title: Row(children: [Icon(Icons.verified_user_rounded, color: Theme.of(c).colorScheme.primary), const SizedBox(width:8), Text(isFirst ? 'Hoş geldin!'.tr() : 'İzinler gerekli')]),
      content: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(isFirst ? 'İndir Gitsin güvenle çalışmak için izinlere ihtiyaç duyar.'.tr() : 'Bazı izinler eksik, uygulama düzgün çalışmayabilir.', style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Row(children: [Icon(Icons.photo_library_rounded, size:18, color: hasStorage? Colors.green: Colors.orange), const SizedBox(width:6), Expanded(child: Text('Galeri & Dosyalar: videoları kaydetmek ve oynatmak için (tam erişim önerilir)', style: TextStyle(color: hasStorage? Colors.green: Colors.orange, fontSize: 12)))]),
        const SizedBox(height:6),
        Row(children: [Icon(Icons.notifications_rounded, size:18, color: hasNotif? Colors.green: Colors.orange), const SizedBox(width:6), Expanded(child: Text('Bildirim: indirme bitince haber verir', style: TextStyle(color: hasNotif? Colors.green: Colors.orange, fontSize: 12)))]),
        const SizedBox(height:10),
        Text('İzinler ayarlardan her zaman değiştirilebilir. Kullanılmadığında ayarlardan kaldırmanız önerilir.', style: TextStyle(color: Colors.grey[600], fontSize:11)),
      ])),
      actions: [
        TextButton(onPressed: () async { await prefs.setBool('first_launch_done', true); if(mounted) Navigator.pop(c); }, child: Text('Daha sonra'.tr())),
        FilledButton(onPressed: () async {
          await prefs.setBool('first_launch_done', true);
          try {
            if (Platform.isAndroid) {
              final info = await DeviceInfoPlugin().androidInfo;
              if (info.version.sdkInt >= 33) {
                await Permission.photos.request();
                await Permission.videos.request();
                await Permission.audio.request();
              } else {
                await Permission.storage.request();
                await Permission.manageExternalStorage.request();
              }
            }
            await Permission.notification.request();
          } catch(_){}
          await NotificationService.init();
          if(mounted) Navigator.pop(c);
          final okStorage = await _hasStoragePermission();
          final okNotif = await Permission.notification.isGranted;
          if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(okStorage && okNotif ? 'İzinler kaydedildi'.tr() : 'Bazı izinler verilmedi, ayarlardan açabilirsin')));
        }, child: Text('İzin ver'.tr())),
        TextButton(onPressed: () async { await openAppSettings(); }, child: const Text('Ayarları aç')),
      ],
    ));
  }

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeTab(key: _homeKey),
      ExplorePage(onSelect: (url){ _homeKey.currentState?.setLinkAndFetch(url); setState(()=> _idx=0); }),
      FilesTab(key: _filesKey),
      const FavoritesTab(),
      const SettingsTab(),
    ];
    return Scaffold(
      body: IndexedStack(index: _idx, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _idx,
        onDestinationSelected: (i) {
          setState(() => _idx = i);
          if (i==2) _filesKey.currentState?.refresh();
        },
        destinations: [
          NavigationDestination(icon: const Icon(Icons.home_rounded), label: 'home'.tr()),
          NavigationDestination(icon: const Icon(Icons.explore_rounded), label: 'explore'.tr()),
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
  ConsumerState<HomeTab> createState() => HomeTabState();
}

class HomeTabState extends ConsumerState<HomeTab> with TickerProviderStateMixin {
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
  int _dlTab = 0; // 0 MP4, 1 MP3, 2 WEBM
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
    // Direkt hazırlanma: paylaşınca otomatik çözümlenir - tüm media'ları tara (YouTube Music dahil)
    void handleMedia(List<SharedMediaFile> media) {
      for (final m in media) {
        final text = m.path.trim();
        // Bazen paylaşılan metin m.path içinde, bazen type text ise yine path'te
        final candidate = YoutubeService.extractVideoId(text) != null ? text : (m.type == SharedMediaType.text ? text : '');
        // Ek olarak: eğer path YouTube URL içeriyorsa direkt al
        String? url;
        if (YoutubeService.isValidYoutubeUrl(text)) url = text;
        else if (YoutubeService.isValidYoutubeUrl(candidate)) url = candidate;
        else {
          // Metin içinde URL ara (örn: "Check https://youtu.be/xxx")
          final match = RegExp(r'https?://[^\s]+').firstMatch(text);
          if (match != null && YoutubeService.isValidYoutubeUrl(match.group(0)!)) url = match.group(0)!;
        }
        if (url != null) {
          _linkCtrl.text = url;
          Future.delayed(const Duration(milliseconds: 300), _fetch);
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('share_preparing'.tr()), behavior: SnackBarBehavior.floating));
          break;
        }
      }
    }
    ReceiveSharingIntent.instance.getInitialMedia().then((List<SharedMediaFile> media) {
      if (media.isNotEmpty) handleMedia(media);
    });
    _intentSub = ReceiveSharingIntent.instance.getMediaStream().listen((List<SharedMediaFile> media) {
      if (media.isNotEmpty) handleMedia(media);
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
      final info = await ref.read(youtubeServiceProvider).getVideoInfo(url).timeout(const Duration(seconds: 15));
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
    if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Altyazı seçenekleri: ${caps.join(', ')}'), behavior: SnackBarBehavior.floating));
  }

  List<StreamOption> _filteredStreams() {
    if (_video==null) return [];
    if (_dlTab==0) { // MP4
      final list = _video!.streams.where((s)=> s.container=='mp4').toList();
      return list.isNotEmpty ? list : _video!.streams.where((s)=> s.type=='muxed').toList();
    } else if (_dlTab==1) { // MP3 (audio)
      final list = _video!.streams.where((s)=> s.type=='audioOnly').toList();
      return list.isNotEmpty ? list : _video!.streams;
    } else { // WEBM
      final list = _video!.streams.where((s)=> s.container=='webm').toList();
      return list.isNotEmpty ? list : _video!.streams.where((s)=> s.type=='videoOnly').toList();
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
      // Bildirim (ayardan kapatılabilir)
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('notify_enabled') ?? true) {
        try { await NotificationService.showDownloadDone(_video!.title, path); } catch(_){}
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${'downloaded'.tr()}: ${path.split('/').last}'), action: SnackBarAction(label: 'open'.tr(), onPressed: () => OpenFilex.open(path)), behavior: SnackBarBehavior.floating));
    } catch (e) {
      final raw = e.toString();
      String friendly = raw;
      if (raw.contains('lisans') || raw.contains('Lisans')) friendly = raw;
      else if (raw.contains('403')) friendly = 'Erişim reddedildi (403): Bu video MP3/WEBM formatında lisans korumalı veya bölge kısıtlı olabilir. MP4 deneyin veya farklı kalite seçin.';
      else if (raw.contains('404')) friendly = 'Stream bulunamadı (404): Video silinmiş veya format desteklenmiyor.';
      else if (raw.contains('Timeout') || raw.contains('Socket')) friendly = 'Bağlantı zaman aşımı: İnternet yavaş, tekrar dene.';
      else friendly = '${'error'.tr()}: $raw';
      setState(() { _downloading = false; _error = friendly; });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendly), backgroundColor: Theme.of(context).colorScheme.error, behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 5), action: SnackBarAction(label: 'Anladım', textColor: Colors.white, onPressed: (){})));
    }
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData('text/plain');
    if (data?.text != null) { _linkCtrl.text = data!.text!; _fetch(); }
  }

  void _clear() => setState(() { _linkCtrl.clear(); _video = null; _error = null; _savedPath = null; });
  void setLinkAndFetch(String url) { _linkCtrl.text = url; _fetch(); }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(padding: const EdgeInsets.all(2), decoration: BoxDecoration(borderRadius: BorderRadius.circular(10)), child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.asset('assets/icons/app_icon.png', width: 32, height: 32, fit: BoxFit.cover))),
          const SizedBox(width: 8),
          Text('İndir Gitsin'.tr(), style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
      ),
      body: RefreshIndicator(
        onRefresh: () async { _clear(); FocusScope.of(context).unfocus(); },
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
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
              // Davet et (viral)
              Card(
                color: Colors.orange.withOpacity(0.08),
                child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
                  Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.orange, borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.share_rounded, color: Colors.white, size:18)),
                  const SizedBox(width:10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Arkadaşını davet et', style: const TextStyle(fontWeight: FontWeight.w800)), Text('İndir Gitsin\'i paylaş, herkes hızlı indirsin', style: TextStyle(color: Colors.grey[600], fontSize:11))])),
                  FilledButton.tonalIcon(onPressed: () async { await Share.share('İndir Gitsin - YouTube & Music indirici https://github.com/ErhaEmir/indir-gitsin/releases'); }, icon: const Icon(Icons.send_rounded, size:16), label: const Text('Davet')),
                ])),
              ),
              const SizedBox(height: 12),
              // Arama (in-app YouTube search)
              const SizedBox(height: 4),
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
              if (_loading) ...[
                const SizedBox(height: 12),
                const LinearProgressIndicator(minHeight: 4, borderRadius: BorderRadius.all(Radius.circular(99))),
                const SizedBox(height: 8),
                Text('Video çözümleniyor...', style: TextStyle(color: Colors.grey[600], fontSize: 12, fontWeight: FontWeight.w600), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                _shimmer(isDark),
              ],
              if (_video != null) ...[
                const SizedBox(height: 16),
                _videoCard(context),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(color: cs.primaryContainer.withOpacity(0.5), borderRadius: BorderRadius.circular(14), border: Border.all(color: cs.primary.withOpacity(0.2))),
                  child: Row(children: [Icon(Icons.download_done_rounded, color: cs.primary), const SizedBox(width: 8), Text('Video hazır - indirme seçenekleri', style: TextStyle(fontWeight: FontWeight.w800, color: cs.onPrimaryContainer, fontSize: 13)), const Spacer(), Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(99)), child: const Text('HAZIR', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800)))]),
                ),
                const SizedBox(height: 10),
                Row(children: [IconButton(icon: Icon(StorageService.isFav(_video!.id) ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: Colors.red), onPressed: () { StorageService.toggleFav(_video!.id, {'id': _video!.id, 'title': _video!.title, 'thumbnail': _video!.thumbnailUrl}); setState(() {}); }), Text('add_favorite'.tr()), const Spacer(), Text('options_count'.tr(namedArgs: {'count': '${_video!.streams.length}'}), style: const TextStyle(color: Colors.grey))]),
                const SizedBox(height: 8),
                // Hızlı profiller + 3'lü format sekmeleri
                Wrap(spacing: 8, runSpacing: 6, children: [
                  ActionChip(label: Text('best_mp4'.tr()), avatar: const Icon(Icons.hd_rounded, size:16), onPressed: ()=> _applyProfile('best')),
                  ActionChip(label: Text('mp3_256'.tr()), avatar: const Icon(Icons.music_note_rounded, size:16), onPressed: ()=> _applyProfile('mp3')),
                  ActionChip(label: const Text('4K'), avatar: const Icon(Icons.high_quality_rounded, size:16), onPressed: ()=> _applyProfile('4k')),
                  ActionChip(label: Text('subtitle_chip'.tr()), avatar: const Icon(Icons.subtitles_rounded, size:16), onPressed: _downloadSubtitle),
                ]),
                const SizedBox(height: 12),
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('MP4'), icon: Icon(Icons.videocam_rounded, size:16)),
                    ButtonSegment(value: 1, label: Text('MP3'), icon: Icon(Icons.music_note_rounded, size:16)),
                    ButtonSegment(value: 2, label: Text('WEBM'), icon: Icon(Icons.movie_rounded, size:16)),
                  ],
                  selected: {_dlTab},
                  onSelectionChanged: (s){
                    setState((){
                      _dlTab = s.first;
                      final list = _filteredStreams();
                      if(list.isNotEmpty) _selected = list.first;
                    });
                  },
                  style: ButtonStyle(visualDensity: VisualDensity.compact),
                ),
                const SizedBox(height: 4),
                Text(_dlTab==0 ? 'MP4 - en uyumlu, her cihazda oynar' : _dlTab==1 ? 'MP3 - sadece ses, en küçük boyut' : 'WEBM - yüksek verim, modern codec', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                const SizedBox(height: 8),
                ..._filteredStreams().asMap().entries.map((e) => _tile(e.value, e.key, cs)),
                const SizedBox(height: 12),
                if (_downloading) Row(children: [
                  Expanded(child: Column(children: [
                    LinearProgressIndicator(value: _progress, borderRadius: BorderRadius.circular(99), minHeight: 8),
                    const SizedBox(height: 4),
                    Text('${(_progress*100).toStringAsFixed(0)}% - indiriliyor...', style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                  ])),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(onPressed: (){ ref.read(downloadServiceProvider).cancel(); setState(()=> _downloading=false); ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('İptal edildi'))); }, icon: const Icon(Icons.cancel_rounded, size:16), label: const Text('İptal')),
                ]),
                const SizedBox(height: 10),
                SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _downloading ? null : _download, icon: Icon(_savedPath != null ? Icons.check_circle_rounded : Icons.download_rounded), label: Text(_savedPath != null ? 'download_again'.tr() : 'download'.tr()))),
                if (_savedPath != null) Padding(padding: const EdgeInsets.only(top: 8), child: SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerPage(path: _savedPath!, title: _video!.title))), icon: const Icon(Icons.play_arrow_rounded), label: Text('play'.tr())))),
              ],
              if (!_loading && _video == null && _error == null) ...[const SizedBox(height: 20), _empty(context)],
            ]),
          ),
        ],
      ),
      ),
    );
  }

  Widget _chip(String t, IconData i) => Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6), decoration: BoxDecoration(color: Colors.white.withOpacity(0.14), borderRadius: BorderRadius.circular(99)), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(i, size: 12, color: Colors.white), const SizedBox(width: 4), Text(t, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w800))]));
  Widget _videoCard(BuildContext c) {
    final v = _video!; final dur = v.duration != null ? '${v.duration!.inMinutes}:${(v.duration!.inSeconds%60).toString().padLeft(2,'0')}' : '';
    return InkWell(
      onTap: (){
        showDialog(context: c, builder: (_) => Dialog(backgroundColor: Colors.transparent, insetPadding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, children: [
          ClipRRect(borderRadius: BorderRadius.circular(16), child: CachedNetworkImage(imageUrl: v.thumbnailUrl, fit: BoxFit.cover)),
          const SizedBox(height: 12),
          Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Theme.of(c).cardColor, borderRadius: BorderRadius.circular(12)), child: Column(children: [
            Text(v.title, style: const TextStyle(fontWeight: FontWeight.w800), textAlign: TextAlign.center),
            const SizedBox(height: 6),
            Text(v.author, style: TextStyle(color: Colors.grey[600], fontSize: 13)),
            const SizedBox(height: 12),
            Column(children: [
              Row(children: [
                Expanded(child: OutlinedButton.icon(onPressed: ()=> Navigator.pop(c), icon: const Icon(Icons.close_rounded), label: Text('close'.tr()))),
                const SizedBox(width:8),
                Expanded(child: FilledButton.icon(onPressed: () async { Navigator.pop(c); final uri = Uri.parse('https://www.youtube.com/watch?v=${v.id}'); if(await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication); }, icon: const Icon(Icons.play_arrow_rounded), label: Text('open_youtube'.tr()))),
              ]),
              const SizedBox(height:8),
              SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: (){
                Navigator.pop(c);
                // En iyi muxed stream ile uygundada izle
                final best = _video!.streams.where((s)=> s.type=='muxed').toList();
                final url = best.isNotEmpty ? best.first.url : _video!.streams.first.url;
                Navigator.push(context, MaterialPageRoute(builder: (_)=> NetworkPlayerPage(url: url, title: v.title)));
              }, icon: const Icon(Icons.ondemand_video_rounded), label: const Text('Uygulamada izle'), style: FilledButton.styleFrom(backgroundColor: Colors.deepPurple))),
            ]),
          ])),
        ])));
      },
      borderRadius: BorderRadius.circular(24),
      child: Card(child: Column(children: [Stack(children: [ClipRRect(borderRadius: const BorderRadius.vertical(top: Radius.circular(24)), child: CachedNetworkImage(imageUrl: v.thumbnailUrl, height: 200, width: double.infinity, fit: BoxFit.cover)), Positioned(bottom: 8, right: 8, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)), child: Text(dur, style: const TextStyle(color: Colors.white, fontSize: 12)))), Positioned.fill(child: Center(child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.black.withOpacity(0.35), shape: BoxShape.circle), child: const Icon(Icons.play_arrow_rounded, color: Colors.white, size: 36))))]), Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(v.title, style: const TextStyle(fontWeight: FontWeight.w800), maxLines: 2), const SizedBox(height: 6), Text(v.author, style: TextStyle(color: Colors.grey[600], fontSize: 13)), const SizedBox(height: 4), Text('Önizlemek için dokun'.tr(), style: TextStyle(color: Theme.of(c).colorScheme.primary, fontSize: 11, fontWeight: FontWeight.w600))]))])),
    );
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

// FILES TAB - dosya yönetimi + depolama seçici + her girişte yenile
class FilesTab extends StatefulWidget { const FilesTab({super.key}); @override State<FilesTab> createState()=> FilesTabState();}
class FilesTabState extends State<FilesTab> {
  List<FileSystemEntity> _files = [];
  String _sort = 'date';
  @override void initState(){ super.initState(); _load(); }
  Future<void> refresh() async => _load();
  Future<Directory> _getDir() async {
    final prefs = await SharedPreferences.getInstance();
    final custom = prefs.getString('custom_download_path');
    if (custom != null && custom.isNotEmpty) return Directory(custom);
    return Directory('/storage/emulated/0/Download/IndirGitsin');
  }
  Future<void> _load() async {
    try {
      final base = Directory('/storage/emulated/0/Download/IndirGitsin');
      List<FileSystemEntity> all = [];
      if (await base.exists()) {
        final baseFiles = await base.list(recursive: true).where((e)=> e is File).toList();
        all.addAll(baseFiles);
      }
      final custom = await _getDir();
      if (custom.path != base.path && await custom.exists()) {
        final customFiles = await custom.list(recursive: true).where((e)=> e is File).toList();
        for(final f in customFiles){ if(!all.any((e)=> e.path==f.path)) all.add(f); }
      }
      // Eğer hiç yoksa custom'ı da dene (eski dosyalar base'de olabilir)
      if (all.isEmpty) {
        final dir = await _getDir();
        if (await dir.exists()) {
          final f = await dir.list(recursive: true).where((e)=> e is File).toList();
          all = f;
        }
      }
      all.sort((a,b){
        if (_sort=='name') return a.path.compareTo(b.path);
        if (_sort=='size') {
          try { return (b as File).lengthSync().compareTo((a as File).lengthSync()); } catch(_){ return 0; }
        }
        try { return b.statSync().modified.compareTo(a.statSync().modified); } catch(_){ return 0; }
      });
      setState(()=>_files=all);
    } catch(_){ setState(()=>_files=[]); }
  }
  Future<void> _rename(File f) async {
    final ctrl = TextEditingController(text: f.path.split('/').last);
    final ok = await showDialog<bool>(context: context, builder: (c)=> AlertDialog(title: Text('Yeniden adlandır'), content: TextField(controller: ctrl), actions: [TextButton(onPressed: ()=> Navigator.pop(c,false), child: Text('cancel'.tr())), FilledButton(onPressed: ()=> Navigator.pop(c,true), child: Text('save'.tr()))]));
    if (ok==true && ctrl.text.isNotEmpty) { final dir = (await _getDir()).path; await f.rename('$dir/${ctrl.text}'); _load(); }
  }
  Future<void> _delete(File f) async {
    final ok = await showDialog<bool>(context: context, builder: (c)=> AlertDialog(title: Text('delete_confirm'.tr()), content: Text(f.path.split('/').last), actions: [TextButton(onPressed: ()=> Navigator.pop(c,false), child: Text('cancel'.tr())), FilledButton(onPressed: ()=> Navigator.pop(c,true), child: Text('delete'.tr()))]));
    if (ok==true) { await f.delete(); _load(); }
  }
  Future<void> _pickStorage() async {
    final ctrl = TextEditingController(text: (await _getDir()).path);
    final ok = await showDialog<bool>(context: context, builder: (c)=> AlertDialog(title: Text('choose_storage'.tr()), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: ctrl, decoration: const InputDecoration(hintText: '/storage/emulated/0/Download/IndirGitsin')), const SizedBox(height:8), Text('storage_desc'.tr(), style: TextStyle(fontSize:11, color: Colors.grey))]), actions: [TextButton(onPressed: ()=> Navigator.pop(c,false), child: Text('cancel'.tr())), FilledButton(onPressed: ()=> Navigator.pop(c,true), child: Text('save'.tr()))]));
    if (ok==true) { final p=await SharedPreferences.getInstance(); await p.setString('custom_download_path', ctrl.text.trim()); _load(); }
  }
  @override Widget build(BuildContext context){
    return Scaffold(
      appBar: AppBar(title: Text('files'.tr()), actions: [
        PopupMenuButton<String>(onSelected: (v){ FocusScope.of(context).unfocus(); if(v=='storage') _pickStorage(); else { setState(()=> _sort=v); _load(); }}, itemBuilder: (_)=> [
          PopupMenuItem(value:'date', child: Text('sort_date'.tr())),
          PopupMenuItem(value:'size', child: Text('sort_size'.tr())),
          PopupMenuItem(value:'name', child: Text('sort_name'.tr())),
          const PopupMenuDivider(),
          PopupMenuItem(value:'storage', child: Row(children: [const Icon(Icons.folder_open_rounded, size:16), const SizedBox(width:8), Text('choose_storage'.tr())])),
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
          }, itemBuilder: (_)=> [PopupMenuItem(value:'play', child: Text('play'.tr())), PopupMenuItem(value:'share', child: Text('share'.tr())), PopupMenuItem(value:'rename', child: Text('rename'.tr())), PopupMenuItem(value:'delete', child: Text('delete'.tr()))]),
          onTap: ()=> isVideo ? Navigator.push(context, MaterialPageRoute(builder: (_)=> PlayerPage(path: f.path, title: name))) : OpenFilex.open(f.path),
          onLongPress: ()=> showModalBottomSheet(context: context, builder: (_)=> Wrap(children: [ListTile(leading: const Icon(Icons.edit_rounded), title: Text('rename'.tr()), onTap: (){ Navigator.pop(context); _rename(f);}), ListTile(leading: const Icon(Icons.share_rounded), title: Text('share'.tr()), onTap: ()async{ Navigator.pop(context); await Share.shareXFiles([XFile(f.path)]);}), ListTile(leading: const Icon(Icons.delete_rounded, color: Colors.red), title: Text('delete'.tr(), style: TextStyle(color: Colors.red)), onTap: (){ Navigator.pop(context); _delete(f);})])),
        );
      })),
    );
  }
}

// FAVORITES + HISTORY - ValueListenable ile otomatik yenilenir
class FavoritesTab extends StatelessWidget { const FavoritesTab({super.key}); @override Widget build(BuildContext c){
  return DefaultTabController(length: 2, child: Scaffold(appBar: AppBar(title: Text('favorites'.tr()), bottom: TabBar(tabs: [Tab(text: 'favorites'.tr()), Tab(text: 'history'.tr())])), body: TabBarView(children: [
    ValueListenableBuilder<Box>(valueListenable: StorageService.fav.listenable(), builder: (_, box, __){
      final fav = box.values.toList().cast<Map>();
      if(fav.isEmpty) return Center(child: Text('no_downloads'.tr()));
      return ListView.builder(itemCount: fav.length, itemBuilder: (_,i){ final m=fav[i]; return ListTile(leading: ClipRRect(borderRadius: BorderRadius.circular(8), child: CachedNetworkImage(imageUrl: m['thumbnail']??'', width:56, height:56, fit: BoxFit.cover)), title: Text(m['title']??'', maxLines:1), subtitle: Text(m['id']??''), trailing: IconButton(icon: const Icon(Icons.delete_rounded), onPressed: ()=> StorageService.fav.delete(m['id'])));});
    }),
    ValueListenableBuilder<Box>(valueListenable: StorageService.history.listenable(), builder: (_, box, __){
      final hist = box.values.toList().cast<Map>().reversed.toList();
      if(hist.isEmpty) return Center(child: Text('no_downloads'.tr()));
      return ListView.builder(itemCount: hist.length, itemBuilder: (_,i){ final m=hist[i]; return ListTile(leading: ClipRRect(borderRadius: BorderRadius.circular(8), child: CachedNetworkImage(imageUrl: m['thumbnail']??'', width:56, height:56, fit: BoxFit.cover)), title: Text(m['title']??'', maxLines:1), subtitle: Text(m['path']?.toString().split('/').last ?? ''), trailing: Row(mainAxisSize: MainAxisSize.min, children: [IconButton(icon: const Icon(Icons.open_in_new_rounded), onPressed: ()=> OpenFilex.open(m['path'])), IconButton(icon: const Icon(Icons.delete_rounded, color: Colors.red), onPressed: ()=> StorageService.history.delete(m['id']))]));});
    }),
  ])));
}}

// SETTINGS - portatif ve kullanıcı dostu
class SettingsTab extends ConsumerStatefulWidget { const SettingsTab({super.key}); @override ConsumerState<SettingsTab> createState()=> _SettingsTabState();}
class _SettingsTabState extends ConsumerState<SettingsTab> {
  bool _autoUpdate = true;
  int _interval = 6;
  bool _checking = false;
  String? _status;
  @override void initState(){ super.initState(); _load(); }
  Future<void> _load() async { final p=await SharedPreferences.getInstance(); setState(()=> { _autoUpdate = p.getBool('auto_update_enabled') ?? true, _interval = p.getInt('update_interval_hours') ?? 6 }); }
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
          Wrap(spacing: 8, children: [
            ChoiceChip(label: const Text('Türkçe'), selected: context.locale.languageCode=='tr', onSelected: (_){ context.setLocale(const Locale('tr')); SharedPreferences.getInstance().then((p)=> p.setString('lang','tr'));}),
            ChoiceChip(label: const Text('English'), selected: context.locale.languageCode=='en', onSelected: (_){ context.setLocale(const Locale('en')); SharedPreferences.getInstance().then((p)=> p.setString('lang','en'));}),
          ]),
        ]))),
        const SizedBox(height: 12),
        // Güncelleme kartı
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.green.withOpacity(0.12), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.system_update_rounded, color: Colors.green)), const SizedBox(width: 10), Text('auto_update'.tr(), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))]),
          const SizedBox(height: 4),
          Text('auto_update_desc'.tr(), style: TextStyle(color: Colors.grey[600], fontSize: 12)),
          const SizedBox(height: 12),
          SwitchListTile(value: _autoUpdate, title: Text(_autoUpdate ? 'auto_on'.tr() : 'auto_off'.tr()), subtitle: Text(_autoUpdate ? 'auto_on_desc'.tr() : 'auto_off_desc'.tr()), onChanged: _toggleAuto, contentPadding: EdgeInsets.zero),
          if (_autoUpdate) ...[
            const SizedBox(height: 8),
            Row(children: [
              Icon(Icons.timer_rounded, size:16, color: Colors.grey[600]),
              const SizedBox(width:6),
              Text('control_interval'.tr(), style: TextStyle(fontSize:12, color: Colors.grey[600])),
              const Spacer(),
              DropdownButton<int>(
                value: _interval,
                underline: Container(height:1, color: Colors.grey[300]),
                items: [
                  DropdownMenuItem(value: 1, child: Text('1 ' + 'hour'.tr())),
                  DropdownMenuItem(value: 6, child: Text('6 ' + 'hour'.tr())),
                  DropdownMenuItem(value: 12, child: Text('12 ' + 'hour'.tr())),
                  DropdownMenuItem(value: 24, child: Text('24 ' + 'hour'.tr())),
                ],
                onChanged: (v) async { if(v==null) return; final p=await SharedPreferences.getInstance(); await p.setInt('update_interval_hours', v); setState(()=> _interval=v); },
              ),
            ]),
          ],
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _checking ? null : _manualCheck, icon: _checking ? const SizedBox(width:16,height:16, child: CircularProgressIndicator(strokeWidth:2, color:Colors.white)) : const Icon(Icons.refresh_rounded), label: Text('check_updates'.tr()))),
          if(_status!=null) Padding(padding: const EdgeInsets.only(top:8), child: Text(_status!, style: TextStyle(color: cs.primary, fontSize:12, fontWeight: FontWeight.w600))),
        ]))),
        // Kullanım kolaylaştırıcı ayarlar
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.orange.withOpacity(0.12), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.tune_rounded, color: Colors.orange)), const SizedBox(width: 10), Text('ease_of_use'.tr(), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))]),
          const SizedBox(height: 8),
          FutureBuilder<SharedPreferences>(future: SharedPreferences.getInstance(), builder: (c,s){
            final p=s.data; final autoClip = p?.getBool('auto_clipboard') ?? true;
            final vib = p?.getBool('haptic') ?? true;
            final notif = p?.getBool('notify_enabled') ?? true;
            final autoFolder = p?.getBool('auto_folder') ?? true;
            final defaultFormat = p?.getString('default_format') ?? 'mp4';
            return Column(children: [
              SwitchListTile(value: autoClip, title: Text('auto_clipboard'.tr()), subtitle: Text('auto_clipboard_desc'.tr(), style: const TextStyle(fontSize:12)), onChanged: (v) async { final pr=await SharedPreferences.getInstance(); await pr.setBool('auto_clipboard', v); (c as Element).markNeedsBuild(); }, contentPadding: EdgeInsets.zero),
              SwitchListTile(value: vib, title: Text('haptic_feedback'.tr()), subtitle: Text('haptic_desc'.tr(), style: const TextStyle(fontSize:12)), onChanged: (v) async { final pr=await SharedPreferences.getInstance(); await pr.setBool('haptic', v); (c as Element).markNeedsBuild(); }, contentPadding: EdgeInsets.zero),
              SwitchListTile(value: notif, title: Text('notify_on_done'.tr()), subtitle: Text('notify_desc'.tr(), style: const TextStyle(fontSize:12)), onChanged: (v) async { 
                final pr=await SharedPreferences.getInstance(); 
                await pr.setBool('notify_enabled', v); 
                if(v) { await Permission.notification.request(); }
                (c as Element).markNeedsBuild(); 
              }, contentPadding: EdgeInsets.zero),
              SwitchListTile(value: autoFolder, title: Text('auto_folder'.tr()), subtitle: Text('auto_folder_desc'.tr(), style: const TextStyle(fontSize:12)), onChanged: (v) async { final pr=await SharedPreferences.getInstance(); await pr.setBool('auto_folder', v); (c as Element).markNeedsBuild(); }, contentPadding: EdgeInsets.zero),
              const SizedBox(height: 8),
              Row(children: [const Icon(Icons.video_settings_rounded, size:16, color: Colors.grey), const SizedBox(width:6), Text('default_format'.tr(), style: const TextStyle(fontSize:12, color: Colors.grey)), const Spacer(), DropdownButton<String>(value: defaultFormat, items: [DropdownMenuItem(value:'mp4', child: Text('MP4')), DropdownMenuItem(value:'mp3', child: Text('MP3')), DropdownMenuItem(value:'webm', child: Text('WEBM'))], onChanged: (v) async { if(v==null) return; final pr=await SharedPreferences.getInstance(); await pr.setString('default_format', v); (c as Element).markNeedsBuild(); })]),

              const SizedBox(height: 4),
              SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () async {
                final ok = await showDialog<bool>(context: context, builder: (c)=> AlertDialog(title: const Text('Temizlensin mi?'), content: const Text('Arama geçmişi, izleme geçmişi ve favoriler silinecek.'), actions: [TextButton(onPressed: ()=> Navigator.pop(c,false), child: Text('cancel'.tr())), FilledButton(onPressed: ()=> Navigator.pop(c,true), child: Text('delete'.tr()))]));
                if(ok!=true) return;
                await StorageService.search.clear();
                await StorageService.history.clear();
                await StorageService.fav.clear();
                // Hive box'ları dinleyen sayfalar otomatik yenilenecek (ValueListenableBuilder)
                if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tümü temizlendi ✓'), behavior: SnackBarBehavior.floating, backgroundColor: Colors.green));
              }, icon: const Icon(Icons.delete_sweep_rounded), label: Text('clear_all'.tr()))),
            ]);
          }),
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
