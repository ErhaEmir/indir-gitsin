import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/subscription_service.dart';
import '../plan/plan_page.dart';
import '../payment/payment_sheet.dart';

class MarketPage extends StatefulWidget {
  const MarketPage({super.key});
  @override State<MarketPage> createState()=> MarketPageState();
}

class MarketPageState extends State<MarketPage> {
  Future<void> refresh() async => _load();
  int _coins = 0;
  Map<String,int> _remaining = {};
  PlanType _plan = PlanType.free;
  int _inviteCnt = 0;
  bool _hasBadge = false;
  bool _isDev = false;

  @override void initState(){ super.initState(); _load(); }

  Future<void> _load() async {
    final c = await SubscriptionService.getCoins();
    final r = await SubscriptionService.getRemaining();
    final p = await SubscriptionService.getPlan();
    final ic = await SubscriptionService.getInviteCount();
    final badge = await SubscriptionService.hasBadge();
    final prefs = await SharedPreferences.getInstance();
    setState((){ _coins=c; _remaining=r; _plan=p; _inviteCnt=ic; _hasBadge=badge; _isDev = prefs.getBool('dev_mode') ?? false; });
  }

  Widget _coinIcon({double s=22})=> Image.asset('assets/icons/ig_coin.png', width:s, height:s, errorBuilder: (_,__,___)=> Icon(Icons.monetization_on_rounded, size:s, color: Colors.amber[700]));

