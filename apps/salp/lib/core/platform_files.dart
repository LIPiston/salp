import 'package:file_picker/file_picker.dart';

import 'android_documents.dart';

/// The OS picker temporarily covers our Activity. Keep that one operation
/// alive; an actual screen lock still invalidates it through PlatformLock.
class PlatformFiles {
  static int _pending = 0;
  static bool get active => _pending != 0;

  static Future<T> _pick<T>(Future<T> Function() operation) async {
    _pending++;
    try {
      return await operation();
    } finally {
      _pending--;
    }
  }

  static Future<List<PlatformFile>> pickFiles() => _pick(FilePicker.pickFiles);
  static Future<PlatformFile?> pickFile() => _pick(FilePicker.pickFile);
  static Future<Uri?> pickDirectory() => _pick(FilePicker.pickDirectory);
  static Future<String?> chooseAndroidDirectory() =>
      _pick(AndroidDocuments.chooseDirectory);
}
