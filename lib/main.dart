import 'dart:io';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:kore_chat/screens/splash/splash_screen.dart';
import 'package:kore_chat/services/navigation_service.dart';
import 'package:kore_chat/services/notification_service.dart';
import 'package:provider/provider.dart';

import 'services/api_call_service.dart';
import 'theme/app_theme.dart';
import 'theme/theme_provider.dart';

void main() async {

  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isIOS) {
    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: "AIzaSyCq0PyTlknBoTx1HSu-8e6J4rLF9HCxASE",
        appId: "1:1083370396976:ios:4e1208c697c412a1af7cf5",
        messagingSenderId: "1083370396976",
        projectId: "kore-connect-574c5",
      ),
    );
  } else {
    await Firebase.initializeApp(
      options: FirebaseOptions(
        apiKey: "AIzaSyBzj9s0kdD3yE6Z1uJmyHd0JwSl2XyrGxM",
        appId: "1:1083370396976:android:f10f291616d67b13af7cf5",
        messagingSenderId: "1083370396976",
        projectId: "kore-connect-574c5",
      ),
    );
  }

  if (Platform.isIOS) {
    await Future.delayed(const Duration(milliseconds: 500));
  }
  await NotificationService().init();


  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: const KoreChatApp(),
    ),
  );
}

class KoreChatApp extends StatelessWidget {
  const KoreChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    final themeProvider = context.watch<ThemeProvider>();
    return MaterialApp(
      navigatorKey: NavigationService.navigatorKey,
      title: 'Kore Chat',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeProvider.themeMode,
      home: const SplashScreen(),
    );
  }
}