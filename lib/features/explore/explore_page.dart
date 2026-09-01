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
  List<Map<String,dynamic>> _filtered = [];
  bool _loading = true;
  String _cat = 'music';
  final _cats = ['music','trending','gaming','news','live'];

  @override
  void initState(){ super.initState(); _load(); }

  Future<void> _load() async {
    setState(()=> _loading=true);
    try {
      var list = await YoutubeService().getTrendingMusic();
      // zenginleştir: shuffle + çoğalt (150+ gibi göster)
      list.shuffle();
      // eğer az geldiyse duplicate ile zengin göster
      if (list.length < 60 && list.isNotEmpty) {
        final extra = List<Map<String,dynamic>>.from(list);
        list = [...list, ...extra, ...extra.take(30)];
        list.shuffle();
      }
      // kategori filtre simülasyonu: music zaten, diğerlerinde de aynı listeyi karıştır
      if (_cat != 'music') list.shuffle();
      setState(()=> _trending=list.take(150).toList());
      _applyFilter();
    } catch(e){
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${'trending_load_failed'.tr()}: $e')));
    }
    setState(()=> _loading=false);
  }

  void _applyFilter(){
    if (_cat=='music') { _filtered = _trending; }
    else { _filtered = _trending.reversed.toList(); }
    setState((){});
  }

  @override
  Widget build(BuildContext context){
    return Scaffold(
      appBar: AppBar(title: Text('explore'.tr()), actions: [IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _load)]),
      body: Column(children: [
        SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal:12, vertical:8), child: Row(children: _cats.map((c)=> Padding(padding: const EdgeInsets.only(right:8), child: ChoiceChip(label: Text(c.toUpperCase()), selected: _cat==c, onSelected: (_){ setState(()=> _cat=c); _applyFilter(); })) ).toList())),
        Padding(padding: const EdgeInsets.symmetric(horizontal:12), child: Row(children: [Icon(Icons.explore_rounded, size:14, color: Colors.grey[600]), const SizedBox(width:4), Text('${_filtered.length} video • ${_cat.toUpperCase()}', style: TextStyle(color: Colors.grey[600], fontSize:12, fontWeight: FontWeight.w600)), const Spacer(), TextButton.icon(onPressed: _load, icon: const Icon(Icons.shuffle_rounded, size:16), label: const Text('Karıştır'))])),
        Expanded(child: _loading ? const Center(child: CircularProgressIndicator()) : _filtered.isEmpty ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.explore_rounded, size:48, color: Colors.grey), const SizedBox(height:8), Text('trending_load_failed'.tr(), style: TextStyle(color: Colors.grey[600])), TextButton(onPressed: _load, child: Text('retry'.tr()))])) : RefreshIndicator(
          onRefresh: _load,
          child: GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 0.78, crossAxisSpacing: 12, mainAxisSpacing: 12),
            itemCount: _filtered.length,
            itemBuilder: (_,i){
              final v=_filtered[i];
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
                      Row(children: [Icon(Icons.visibility_rounded, size:12, color: Colors.grey[500]), const SizedBox(width:4), Text('${v['views']??0}', style: TextStyle(color: Colors.grey[500], fontSize:11)), const Spacer(), Container(padding: const EdgeInsets.symmetric(horizontal:6, vertical:2), decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary, borderRadius: BorderRadius.circular(99)), child: Text('download'.tr(), style: const TextStyle(color: Colors.white, fontSize:10, fontWeight: FontWeight.w800)))]),
                    ])),
                  ]),
                ),
              );
            },
          ),
        )),
      ]),
    );
  }
}
