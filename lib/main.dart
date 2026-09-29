
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:image_picker/image_picker.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image/image.dart' as img;

import 'firebase_options.dart';

const String appUrl = 'https://x3fwsiq3sbsyniks3wwlumhqqy0uggcr.lambda-url.ap-south-1.on.aws';
const String registerTokenUrl =
    'https://x3fwsiq3sbsyniks3wwlumhqqy0uggcr.lambda-url.ap-south-1.on.aws/api/notifications/register';

const int maxImageBytes = 200 * 1024; // 200 KiB

/// Runs in a background isolate. Returns JPEG bytes at or below 200 KiB.
Uint8List _compressImageTo200KB(Uint8List inputBytes) {
  final decoded = img.decodeImage(inputBytes);

  if (decoded == null) {
    throw Exception('Could not decode the cropped image.');
  }

  var working = decoded;

  // Try reducing JPEG quality first, then shrink the image and retry.
  const qualities = [82, 75, 68, 60, 52, 45, 38, 32];

  for (var resizeAttempt = 0; resizeAttempt < 12; resizeAttempt++) {
    for (final quality in qualities) {
      final encoded = img.encodeJpg(working, quality: quality);

      if (encoded.length <= maxImageBytes) {
        return Uint8List.fromList(encoded);
      }
    }

    // Scale down while preserving the image's aspect ratio.
    final newWidth = (working.width * 0.8).round();
    if (newWidth < 320 || newWidth >= working.width) {
      break;
    }

    working = img.copyResize(
      working,
      width: newWidth,
      interpolation: img.Interpolation.average,
    );
  }

  throw Exception(
    'Unable to compress the cropped image below 200 KB. '
    'Please try cropping a smaller area.',
  );
}

Future<File> compressCroppedImage(String croppedPath) async {
  final sourceBytes = await File(croppedPath).readAsBytes();

  // Offload image decoding/resizing/encoding so the UI stays responsive.
  final compressedBytes = await compute(
    _compressImageTo200KB,
    sourceBytes,
  );

  if (compressedBytes.length > maxImageBytes) {
    throw Exception('Compressed image exceeds the 200 KB limit.');
  }

  final outputPath =
      '${Directory.systemTemp.path}/society_crop_'
      '${DateTime.now().microsecondsSinceEpoch}.jpg';

  final outputFile = File(outputPath);
  await outputFile.writeAsBytes(compressedBytes, flush: true);

  return outputFile;
}

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

  final ImagePicker _imagePicker = ImagePicker();
  String? pendingNotificationPath;

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
            navigateToPendingNotification();
          },
        ),
      )
      ..loadRequest(Uri.parse(appUrl));

    setupFilePicker();
    setupNotifications();

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

  Future<void> setupFilePicker() async {
    final androidController =
        webViewController.platform as AndroidWebViewController;

    await androidController.setOnShowFileSelector((params) async {
      try {
        // 1. Pick an image from the gallery.
        final XFile? pickedImage = await _imagePicker.pickImage(
          source: ImageSource.gallery,
        );

        if (pickedImage == null) {
          return <String>[];
        }

        // 2. Open the native Android uCrop screen.
        final CroppedFile? croppedImage = await ImageCropper().cropImage(
          sourcePath: pickedImage.path,
          maxWidth: 1920,
          maxHeight: 1920,
          compressFormat: ImageCompressFormat.jpg,
          compressQuality: 85,
          uiSettings: [
            AndroidUiSettings(
              toolbarTitle: 'Adjust photo',
              initAspectRatio: CropAspectRatioPreset.original,
              lockAspectRatio: false,
              hideBottomControls: false,
              showCropGrid: true,
            ),
          ],
        );

        // 3. User cancelled cropping.
        if (croppedImage == null) {
          return <String>[];
        }

        // 4. Recompress/resize the cropped result to max 200 KiB.
        final File finalImage = await compressCroppedImage(
          croppedImage.path,
        );

        debugPrint(
          'Cropped upload image size: '
          '${(await finalImage.length() / 1024).toStringAsFixed(1)} KB',
        );

        // 5. Return the final compressed file to the WebView input.
        return <String>[
          Uri.file(finalImage.path).toString(),
        ];
      } catch (error, stackTrace) {
        debugPrint('Image pick/crop/compress failed: $error');
        debugPrintStack(stackTrace: stackTrace);
        return <String>[];
      }
    });
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
      home: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, result) async {
          if (didPop) return;
          await handleBack();
        },
        child: Scaffold(
          body: SafeArea(
            child: Stack(
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