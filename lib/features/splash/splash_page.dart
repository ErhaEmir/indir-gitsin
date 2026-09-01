import 'package:flutter/material.dart';

class SplashPage extends StatefulWidget {
  final Widget child;
  const SplashPage({super.key, required this.child});
  @override State<SplashPage> createState()=> _SplashPageState();
}

class _SplashPageState extends State<SplashPage> with SingleTickerProviderStateMixin {
  bool _show = true;
  late AnimationController _c;
  late Animation<double> _scale;
  late Animation<double> _fade;

  @override void initState(){
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _scale = CurvedAnimation(parent: _c, curve: Curves.easeOutBack);
    _fade = CurvedAnimation(parent: _c, curve: Curves.easeIn);
    _c.forward();
    Future.delayed(const Duration(seconds: 3), (){
      if (mounted) setState(()=> _show=false);
    });
  }
  @override void dispose(){
    _c.dispose();
    super.dispose();
  }
  @override Widget build(BuildContext context){
    if (!_show) return widget.child;
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [cs.primary, const Color(0xFF7B0000)])),
        child: Center(child: FadeTransition(opacity: _fade, child: ScaleTransition(scale: _scale, child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(padding: const EdgeInsets.all(18), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(28), boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 20)]), child: ClipRRect(borderRadius: BorderRadius.circular(16), child: Image.asset('assets/icons/app_icon.png', width: 96, height: 96, fit: BoxFit.cover, errorBuilder: (_,__,___)=> Icon(Icons.download_rounded, size: 64, color: cs.primary)))),
          const SizedBox(height: 20),
          const Text('İndir Gitsin', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w900, fontSize: 28, letterSpacing: 0.5)),
          const SizedBox(height: 6),
          Text('YouTube & Music', style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 14, fontWeight: FontWeight.w600)),
          const SizedBox(height: 28),
          SizedBox(width: 36, height: 36, child: CircularProgressIndicator(strokeWidth: 3, color: Colors.white.withOpacity(0.95))),
          const SizedBox(height: 12),
          Text('Yükleniyor...', style: TextStyle(color: Colors.white.withOpacity(0.9), fontSize: 12, fontWeight: FontWeight.w600)),
        ])))),
      ),
    );
  }
}
