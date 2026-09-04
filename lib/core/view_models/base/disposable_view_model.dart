import "package:flutter/foundation.dart";

/// A [ChangeNotifier] that guards against notifying after disposal, which
/// otherwise throws when an in-flight async call resolves post-dispose.
abstract class DisposableViewModel extends ChangeNotifier {
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  void notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }
}
