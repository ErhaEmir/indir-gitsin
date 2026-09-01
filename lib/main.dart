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
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'core/theme.dart';
import 'core/youtube_service.dart';
import 'core/download_service.dart';
import 'core/app_update_service.dart';
import 'core/storage_service.dart';
import 'core/notification_service.dart';
import 'core/subscription_service.dart';
import 'features/player/player_page.dart';
import 'features/player/network_player_page.dart';
import 'features/explore/explore_page.dart';
import 'features/plan/plan_page.dart';
import 'features/market/market_page.dart';

final youtubeServiceProvider = Provider((ref) => YoutubeService());
final downloadServiceProvider = Provider((ref) => DownloadService());
final themeModeProvider = StateProvider<String>((ref) => 'system');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  await StorageService.init();
  await NotificationService.init();
  await SubscriptionService.ensureInit();
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
  Future<void> _checkPlanActive() async {
    await SubscriptionService.ensureInit();
    await SubscriptionService.enforcePlanRestrictions();
    // tema kilidi — free + amoled ise koyu yap
    final prefs = await SharedPreferences.getInstance();
    final planStr = prefs.getString('sub_plan') ?? 'free';
    final isDev = prefs.getBool('dev_mode') ?? false;
    if (!isDev && planStr=='free' && prefs.getString('theme_mode')=='amoled') {
      await prefs.setString('theme_mode', 'dark');
      ref.read(themeModeProvider.notifier).state = 'dark';
    }
    final active = await SubscriptionService.isPlanActive();
    if (!active && mounted) {
      await Navigator.of(context).push(MaterialPageRoute(builder: (_)=> const PlanPage(mustSelect: true)));
      setState((){});
    }
  }

  @override
  void initState() {
    super.initState();
    _checkPlanActive();
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
              // Direkt ayarlara götür (6 sekme: 0 Home,1 Keşfet,2 Dosyalar,3 Favoriler,4 Market,5 Ayarlar)
              setState(()=> _idx=5);
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
    // Sadece ilk kurulumda veya her ikisi de eksikse göster — her açılışta zorla değil
    if (done) {
      // storage yoksa bile app-scoped dizine yazabildiğimiz için sadece bildirim eksikse ve daha önce sorulmadıysa göster
      if (hasStorage && hasNotif) return;
      // kullanıcı "Daha sonra" dediyse tekrar rahatsız etme (done=true ise sessiz)
      if (!hasStorage && hasNotif) return; // scoped storage ile çalışır
      if (hasStorage && !hasNotif) {
        // bildirim izni opsiyonel — sadece ilk kez sor
        final asked = prefs.getBool('notif_asked') ?? false;
        if (asked) return;
      }
    }
    if (!mounted) return;
    final isFirst = !done;
    await showDialog(context: context, barrierDismissible: true, builder: (c)=> AlertDialog(
      title: Row(children: [Icon(Icons.verified_user_rounded, color: Theme.of(c).colorScheme.primary), const SizedBox(width:8), Text(isFirst ? 'Hoş geldin!'.tr() : 'İzinler gerekli')]),
      content: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(isFirst ? 'İndir Gitsin güvenle çalışmak için izinlere ihtiyaç duyar.'.tr() : 'Bazı izinler eksik, uygulama düzgün çalışmayabilir.', style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        Row(children: [Icon(Icons.photo_library_rounded, size:18, color: hasStorage? Colors.green: Colors.orange), const SizedBox(width:6), Expanded(child: Text('gallery_perm_full'.tr(), style: TextStyle(color: hasStorage? Colors.green: Colors.orange, fontSize: 12)))]),
        const SizedBox(height:6),
        Row(children: [Icon(Icons.notifications_rounded, size:18, color: hasNotif? Colors.green: Colors.orange), const SizedBox(width:6), Expanded(child: Text('notif_perm_full'.tr(), style: TextStyle(color: hasNotif? Colors.green: Colors.orange, fontSize: 12)))]),
        const SizedBox(height:10),
        FutureBuilder<bool>(
          future: SharedPreferences.getInstance().then((p)=> p.getBool('auto_revoke') ?? false),
          builder: (c,snap){
            final val = snap.data ?? false;
            return SwitchListTile(
              value: val,
              title: Text('auto_revoke'.tr(), style: const TextStyle(fontSize:13, fontWeight: FontWeight.w700)),
              subtitle: Text('auto_revoke_desc'.tr(), style: const TextStyle(fontSize:11)),
              contentPadding: EdgeInsets.zero,
              onChanged: (v) async { final p=await SharedPreferences.getInstance(); await p.setBool('auto_revoke', v); (c as Element).markNeedsBuild(); },
            );
          },
        ),
        Text('perm_hint'.tr(), style: TextStyle(color: Colors.grey[600], fontSize:11)),
      ])),
      actions: [
        TextButton(onPressed: () async { await prefs.setBool('first_launch_done', true); if(mounted) Navigator.pop(c); }, child: Text('Daha sonra'.tr())),
        FilledButton(onPressed: () async {
          await prefs.setBool('first_launch_done', true);
          await prefs.setBool('notif_asked', true);
          try {
            if (Platform.isAndroid) {
              final info = await DeviceInfoPlugin().androidInfo;
              if (info.version.sdkInt >= 33) {
                await Permission.photos.request();
                await Permission.videos.request();
                await Permission.audio.request();
              } else {
                await Permission.storage.request();
                // MANAGE_EXTERNAL_STORAGE sadece kullanıcı FilesTab'da özel klasör seçerse istenecek — ilk kurulumda sorma (Play Store reddi)
              }
            }
            await Permission.notification.request();
          } catch(_){}
          await NotificationService.init();
          if(mounted) Navigator.pop(c);
          final okStorage = await _hasStoragePermission();
          final okNotif = await Permission.notification.isGranted;
          if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(okStorage || okNotif ? 'İzinler kaydedildi'.tr() : 'İzinler ayarlardan her zaman değiştirilebilir')));
        }, child: Text('İzin ver'.tr())),
        TextButton(onPressed: () async { await prefs.setBool('notif_asked', true); await openAppSettings(); }, child: const Text('Ayarları aç')),
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
      const MarketPage(),
      const SettingsTab(),
    ];
    return Scaffold(
      body: IndexedStack(index: _idx, children: pages),
      bottomNavigationBar: NavigationBarTheme(
        data: NavigationBarThemeData(
          labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 10, fontWeight: FontWeight.w600)),
          iconTheme: WidgetStateProperty.all(const IconThemeData(size: 22)),
          height: 62,
        ),
        child: NavigationBar(
          selectedIndex: _idx,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          onDestinationSelected: (i) {
            setState(() => _idx = i);
            if (i==2) _filesKey.currentState?.refresh();
          },
          destinations: [
            NavigationDestination(icon: const Icon(Icons.home_rounded), label: 'home'.tr()),
            NavigationDestination(icon: const Icon(Icons.explore_rounded), label: 'explore'.tr()),
            NavigationDestination(icon: const Icon(Icons.folder_rounded), label: 'files'.tr()),
            NavigationDestination(icon: const Icon(Icons.favorite_rounded), label: 'favorites'.tr()),
            NavigationDestination(icon: const Icon(Icons.storefront_rounded), label: 'Market'),
            NavigationDestination(icon: const Icon(Icons.settings_rounded), label: 'settings'.tr()),
          ],
        ),
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
  int _quotaVersion = 0;

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
      setState(() => _error = 'Bağlantı yavaş — tekrar dene (sunucu yoğun olabilir)');
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      final isDev = prefs.getBool('dev_mode') ?? false;
      final raw = e.toString();
      String msg;
      if (isDev) {
        msg = '${'failed'.tr()}: $raw';
      } else {
        if (raw.contains('VideoUnavailable') || raw.contains('Video bulunamadı')) msg = 'Video bulunamadı veya gizli — gizlilik ayarını Herkese Açık yapıp tekrar dene';
        else if (raw.contains('lisans') || raw.contains('Lisans') || raw.contains('copyright')) msg = 'Bu video lisans korumalı olabilir — MP4 ile tekrar dene veya farklı video dene';
        else if (raw.contains('Requires login') || raw.contains('giriş gerektiriyor')) msg = 'Bu video giriş gerektiriyor — herkese açık bir link dene';
        else if (raw.contains('403')) msg = 'YouTube erişimi geçici olarak reddedildi (403) — MP4 dene veya 1 dk sonra tekrar dene';
        else if (raw.contains('404')) msg = 'Video veya format bulunamadı (404) — farklı kalite seçmeyi dene';
        else if (raw.contains('Timeout') || raw.contains('Socket')) msg = 'Bağlantı zaman aşımı — internetini kontrol et ve tekrar dene';
        else if (raw.contains('Geçersiz YouTube linki')) msg = 'Geçersiz YouTube linki — youtu.be / youtube.com / music.youtube.com linki kullan';
        else msg = 'Video bilgisi alınamadı — interneti kontrol et ve tekrar dene';
      }
      setState(() => _error = msg);
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
      if (res.isEmpty && mounted) setState(() => _error = 'Sonuç bulunamadı — farklı kelime dene');
    } on TimeoutException {
      setState(() => _error = 'Arama zaman aşımı — tekrar dene');
    } catch (e) { setState(() => _error = 'Arama hatası: $e'); }
    finally { setState(() => _searching = false); }
  }

  Future<void> _fetchPlaylist(String url) async {
    setState(() { _loading = true; _error = null; _playlist = []; });
    try {
      final list = await ref.read(youtubeServiceProvider).getPlaylistVideos(url).timeout(const Duration(seconds: 15));
      setState(() { _playlist = list; });
      if (list.isEmpty) { setState(() => _error = 'Playlist boş veya alınamadı — herkese açık playlist dene'); return; }
      if (list.isNotEmpty) { _linkCtrl.text = 'https://www.youtube.com/watch?v=${list.first.id}'; await _fetch(); }
    } on TimeoutException { setState(() => _error = 'Playlist zaman aşımı — tekrar dene'); }
    catch (e) { setState(() => _error = 'Playlist alınamadı: $e'); }
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
    // Kota kontrolü
    final isAudio = _selected!.type == 'audioOnly';
    bool can = isAudio ? await SubscriptionService.canDownloadAudio() : await SubscriptionService.canDownloadVideo();
    if (!can) {
      if (!mounted) return;
      final kind = isAudio ? 'ses' : 'video';
      await showDialog(context: context, builder: (c)=> AlertDialog(
        title: Row(children: [Icon(Icons.block_rounded, color: Colors.red), const SizedBox(width:8), Text('Limit Doldu')]),
        content: Text('Günlük $kind indirme limitine ulaştınız. İsterseniz planınızı yükseltin veya birikmiş coin\'lerinizle marketten hak satın alın.'),
        actions: [
          TextButton(onPressed: ()=> Navigator.pop(c), child: Text('Kapat'.tr())),
          FilledButton(onPressed: (){ Navigator.pop(c); Navigator.push(context, MaterialPageRoute(builder: (_)=> const MarketPage())); }, child: const Text('Markete Git')),
          FilledButton.tonalIcon(onPressed: (){ Navigator.pop(c); Navigator.push(context, MaterialPageRoute(builder: (_)=> const PlanPage())); }, icon: const Icon(Icons.workspace_premium_rounded, size:16), label: const Text('Planı Yükselt')),
        ],
      ));
      return;
    }
    HapticFeedback.mediumImpact();
    setState(() { _downloading = true; _progress = 0; _error = null; });
    // ext catch bloğunda da lazım olduğu için try dışında tanımla
    final extRaw = _selected!.container == 'mp4' ? 'mp4' : _selected!.container;
    final ext = _selected!.type == 'audioOnly' ? 'm4a' : extRaw;
    try {
      final svc = ref.read(downloadServiceProvider);
      final path = await svc.download(
        url: _selected!.url, fileName: _video!.title, ext: ext,
        videoId: _video!.id, streamTag: _selected!.tag,
        onProgress: (rx, total) { if (total > 0 && mounted) setState(() => _progress = rx / total); },
      );
      StorageService.addHistory({'id': _video!.id, 'title': _video!.title, 'thumbnail': _video!.thumbnailUrl, 'url': 'https://www.youtube.com/watch?v=${_video!.id}', 'path': path, 'date': DateTime.now().toIso8601String()});
      // Kota düş
      if (isAudio) await SubscriptionService.consumeAudio(); else await SubscriptionService.consumeVideo();
      if (mounted) setState(()=> _quotaVersion++);
      setState(() { _savedPath = path; _downloading = false; _progress = 1; });
      HapticFeedback.heavyImpact();
      // Bildirim (ayardan kapatılabilir)
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('notify_enabled') ?? true) {
        try { await NotificationService.showDownloadDone(_video!.title, path); } catch(_){}
      }
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${'downloaded'.tr()}: ${path.split('/').last}'), action: SnackBarAction(label: 'open'.tr(), onPressed: () => OpenFilex.open(path)), behavior: SnackBarBehavior.floating));
    } catch (e) {
      final prefs = await SharedPreferences.getInstance();
      final isDev = prefs.getBool('dev_mode') ?? false;
      final raw = e.toString();
      String friendly;
      if (isDev) {
        friendly = raw;
      } else {
        if (raw.contains('lisans') || raw.contains('Lisans')) friendly = 'Lisans korumalı — MP4 ile tekrar dene veya farklı video dene';
        else if (raw.contains('403')) {
          if (ext == 'mp3' || ext == 'm4a') friendly = 'MP3 koruması (403) — MP4 veya M4A dene, olmazsa farklı video dene';
          else if (ext == 'webm') friendly = 'WEBM kısıtlı (403) — MP4 dene';
          else friendly = 'İndirme reddedildi (403) — MP4 ile tekrar dene';
        }
        else if (raw.contains('404')) friendly = 'Format bulunamadı (404) — farklı kalite seç';
        else if (raw.contains('Depolama izni')) friendly = 'Depolama izni verilmedi — Ayarlar > İzin ver';
        else if (raw.contains('çok küçük') || raw.contains('küçük')) friendly = 'İndirilen dosya bozuk — tekrar dene, MP4 önerilir';
        else if (raw.contains('Timeout') || raw.contains('Socket') || raw.contains('zaman aşımı')) friendly = 'Bağlantı zaman aşımı — interneti kontrol et ve tekrar dene';
        else if (raw.contains('alan') || raw.contains('space')) friendly = 'Depolama alanı yetersiz — yer aç ve tekrar dene';
        else friendly = 'İndirme başarısız — MP4 ile tekrar dene';
      }
      setState(() { _downloading = false; _error = friendly; });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(friendly), backgroundColor: Theme.of(context).colorScheme.error, behavior: SnackBarBehavior.floating, duration: const Duration(seconds: 6),
        action: SnackBarAction(label: 'Tekrar', textColor: Colors.white, onPressed: _download),
      ));
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
        actions: [
          FutureBuilder<PlanType>(future: SubscriptionService.getPlan(), builder: (c,pSnap){
            final isUnlimited = pSnap.data == PlanType.unlimited;
            return FutureBuilder<int>(future: SubscriptionService.getCoins(), builder: (c2,s)=> Padding(padding: const EdgeInsets.only(top:6,bottom:6), child: Chip(avatar: Image.asset('assets/icons/ig_coin.png', width:22, height:22, errorBuilder: (_,__,___)=> const Icon(Icons.monetization_on_rounded, size:22, color: Colors.amber)), label: Text(isUnlimited ? '∞' : '${s.data??0}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize:13)), visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal:6))));
          }),
          const SizedBox(width:4),
          Padding(padding: const EdgeInsets.only(right:8), child: FilledButton.tonalIcon(onPressed: () async { await Navigator.push(context, MaterialPageRoute(builder: (_)=> const PlanPage())); setState((){}); }, icon: const Icon(Icons.workspace_premium_rounded, size:16), label: const Text('Planı Yükselt', style: TextStyle(fontSize:11, fontWeight: FontWeight.w800)))),
        ],
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
                  FilledButton.tonalIcon(onPressed: () async {
                    await Share.share('İndir Gitsin - YouTube & Music indirici https://github.com/ErhaEmir/indir-gitsin/releases');
                    final res = await SubscriptionService.doInvite();
                    if (res=='coin' && context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('+30 Coin!'), backgroundColor: Colors.green));
                    else if (res=='badge' && context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Rozet kazandın 🏅'), backgroundColor: Colors.deepPurple));
                    setState((){});
                  }, icon: const Icon(Icons.send_rounded, size:16), label: const Text('Davet')),
                ])),
              ),
              const SizedBox(height: 10),
              // Kota kartı
              FutureBuilder<Map<String,int>>(key: ValueKey(_quotaVersion), future: SubscriptionService.getRemaining(), builder: (c,snap){
                final r = snap.data;
                if (r==null) return const SizedBox();
                final rv = r['video'] ?? 0; final ra = r['audio'] ?? 0; final lv = r['limitVideo'] ?? 0; final la = r['limitAudio'] ?? 0; final ev = r['extraVideo'] ?? 0; final ea = r['extraAudio'] ?? 0;
                final totalV = lv + ev; final totalA = la + ea;
                return FutureBuilder<PlanType>(future: SubscriptionService.getPlan(), builder: (c2,ps){
                  final plan = ps.data ?? PlanType.free;
                  final isUnlimited = plan == PlanType.unlimited;
                  final videoText = isUnlimited ? 'Video ∞' : (ev>0 ? 'Video $rv / $totalV kaldı ($lv+$ev)' : 'Video $rv / $lv kaldı');
                  final audioText = isUnlimited ? 'Ses ∞' : (ea>0 ? 'Ses $ra / $totalA kaldı ($la+$ea)' : 'Ses $ra / $la kaldı');
                  final progressV = isUnlimited ? 1.0 : (totalV==0?0: (rv/totalV).clamp(0,1).toDouble());
                  final progressA = isUnlimited ? 1.0 : (totalA==0?0: (ra/totalA).clamp(0,1).toDouble());
                  return Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer.withOpacity(0.5), borderRadius: BorderRadius.circular(16), border: Border.all(color: Theme.of(context).colorScheme.primary.withOpacity(0.2))), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [Icon(Icons.account_circle_rounded, size:16, color: cs.primary), const SizedBox(width:6), Text('Plan: ${plan.name.toUpperCase()}', style: TextStyle(fontWeight: FontWeight.w900, color: cs.primary, fontSize:12)), const Spacer(), Image.asset('assets/icons/ig_coin.png', width:20, height:20, errorBuilder: (_,__,___)=> const Icon(Icons.monetization_on_rounded, size:20, color: Colors.amber)), const SizedBox(width:4), FutureBuilder<int>(future: SubscriptionService.getCoins(), builder: (c3,s3){
                      final coins = s3.data ?? 0;
                      return Text(isUnlimited ? '∞ Coin' : '$coins Coin', style: const TextStyle(fontWeight: FontWeight.w800, fontSize:13));
                    })]),
                    const SizedBox(height:8),
                    Row(children: [
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [const Icon(Icons.videocam_rounded, size:14), const SizedBox(width:4), Text(videoText, style: const TextStyle(fontWeight: FontWeight.w700, fontSize:12))]), const SizedBox(height:4), LinearProgressIndicator(value: progressV, minHeight:6, borderRadius: BorderRadius.circular(99)) ])),
                      const SizedBox(width:12),
                      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(children: [const Icon(Icons.music_note_rounded, size:14), const SizedBox(width:4), Text(audioText, style: const TextStyle(fontWeight: FontWeight.w700, fontSize:12))]), const SizedBox(height:4), LinearProgressIndicator(value: progressA, minHeight:6, borderRadius: BorderRadius.circular(99), color: Colors.green) ])),
                    ]),
                    const SizedBox(height:6),
                    Text('Kotalar her gün gece yarısı sıfırlanır', style: TextStyle(fontSize:10, color: Colors.grey[600])),
                  ]));
                });
              }),
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
    // DownloadService ile aynı mantık — ilk yazılabilir aday
    try {
      final svc = DownloadService();
      final p = await svc.getDownloadPath();
      return Directory(p);
    } catch (_) {}
    return Directory('/storage/emulated/0/Download/IndirGitsin');
  }
  Future<void> _load() async {
    try {
      List<FileSystemEntity> all = [];
      final seenPaths = <String>{};
      // Tüm aday klasörleri tara (DownloadService.getAllDownloadDirs mantığı)
      final candidates = <String>[
        '/storage/emulated/0/Download/IndirGitsin',
        '/storage/emulated/0/Downloads/IndirGitsin',
      ];
      final custom = await _getDir();
      if (!candidates.contains(custom.path)) candidates.add(custom.path);
      // DownloadService fallback'lerini de ekle
      try {
        final svc = DownloadService();
        for (final d in await svc.getAllDownloadDirs()) {
          if (!candidates.contains(d.path)) candidates.add(d.path);
        }
      } catch (_) {}
      for (final pth in candidates) {
        final dir = Directory(pth);
        if (await dir.exists()) {
          final files = await dir.list(recursive: true).where((e)=> e is File && !e.path.endsWith('.nomedia') && !e.path.contains('/.')).toList();
          for (final f in files) { if (seenPaths.add(f.path)) all.add(f); }
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
    if (ok==true && ctrl.text.isNotEmpty) {
      try {
        final dir = f.parent.path; // aynı klasörde yeniden adlandır
        final newPath = '$dir/${ctrl.text}';
        // uzantı kaybolduysa eskiyi ekle
        if (!newPath.contains('.')) {
          final ext = f.path.split('.').last;
          await f.rename('$newPath.$ext');
        } else {
          await f.rename(newPath);
        }
        _load();
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Yeniden adlandırma hatası: $e')));
      }
    }
  }
  Future<void> _delete(File f) async {
    final ok = await showDialog<bool>(context: context, builder: (c)=> AlertDialog(title: Text('delete_confirm'.tr()), content: Text(f.path.split('/').last), actions: [TextButton(onPressed: ()=> Navigator.pop(c,false), child: Text('cancel'.tr())), FilledButton(onPressed: ()=> Navigator.pop(c,true), child: Text('delete'.tr()))]));
    if (ok==true) { await f.delete(); _load(); }
  }
  Future<void> _pickStorage() async {
    final ctrl = TextEditingController(text: (await _getDir()).path);
    final ok = await showDialog<bool>(context: context, builder: (c)=> AlertDialog(title: Text('choose_storage'.tr()), content: Column(mainAxisSize: MainAxisSize.min, children: [TextField(controller: ctrl, decoration: const InputDecoration(hintText: '/storage/emulated/0/Download/IndirGitsin')), const SizedBox(height:8), Text('storage_desc'.tr(), style: TextStyle(fontSize:11, color: Colors.grey)), const SizedBox(height:6), Text('Özel klasör seçersen Android 11+ için Tüm dosyalar izni istenebilir', style: TextStyle(fontSize:11, color: Colors.orange))]), actions: [TextButton(onPressed: ()=> Navigator.pop(c,false), child: Text('cancel'.tr())), FilledButton(onPressed: ()=> Navigator.pop(c,true), child: Text('save'.tr()))]));
    if (ok==true) {
      final newPath = ctrl.text.trim();
      // Custom path harici Download ise MANAGE_EXTERNAL_STORAGE iste
      if (Platform.isAndroid && newPath != '/storage/emulated/0/Download/IndirGitsin' && newPath.isNotEmpty) {
        try {
          final info = await DeviceInfoPlugin().androidInfo;
          if (info.version.sdkInt >= 30) {
            final st = await Permission.manageExternalStorage.status;
            if (!st.isGranted) await Permission.manageExternalStorage.request();
          }
        } catch (_) {}
      }
      final p=await SharedPreferences.getInstance(); await p.setString('custom_download_path', newPath); _load();
    }
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
      body: _files.isEmpty ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.folder_rounded, size:48, color: Colors.grey[400]), const SizedBox(height:8), Text('no_downloads'.tr()), Text('İndirilenler /Download/IndirGitsin veya seçili klasörde görünür', style: TextStyle(fontSize:11, color: Colors.grey[600])), TextButton(onPressed: _load, child: const Text('Yenile'))])) : RefreshIndicator(onRefresh: _load, child: ListView.separated(itemCount: _files.length, separatorBuilder: (_,__)=> const Divider(height:1), itemBuilder: (c,i){
        final f = _files[i] as File; final name = f.path.split('/').last; final ext = name.split('.').last.toLowerCase(); final isVideo = ['mp4','mkv','webm','avi','mov'].contains(ext); final isAudio = ['mp3','m4a','opus','aac','wav'].contains(ext);
        return ListTile(
          leading: Icon(isVideo ? Icons.videocam_rounded : (isAudio ? Icons.music_note_rounded : Icons.insert_drive_file_rounded), color: Theme.of(context).colorScheme.primary),
          title: Text(name, maxLines:1, overflow: TextOverflow.ellipsis),
          subtitle: Text('${(f.lengthSync()/1024/1024).toStringAsFixed(1)} MB • ${f.statSync().modified.toString().substring(0,16)} • ${ext.toUpperCase()}'),
          trailing: PopupMenuButton<String>(onSelected: (v) async {
            if(v=='play'){ if(isVideo) Navigator.push(context, MaterialPageRoute(builder: (_)=> PlayerPage(path: f.path, title: name))); else await OpenFilex.open(f.path); }
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
  // Şifre doğrulama — hash obscure
  bool _verifyPin(String input, int which) {
    int h = 0; for (int i = 0; i < input.length; i++) { h = (h * 31 + input.codeUnitAt(i)) % 999999; }
    if (which == 1) return h == 955227; // dev.32.eb
    if (which == 2) return h == 182398; // 192.168
    return false;
  }
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
      appBar: AppBar(title: Text('settings'.tr()), actions: [
        Padding(padding: const EdgeInsets.only(right:8), child: FilledButton.tonalIcon(onPressed: () async { await Navigator.push(context, MaterialPageRoute(builder: (_)=> const PlanPage())); setState((){}); }, icon: const Icon(Icons.workspace_premium_rounded, size:16), label: const Text('Planı Yükselt', style: TextStyle(fontSize:11)))),
      ]),
      body: ListView(padding: const EdgeInsets.fromLTRB(16,12,16,24), children: [
        // Plan kartı
        FutureBuilder<PlanType>(future: SubscriptionService.getPlan(), builder: (c,snap){
          final p = snap.data ?? PlanType.free;
          return FutureBuilder<Map<String,int>>(future: SubscriptionService.getRemaining(), builder: (c2,s2){
            final r = s2.data;
            return Card(color: Colors.deepPurple.withOpacity(0.06), child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.deepPurple, borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.workspace_premium_rounded, color: Colors.white)), const SizedBox(width:10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Mevcut Plan: ${p.name.toUpperCase()}', style: const TextStyle(fontWeight: FontWeight.w900)), Text(r==null ? '' : 'Video ${r['video']}/${r['limitVideo']} • Ses ${r['audio']}/${r['limitAudio']}', style: TextStyle(color: Colors.grey[600], fontSize:12))])) , FilledButton(onPressed: () async { await Navigator.push(context, MaterialPageRoute(builder: (_)=> const PlanPage())); setState((){}); }, child: const Text('Değiştir'))]),
              const SizedBox(height:8),
              SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () async { await Navigator.push(context, MaterialPageRoute(builder: (_)=> const MarketPage())); setState((){}); }, icon: const Icon(Icons.storefront_rounded), label: const Text('Markete Git'))),
              FutureBuilder<bool>(future: SubscriptionService.isPlanActive(), builder: (c3,s3){
                if (s3.data==false) return Padding(padding: const EdgeInsets.only(top:8), child: Text('Plan iptal edildi — yeni plan seçmelisin', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w700, fontSize:12)));
                return const SizedBox();
              }),
            ])));
          });
        }),
        const SizedBox(height:12),
        // Tema kartı
        Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: cs.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(12)), child: Icon(Icons.palette_rounded, color: cs.primary)), const SizedBox(width: 10), Text('theme'.tr(), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))]),
          const SizedBox(height: 12),
          FutureBuilder<List<dynamic>>(future: Future.wait([SubscriptionService.getPlan(), SharedPreferences.getInstance()]), builder: (c,snap){
            final plan = snap.data !=null ? snap.data![0] as PlanType : PlanType.free;
            final isDev = snap.data !=null ? (snap.data![1] as SharedPreferences).getBool('dev_mode') ?? false : false;
            final amoledLocked = !isDev && plan==PlanType.free;
            return Wrap(spacing: 8, runSpacing: 8, children: [
              ChoiceChip(label: Text('theme_system'.tr()), selected: mode=='system', onSelected: (_){ ref.read(themeModeProvider.notifier).state='system'; SharedPreferences.getInstance().then((p)=> p.setString('theme_mode','system'));}),
              ChoiceChip(label: Text('theme_light'.tr()), selected: mode=='light', onSelected: (_){ ref.read(themeModeProvider.notifier).state='light'; SharedPreferences.getInstance().then((p)=> p.setString('theme_mode','light'));}),
              ChoiceChip(label: Text('theme_dark'.tr()), selected: mode=='dark', onSelected: (_){ ref.read(themeModeProvider.notifier).state='dark'; SharedPreferences.getInstance().then((p)=> p.setString('theme_mode','dark'));}),
              Tooltip(message: amoledLocked ? 'Free planda kapalı — Plus/Pro veya Dev modunda açılır' : '', child: ChoiceChip(label: Text('theme_amoled'.tr()), selected: mode=='amoled', avatar: Icon(Icons.contrast_rounded, size:16, color: amoledLocked ? Colors.grey : null), onSelected: amoledLocked ? null : (_){ ref.read(themeModeProvider.notifier).state='amoled'; SharedPreferences.getInstance().then((p)=> p.setString('theme_mode','amoled'));}, disabledColor: Colors.grey[300], labelStyle: TextStyle(color: amoledLocked ? Colors.grey : null))),
            ]);
          }),
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
            final p=s.data;
            final planStr = p?.getString('sub_plan') ?? 'free';
            final isDev = p?.getBool('dev_mode') ?? false;
            final isPremium = planStr=='plus' || planStr=='pro' || planStr=='unlimited' || isDev;
            final autoClip = p?.getBool('auto_clipboard') ?? true;
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
              Opacity(opacity: isPremium?1:0.5, child: SwitchListTile(value: autoFolder, title: Text('auto_folder'.tr()), subtitle: Text(isPremium ? 'auto_folder_desc'.tr() : 'Premium — Plus/Pro ile açılır', style: const TextStyle(fontSize:12)), onChanged: isPremium ? (v) async { final pr=await SharedPreferences.getInstance(); await pr.setBool('auto_folder', v); (c as Element).markNeedsBuild(); } : null, contentPadding: EdgeInsets.zero)),
              Opacity(opacity: isPremium?1:0.5, child: SwitchListTile(value: p?.getBool('auto_revoke') ?? false, title: Text('auto_revoke'.tr()), subtitle: Text(isPremium ? 'auto_revoke_desc'.tr() : 'Premium — Plus/Pro ile açılır', style: const TextStyle(fontSize:12)), onChanged: isPremium ? (v) async { final pr=await SharedPreferences.getInstance(); await pr.setBool('auto_revoke', v); (c as Element).markNeedsBuild(); } : null, contentPadding: EdgeInsets.zero)),
              const SizedBox(height: 8),
              Opacity(opacity: isPremium?1:0.5, child: Row(children: [const Icon(Icons.video_settings_rounded, size:16, color: Colors.grey), const SizedBox(width:6), Text(isPremium ? 'default_format'.tr() : 'Varsayılan format (Premium)', style: const TextStyle(fontSize:12, color: Colors.grey)), const Spacer(), DropdownButton<String>(value: defaultFormat, items: [DropdownMenuItem(value:'mp4', child: Text('MP4')), DropdownMenuItem(value:'mp3', child: Text('MP3')), DropdownMenuItem(value:'webm', child: Text('WEBM'))], onChanged: isPremium ? (v) async { if(v==null) return; final pr=await SharedPreferences.getInstance(); await pr.setString('default_format', v); (c as Element).markNeedsBuild(); } : null)])),

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
        // Geliştirici Test Modu - Hakkında üstünde, normalde kapalı
        Card(
          color: Colors.deepPurple.withOpacity(0.06),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: FutureBuilder<SharedPreferences>(
              future: SharedPreferences.getInstance(),
              builder: (c, snap) {
                final isDev = snap.data?.getBool('dev_mode') ?? false;
                return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.deepPurple.withOpacity(0.12), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.bug_report_rounded, color: Colors.deepPurple)),
                    const SizedBox(width: 10),
                    Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Geliştirici Test Modu', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))])),
                    Switch(
                      value: isDev,
                      onChanged: (v) async {
                        final prefs = await SharedPreferences.getInstance();
                        final isLocked = prefs.getBool('dev_mode_locked') ?? false;
                        if (v) {
                          // Eğer kilitliyse 2. şifre sor
                          if (isLocked) {
                            final pin2Ctrl = TextEditingController();
                            final ok2 = await showDialog<bool>(
                              context: context,
                              builder: (d) => AlertDialog(
                                title: const Text('Şifre Gerekli'),
                                content: Column(mainAxisSize: MainAxisSize.min, children: [
                                  const Text('Devam etmek için şifre girin'),
                                  const SizedBox(height: 12),
                                  TextField(controller: pin2Ctrl, keyboardType: TextInputType.text, decoration: const InputDecoration(hintText: '••••', border: OutlineInputBorder()), obscureText: true),
                                ]),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(d, false), child: Text('cancel'.tr())),
                                  FilledButton(onPressed: () => Navigator.pop(d, _verifyPin(pin2Ctrl.text, 2)), child: const Text('Onayla')),
                                ],
                              ),
                            );
                            if (ok2 == true) {
                              await prefs.setBool('dev_mode_locked', false);
                              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kilit açıldı, tekrar deneyin'), backgroundColor: Colors.green));
                            } else {
                              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Yanlış şifre'), backgroundColor: Colors.red));
                            }
                            return;
                          }
                          // Normal 1. şifre sor
                          final pinCtrl = TextEditingController();
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (d) => AlertDialog(
                              title: const Text('Şifre Girin'),
                              content: Column(mainAxisSize: MainAxisSize.min, children: [
                                const Text('Geliştirici modunu açmak için şifre girin'),
                                const SizedBox(height: 12),
                                TextField(controller: pinCtrl, keyboardType: TextInputType.text, decoration: const InputDecoration(hintText: '••••', border: OutlineInputBorder()), obscureText: true),
                              ]),
                              actions: [
                                TextButton(onPressed: () => Navigator.pop(d, false), child: Text('cancel'.tr())),
                                FilledButton(onPressed: () => Navigator.pop(d, _verifyPin(pinCtrl.text, 1)), child: const Text('Onayla')),
                              ],
                            ),
                          );
                          if (ok == true) {
                            // Uyarı dialog'u (düzgün Türkçe)
                            final approved = await showDialog<bool>(
                              context: context,
                              builder: (d) => AlertDialog(
                                title: Row(children: [const Icon(Icons.warning_rounded, color: Colors.red), const SizedBox(width:8), const Text('Dikkat!')]),
                                content: SingleChildScrollView(child: Text(
                                  'Bu mod sadece test amaçlı kullanılmalıdır.\n\n'
                                  'Uygulamaya veya telefonunuza geri dönülemez zarar verebilir. Olası hasar veya yazılımsal olarak ortaya çıkabilecek hiçbir hatanın sorumluluğu bize ait değildir.\n\n'
                                  '• Yapılan işlemler geri alınamaz, veriler silinebilir\n'
                                  '• Cihazınızda kararsızlık veya veri kaybı oluşabilir\n'
                                  '• Lütfen dikkatli kullanın ve bilmediğiniz ayarları değiştirmeyin',
                                  style: TextStyle(color: Colors.grey[800], height: 1.4),
                                )),
                                actions: [
                                  TextButton(onPressed: () => Navigator.pop(d, false), child: Text('cancel'.tr())),
                                  FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('ONAYLIYORUM'), style: FilledButton.styleFrom(backgroundColor: Colors.red)),
                                ],
                              ),
                            );
                            if (approved != true) return;
                            // Kırmızı bildirim (siyah yazı)
                            try {
                              final androidDetails = AndroidNotificationDetails(
                                'dev_mode_channel',
                                'Geliştirici Modu',
                                channelDescription: 'Geliştirici modu uyarısı',
                                importance: Importance.high,
                                priority: Priority.high,
                                color: const Color(0xFFFF0000),
                                icon: '@mipmap/launcher_icon',
                              );
                              await NotificationService.showCustom(
                                title: 'DİKKAT: _GELİŞTİRİCİ_TEST_MODU:TRUE',
                                body: 'Geliştirici modu aktif',
                                color: Colors.red,
                              );
                              // Alternatif: SnackBar ile de göster
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('DİKKAT: _GELİŞTİRİCİ_TEST_MODU:TRUE', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w800)), backgroundColor: Colors.red, duration: Duration(seconds: 4)));
                              }
                            } catch (_) {}
                            // Onaylandıysa mod aktif - sadece kırmızı bildirim (logo ile), ayarlar kaydedildi bildirimi yok
                            await prefs.setBool('dev_mode', true);
                            (c as Element).markNeedsBuild();
                          } else {
                            // Yanlış şifre -> kilitle
                            await prefs.setBool('dev_mode_locked', true);
                            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Yanlış şifre'), backgroundColor: Colors.red, duration: Duration(seconds: 2)));
                          }
                        } else {
                          final p = await SharedPreferences.getInstance();
                          await p.setBool('dev_mode', false);
                          (c as Element).markNeedsBuild();
                        }
                      },
                    ),
                  ]),
                  if (isDev) ...[
                    const Divider(height: 16),
                    Text('Test Araçları', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.deepPurple[700], fontSize: 13)),
                    const SizedBox(height: 8),
                    Wrap(spacing: 8, runSpacing: 8, children: [
                      ActionChip(label: const Text('İlk kurulumu simüle et'), avatar: const Icon(Icons.restart_alt_rounded, size:16), onPressed: () async {
                        final p = await SharedPreferences.getInstance();
                        await p.remove('first_launch_done');
                        await p.remove('last_update_check');
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sıfırlandı - uygulamayı yeniden başlat, ilk kurulum ekranı gelecek')));
                      }),
                      ActionChip(label: const Text('Önbelleği temizle'), avatar: const Icon(Icons.cleaning_services_rounded, size:16), onPressed: () async {
                        await StorageService.search.clear();
                        ref.read(youtubeServiceProvider).clearCache();
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Önbellek temizlendi')));
                      }),
                      ActionChip(label: const Text('Tüm verileri sıfırla'), avatar: const Icon(Icons.delete_forever_rounded, size:16), onPressed: () async {
                        await StorageService.history.clear();
                        await StorageService.fav.clear();
                        await StorageService.search.clear();
                        await SubscriptionService.resetAllToZero();
                        // reset sonrası günlük 10 coin ver (ilk giriş)
                        await SubscriptionService.addCoins(10);
                        final p = await SharedPreferences.getInstance();
                        await p.setString('sub_last_daily', '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2,'0')}-${DateTime.now().day.toString().padLeft(2,'0')}');
                        if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Tüm veriler sıfırlandı — Coin/Hak 0, günlük 10 Coin verildi')));
                        (c as Element).markNeedsBuild();
                      }),
                    ]),
                    const SizedBox(height: 8),
                    Text('Dev Coin & Plan Araçları', style: TextStyle(fontWeight: FontWeight.w700, color: Colors.red[700], fontSize:13)),
                    const SizedBox(height:6),
                    FutureBuilder<int>(future: SubscriptionService.getCoins(), builder: (c2,s2)=> Text('Mevcut Coin: ${s2.data??0}', style: const TextStyle(fontWeight: FontWeight.w800))),
                    const SizedBox(height:6),
                    Wrap(spacing:8, runSpacing:8, children: [
                      FilledButton.icon(onPressed: () async {
                        final ctrl = TextEditingController();
                        final v = await showDialog<int>(context: context, builder: (d)=> AlertDialog(title: const Text('Coin Ekle'), content: TextField(controller: ctrl, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'Miktar', border: OutlineInputBorder())), actions: [TextButton(onPressed: ()=> Navigator.pop(d), child: Text('cancel'.tr())), FilledButton(onPressed: (){ final n=int.tryParse(ctrl.text) ?? 0; Navigator.pop(d, n); }, child: const Text('Ekle'))]));
                        if (v!=null && v>0) { await SubscriptionService.addCoins(v); (c as Element).markNeedsBuild(); if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('+$v Coin'))); }
                      }, icon: const Icon(Icons.add_rounded), label: const Text('Coin Ekle')),
                      FilledButton.icon(onPressed: () async {
                        final ctrl = TextEditingController();
                        final v = await showDialog<int>(context: context, builder: (d)=> AlertDialog(title: const Text('Coin Sil'), content: TextField(controller: ctrl, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'Miktar', border: OutlineInputBorder())), actions: [TextButton(onPressed: ()=> Navigator.pop(d), child: Text('cancel'.tr())), FilledButton(onPressed: (){ final n=int.tryParse(ctrl.text) ?? 0; Navigator.pop(d, n); }, child: const Text('Sil'))]));
                        if (v!=null && v>0) { await SubscriptionService.removeCoins(v); (c as Element).markNeedsBuild(); if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('-$v Coin'))); }
                      }, icon: const Icon(Icons.remove_rounded), label: const Text('Coin Sil')),
                      FilledButton.tonalIcon(onPressed: () async { await SubscriptionService.selectPlan(PlanType.unlimited); (c as Element).markNeedsBuild(); if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Sınırsız Plan aktif'))); }, icon: const Icon(Icons.all_inclusive_rounded), label: const Text('Sınırsız Aktif')),
                      OutlinedButton.icon(onPressed: () async { await SubscriptionService.selectPlan(PlanType.free); (c as Element).markNeedsBuild(); }, icon: const Icon(Icons.restart_alt_rounded), label: const Text('Free Yap')),
                      FilledButton.tonalIcon(onPressed: () async { await Navigator.push(context, MaterialPageRoute(builder: (_)=> const PlanPage())); (c as Element).markNeedsBuild(); }, icon: const Icon(Icons.workspace_premium_rounded), label: const Text('Plan Seç')),
                      FilledButton.tonalIcon(onPressed: () async { await Navigator.push(context, MaterialPageRoute(builder: (_)=> const MarketPage())); }, icon: const Icon(Icons.storefront_rounded), label: const Text('Markete Git')),
                    ]),
                    const SizedBox(height: 6),
                    Text('Hata detayları artık 404 gibi teknik kodlarla gösterilecek + Plus/Pro ve sınırsız devde ücretsiz seçilebilir, tüm gri ayarlar açılır', style: TextStyle(color: Colors.grey[600], fontSize: 11)),
                  ],
                ]);
              },
            ),
          ),
        ),
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
