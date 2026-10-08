import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:battery_plus/battery_plus.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import '../core/constants.dart';
import '../core/database/breadcrumb_dao.dart';
import 'dead_reckoning_service.dart';

enum SosStatus { idle, sending, active, failed, cancelled }

class EmergencySosService {
  final BreadcrumbDao _breadcrumbDao;
  final Battery _battery = Battery();
  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  SosStatus _status = SosStatus.idle;
  SosStatus get status => _status;

  final _statusController = StreamController<SosStatus>.broadcast();
  Stream<SosStatus> get statusStream => _statusController.stream;

  Timer? _retryTimer;
  int _retryAttempts = 0;
  static const int _maxRetries = 10;
  String? _activeSosId;
  DateTime? _sosStartTime;

  NavigationState? _lastNavState;
  String? _rangerId;
  String? _patrolId;

  EmergencySosService({BreadcrumbDao? breadcrumbDao})
      : _breadcrumbDao = breadcrumbDao ?? BreadcrumbDao();

  void configure({String? rangerId, String? patrolId}) {
    _rangerId = rangerId;
    _patrolId = patrolId;
  }

  void updateNavState(NavigationState state) {
    _lastNavState = state;
  }

  Future<void> triggerSos() async {
    if (_status == SosStatus.active || _status == SosStatus.sending) return;

    _setStatus(SosStatus.sending);
    _sosStartTime = DateTime.now();
    _retryAttempts = 0;

    await _showNotification('SOS ACTIVATED', 'Emergency alert transmitting...');
    await _sendSos();
  }

  Future<void> _sendSos() async {
    try {
      final batteryLevel = await _battery.batteryLevel;
      final recentCrumbs = await _breadcrumbDao.getRecentBreadcrumbs(limit: 100);

      final trailCoords = recentCrumbs.map((c) => [c.lon, c.lat]).toList();

      final payload = {
        'ranger_id': _rangerId ?? 'unknown',
        'patrol_id': _patrolId,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'lat': _lastNavState?.lat ?? 0.0,
        'lon': _lastNavState?.lon ?? 0.0,
        'heading_deg': _lastNavState?.headingDeg ?? 0.0,
        'speed_kmh': _lastNavState?.speedKmh ?? 0.0,
        'battery_pct': batteryLevel,
        'confidence_radius_m': _lastNavState?.confidenceRadiusM ?? 999.0,
        'gnss_quality': _lastNavState?.gnssQuality ?? 'LOST',
        'mode': _lastNavState?.mode ?? 'UNKNOWN',
        'recent_trail': {
          'type': 'LineString',
          'coordinates': trailCoords,
        },
      };

      final response = await http
          .post(
            Uri.parse('${AppConstants.apiBaseUrl}/alerts/sos'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final body = jsonDecode(response.body);
        _activeSosId = body['sos_id'] as String?;
        _setStatus(SosStatus.active);
        await _showNotification(
            'SOS CONFIRMED', 'Base camp has received your alert');
      } else {
        _scheduleRetry();
      }
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    _retryAttempts++;
    if (_retryAttempts > _maxRetries) {
      _setStatus(SosStatus.failed);
      return;
    }

    _setStatus(SosStatus.sending);
    final delaySec = min(60, pow(2, _retryAttempts).toInt());
    _retryTimer = Timer(Duration(seconds: delaySec), _sendSos);
  }

  Future<void> cancelSos() async {
    _retryTimer?.cancel();
    _retryTimer = null;

    if (_activeSosId != null) {
      try {
        await http.post(
          Uri.parse('${AppConstants.apiBaseUrl}/alerts/sos/cancel'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'sos_id': _activeSosId,
            'ranger_id': _rangerId ?? 'unknown',
          }),
        );
      } catch (_) {}
    }

    _activeSosId = null;
    _sosStartTime = null;
    _setStatus(SosStatus.cancelled);
    await Future.delayed(const Duration(seconds: 2));
    _setStatus(SosStatus.idle);
  }

  Duration get elapsedSinceActivation {
    if (_sosStartTime == null) return Duration.zero;
    return DateTime.now().difference(_sosStartTime!);
  }

  void _setStatus(SosStatus newStatus) {
    _status = newStatus;
    _statusController.add(newStatus);
  }

  Future<void> _showNotification(String title, String body) async {
    const androidDetails = AndroidNotificationDetails(
      'sos_channel',
      'SOS Alerts',
      channelDescription: 'Emergency SOS notifications',
      importance: Importance.max,
      priority: Priority.max,
      ongoing: true,
      autoCancel: false,
    );
    const details = NotificationDetails(android: androidDetails);
    await _notifications.show(999, title, body, details);
  }

  void dispose() {
    _retryTimer?.cancel();
    _statusController.close();
  }
}
