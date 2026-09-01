import 'package:shared_preferences/shared_preferences.dart';

enum PlanType { free, plus, pro, unlimited }

class SubscriptionService {
  static const _kPlan = 'sub_plan';
  static const _kCoins = 'sub_coins';
  static const _kVideoUsed = 'sub_video_used';
  static const _kAudioUsed = 'sub_audio_used';
  static const _kExtraVideo = 'sub_extra_video';
  static const _kExtraAudio = 'sub_extra_audio';
  static const _kQuotaDate = 'sub_quota_date'; // yyyy-MM-dd
  static const _kLastDaily = 'sub_last_daily';
  static const _kInviteCount = 'sub_invite_count';
  static const _kBadge = 'sub_badge_unlocked';
  static const _kWelcomeGiven = 'sub_welcome_given'; // Set<String> plans
  static const _kPlanActive = 'sub_plan_active'; // bool - false ise plan iptal, seçim zorunlu
  static const _kStreak = 'sub_streak';

  static String _today() {
    final n = DateTime.now();
    return '${n.year}-${n.month.toString().padLeft(2,'0')}-${n.day.toString().padLeft(2,'0')}';
  }

  static Map<String,int> limits(PlanType p) {
    switch(p){
      case PlanType.free: return {'video':4,'audio':2};
      case PlanType.plus: return {'video':24,'audio':12};
      case PlanType.pro: return {'video':80,'audio':80};
      case PlanType.unlimited: return {'video':9999,'audio':9999};
    }
  }

  static int welcomeCoins(PlanType p){
    switch(p){
      case PlanType.free: return 150;
      case PlanType.plus: return 500;
      case PlanType.pro: return 1500;
      case PlanType.unlimited: return 0;
    }
  }

  static PlanType fromString(String? s){
    switch(s){
      case 'plus': return PlanType.plus;
      case 'pro': return PlanType.pro;
      case 'unlimited': return PlanType.unlimited;
      default: return PlanType.free;
    }
  }
  static String toStringValue(PlanType p){
    switch(p){
      case PlanType.free: return 'free';
      case PlanType.plus: return 'plus';
      case PlanType.pro: return 'pro';
      case PlanType.unlimited: return 'unlimited';
    }
  }

  static Future<void> ensureInit() async {
    final prefs = await SharedPreferences.getInstance();
    if (!prefs.containsKey(_kPlan)) {
      await prefs.setString(_kPlan, 'free');
      await prefs.setBool(_kPlanActive, true);
    }
    if (!prefs.containsKey(_kCoins)) {
      // ilk açılış - welcome
      await prefs.setInt(_kCoins, 150);
      await prefs.setStringList(_kWelcomeGiven, ['free']);
    }
    // quota date reset
    await _ensureQuotaReset();
    // daily login +10
    await _checkDailyBonus();
  }

