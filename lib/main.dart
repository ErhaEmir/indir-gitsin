import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:open_filex/open_filex.dart';
import 'core/theme.dart';
import 'core/youtube_service.dart';
import 'core/download_service.dart';

// Providerlar
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

class _HomePageState extends ConsumerState<HomePage> {
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

  @override
  void initState() {
    super.initState();
    _listenShareIntent();
    // Clipboard otomatik algılama
    _checkClipboard();
  }

  Future<void> _checkClipboard() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text ?? '';
    if (YoutubeService.isValidYoutubeUrl(text)) {
      _linkCtrl.text = text;
      _fetch();
    }
  }

  void _listenShareIntent() {
    // Uygulama kapalıyken gelen paylaşım
    ReceiveSharingIntent.instance.getInitialText().then((value) {
      if (value != null && YoutubeService.isValidYoutubeUrl(value)) {
        _linkCtrl.text = value;
        _fetch();
      }
    });
    // Uygulama açıkken gelen paylaşım
    _intentSub = ReceiveSharingIntent.instance.getTextStream().listen((value) {
      if (YoutubeService.isValidYoutubeUrl(value)) {
        _linkCtrl.text = value;
        _fetch();
      }
    }, onError: (e) => debugPrint('intent error $e'));
  }

  @override
  void dispose() {
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
    setState(() {
      _loading = true;
      _error = null;
      _video = null;
      _selected = null;
      _savedPath = null;
    });
    try {
      final info = await ref.read(youtubeServiceProvider).getVideoInfo(url);
      setState(() {
        _video = info;
        _selected = info.streams.isNotEmpty ? info.streams.first : null;
      });
    } catch (e) {
      setState(() => _error = 'Video bilgisi alınamadı: $e');
    } finally {
      setState(() => _loading = false);
    }
  }

  Future<void> _download() async {
    if (_video == null || _selected == null) return;
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
          if (total > 0) setState(() => _progress = rx / total);
        },
      );
      setState(() {
        _savedPath = path;
        _downloading = false;
        _progress = 1;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('İndirildi: $path'),
            action: SnackBarAction(label: 'AÇ', onPressed: () => OpenFilex.open(path)),
            behavior: SnackBarBehavior.floating,
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

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: cs.primary, borderRadius: BorderRadius.circular(12)),
            child: const Icon(Icons.download_rounded, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 10),
          const Text('İndir Gitsin', style: TextStyle(fontWeight: FontWeight.w800)),
        ]),
        actions: [
          IconButton(icon: const Icon(Icons.history_rounded), onPressed: () => _showHistory()),
          const SizedBox(width: 4),
        ],
      ),
      body: CustomScrollView(
        controller: _scrollCtrl,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            sliver: SliverList.list(children: [
              // Hero kart
              Container(
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [cs.primary, cs.primary.withOpacity(0.85)]),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('YouTube & Music', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700, fontSize: 16)),
                      const SizedBox(height: 4),
                      Text('Linki yapıştır veya YouTube\'dan Paylaş → İndir Gitsin',
                          style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 13)),
                      const SizedBox(height: 12),
                      Row(children: [
                        _chip('MP4', Icons.videocam_rounded),
                        const SizedBox(width: 8),
                        _chip('MP3', Icons.music_note_rounded),
                        const SizedBox(width: 8),
                        _chip('4K', Icons.high_quality_rounded),
                      ]),
                    ]),
                  ),
                  const Icon(Icons.play_circle_fill_rounded, color: Colors.white, size: 54),
                ]),
              ),
              const SizedBox(height: 18),
              // Link input
              TextField(
                controller: _linkCtrl,
                decoration: InputDecoration(
                  hintText: 'https://www.youtube.com/watch?v= ...',
                  prefixIcon: const Icon(Icons.link_rounded),
                  suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(icon: const Icon(Icons.content_paste_rounded), onPressed: _paste, tooltip: 'Yapıştır'),
                    const SizedBox(width: 4),
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilledButton.icon(
                        onPressed: _loading ? null : _fetch,
                        icon: _loading
                            ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.search_rounded, size: 18),
                        label: const Text('Getir'),
                      ),
                    ),
                  ]),
                  filled: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16), borderSide: BorderSide.none),
                ),
                onSubmitted: (_) => _fetch(),
              ),
              const SizedBox(height: 10),
              // Yardım metni
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: cs.secondaryContainer, borderRadius: BorderRadius.circular(14)),
                child: Row(children: [
                  Icon(Icons.share_rounded, size: 18, color: cs.onSecondaryContainer),
                  const SizedBox(width: 8),
                  Expanded(
                      child: Text('YouTube uygulamasında Paylaş → İndir Gitsin seçeneği de çalışır',
                          style: TextStyle(fontSize: 12, color: cs.onSecondaryContainer))),
                ]),
              ),
              const SizedBox(height: 16),
              if (_error != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(color: cs.errorContainer, borderRadius: BorderRadius.circular(14)),
                  child: Row(children: [
                    Icon(Icons.error_outline_rounded, color: cs.onErrorContainer),
                    const SizedBox(width: 8),
                    Expanded(child: Text(_error!, style: TextStyle(color: cs.onErrorContainer))),
                  ]),
                ),
              if (_loading) ...[
                const SizedBox(height: 16),
                _shimmerCard(),
              ],
              if (_video != null) ...[
                const SizedBox(height: 8),
                _videoCard(context),
                const SizedBox(height: 16),
                Text('İndirme Seçenekleri', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 8),
                Text('YouTube & YouTube Music videoları aynı kalitede indirilir', style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 12),
                ..._video!.streams.map((s) => _streamTile(s, cs)),
                const SizedBox(height: 16),
                if (_downloading)
                  Column(children: [
                    LinearProgressIndicator(value: _progress, borderRadius: BorderRadius.circular(8), minHeight: 8),
                    const SizedBox(height: 8),
                    Text('%${(_progress * 100).toStringAsFixed(0)} indiriliyor...'),
                  ]),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _downloading ? null : _download,
                    icon: Icon(_savedPath != null ? Icons.check_circle_rounded : Icons.download_rounded),
                    label: Text(_savedPath != null ? 'Tekrar İndir' : 'Seçili Kaliteyi İndir'),
                  ),
                ),
                if (_savedPath != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: OutlinedButton.icon(
                      onPressed: () => OpenFilex.open(_savedPath!),
                      icon: const Icon(Icons.play_arrow_rounded),
                      label: Text('Dosyayı Aç: ${_savedPath!.split('/').last}'),
                    ),
                  ),
              ],
              if (!_loading && _video == null && _error == null) ...[
                const SizedBox(height: 24),
                _emptyState(context),
              ],
            ]),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: Text('İndir Gitsin • İndirilenler: /Download/IndirGitsin • v1.0.0',
              textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Colors.grey)),
        ),
      ),
    );
  }

  Widget _chip(String t, IconData i) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(color: Colors.white.withOpacity(0.18), borderRadius: BorderRadius.circular(99)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(i, size: 14, color: Colors.white),
          const SizedBox(width: 4),
          Text(t, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
      );

  Widget _videoCard(BuildContext context) {
    final v = _video!;
    final dur = v.duration != null ? _fmtDur(v.duration!) : '';
    return Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Stack(children: [
          ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            child: CachedNetworkImage(imageUrl: v.thumbnailUrl, height: 200, width: double.infinity, fit: BoxFit.cover),
          ),
          Positioned(
            bottom: 10,
            right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: Colors.black87, borderRadius: BorderRadius.circular(8)),
              child: Text(dur, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
            ),
          ),
        ]),
        Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(v.title, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15), maxLines: 2, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 6),
            Row(children: [
              Icon(Icons.person_rounded, size: 16, color: Theme.of(context).colorScheme.primary),
              const SizedBox(width: 4),
              Expanded(child: Text(v.author, style: TextStyle(fontSize: 13, color: Colors.grey[700]))),
              if (v.viewCount != null) ...[
                const Icon(Icons.visibility_rounded, size: 14, color: Colors.grey),
                const SizedBox(width: 4),
                Text(_fmtViews(v.viewCount!), style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ]),
          ]),
        ),
      ]),
    );
  }

  Widget _streamTile(StreamOption s, ColorScheme cs) {
    final selected = _selected?.tag == s.tag && _selected?.type == s.type;
    IconData icon;
    Color col;
    String badge;
    if (s.type == 'muxed') {
      icon = Icons.hd_rounded;
      col = cs.primary;
      badge = 'Video+Ses';
    } else if (s.type == 'videoOnly') {
      icon = Icons.videocam_outlined;
      col = Colors.orange;
      badge = 'Sadece Video';
    } else {
      icon = Icons.music_note_rounded;
      col = Colors.green;
      badge = 'Sadece Ses';
    }
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        border: Border.all(color: selected ? cs.primary : Colors.grey.withOpacity(0.2), width: selected ? 2 : 1),
        borderRadius: BorderRadius.circular(16),
        color: selected ? cs.primaryContainer.withOpacity(0.5) : Theme.of(context).cardColor,
      ),
      child: RadioListTile<StreamOption>(
        value: s,
        groupValue: _selected,
        onChanged: (v) => setState(() => _selected = v),
        secondary: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(color: col.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
          child: Icon(icon, color: col),
        ),
        title: Text(s.qualityLabel, style: const TextStyle(fontWeight: FontWeight.w700)),
        subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const SizedBox(height: 2),
          Row(children: [
            Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(99)),
                child: Text(badge, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700))),
            const SizedBox(width: 6),
            Text('${s.container.toUpperCase()} • ${s.sizeLabel}', style: const TextStyle(fontSize: 12)),
          ]),
        ]),
        activeColor: cs.primary,
      ),
    );
  }

  Widget _shimmerCard() => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            Container(height: 16, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(8))),
            const SizedBox(height: 10),
            Container(height: 16, width: 180, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(8))),
          ]),
        ),
      );

  Widget _emptyState(BuildContext context) => Column(children: [
        Icon(Icons.download_for_offline_rounded, size: 72, color: Theme.of(context).colorScheme.primary.withOpacity(0.3)),
        const SizedBox(height: 12),
        Text('Henüz bir video seçilmedi', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        Text('YouTube veya YouTube Music linkini yukarıya yapıştır,\nveya YouTube uygulamasından Paylaş → İndir Gitsin yap',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.grey[600], fontSize: 13)),
        const SizedBox(height: 16),
        Wrap(spacing: 8, runSpacing: 8, children: [
          ActionChip(label: const Text('Demo linki dene'), avatar: const Icon(Icons.play_arrow_rounded, size: 18), onPressed: () {
            _linkCtrl.text = 'https://www.youtube.com/watch?v=jNQXAC9IVRw';
            _fetch();
          }),
          ActionChip(label: const Text('Music linki dene'), avatar: const Icon(Icons.music_note_rounded, size: 18), onPressed: () {
            _linkCtrl.text = 'https://music.youtube.com/watch?v=jNQXAC9IVRw';
            _fetch();
          }),
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
          if (_savedPath == null)
            const Padding(padding: EdgeInsets.all(24), child: Text('Henüz indirme yok', style: TextStyle(color: Colors.grey)))
          else
            ListTile(
              leading: const Icon(Icons.video_file_rounded),
              title: Text(_savedPath!.split('/').last),
              subtitle: Text(_savedPath!),
              trailing: IconButton(icon: const Icon(Icons.open_in_new_rounded), onPressed: () => OpenFilex.open(_savedPath!)),
            ),
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
