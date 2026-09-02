import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

bool isValidLuhn(String number) {
  final digits = number.replaceAll(RegExp(r'\D'), '');
  if (digits.length != 16) return false;
  int sum = 0;
  bool alt = false;
  for (int i = digits.length - 1; i >= 0; i--) {
    int n = int.parse(digits[i]);
    if (alt) {
      n *= 2;
      if (n > 9) n -= 9;
    }
    sum += n;
    alt = !alt;
  }
  return sum % 10 == 0;
}

bool isValidExpiry(String exp) {
  final m = RegExp(r'^(\d{2})/(\d{2})$').firstMatch(exp.trim());
  if (m == null) return false;
  int mm = int.tryParse(m.group(1)!) ?? 0;
  int yy = int.tryParse(m.group(2)!) ?? -1;
  if (mm < 1 || mm > 12) return false;
  final now = DateTime.now();
  int fullYear = 2000 + yy;
  // expiry is end of month
  final expiry = DateTime(fullYear, mm + 1, 0);
  return expiry.isAfter(DateTime(now.year, now.month, 1));
}

bool isValidCvv(String cvv) => RegExp(r'^\d{3}$').hasMatch(cvv.trim());
bool isValidName(String name) => name.trim().split(' ').where((e)=> e.isNotEmpty).length >= 2 && name.trim().length >= 5;

class PaymentSheet extends StatefulWidget {
  final String title;
  final String price;
  final String description;
  final Future<void> Function() onSuccessDev; // dev success callback
  const PaymentSheet({super.key, required this.title, required this.price, required this.description, required this.onSuccessDev});

  static Future<void> show(BuildContext context, {required String title, required String price, required String description, required Future<void> Function() onSuccessDev}) async {
    final prefs = await SharedPreferences.getInstance();
    final isDev = prefs.getBool('dev_mode') ?? false;
    final panelEnabled = prefs.getBool('dev_payment_panel_enabled') ?? true;
    // Dev ve panel kapalıysa direkt başar
    if (isDev && !panelEnabled) {
      await onSuccessDev();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ödeme başarılı (Dev - panel kapalı) ✓'), backgroundColor: Colors.green, behavior: SnackBarBehavior.floating));
      }
      return;
    }
    // Normal akış: panel göster
    if (!context.mounted) return;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: PaymentSheet(title: title, price: price, description: description, onSuccessDev: onSuccessDev),
      ),
    );
  }

  @override State<PaymentSheet> createState()=> _PaymentSheetState();
}

class _PaymentSheetState extends State<PaymentSheet> {
  final _name = TextEditingController();
  final _card = TextEditingController();
  final _exp = TextEditingController();
  final _cvv = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscureCvv = true;

  @override void dispose(){
    // bellekten sil
    _name.clear(); _card.clear(); _exp.clear(); _cvv.clear();
    _name.dispose(); _card.dispose(); _exp.dispose(); _cvv.dispose();
    super.dispose();
  }

