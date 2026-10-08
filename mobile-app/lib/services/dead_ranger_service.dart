import 'dart:async';
import '../core/constants.dart';

enum WatchdogLevel { normal, warning, critical }

typedef WatchdogCallback = void Function(WatchdogLevel level, Duration elapsed);

class DeadRangerService {
  final Duration warningThreshold;
  final Duration criticalThreshold;
  final WatchdogCallback? onAlert;

  Timer? _tickTimer;
  DateTime? _lastActivity;
  WatchdogLevel _currentLevel = WatchdogLevel.normal;
  bool _running = false;
  bool _dismissed = false;

  final _levelController = StreamController<WatchdogLevel>.broadcast();
  Stream<WatchdogLevel> get levelStream => _levelController.stream;
  WatchdogLevel get currentLevel => _currentLevel;

  DeadRangerService({
    int warningMinutes = AppConstants.watchdogWarningMinutes,
    int criticalMinutes = AppConstants.watchdogCriticalMinutes,
    this.onAlert,
  })  : warningThreshold = Duration(minutes: warningMinutes),
        criticalThreshold = Duration(minutes: criticalMinutes);

  void start() {
    if (_running) return;
    _running = true;
    _dismissed = false;
    _lastActivity = DateTime.now();
    _currentLevel = WatchdogLevel.normal;
    _levelController.add(_currentLevel);

    _tickTimer = Timer.periodic(const Duration(seconds: 10), (_) => _check());
  }

  void _check() {
    if (!_running || _dismissed) return;
    final last = _lastActivity;
    if (last == null) return;

    final elapsed = DateTime.now().difference(last);
    WatchdogLevel newLevel;

    if (elapsed >= criticalThreshold) {
      newLevel = WatchdogLevel.critical;
    } else if (elapsed >= warningThreshold) {
      newLevel = WatchdogLevel.warning;
    } else {
      newLevel = WatchdogLevel.normal;
    }

    if (newLevel != _currentLevel) {
      _currentLevel = newLevel;
      _levelController.add(newLevel);
      onAlert?.call(newLevel, elapsed);
    }
  }

  void recordActivity() {
    _lastActivity = DateTime.now();
    if (_currentLevel != WatchdogLevel.normal) {
      _currentLevel = WatchdogLevel.normal;
      _levelController.add(_currentLevel);
    }
    _dismissed = false;
  }

  void recordMotion(double speedMps) {
    if (speedMps > AppConstants.speedDeadbandMps) {
      recordActivity();
    }
  }

  void dismiss() {
    _dismissed = true;
    _lastActivity = DateTime.now();
    _currentLevel = WatchdogLevel.normal;
    _levelController.add(_currentLevel);
  }

  Duration get timeSinceLastActivity {
    final last = _lastActivity;
    if (last == null) return Duration.zero;
    return DateTime.now().difference(last);
  }

  void stop() {
    _running = false;
    _tickTimer?.cancel();
    _tickTimer = null;
    _currentLevel = WatchdogLevel.normal;
    _levelController.add(_currentLevel);
  }

  void dispose() {
    stop();
    _levelController.close();
  }
}
