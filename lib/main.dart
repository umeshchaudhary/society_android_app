import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:file_selector/file_selector.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'firebase_options.dart';

const String appUrl = 'https://x3fwsiq3sbsyniks3wwlumhqqy0uggcr.lambda-url.ap-south-1.on.aws';
const String registerTokenUrl =
    'https://x3fwsiq3sbsyniks3wwlumhqqy0uggcr.lambda-url.ap-south-1.on.aws/api/notifications/register';


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
  bool hasServerError = false;
  String? fcmToken;
  bool tokenRegistered = false;
  bool registering = false;

  String? pendingNotificationPath;

  @override
  void initState() {
    super.initState();

    webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'FcmBridge',
        onMessageReceived: (msg) {
          registering = false;
          if (msg.message == 'ok') {
            tokenRegistered = true;
            debugPrint('FCM device token registered');
          } else {
            debugPrint('FCM token registration failed, will retry');
          }
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) {
              setState(() {
                isLoading = true;
                hasServerError = false;
              });
            }
          },
          onPageFinished: (_) {
            if (mounted) setState(() => isLoading = false);
            registerTokenInWebView();
            navigateToPendingNotification();
          },
          onHttpError: (error) {
            final statusCode = error.response?.statusCode;

            if (statusCode != null && statusCode >= 500 && statusCode <= 599) {
              if (mounted) {
                setState(() {
                  isLoading = false;
                  hasServerError = true;
                });
              }
            }
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true) {
              if (mounted) {
                setState(() {
                  isLoading = false;
                  hasServerError = true;
                });
              }
            }
          },
        ),
      )
      ..loadRequest(Uri.parse(appUrl));

    setupNotifications();
    setupFilePicker();

    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      openNotificationDestination(message);
    });

    checkInitialNotification();
  }

  Future<void> checkInitialNotification() async {
    final message = await FirebaseMessaging.instance.getInitialMessage();

    if (message != null) {
      openNotificationDestination(message);
    }
  }

  void openNotificationDestination(RemoteMessage message) {
    final path = message.data['path'] as String? ?? '/';

    // Accept only internal site paths, not arbitrary URLs.
    if (!path.startsWith('/') || path.startsWith('//')) return;

    pendingNotificationPath = path;
    navigateToPendingNotification();
  }

  Future<void> navigateToPendingNotification() async {
    final path = pendingNotificationPath;
    if (path == null || !mounted) return;

    pendingNotificationPath = null;

    await webViewController.loadRequest(
      Uri.parse('$appUrl$path'),
    );
  }


  Future<void> handleBack() async {
    if (await webViewController.canGoBack()) {
      await webViewController.goBack();
    }
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
      tokenRegistered = false;
      debugPrint('FCM token refreshed');
      registerTokenInWebView();
    });

    FirebaseMessaging.onMessage.listen((message) {
      debugPrint(
        'Notification received: ${message.notification?.title}',
      );
    });
  }

  Future<void> setupFilePicker() async {
    final androidController =
        webViewController.platform as AndroidWebViewController;

    await androidController.setOnShowFileSelector((params) async {
      try {
        final file = await openFile(
          acceptedTypeGroups: [
            XTypeGroup(
              label: 'Images',
              extensions: ['jpg', 'jpeg', 'png', 'webp', 'heic'],
            ),
          ],
        );

        if (file == null) {
          return <String>[];
        }

        return <String>[
          Uri.file(file.path).toString(),
        ];
      } catch (error, stackTrace) {
        debugPrint('File picker failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        return <String>[];
      }
    });
  }

  Future<void> registerTokenInWebView() async {
    final token = fcmToken;
    if (token == null || tokenRegistered || registering) return;

    registering = true;
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

          FcmBridge.postMessage(response.ok ? 'ok' : 'fail');
        } catch (error) {
          FcmBridge.postMessage('fail');
        }
      })();
    ''';

    try {
      await webViewController.runJavaScript(script);
    } catch (error) {
      // The page may not be ready yet; onPageFinished will retry.
      registering = false;
      debugPrint('Token registration deferred: $error');
    }
  }

  void retryConnection() {
    setState(() {
      hasServerError = false;
      isLoading = true;
    });

    webViewController.loadRequest(Uri.parse(appUrl));
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) return;
          await handleBack();
        },
        child: Scaffold(
          body: SafeArea(
            child: hasServerError
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(
                            Icons.cloud_off,
                            size: 70,
                          ),
                          const SizedBox(height: 20),
                          const Text(
                            'Something went wrong',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Text(
                            'Unable to connect to SV Connect.\nPlease try again.',
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 24),
                          ElevatedButton(
                            onPressed: retryConnection,
                            child: const Text('Try Again'),
                          ),
                        ],
                      ),
                    ),
                  )
                : Stack(
                    children: [
                      WebViewWidget(controller: webViewController),
                      if (isLoading) const LinearProgressIndicator(),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}