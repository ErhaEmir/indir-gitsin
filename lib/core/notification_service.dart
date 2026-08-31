import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:open_filex/open_filex.dart';

class NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _inited = false;

  static Future<void> init() async {
    if (_inited) return;
    const android = AndroidInitializationSettings('@mipmap/launcher_icon');
    const settings = InitializationSettings(android: android);
    await _plugin.initialize(settings, onDidReceiveNotificationResponse: (r){
      if (r.payload != null) OpenFilex.open(r.payload!);
    });
    _inited = true;
  }

  static Future<void> showDownloadDone(String title, String path) async {
    const androidDetails = AndroidNotificationDetails(
      'download_channel',
      'İndirmeler',
      channelDescription: 'Video indirildi bildirimleri',
      importance: Importance.high,
      priority: Priority.high,
      icon: '@mipmap/launcher_icon',
      largeIcon: DrawableResourceAndroidBitmap('@mipmap/launcher_icon'),
    );
    const details = NotificationDetails(android: androidDetails);
    await _plugin.show(0, 'Video indirildi', title, details, payload: path);
  }

  static Future<void> showUpdate(String version) async {
    const androidDetails = AndroidNotificationDetails('update_channel', 'Güncellemeler', importance: Importance.high, priority: Priority.high, icon: '@mipmap/launcher_icon');
    await _plugin.show(1, 'Güncelleme hazır', 'İndir Gitsin $version indirildi, kurmak için dokun', const NotificationDetails(android: androidDetails));
  }

  static Future<void> showCustom({required String title, required String body, Color? color}) async {
    final androidDetails = AndroidNotificationDetails(
      'dev_mode_channel',
      'Geliştirici Modu',
      channelDescription: 'Geliştirici modu uyarısı',
      importance: Importance.high,
      priority: Priority.high,
      color: color ?? const Color(0xFFFF0000),
      icon: '@mipmap/launcher_icon',
      largeIcon: DrawableResourceAndroidBitmap('@mipmap/launcher_icon'),
      styleInformation: BigTextStyleInformation(body, htmlFormatBigText: true),
    );
    await _plugin.show(2, title, body, NotificationDetails(android: androidDetails));
  }
}
