import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/widgets.dart';
import '../cores/notification/app_notifications.dart';
import '../cores/timezone/app_timezone.dart';
import '../firebase_options.dart'; // dibuat otomatis oleh `flutterfire configure`
import 'di/injection.dart';

/// Inisialisasi sebelum `runApp`: binding, Firebase, zona waktu, notifikasi, lalu rakit dependensi.
Future<AppDependencies> bootstrap() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await AppTimezone.init();
  await AppNotifications.init();
  return Injection.build();
}
