import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/subscription_service.dart';

class PlanPage extends StatefulWidget {
  const PlanPage({super.key, this.mustSelect=false});
  final bool mustSelect;
  @override State<PlanPage> createState()=> _PlanPageState();
}

class _PlanPageState extends State<PlanPage> {
  PlanType _current = PlanType.free;
  bool _isDev = false;
  bool _loading = true;

  @override void initState(){ super.initState(); _load(); }

  Future<void> _load() async {
    final c = await SubscriptionService.getPlan();
    final prefs = await SharedPreferences.getInstance();
    setState((){ _current=c; _isDev = prefs.getBool('dev_mode') ?? false; _loading=false; });
  }

  Future<void> _select(PlanType p) async {
    if ((p==PlanType.plus || p==PlanType.pro) && !_isDev) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Plus ve Pro planları şu anda kapalı — yakında!'), behavior: SnackBarBehavior.floating));
      return;
    }
    final ok = await SubscriptionService.selectPlan(p);
    if (ok) {
      await _load();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${p.name.toUpperCase()} aktif!'), backgroundColor: Colors.green, behavior: SnackBarBehavior.floating));
      if (widget.mustSelect && mounted) Navigator.of(context).pop(true);
    }
  }

  Future<void> _cancel() async {
    final confirm = await showDialog<bool>(context: context, builder: (c)=> AlertDialog(
      title: const Text('Plan iptal edilsin mi?'),
      content: const Text('Plan iptal edilirse uygulama yeni bir plan seçilene kadar kullanılamaz. Free plan da iptal edilirse yeniden seçim ekranı gelir.'),
      actions: [TextButton(onPressed: ()=> Navigator.pop(c,false), child: const Text('Vazgeç')), FilledButton(onPressed: ()=> Navigator.pop(c,true), child: const Text('İptal et'), style: FilledButton.styleFrom(backgroundColor: Colors.red))],
    ));
    if (confirm!=true) return;
    await SubscriptionService.cancelPlan();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Plan iptal edildi — yeni plan seçin'), backgroundColor: Colors.orange));
      // If mustSelect false, push mustSelect version
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_)=> const PlanPage(mustSelect: true)));
    }
  }

  Widget _coinIcon({double size=22}){
    return Image.asset('assets/icons/ig_coin.png', width:size, height:size, errorBuilder: (_,__,___)=> Icon(Icons.monetization_on_rounded, size:size, color: Colors.amber));
  }

  @override Widget build(BuildContext context){
    if (_loading) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final cs = Theme.of(context).colorScheme;
    return PopScope(
      canPop: !widget.mustSelect,
      onPopInvokedWithResult: (didPop, result){
        if (!didPop && widget.mustSelect) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Devam etmek için bir plan seçmelisin'), backgroundColor: Colors.red));
        }
      },
      child: Scaffold(
        appBar: AppBar(title: Text(widget.mustSelect ? 'Plan Seçin' : 'Planlar'.tr()), automaticallyImplyLeading: !widget.mustSelect),
        body: ListView(padding: const EdgeInsets.fromLTRB(16,12,16,24), children: [
          if (widget.mustSelect) Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.red.withOpacity(0.3))), child: Row(children: [const Icon(Icons.warning_rounded, color: Colors.red), const SizedBox(width:8), Expanded(child: Text('Uygulamayı kullanmak için bir plan seçmelisin. Free plan ücretsiz.', style: TextStyle(color: Colors.red[800], fontWeight: FontWeight.w700)))]) ),
          if (widget.mustSelect) const SizedBox(height:12),
          _planCard(
            title: 'Free',
            price: 'Ücretsiz',
            video: '4 video / gün',
            audio: '2 ses / gün',
            coin: '150 Coin hediye',
            features: ['Temel ayarlar açık', 'AMOLED kapalı (gri)','Günlük +10 coin','Davet +30 coin (10 limit)'],
            color: Colors.grey,
            isCurrent: _current==PlanType.free,
            isDisabled: false,
            onSelect: ()=> _select(PlanType.free),
          ),
          _planCard(
            title: 'Plus',
            price: '36 TL / ay',
            video: '24 video / gün',
            audio: '12 ses / gün',
            coin: '500 Coin hediye',
            features: ['Tüm ayarlar açık','AMOLED dahil','Öncelikli destek','500 Coin başlangıç'],
            color: Colors.blue,
            isCurrent: _current==PlanType.plus,
            isDisabled: !_isDev,
            disabledReason: 'Yakında — Şu an kapalı',
            onSelect: ()=> _select(PlanType.plus),
          ),
          _planCard(
            title: 'Pro',
            price: '50 TL / ay',
            video: '80 video / gün',
            audio: '80 ses / gün',
            coin: '1500 Coin hediye',
            features: ['Tüm ayarlar açık','Teknik Destek ayrıcalığı','En yüksek kota','1500 Coin başlangıç'],
            color: Colors.deepPurple,
            isCurrent: _current==PlanType.pro,
            isDisabled: !_isDev,
            disabledReason: 'Yakında — Şu an kapalı',
            onSelect: ()=> _select(PlanType.pro),
          ),
          if (_isDev) _planCard(
            title: 'Sınırsız (Dev)',
            price: 'Test - Ücretsiz',
            video: '∞ video',
            audio: '∞ ses',
            coin: 'Limitsiz',
            features: ['Tüm kilitler açık','Kotasız indirme','Sadece Dev modunda'],
            color: Colors.red,
            isCurrent: _current==PlanType.unlimited,
            isDisabled: false,
            onSelect: ()=> _select(PlanType.unlimited),
          ),
          const SizedBox(height:16),
          if (_isDev) Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.green.withOpacity(0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.green.withOpacity(0.2))), child: Row(children: [const Icon(Icons.check_circle_rounded, color: Colors.green, size:20), const SizedBox(width:8), Expanded(child: Text('Dev modu açık: Plus/Pro ve Sınırsız planlar test için seçilebilir', style: TextStyle(fontSize:12, color: Colors.green)))])),
          const SizedBox(height:16),
          FutureBuilder<PlanType>(future: SubscriptionService.getPlan(), builder: (c,snap){
            return OutlinedButton.icon(onPressed: _cancel, icon: const Icon(Icons.cancel_rounded, color: Colors.red), label: const Text('Planı İptal Et', style: TextStyle(color: Colors.red)), style: OutlinedButton.styleFrom(side: const BorderSide(color: Colors.red)));
          }),
          const SizedBox(height:8),
          Text('İptal edersen plan seçim ekranı gelir, yeni plan seçmeden uygulama kullanılamaz.', style: TextStyle(fontSize:11, color: Colors.grey[600]), textAlign: TextAlign.center),
        ]),
      ),
    );
  }

  Widget _planCard({required String title, required String price, required String video, required String audio, required String coin, required List<String> features, required Color color, required bool isCurrent, required bool isDisabled, String? disabledReason, required VoidCallback onSelect}){
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textColor = isDark ? Colors.white : Colors.black87;
    final subTextColor = isDark ? Colors.white70 : Colors.black87;
    return Container(
      margin: const EdgeInsets.only(bottom:12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: isCurrent ? color : Colors.grey.withOpacity(0.25), width: isCurrent ? 2 : 1),
        color: isDisabled ? (isDark ? Colors.white.withOpacity(0.06) : Colors.grey.withOpacity(0.06)) : (isCurrent ? color.withOpacity(isDark ? 0.18 : 0.08) : Theme.of(context).cardColor),
      ),
      child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(padding: const EdgeInsets.symmetric(horizontal:10, vertical:6), decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(99)), child: Text(title.toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize:12))),
          const SizedBox(width:8),
          if (isCurrent) Container(padding: const EdgeInsets.symmetric(horizontal:8, vertical:4), decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(99)), child: const Text('AKTİF', style: TextStyle(color: Colors.white, fontSize:10, fontWeight: FontWeight.w800))),
          const Spacer(),
          Text(price, style: TextStyle(fontWeight: FontWeight.w900, color: color, fontSize:16)),
        ]),
        const SizedBox(height:10),
        Row(children: [
          _badge(Icons.videocam_rounded, video), const SizedBox(width:8), _badge(Icons.music_note_rounded, audio),
        ]),
        const SizedBox(height:8),
        Row(children: [ _coinIcon(size:22), const SizedBox(width:4), Text(coin, style: TextStyle(fontWeight: FontWeight.w800, fontSize:13, color: isDark ? Colors.amber[300] : Colors.black87))]),
        const SizedBox(height:8),
        ...features.map((f)=> Padding(padding: const EdgeInsets.only(bottom:4), child: Row(children: [Icon(Icons.check_circle_rounded, size:14, color: isDisabled ? Colors.grey : color), const SizedBox(width:6), Expanded(child: Text(f, style: TextStyle(fontSize:12, fontWeight: FontWeight.w600, color: isDisabled ? Colors.grey : subTextColor))) ]))),
        const SizedBox(height:12),
        SizedBox(width: double.infinity, child: FilledButton(
          onPressed: isDisabled ? null : onSelect,
          style: FilledButton.styleFrom(backgroundColor: isCurrent ? Colors.green : color, disabledBackgroundColor: isDark ? Colors.white12 : Colors.grey[300], disabledForegroundColor: Colors.grey[500]),
          child: Text(isDisabled ? (disabledReason ?? 'Kapalı') : (isCurrent ? 'Seçili ✓' : 'Seç')),
        )),
        if (isDisabled) Padding(padding: const EdgeInsets.only(top:6), child: Text(disabledReason ?? 'Kapalı', style: TextStyle(fontSize:11, color: isDark ? Colors.white54 : Colors.grey), textAlign: TextAlign.center)),
      ])),
    );
  }

  Widget _badge(IconData i, String t){
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(padding: const EdgeInsets.symmetric(horizontal:8, vertical:4), decoration: BoxDecoration(color: isDark ? Colors.white.withOpacity(0.10) : Colors.black.withOpacity(0.06), borderRadius: BorderRadius.circular(99)), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(i, size:14, color: isDark ? Colors.white70 : Colors.black87), const SizedBox(width:4), Text(t, style: TextStyle(fontSize:11, fontWeight: FontWeight.w700, color: isDark ? Colors.white : Colors.black87))]));
  }
}
