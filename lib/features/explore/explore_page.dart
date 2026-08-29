import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:easy_localization/easy_localization.dart';
import '../../core/youtube_service.dart';

class ExplorePage extends StatefulWidget {
  final void Function(String url) onSelect;
  const ExplorePage({super.key, required this.onSelect});
  @override State<ExplorePage> createState()=> _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  List<Map<String,dynamic>> _trending = [];
  bool _loading = true;
  @override
  void initState(){ super.initState(); _load(); }
  Future<void> _load() async {
    setState(()=> _loading=true);
    try {
      final list = await YoutubeService().getTrending();
      setState(()=> _trending=list);
    } catch(e){
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Trend yüklenemedi: $e')));
    }
    setState(()=> _loading=false);
  }
  @override
  Widget build(BuildContext context){
    return Scaffold(
      appBar: AppBar(title: Text('Keşfet'.tr()), actions: [IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _load)]),
      body: _loading ? const Center(child: CircularProgressIndicator()) : _trending.isEmpty ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.explore_rounded, size:48, color: Colors.grey), const SizedBox(height:8), Text('Trend yüklenemedi', style: TextStyle(color: Colors.grey[600])), TextButton(onPressed: _load, child: const Text('Tekrar dene'))])) : RefreshIndicator(
        onRefresh: _load,
        child: GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 0.78, crossAxisSpacing: 12, mainAxisSpacing: 12),
          itemCount: _trending.length,
          itemBuilder: (_,i){
            final v=_trending[i];
            return InkWell(
              onTap: ()=> widget.onSelect('https://www.youtube.com/watch?v=${v['id']}'),
              borderRadius: BorderRadius.circular(16),
              child: Card(
                clipBehavior: Clip.antiAlias,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  AspectRatio(aspectRatio: 16/9, child: CachedNetworkImage(imageUrl: v['thumbnail']??'', fit: BoxFit.cover, errorWidget: (_,__,___)=> Container(color: Colors.grey[300]))),
                  Padding(padding: const EdgeInsets.all(8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(v['title']??'', maxLines:2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize:12)),
                    const SizedBox(height:4),
                    Text(v['author']??'', maxLines:1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.grey[600], fontSize:11)),
                    const SizedBox(height:4),
                    Row(children: [Icon(Icons.visibility_rounded, size:12, color: Colors.grey[500]), const SizedBox(width:4), Text('${v['views']??0}', style: TextStyle(color: Colors.grey[500], fontSize:11)), const Spacer(), Container(padding: const EdgeInsets.symmetric(horizontal:6, vertical:2), decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(99)), child: const Text('İNDİR', style: TextStyle(color: Colors.white, fontSize:10, fontWeight: FontWeight.w800)))]),
                  ])),
                ]),
              ),
            );
          },
        ),
      ),
    );
  }
}
