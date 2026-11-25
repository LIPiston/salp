import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'core/repository.dart';
import 'ui/workbench.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    for (final name in ['FreeRDP', 'OpenSSL']) {
      yield LicenseEntryWithLineBreaks([
        name,
      ], await rootBundle.loadString('assets/licenses/$name.txt'));
    }
  });
  runApp(const SalpApp());
}

class SalpApp extends StatelessWidget {
  const SalpApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'salp',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff6bb9aa),
        brightness: Brightness.dark,
        surface: const Color(0xff171b20),
      ),
      scaffoldBackgroundColor: const Color(0xff101419),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
      visualDensity: Platform.isAndroid
          ? VisualDensity.standard
          : VisualDensity.compact,
    ),
    home: const Bootstrap(),
  );
}

class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});
  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  late Future<Repository> repository;
  @override
  void initState() {
    super.initState();
    repository = Repository.open();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<Repository>(
    future: repository,
    builder: (context, snapshot) {
      if (snapshot.hasData) return Workbench(repository: snapshot.data!);
      return Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.terminal, size: 40),
                  const SizedBox(height: 20),
                  const Text('salp', style: TextStyle(fontSize: 28)),
                  const SizedBox(height: 20),
                  if (snapshot.hasError) ...[
                    const Text(
                      '无法打开系统安全存储或本地保险库。请解锁系统密钥库后重试；已有数据会保留。',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () =>
                          setState(() => repository = Repository.open()),
                      child: const Text('重试'),
                    ),
                  ] else
                    const CircularProgressIndicator(),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