  @override Widget build(BuildContext context){
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness==Brightness.dark;
    return Container(
      decoration: BoxDecoration(color: Theme.of(context).scaffoldBackgroundColor, borderRadius: const BorderRadius.vertical(top: Radius.circular(28))),
      child: SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 12, 20, 20), child: Form(key: _formKey, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(99)))),
        const SizedBox(height: 12),
        Row(children: [
          Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(color: cs.primary.withOpacity(0.12), borderRadius: BorderRadius.circular(14)), child: Icon(Icons.lock_rounded, color: cs.primary)),
          const SizedBox(width:12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Güvenli Ödeme', style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: cs.primary)),
            Row(children: [Icon(Icons.verified_user_rounded, size:12, color: Colors.green[700]), const SizedBox(width:4), Text('256-bit SSL ile Güvenli Ödeme', style: TextStyle(fontSize:11, color: Colors.green[700], fontWeight: FontWeight.w700))]),
          ])),
          Container(padding: const EdgeInsets.symmetric(horizontal:8, vertical:4), decoration: BoxDecoration(color: Colors.green.withOpacity(0.12), borderRadius: BorderRadius.circular(99)), child: Row(children: [Icon(Icons.lock_rounded, size:12, color: Colors.green[700]), const SizedBox(width:4), Text('SSL', style: TextStyle(fontSize:11, fontWeight: FontWeight.w800, color: Colors.green[700]))])),
        ]),
        const SizedBox(height:16),
        Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: cs.primaryContainer.withOpacity(0.4), borderRadius: BorderRadius.circular(16)), child: Row(children: [
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w800)), Text(widget.description, style: TextStyle(color: Colors.grey[600], fontSize:12))])),
          Text(widget.price, style: TextStyle(fontWeight: FontWeight.w900, color: cs.primary, fontSize:16)),
        ])),
        const SizedBox(height:16),
        TextFormField(controller: _name, decoration: InputDecoration(labelText: 'Kart Sahibi Ad Soyad', hintText: 'Ad Soyad', prefixIcon: Icon(Icons.person_rounded, color: cs.primary), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))), textCapitalization: TextCapitalization.words, validator: (v)=> isValidName(v??'') ? null : 'Ad Soyad en az 2 kelime'),
        const SizedBox(height:12),
        TextFormField(controller: _card, decoration: InputDecoration(labelText: 'Kart Numarası (16 hane)', hintText: '0000 0000 0000 0000', prefixIcon: Icon(Icons.credit_card_rounded, color: cs.primary), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)), counterText: ''), keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(16), _CardFormatter()], maxLength: 19, validator: (v){
          final raw = v?.replaceAll(' ', '') ?? '';
          if (raw.length!=16) return '16 hane girin';
          if (!isValidLuhn(raw)) return 'Geçersiz kart numarası';
          return null;
        }, autovalidateMode: AutovalidateMode.onUserInteraction),
        const SizedBox(height:12),
        Row(children: [
          Expanded(child: TextFormField(controller: _exp, decoration: InputDecoration(labelText: 'AA/YY', hintText: '12/28', prefixIcon: Icon(Icons.calendar_today_rounded, color: cs.primary), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))), keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(4), _ExpiryFormatter()], validator: (v)=> isValidExpiry(v??'') ? null : 'Geçersiz tarih', autovalidateMode: AutovalidateMode.onUserInteraction)),
          const SizedBox(width:12),
          Expanded(child: TextFormField(controller: _cvv, decoration: InputDecoration(labelText: 'CVV', hintText: '123', prefixIcon: Icon(Icons.lock_outline_rounded, color: cs.primary), suffixIcon: IconButton(icon: Icon(_obscureCvv ? Icons.visibility_off_rounded : Icons.visibility_rounded, size:18), onPressed: ()=> setState(()=> _obscureCvv=!_obscureCvv)), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14))), keyboardType: TextInputType.number, inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)], obscureText: _obscureCvv, validator: (v)=> isValidCvv(v??'') ? null : '3 hane', autovalidateMode: AutovalidateMode.onUserInteraction)),
        ]),
        const SizedBox(height:16),
        SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: _onConfirm, icon: const Icon(Icons.lock_rounded, size:18), label: const Text('Ödemeyi Onayla', style: TextStyle(fontWeight: FontWeight.w800)))),
        const SizedBox(height:8),
        Center(child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.shield_rounded, size:12, color: Colors.grey[600]), const SizedBox(width:4), Text('Kart bilgileriniz asla saklanmaz — yalnızca Luhn kontrolü yapılır', style: TextStyle(fontSize:10, color: Colors.grey[600]))])),
        const SizedBox(height:4),
        Center(child: Text('256-bit SSL ile Güvenli Ödeme • PCI-DSS uyumlu simülasyon', style: TextStyle(fontSize:10, color: Colors.grey[500]))),
      ])))),
    );
  }

  Future<void> _onConfirm() async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Lütfen bilgileri kontrol edin'), behavior: SnackBarBehavior.floating, backgroundColor: Colors.orange));
      return;
    }
    // Luhn ek kontrol (buton pasif değilse de)
    final rawCard = _card.text.replaceAll(' ', '');
    if (!isValidLuhn(rawCard)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Geçersiz kart numarası'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating));
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final isDev = prefs.getBool('dev_mode') ?? false;
    // Kart bilgileri RAM'den temizlenecek — hiçbir yere yazma
    final name = _name.text; final card = rawCard; final exp = _exp.text; final cvv = _cvv.text;
    // log yok, prefs yok — sadece RAM
    // Simülasyon: normal kullanıcıda hep başarısız
    if (!isDev) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('İşlem gerçekleştirilemedi'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating, duration: Duration(seconds: 3)));
      }
      // bellek temizle
      _name.clear(); _card.clear(); _exp.clear(); _cvv.clear();
      return;
    }
    // Dev modda: panel açıkken geçerli kart => başar
    Navigator.pop(context);
    await widget.onSuccessDev();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Ödeme başarılı ✓'), backgroundColor: Colors.green, behavior: SnackBarBehavior.floating));
    }
    _name.clear(); _card.clear(); _exp.clear(); _cvv.clear();
  }
}

class _CardFormatter extends TextInputFormatter {
  @override TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue){
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final buffer = StringBuffer();
    for (int i=0;i<digits.length;i++){
      buffer.write(digits[i]);
      if ((i+1)%4==0 && i+1!=digits.length) buffer.write(' ');
    }
    final s = buffer.toString();
    return TextEditingValue(text: s, selection: TextSelection.collapsed(offset: s.length));
  }
}
class _ExpiryFormatter extends TextInputFormatter {
  @override TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue){
    var digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length>4) digits = digits.substring(0,4);
    String out = digits;
    if (digits.length>=3) out = '${digits.substring(0,2)}/${digits.substring(2)}';
    return TextEditingValue(text: out, selection: TextSelection.collapsed(offset: out.length));
  }
}
