import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shimmer/shimmer.dart';
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
      case PlanType.unlimited: return 999;
    }
  }

  List<Map<String,dynamic>> _base = [];
  PlanType? _cachedPlan;
  Future<void> _load({bool force=false}) async {
    if (force) {
      _cache.remove(_cat);
      if (_cat=='music') _base.clear();
    }
    setState(()=> _loading=true);
    try {
      final plan = await SubscriptionService.getPlan();
      final limit = _limitForPlan(plan);
      if (_cachedPlan != null && _cachedPlan != plan) {
        _cache.clear();
        _base.clear();
      }
      _cachedPlan = plan;

      if (!force && _cache.containsKey(_cat) && _cache[_cat]!.isNotEmpty) {
        _all = _cache[_cat]!;
        var list = List<Map<String,dynamic>>.from(_all);
        // limit değiştiyse base ile doldur
        if (list.length < limit && _base.isNotEmpty) {
          list = [...list, ..._base.take(limit - list.length)];
        }
        list.shuffle();
        _filtered = plan==PlanType.unlimited ? list : list.take(limit).toList();
        setState(()=> _loading=false);
        return;
      }

      List<Map<String,dynamic>> list = [];
      final svc = YoutubeService();
      if (_cat=='music') {
        if (_base.isEmpty) _base = await svc.getTrendingMusic();
        list = List<Map<String,dynamic>>.from(_base);
      } else if (_cat=='trending') {
        try {
          final res = await svc.search('trending Turkey 2024');
          list = res.map((v)=> {'id': v.id, 'title': v.title, 'thumbnail': v.thumbnailUrl, 'author': v.author, 'views': v.viewCount ?? 0}).toList();
        } catch (_){}
        if (list.isEmpty) {
          if (_base.isEmpty) _base = await svc.getTrendingMusic();
          list = List<Map<String,dynamic>>.from(_base);
          list.shuffle();
        }
      } else if (_cat=='gaming') {
        try {
          final res = await svc.search('gaming Turkey');
          list = res.map((v)=> {'id': v.id, 'title': v.title, 'thumbnail': v.thumbnailUrl, 'author': v.author, 'views': v.viewCount ?? 0}).toList();
        } catch (_){}
        if (list.isEmpty) {
          if (_base.isEmpty) _base = await svc.getTrendingMusic();
          list = List<Map<String,dynamic>>.from(_base).reversed.toList();
        }
      } else if (_cat=='news') {
        try {
          final res = await svc.search('haber gündem son dakika');
          list = res.map((v)=> {'id': v.id, 'title': v.title, 'thumbnail': v.thumbnailUrl, 'author': v.author, 'views': v.viewCount ?? 0}).toList();
        } catch (_){}
        if (list.isEmpty) {
          if (_base.isEmpty) _base = await svc.getTrendingMusic();
          list = List<Map<String,dynamic>>.from(_base);
          list.sort((a,b)=> (b['views'] as int? ?? 0).compareTo(a['views'] as int? ?? 0));
        }
      } else if (_cat=='live') {
        try {
          final res = await svc.search('canlı yayın live Turkey');
          list = res.map((v)=> {'id': v.id, 'title': v.title, 'thumbnail': v.thumbnailUrl, 'author': v.author, 'views': v.viewCount ?? 0}).toList();
        } catch (_){}
        if (list.isEmpty) {
          if (_base.isEmpty) _base = await svc.getTrendingMusic();
          list = List<Map<String,dynamic>>.from(_base);
        }
      }
      list.shuffle();
      // sınırsız için de limit kadar göster ama her refresh farklı
      if (list.isEmpty) {
        if (_base.isNotEmpty) list = List<Map<String,dynamic>>.from(_base);
      }
      if (list.length < limit && list.isNotEmpty) {
        final extra = List<Map<String,dynamic>>.from(list);
        list = [...list, ...extra];
        list.shuffle();
      }
      _cache[_cat] = list;
      _all = list;
      _filtered = plan==PlanType.unlimited ? list : list.take(limit).toList();
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
      appBar: AppBar(title: Text('explore'.tr()), actions: [IconButton(icon: const Icon(Icons.refresh_rounded), onPressed: ()=> _load(force:true))]),
      body: Column(children: [
        SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal:12, vertical:8), child: Row(children: _cats.map((c)=> Padding(padding: const EdgeInsets.only(right:8), child: ChoiceChip(label: Text(c.toUpperCase(), style: const TextStyle(fontSize:12, fontWeight: FontWeight.w700)), selected: _cat==c, onSelected: (_){ _onCat(c); })) ).toList())),
        FutureBuilder<PlanType>(future: SubscriptionService.getPlan(), builder: (c,snap){
          final p = snap.data ?? PlanType.free;
          final lim = _limitForPlan(p);
          final label = p==PlanType.unlimited ? '${_filtered.length} video • ${_cat.toUpperCase()} • ∞' : '${_filtered.length}/$lim video • ${_cat.toUpperCase()} • ${p.name.toUpperCase()}';
          return Padding(padding: const EdgeInsets.symmetric(horizontal:12), child: Row(children: [Icon(Icons.explore_rounded, size:14, color: Colors.grey[600]), const SizedBox(width:4), Text(label, style: TextStyle(color: Colors.grey[600], fontSize:11, fontWeight: FontWeight.w600)), const Spacer(), TextButton.icon(onPressed: ()=> _load(force:true), icon: const Icon(Icons.shuffle_rounded, size:16), label: Text('Karıştır'.tr(), style: TextStyle(fontSize:12)))]));
        }),
        Expanded(child: _loading ? GridView.builder(padding: const EdgeInsets.all(12), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 0.78, crossAxisSpacing: 12, mainAxisSpacing: 12), itemCount: 6, itemBuilder: (_,i)=> Shimmer.fromColors(baseColor: Colors.grey[300]!, highlightColor: Colors.grey[100]!, child: Card(child: Container(height: 180, color: Colors.white)))) : _filtered.isEmpty ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(color: Theme.of(context).colorScheme.primary.withOpacity(0.1), shape: BoxShape.circle), child: Icon(Icons.explore_rounded, size:48, color: Theme.of(context).colorScheme.primary)), const SizedBox(height:12), Text('trending_load_failed'.tr(), style: TextStyle(color: Colors.grey[600], fontWeight: FontWeight.w700)), const SizedBox(height:4), Text('Keşfet için internet gerekli, pull-to-refresh ile yenile'.tr(), style: TextStyle(color: Colors.grey[500], fontSize:12)), const SizedBox(height:8), FilledButton.icon(onPressed: ()=> _load(force:true), icon: const Icon(Icons.refresh_rounded), label: Text('retry'.tr()))])) : RefreshIndicator(
          onRefresh: ()=> _load(force:true),
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