  static Future<void> _ensureQuotaReset() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _today();
    final saved = prefs.getString(_kQuotaDate);
    if (saved != today) {
      await prefs.setString(_kQuotaDate, today);
      await prefs.setInt(_kVideoUsed, 0);
      await prefs.setInt(_kAudioUsed, 0);
      // extra haklar sıfırlanmaz - coin ile alınanlar kalıcı tek kullanımlık
    }
  }

  static Future<void> _checkDailyBonus() async {
    final prefs = await SharedPreferences.getInstance();
    final today = _today();
    final last = prefs.getString(_kLastDaily);
    if (last != today) {
      await prefs.setString(_kLastDaily, today);
      final cur = prefs.getInt(_kCoins) ?? 0;
      await prefs.setInt(_kCoins, cur + 10);
      // streak
      final streak = (prefs.getInt(_kStreak) ?? 0) + 1;
      await prefs.setInt(_kStreak, streak);
    }
  }

  static Future<PlanType> getPlan() async {
    final prefs = await SharedPreferences.getInstance();
    return fromString(prefs.getString(_kPlan));
  }

  static Future<bool> isPlanActive() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kPlanActive) ?? true;
  }

  static Future<void> setPlanActive(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kPlanActive, v);
  }

  static Future<int> getCoins() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kCoins) ?? 0;
  }

  static Future<Map<String,int>> getRemaining() async {
    await _ensureQuotaReset();
    final prefs = await SharedPreferences.getInstance();
    final plan = fromString(prefs.getString(_kPlan));
    final isDev = prefs.getBool('dev_mode') ?? false;
    if (isDev && plan == PlanType.unlimited) {
      return {'video':9999,'audio':9999,'limitVideo':9999,'limitAudio':9999};
    }
    final lim = limits(plan);
    final usedV = prefs.getInt(_kVideoUsed) ?? 0;
    final usedA = prefs.getInt(_kAudioUsed) ?? 0;
    final extraV = prefs.getInt(_kExtraVideo) ?? 0;
    final extraA = prefs.getInt(_kExtraAudio) ?? 0;
    return {
      'video': (lim['video']! - usedV) + extraV,
      'audio': (lim['audio']! - usedA) + extraA,
      'limitVideo': lim['video']!,
      'limitAudio': lim['audio']!,
      'usedVideo': usedV,
      'usedAudio': usedA,
      'extraVideo': extraV,
      'extraAudio': extraA,
    };
  }

  static Future<bool> canDownloadVideo() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('dev_mode') ?? false) {
      final pl = fromString(prefs.getString(_kPlan));
      if (pl == PlanType.unlimited) return true;
    }
    final r = await getRemaining();
    return (r['video']! > 0);
  }

  static Future<bool> canDownloadAudio() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('dev_mode') ?? false) {
      final pl = fromString(prefs.getString(_kPlan));
      if (pl == PlanType.unlimited) return true;
    }
    final r = await getRemaining();
    return (r['audio']! > 0);
  }

  static Future<void> consumeVideo() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('dev_mode') ?? false && fromString(prefs.getString(_kPlan))==PlanType.unlimited) return;
    int extra = prefs.getInt(_kExtraVideo) ?? 0;
    if (extra > 0) {
      await prefs.setInt(_kExtraVideo, extra - 1);
    } else {
      int used = prefs.getInt(_kVideoUsed) ?? 0;
      await prefs.setInt(_kVideoUsed, used + 1);
    }
  }

  static Future<void> consumeAudio() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('dev_mode') ?? false && fromString(prefs.getString(_kPlan))==PlanType.unlimited) return;
    int extra = prefs.getInt(_kExtraAudio) ?? 0;
    if (extra > 0) {
      await prefs.setInt(_kExtraAudio, extra - 1);
    } else {
      int used = prefs.getInt(_kAudioUsed) ?? 0;
      await prefs.setInt(_kAudioUsed, used + 1);
    }
  }

  static Future<bool> selectPlan(PlanType p) async {
    final prefs = await SharedPreferences.getInstance();
    final isDev = prefs.getBool('dev_mode') ?? false;
    // Plus/Pro kapalı - dev değilse reddet
    if ((p==PlanType.plus || p==PlanType.pro) && !isDev) return false;

    final cur = fromString(prefs.getString(_kPlan));
    if (cur == p) {
      await prefs.setBool(_kPlanActive, true);
      return true;
    }
    await prefs.setString(_kPlan, toStringValue(p));
    await prefs.setBool(_kPlanActive, true);
    // welcome coin bir kez
    final given = prefs.getStringList(_kWelcomeGiven) ?? [];
    if (!given.contains(toStringValue(p))) {
      final wc = welcomeCoins(p);
      if (wc>0) {
        final curCoins = prefs.getInt(_kCoins) ?? 0;
        await prefs.setInt(_kCoins, curCoins + wc);
      }
      given.add(toStringValue(p));
      await prefs.setStringList(_kWelcomeGiven, given);
    }
    // kota sıfırla seçince? kullanılmışı koru ama limit değişir
    return true;
  }

  static Future<void> cancelPlan() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kPlanActive, false);
  }

  static Future<bool> buyExtraVideo() async {
    final prefs = await SharedPreferences.getInstance();
    int coins = prefs.getInt(_kCoins) ?? 0;
    if (coins < 20) return false;
    await prefs.setInt(_kCoins, coins - 20);
    int extra = prefs.getInt(_kExtraVideo) ?? 0;
    await prefs.setInt(_kExtraVideo, extra + 1);
    return true;
  }

  static Future<bool> buyExtraAudio() async {
    final prefs = await SharedPreferences.getInstance();
    int coins = prefs.getInt(_kCoins) ?? 0;
    if (coins < 15) return false;
    await prefs.setInt(_kCoins, coins - 15);
    int extra = prefs.getInt(_kExtraAudio) ?? 0;
    await prefs.setInt(_kExtraAudio, extra + 1);
    return true;
  }

  static Future<bool> buyCoinPack(int coins, int price) async {
    // Gerçek ödeme entegrasyonu yok - simüle et
    final prefs = await SharedPreferences.getInstance();
    int cur = prefs.getInt(_kCoins) ?? 0;
    await prefs.setInt(_kCoins, cur + coins);
    return true;
  }

  static Future<void> addCoins(int amount) async {
    final p = await SharedPreferences.getInstance();
    int cur = p.getInt(_kCoins) ?? 0;
    await p.setInt(_kCoins, cur + amount);
  }

  static Future<void> removeCoins(int amount) async {
    final p = await SharedPreferences.getInstance();
    int cur = p.getInt(_kCoins) ?? 0;
    int newVal = (cur - amount).clamp(0, 999999);
    await p.setInt(_kCoins, newVal);
  }

  static Future<int> getInviteCount() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kInviteCount) ?? 0;
  }

  static Future<bool> hasBadge() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kBadge) ?? false;
  }

  static Future<String> doInvite() async {
    final prefs = await SharedPreferences.getInstance();
    int cnt = prefs.getInt(_kInviteCount) ?? 0;
    cnt++;
    await prefs.setInt(_kInviteCount, cnt);
    if (cnt <= 10) {
      int cur = prefs.getInt(_kCoins) ?? 0;
      await prefs.setInt(_kCoins, cur + 30);
      return 'coin';
    } else {
      await prefs.setBool(_kBadge, true);
      return 'badge';
    }
  }

  static Future<int> getStreak() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt(_kStreak) ?? 0;
  }
}
