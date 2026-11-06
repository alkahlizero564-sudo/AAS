import 'package:flutter/material.dart';
import 'screens/home_screen.dart';

void main() => runApp(const AasApp());

class AasApp extends StatelessWidget {
  const AasApp({super.key});

  @override
  Widget build(BuildContext context) {
    const lime = Color(0xFFC6F750);
    const navy = Color(0xFF0F1630);
    const card = Color(0xFF1A2347);

    return MaterialApp(
      title: 'AAS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: navy,
        colorScheme: const ColorScheme.dark(
          primary: lime,
          onPrimary: navy,
          surface: card,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: navy,
          elevation: 0,
          centerTitle: true,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: card,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
      ),
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child!,
      ),
      home: const HomeScreen(),
    );
  }
}
