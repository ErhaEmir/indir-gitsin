import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:open_filex/open_filex.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  static Future<void> init() async {
    if (_inited) return;
    const android = AndroidInitializationSettings('@drawable/ic_stat_logo');
    const settings = InitializationSettings(android: android);
    await _plugin.initialize(settings, onDidReceiveNotificationResponse: (r){
      if (r.payload != null) OpenFilex.open(r.payload!);
    });
    _inited = true;
  }

  static Future<String> _lang() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getString('lang') ?? 'tr';
    } catch (_) { return 'tr'; }
  }

  static Future<void> showDownloadDone(String title, String path) async {
    final lang = await _lang();
    final notifTitle = lang == 'en' ? 'Video downloaded' : 'Video indirildi';
    const androidDetails = AndroidNotificationDetails(
      'download_channel',
      'İndirmeler',
      channelDescription: 'Video indirildi bildirimleri',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@drawable/ic_stat_logo',
    );
    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(0, notifTitle, title, details, payload: path);
  }

  static Future<void> showUpdate(String version) async {
    final lang = await _lang();
    final title = lang == 'en' ? 'Update ready' : 'Güncelleme hazır';
    final body = lang == 'en' ? 'Indir Gitsin $version downloaded, tap to install' : 'İndir Gitsin $version indirildi, kurmak için dokun';
    const androidDetails = AndroidNotificationDetails('update_channel', 'Güncellemeler', importance: Importance.high, priority: Priority.high, icon: '@drawable/ic_stat_logo');
    await _plugin.show(1, title, body, const NotificationDetails(android: androidDetails));
  }

  static Future<void> showCustom({required String title, required String body, Color? color}) async {
    final androidDetails = AndroidNotificationDetails(
      'dev_mode_channel',
      'Geliştirici Modu',
      channelDescription: 'Geliştirici modu uyarısı',
      importance: Importance.high,
      priority: Priority.high,
      color: color ?? const Color(0xFFFF0000),
      colorized: true,
      icon: '@drawable/ic_stat_logo',
      styleInformation: BigTextStyleInformation(body, htmlFormatBigText: true),
    );
    await _plugin.show(2, title, body, NotificationDetails(android: androidDetails));
  }
}
