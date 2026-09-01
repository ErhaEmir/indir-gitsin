import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:easy_localization/easy_localization.dart';
import '../../core/youtube_service.dart';
import '../../core/subscription_service.dart';

class ExplorePage extends StatefulWidget {
  final void Function(String url) onSelect;
  const ExplorePage({super.key, required this.onSelect});
  @override State<ExplorePage> createState()=> _ExplorePageState();
}

class _ExplorePageState extends State<ExplorePage> {
  List<Map<String,dynamic>> _all = [];
  List<Map<String,dynamic>> _filtered = [];
  bool _loading = true;
  String _cat = 'music';
  final _cats = ['music','trending','gaming','news','live'];
  // kategori bazlı cache
  final Map<String, List<Map<String,dynamic>>> _cache = {};

  @override void initState(){ super.initState(); _load(); }

  int _limitForPlan(PlanType p){
    switch(p){
      case PlanType.free: return 30;
      case PlanType.plus: return 40;
      case PlanType.pro: return 100;
      case PlanType.unlimited: return 150;
    }
  }

  List<Map<String,dynamic>> _base = [];
  Future<void> _load() async {
    setState(()=> _loading=true);
    try {
      final plan = await SubscriptionService.getPlan();
      final limit = _limitForPlan(plan);

      if (_cache.containsKey(_cat) && _cache[_cat]!.isNotEmpty) {
        _all = _cache[_cat]!;
        _filtered = _all.take(limit).toList();
        setState(()=> _loading=false);
        return;
      }

      if (_base.isEmpty) {
        _base = await YoutubeService().getTrendingMusic();
        // yavaş değil — tek sefer fetch, sonra kategori türevleri local
      }
      List<Map<String,dynamic>> list = List<Map<String,dynamic>>.from(_base);
      // kategori bazlı hızlı farklılaştırma (ağ yok)
      if (_cat=='gaming') {
        list = list.reversed.toList();
      } else if (_cat=='news') {
        list.sort((a,b)=> (b['views'] as int? ?? 0).compareTo(a['views'] as int? ?? 0));
      } else if (_cat=='live') {
        list.shuffle();
        list = list..shuffle();
      } else if (_cat=='trending') {
        list.shuffle();
      }
      list.shuffle(); // her kategori için farklı seed etkisi

      if (list.length < limit && list.isNotEmpty) {
        final extra = List<Map<String,dynamic>>.from(list);
        list = [...list, ...extra];
        list.shuffle();
      }
      _cache[_cat] = list;
      _all = list;
      _filtered = _all.take(limit).toList();
    } catch(e){
      if(mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${'trending_load_failed'.tr()}: $e')));
    }
    setState(()=> _loading=false);
  }

  void _onCat(String c){
    setState(()=> _cat=c);
    _load();
  }

  @override
  Widget build(BuildContext context){
    return Scaffold(
      appBar: AppBar(title: Text('explore'.tr()), actions: [IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: _load)]),
      body: Column(children: [
        SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal:12, vertical:8), child: Row(children: _cats.map((c)=> Padding(padding: const EdgeInsets.only(right:8), child: ChoiceChip(label: Text(c.toUpperCase(), style: const TextStyle(fontSize:12, fontWeight: FontWeight.w700)), selected: _cat==c, onSelected: (_){ _onCat(c); })) ).toList())),
        FutureBuilder<PlanType>(future: SubscriptionService.getPlan(), builder: (c,snap){
          final p = snap.data ?? PlanType.free;
          final lim = _limitForPlan(p);
          return Padding(padding: const EdgeInsets.symmetric(horizontal:12), child: Row(children: [Icon(Icons.explore_rounded, size:14, color: Colors.grey[600]), const SizedBox(width:4), Text('${_filtered.length}/$lim video • ${_cat.toUpperCase()} • ${p.name.toUpperCase()}', style: TextStyle(color: Colors.grey[600], fontSize:11, fontWeight: FontWeight.w600)), const Spacer(), TextButton.icon(onPressed: _load, icon: const Icon(Icons.shuffle_rounded, size:16), label: const Text('Karıştır', style: TextStyle(fontSize:12)))]));
        }),
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
