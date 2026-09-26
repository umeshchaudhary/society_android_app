import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'firebase_options.dart';

const String appUrl = 'https://d1zjrqrmxapuvq.cloudfront.net';
const String registerTokenUrl =
    'https://d1zjrqrmxapuvq.cloudfront.net/api/notifications/register';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  runApp(const SocietyApp());
}

class SocietyApp extends StatefulWidget {
  const SocietyApp({super.key});

  @override
  State<SocietyApp> createState() => _SocietyAppState();
}

class _SocietyAppState extends State<SocietyApp> {
  late final WebViewController webViewController;
  bool isLoading = true;
  String? fcmToken;

  @override
  void initState() {
    super.initState();

    webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => isLoading = true);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => isLoading = false);
            registerTokenInWebView();
          },
        ),
      )
      ..loadRequest(Uri.parse(appUrl));

    setupNotifications();
  }

  Future<void> setupNotifications() async {
    final messaging = FirebaseMessaging.instance;

    await messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    final token = await messaging.getToken();
    if (token != null) {
      fcmToken = token;
      debugPrint('FCM token obtained');
      registerTokenInWebView();
    }

    messaging.onTokenRefresh.listen((newToken) {
      fcmToken = newToken;
      debugPrint('FCM token refreshed');
      registerTokenInWebView();
    });

    FirebaseMessaging.onMessage.listen((message) {
      debugPrint(
        'Notification received: ${message.notification?.title}',
      );
    });

    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      debugPrint('Notification tapped: ${message.data}');
    });

    final initialMessage = await messaging.getInitialMessage();
    if (initialMessage != null) {
      debugPrint('App opened from notification: ${initialMessage.data}');
    }
  }

  Future<void> registerTokenInWebView() async {
    final token = fcmToken;
    if (token == null) return;

    // Safely encode the token as a JavaScript string literal.
    final tokenJson = jsonEncode(token);

    final script = '''
      (async () => {
        try {
          const response = await fetch(${jsonEncode(registerTokenUrl)}, {
            method: 'POST',
            credentials: 'same-origin',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
              token: $tokenJson,
              platform: 'android'
            })
          });

          if (response.ok) {
            console.log('FCM device token registered');
          } else {
            console.log('FCM token registration status:', response.status);
          }
        } catch (error) {
          console.log('FCM token registration failed:', error);
        }
      })();
    ''';

    try {
      await webViewController.runJavaScript(script);
    } catch (error) {
      // The page may not be ready yet; onPageFinished will retry.
      debugPrint('Token registration deferred: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: SafeArea(
          child: Stack(
            children: [
              WebViewWidget(controller: webViewController),
              if (isLoading) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
    );
  }
}