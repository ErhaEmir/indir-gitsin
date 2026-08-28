import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static const historyBox = 'history';
  static const favBox = 'favorites';
  static const searchBox = 'search_history';

  static Future<void> init() async {
    await Hive.initFlutter();
    await Hive.openBox(historyBox);
    await Hive.openBox(favBox);
    await Hive.openBox(searchBox);
  }

  // History: {id, title, thumbnail, url, date, path}
  static Box get history => Hive.box(historyBox);
  static Box get fav => Hive.box(favBox);
  static Box get search => Hive.box(searchBox);

  static void addHistory(Map<String, dynamic> item) {
    history.put(item['id'], item);
    // son 100
    if (history.length > 100) {
      final keys = history.keys.toList();
      history.delete(keys.first);
    }
  }

  static void addSearch(String url) {
    final list = search.get('list', defaultValue: <String>[]) as List;
    list.remove(url);
    list.insert(0, url);
    if (list.length > 20) list.removeLast();
    search.put('list', list);
  }

  static List<String> getSearchHistory() => (search.get('list', defaultValue: <String>[]) as List).cast<String>();

  static void toggleFav(String id, Map<String, dynamic> item) {
    if (fav.containsKey(id)) fav.delete(id);
    else fav.put(id, item);
  }

  static bool isFav(String id) => fav.containsKey(id);

  // Theme: system / light / dark / amoled
  static Future<String> getThemeMode() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('theme_mode') ?? 'system';
  }

  static Future<void> setThemeMode(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('theme_mode', v);
  }

  static Future<String> getLang() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('lang') ?? 'tr';
  }

  static Future<void> setLang(String v) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('lang', v);
  }
}
