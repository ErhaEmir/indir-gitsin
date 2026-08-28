import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

class PlayerPage extends StatefulWidget {
  final String path;
  final String title;
  const PlayerPage({super.key, required this.path, required this.title});
  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  late VideoPlayerController _vc;
  ChewieController? _chewie;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final file = File(widget.path);
      if (!await file.exists()) { setState(() => _error = true); return; }
      // video mu audio mu?
      _vc = VideoPlayerController.file(file);
      await _vc.initialize();
      _chewie = ChewieController(
        videoPlayerController: _vc,
        autoPlay: true,
        looping: false,
        showControls: true,
        materialProgressColors: ChewieProgressColors(playedColor: Theme.of(context).colorScheme.primary),
        placeholder: Center(child: Text(widget.title)),
      );
      setState(() {});
    } catch (_) {
      setState(() => _error = true);
    }
  }

  @override
  void dispose() {
    _chewie?.dispose();
    _vc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: _error
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.error_rounded, size: 48), const SizedBox(height: 12), Text('Oynatılamadı: ${widget.path.split('/').last}'), const SizedBox(height: 12), Text('Ses dosyası ise sistem oynatıcısıyla açmayı deneyin', style: TextStyle(color: Colors.grey[600]))]))
          : _chewie == null
              ? const Center(child: CircularProgressIndicator())
              : Chewie(controller: _chewie!),
    );
  }
}
