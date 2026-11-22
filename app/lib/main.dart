import 'package:flutter/material.dart';

import 'core.dart';
import 'home.dart';
import 'theme.dart';

void main() => runApp(const HyRouteApp());

class HyRouteApp extends StatelessWidget {
  const HyRouteApp({super.key, this.core = const PlatformCore()});

  final ClientCore core;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HyRoute',
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      home: Home(core: core),
    );
  }
}
