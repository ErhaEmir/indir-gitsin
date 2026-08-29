import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';

class NetworkPlayerPage extends StatefulWidget {
  final String url;
  final String title;
  const NetworkPlayerPage({super.key, required this.url, required this.title});
  @override
  State<NetworkPlayerPage> createState()=> _NetworkPlayerPageState();
}

class _NetworkPlayerPageState extends State<NetworkPlayerPage> {
  late VideoPlayerController _vc;
  ChewieController? _chewie;
  bool _error=false;
  @override
  void initState(){
    super.initState();
    _vc = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _vc.initialize().then((_) {
      _chewie = ChewieController(videoPlayerController: _vc, autoPlay: true, showControls: true);
      setState((){});
    }).catchError((e){ setState(()=> _error=true); });
  }
  @override
  void dispose(){ _chewie?.dispose(); _vc.dispose(); super.dispose();}
  @override
  Widget build(BuildContext context){
    return Scaffold(
      appBar: AppBar(title: Text(widget.title, maxLines:1, overflow: TextOverflow.ellipsis)),
      body: _error ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.error_rounded, size:48, color: Colors.red), const SizedBox(height:8), const Text('Oynatılamadı - YouTube direkt oynatma kısıtlı olabilir'), const SizedBox(height:8), Text(widget.url, style: const TextStyle(fontSize:10, color: Colors.grey))])) : _chewie==null ? const Center(child: CircularProgressIndicator()) : Chewie(controller: _chewie!),
    );
  }
}