  @override Widget build(BuildContext context){
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Market'), actions: [Padding(padding: const EdgeInsets.only(right:12), child: Chip(avatar: _coinIcon(s:22), label: Text(_plan==PlanType.unlimited ? '∞' : '$_coins', style: const TextStyle(fontWeight: FontWeight.w800, fontSize:13)), backgroundColor: Colors.amber.withOpacity(0.2), padding: const EdgeInsets.symmetric(horizontal:6)))]),
      body: RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.fromLTRB(16,12,16,24), children: [
        // Coin + plan banner
        Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(gradient: LinearGradient(colors: [Colors.amber[700]!, Colors.orange[600]!]), borderRadius: BorderRadius.circular(20)), child: Row(children: [
          _coinIcon(s:42),
          const SizedBox(width:12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_plan==PlanType.unlimited ? '∞ Coin' : '$_coins Coin', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize:18)),
            Text(_plan==PlanType.unlimited ? 'Plan: UNLIMITED • ∞ / ∞' : 'Plan: ${_plan.name.toUpperCase()} • ${_remaining['video']??0} video / ${_remaining['audio']??0} ses kaldı', style: const TextStyle(color: Colors.white, fontSize:12)),
          ])),
          FilledButton(onPressed: ()=> Navigator.push(context, MaterialPageRoute(builder: (_)=> const PlanPage())), style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.orange[700]), child: const Text('Planı Yükselt')),
        ])),
        const SizedBox(height:16),
        Text('Hak Satın Al (Coin ile)', style: TextStyle(fontWeight: FontWeight.w800, fontSize:16, color: cs.primary)),
        const SizedBox(height:8),
        Row(children: [
          Expanded(child: _buyCard(title: '+1 Video Hakkı', price: '20', icon: Icons.videocam_rounded, onBuy: () async {
            final ok = await SubscriptionService.buyExtraVideo();
            if (!ok) { if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Yetersiz Coin — 20 gerekli'))); return; }
            await _load(); if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('1 Video hakkı eklendi ✓'), backgroundColor: Colors.green));
          })),
          const SizedBox(width:12),
          Expanded(child: _buyCard(title: '+1 Ses Hakkı', price: '15', icon: Icons.music_note_rounded, onBuy: () async {
            final ok = await SubscriptionService.buyExtraAudio();
            if (!ok) { if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Yetersiz Coin — 15 gerekli'))); return; }
            await _load(); if(mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('1 Ses hakkı eklendi ✓'), backgroundColor: Colors.green));
          })),
        ]),
        Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(color: Colors.green.withOpacity(0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.green.withOpacity(0.2))), child: Row(children: [Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.lock_rounded, color: Colors.white, size:18)), const SizedBox(width:10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('256bit SSL güvenli ödeme', style: TextStyle(fontSize:13, fontWeight: FontWeight.w800, color: Colors.green[800])), const SizedBox(height:2), Text('verileriniz satın alma işlemi haricinde saklanmaz', style: TextStyle(fontSize:11, color: Colors.grey[700]))]))])),
        const SizedBox(height:12),
        Text('Coin Paketleri (Gerçek Para — Simüle)', style: TextStyle(fontWeight: FontWeight.w800, fontSize:16, color: cs.primary)),
        const SizedBox(height:8),
        ...[
          {'c':100,'p':10},
          {'c':250,'p':20},
          {'c':500,'p':25},
          {'c':1000,'p':30},
        ].map((e)=> Card(child: ListTile(leading: _coinIcon(), title: Text('${e['c']} Coin'), subtitle: Text('${e['p']} TL'), trailing: FilledButton(onPressed: () async {
          await PaymentSheet.show(context, title: '${e['c']} Coin Paketi', price: '${e['p']} TL', description: '${e['c']} Coin', onSuccessDev: () async {
            await SubscriptionService.buyCoinPack(e['c'] as int, e['p'] as int);
            await _load();
            if(context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${e['c']} Coin eklendi ✓')));
          });
        }, child: const Text('Satın Al')),))),
        const SizedBox(height:16),
        Text('Coin Kazan', style: TextStyle(fontWeight: FontWeight.w800, fontSize:16, color: cs.primary)),
        const SizedBox(height:8),
        Card(color: Colors.green.withOpacity(0.08), child: ListTile(leading: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.green, borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.calendar_today_rounded, color: Colors.white)), title: const Text('Günlük Giriş +10 Coin', style: TextStyle(fontWeight: FontWeight.w700)), subtitle: const Text('Her yeni gün otomatik verilir (bugün verildi)'), trailing: FutureBuilder<int>(future: SubscriptionService.getStreak(), builder: (c,s)=> Text('Streak ${s.data??0} 🔥', style: const TextStyle(fontWeight: FontWeight.w800))))),
        Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.orange, borderRadius: BorderRadius.circular(10)), child: const Icon(Icons.share_rounded, color: Colors.white)), const SizedBox(width:10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Arkadaşını Davet Et +30 Coin', style: const TextStyle(fontWeight: FontWeight.w800)), Text('Benzersiz arkadaş, 10 limite kadar coin, sonrası rozet', style: TextStyle(color: Colors.grey[600], fontSize:11))]))]),
          const SizedBox(height:8),
          Row(children: [Text('Davet: $_inviteCnt/10', style: const TextStyle(fontWeight: FontWeight.w700)), const SizedBox(width:8), if(_hasBadge) Container(padding: const EdgeInsets.symmetric(horizontal:8, vertical:4), decoration: BoxDecoration(color: Colors.deepPurple, borderRadius: BorderRadius.circular(99)), child: const Text('ROZET 🏅', style: TextStyle(color: Colors.white, fontSize:11, fontWeight: FontWeight.w800)))]),
          const SizedBox(height:8),
          SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: () async {
            final res = await Share.share('İndir Gitsin - YouTube & Music indirici https://github.com/ErhaEmir/indir-gitsin/releases');
            // Simüle: her paylaşım 1 davet sayılsın (gerçekte link tıklaması gerekir ama demo için)
            // Kullanıcı paylaştıktan sonra coin ver
            // Not: share result ignored, direkt davet say
          }, icon: const Icon(Icons.send_rounded), label: const Text('Davet Et'))),
          if (_isDev) ...[
            const SizedBox(height:6),
            SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: () async {
              final what = await SubscriptionService.doInvite();
              await _load();
              if (what=='coin' && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('+30 Coin eklendi!'), backgroundColor: Colors.green));
              if (what=='badge' && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Rozet kazandın 🏅 (limit doldu)'), backgroundColor: Colors.deepPurple));
            }, icon: const Icon(Icons.person_add_rounded), label: Text(_inviteCnt <10 ? 'Simüle: Davet say (+30)' : 'Simüle: Rozet al'))),
          ],
        ]))),
        if (_isDev) ...[
          const SizedBox(height:12),
          Card(color: Colors.red.withOpacity(0.06), child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [const Icon(Icons.bug_report_rounded, color: Colors.red), const SizedBox(width:8), const Text('Dev: Coin Ekle/Sil', style: TextStyle(fontWeight: FontWeight.w800))]),
            const SizedBox(height:8),
            Wrap(spacing:8, runSpacing:8, children: [
              FilledButton(onPressed: () async { await SubscriptionService.addCoins(100); await _load(); }, child: const Text('+100')),
              FilledButton(onPressed: () async { await SubscriptionService.addCoins(1000); await _load(); }, child: const Text('+1000')),
              OutlinedButton(onPressed: () async { await SubscriptionService.removeCoins(50); await _load(); }, child: const Text('-50')),
              OutlinedButton(onPressed: () async { await SubscriptionService.removeCoins(500); await _load(); }, child: const Text('-500')),
            ]),
          ]))),
        ],
        const SizedBox(height:12),
        SizedBox(width: double.infinity, child: OutlinedButton.icon(onPressed: ()=> Navigator.push(context, MaterialPageRoute(builder: (_)=> const PlanPage())), icon: const Icon(Icons.workspace_premium_rounded), label: const Text('Plan Seçim Ekranını Aç'))),
      ])),
    );
  }

  Widget _buyCard({required String title, required String price, required IconData icon, required VoidCallback onBuy}){
    return Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [
      Icon(icon, size:30, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height:6),
      Text(title, style: const TextStyle(fontWeight: FontWeight.w800), textAlign: TextAlign.center),
      const SizedBox(height:4),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [_coinIcon(s:20), const SizedBox(width:4), Text(price, style: const TextStyle(fontWeight: FontWeight.w800, fontSize:14))]),
      const SizedBox(height:8),
      SizedBox(width: double.infinity, child: FilledButton(onPressed: onBuy, child: const Text('Al'))),
    ])));
  }
}
