import 'dart:io' show Directory, File, Platform;

import 'package:flutter/material.dart';
import 'package:hive_ce_flutter/hive_flutter.dart' show Hive, HiveX;
import 'package:hooks_riverpod/hooks_riverpod.dart' show ProviderScope;
import 'package:path_provider/path_provider.dart'
    show getApplicationDocumentsDirectory, getApplicationSupportDirectory;
import 'package:pdfrx_engine/pdfrx_engine.dart' show Pdfrx, pdfrxInitialize;
import 'package:window_manager/window_manager.dart'
    show WindowOptions, windowManager;
import 'src/app.dart' show App;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  await _initializeStorage();
  _configurePdfiumModulePath();
  await pdfrxInitialize();

  WindowOptions windowOptions = const WindowOptions(
    minimumSize: Size(854, 480),
    title: 'TTS Mod Vault 2.1.0',
    center: true,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(ProviderScope(child: App()));
}

/// Initializes Hive in the standard macOS application-support directory.
///
/// Older releases used Hive's Flutter default, which placed the database in
/// `~/Documents/TTS Mod Vault`. On the first launch after upgrading, migrate
/// the existing database files once so settings and cached metadata survive.
Future<void> _initializeStorage() async {
  if (!Platform.isMacOS) {
    await Hive.initFlutter('TTS Mod Vault');
    return;
  }

  try {
    final applicationSupportDirectory = await getApplicationSupportDirectory();
    final storageDirectory =
        Directory('${applicationSupportDirectory.path}/TTS Mod Vault');
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final legacyDirectory =
        Directory('${documentsDirectory.path}/TTS Mod Vault');

    await storageDirectory.create(recursive: true);
    if (!await _containsHiveData(storageDirectory) &&
        await legacyDirectory.exists()) {
      await _migrateHiveData(legacyDirectory, storageDirectory);
    }

    Hive.init(storageDirectory.path);
  } catch (error) {
    // Keep existing installations usable if Application Support is unavailable.
    debugPrint('Failed to initialize Application Support storage: $error');
    await Hive.initFlutter('TTS Mod Vault');
  }
}

Future<bool> _containsHiveData(Directory directory) async {
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is File && entity.path.endsWith('.hive')) return true;
  }
  return false;
}

Future<void> _migrateHiveData(
  Directory legacyDirectory,
  Directory storageDirectory,
) async {
  await for (final entity in legacyDirectory.list(followLinks: false)) {
    if (entity is! File || entity.path.endsWith('.lock')) continue;

    final fileName = entity.uri.pathSegments.last;
    await entity.copy('${storageDirectory.path}/$fileName');
  }
}

/// Points pdfrx at the pdfium dynamic library bundled with the app.
///
/// `pdfrx_engine` delivers pdfium as a Dart native asset, which on macOS ends
/// up as `Contents/Frameworks/pdfium.framework` inside the `.app`. The default
/// Dart `pdfrxInitialize()` never sets a module path, so on macOS pdfium_dart
/// falls back to `DynamicLibrary.process()` — it assumes pdfium is already
/// linked into the process. That assumption holds for JIT/debug (`flutter run`
/// preloads native-asset libraries) but not for AOT/release builds, where the
/// bundled framework is present but never loaded. The result is the downloaded
/// release dying at startup with `Failed to lookup symbol 'FPDF_InitLibrary'`.
///
/// Setting [Pdfrx.pdfiumModulePath] to the bundled framework forces
/// `DynamicLibrary.open()` on that exact path, which loads pdfium correctly in
/// both debug and release. The path is propagated to pdfrx's worker isolate.
void _configurePdfiumModulePath() {
  if (!Platform.isMacOS) return;

  // .../TTS Mod Vault.app/Contents/MacOS/<exe> -> .../Contents/Frameworks/...
  final macOsDir = File(Platform.resolvedExecutable).parent;
  final pdfium =
      '${macOsDir.parent.path}/Frameworks/pdfium.framework/pdfium';
  if (File(pdfium).existsSync()) {
    Pdfrx.pdfiumModulePath = pdfium;
  }
}
