# İndir Gitsin — YouTube & YouTube Music İndirici

Modern, hızlı ve kullanıcı dostu YouTube indirme uygulaması. Link yapıştır → kalite seç → indir. YouTube uygulamasından **Paylaş → İndir Gitsin** ile de çalışır.

## Özellikler
- 🔗 Link yapıştırınca otomatik algılama + thumbnail & başlık önizleme
- 🎬 Muxed (video+ses), sadece video, sadece ses (M4A) seçenekleri — MP4 / MP3
- 📤 Android **Share Intent**: YouTube / YouTube Music / youtu.be / m.youtube.com linkleriyle uygulamaya düşer
- 📁 İndirilenler `/Download/IndirGitsin` klasörüne kaydedilir
- 🎨 Material 3, açık/koyu tema, Google Fonts, modern kartlar
- 📱 Android 5.1+ (minSdk 21), Android 13/14 scoped storage uyumlu

## Teknoloji Seçimi
**Flutter + Dart** seçildi, neden:
- Tek kod tabanıyla modern Material 3 UI, hot-reload ile APK olmadan test
- `youtube_explode_dart` ile saf Dart'ta video/stream bilgisi (ek sunucu / yt-dlp gerekmez)
- `receive_sharing_intent` ile paylaşım entegrasyonu, `dio` ile indirme + progress
- GitHub Actions ile `flutter build apk` otomatik release

Alternatifler (Kotlin/Compose, React Native) elendi: Flutter daha hızlı UI iterasyonu ve tek paketle YouTube Music desteği sağlıyor.

## APK olmadan test (2 yöntem)

### 1) Web Önizleme (APK gerekmez, hemen dene)
```powershell
python -m http.server 8765 --directory web-demo
# tarayıcıda http://localhost:8765 aç
# YouTube linkini yapıştır → kalite seç → simule indirme
```
Bu önizleme Flutter UI ile birebir aynı akışı ve aynı YouTube regex'ini kullanır. Gerçek indirme APK'da yapılır.

### 2) Flutter Hot Reload (emülatör / fiziksel cihaz)
```powershell
# Flutter kurulu ise
flutter pub get
flutter run          # debug, hot reload
flutter run -d chrome # web'de dene
```

## Kurulum (geliştirici)
```powershell
# Gereksinimler: Flutter 3.24+, Java 17, Android SDK
flutter pub get
flutter analyze
flutter test

# APK oluştur
flutter build apk --release                 # universal
flutter build apk --release --split-per-abi # abi başına
flutter build appbundle --release           # Play Store
```
APK çıktısı: `build/app/outputs/flutter-apk/app-release.apk` ve `app-*-release.apk`

## Android Entegrasyonu
`android/app/src/main/AndroidManifest.xml:line_number`:
- `ACTION_SEND` intent-filter (`text/plain`) → Paylaş menüsünde görünme
- `ACTION_VIEW` intent-filter (`https` youtube.com, youtu.be, music.youtube.com, m.youtube.com)
- İzinler: `INTERNET`, `WRITE_EXTERNAL_STORAGE` (maxSdk 29), `READ_MEDIA_*`, `MANAGE_EXTERNAL_STORAGE`

## GitHub'a push edince otomatik Release
`.github/workflows/release.yml:line_number`:
- `push` → `main`/`master` veya `v*` tag'inde tetiklenir
- `flutter build apk --split-per-abi` + `appbundle` → `softprops/action-gh-release` ile tag `v<version>-<run_number>` oluşturur
- APK/AAB dosyaları release'e eklenir, notlar otomatik üretilir

**Repo'yu bağlamak:**
```powershell
git init
git add .
git commit -m "feat: indir gitsin v1.0.0"
git branch -M main
git remote add origin https://github.com/KULLANICI/indir-gitsin.git
git push -u origin main
# birkaç saniye sonra GitHub → Releases sekmesinde APK hazır
```

## Proje Yapısı
```
lib/
  main.dart                # Material 3 UI, link input, video kart, stream listesi, indirme
  core/
    youtube_service.dart   # youtube_explode_dart sarmalayıcı, URL regex, muxed/videoOnly/audioOnly
    download_service.dart  # dio + permission_handler + path_provider
    theme.dart             # Material 3 light/dark
android/app/src/main/AndroidManifest.xml
.github/workflows/release.yml
web-demo/index.html        # APK olmadan tarayıcıda test
```

## Notlar / Sınırlamalar
- YouTube TOS: Yalnızca kendi içeriğinizi veya indirme izni olan videoları indirin.
- Bazı videolar (DRM / üyelik) `youtube_explode_dart` ile alınamayabilir — hata mesajı gösterilir.
- Dosya adı sanitize edilir (`[\\/:*?"<>|]` → `_`).

## Lisans
MIT
