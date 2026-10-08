import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import 'package:connectivity_plus/connectivity_plus.dart';
import '../core/constants.dart';
import '../core/database/breadcrumb_dao.dart';

class SyncStats {
  final int pendingCount;
  final int lastBatchSize;
  final bool lastSyncSuccess;
  final DateTime? lastSyncTime;
  final int totalSynced;

  const SyncStats({
    this.pendingCount = 0,
    this.lastBatchSize = 0,
    this.lastSyncSuccess = false,
    this.lastSyncTime,
    this.totalSynced = 0,
  });
}

class SyncService {
  final BreadcrumbDao _dao;
  final Connectivity _connectivity = Connectivity();

  Timer? _syncTimer;
  bool _running = false;
  bool _syncing = false;
  int _failureCount = 0;
  int _totalSynced = 0;

  SyncStats _lastStats = const SyncStats();
  SyncStats get lastStats => _lastStats;

  final _statsController = StreamController<SyncStats>.broadcast();
  Stream<SyncStats> get statsStream => _statsController.stream;

  String? _authToken;
  String? _rangerId;

  SyncService({BreadcrumbDao? dao}) : _dao = dao ?? BreadcrumbDao();

  void configure({String? authToken, String? rangerId}) {
    _authToken = authToken;
    _rangerId = rangerId;
  }

  void start() {
    if (_running) return;
    _running = true;
    _failureCount = 0;
    _scheduleNextSync();
  }

  void _scheduleNextSync() {
    if (!_running) return;

    final baseInterval = AppConstants.syncIntervalSeconds;
    final backoffSec = _failureCount > 0
        ? min(300, baseInterval * pow(2, min(_failureCount, 5)).toInt())
        : baseInterval;

    _syncTimer = Timer(Duration(seconds: backoffSec), _performSync);
  }

  Future<void> _performSync() async {
    if (!_running || _syncing) {
      _scheduleNextSync();
      return;
    }

    final connectivityResult = await _connectivity.checkConnectivity();
    if (connectivityResult.contains(ConnectivityResult.none)) {
      _scheduleNextSync();
      return;
    }

    _syncing = true;

    try {
      final unsyncedCrumbs =
          await _dao.getUnsyncedBreadcrumbs(limit: AppConstants.syncBatchSize);

      if (unsyncedCrumbs.isEmpty) {
        _syncing = false;
        _updateStats(batchSize: 0, success: true);
        _scheduleNextSync();
        return;
      }

      final features = unsyncedCrumbs.map((c) => {
            'type': 'Feature',
            'properties': {
              'timestamp_s': c.timestampS,
              'speed_kmh': c.speedKmh,
              'heading_deg': c.headingDeg,
              'mode': c.mode,
              'confidence_m': c.confidenceM,
              'is_outage': c.isOutage,
              'is_snapped': c.isSnapped,
              'patrol_id': c.patrolId,
            },
            'geometry': {
              'type': 'Point',
              'coordinates': [c.lon, c.lat],
            },
          }).toList();

      final payload = {
        'type': 'FeatureCollection',
        'features': features,
        'metadata': {
          'ranger_id': _rangerId ?? 'unknown',
          'batch_size': unsyncedCrumbs.length,
          'sync_time': DateTime.now().toUtc().toIso8601String(),
        },
      };

      final headers = <String, String>{
        'Content-Type': 'application/json',
      };
      if (_authToken != null) {
        headers['Authorization'] = 'Bearer $_authToken';
      }

      final response = await http
          .post(
            Uri.parse('${AppConstants.apiBaseUrl}/sync/upload'),
            headers: headers,
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200 || response.statusCode == 201) {
        final ids = unsyncedCrumbs
            .where((c) => c.id != null)
            .map((c) => c.id!)
            .toList();
        await _dao.markAsSynced(ids);
        _totalSynced += unsyncedCrumbs.length;
        _failureCount = 0;
        _updateStats(batchSize: unsyncedCrumbs.length, success: true);
      } else {
        _failureCount++;
        _updateStats(batchSize: unsyncedCrumbs.length, success: false);
      }
    } catch (_) {
      _failureCount++;
      _updateStats(batchSize: 0, success: false);
    } finally {
      _syncing = false;
      _scheduleNextSync();
    }
  }

  Future<void> _updateStats({
    required int batchSize,
    required bool success,
  }) async {
    final pending = await _dao.getUnsyncedCount();
    _lastStats = SyncStats(
      pendingCount: pending,
      lastBatchSize: batchSize,
      lastSyncSuccess: success,
      lastSyncTime: DateTime.now(),
      totalSynced: _totalSynced,
    );
    _statsController.add(_lastStats);
  }

  Future<void> forceSyncNow() async {
    _syncTimer?.cancel();
    await _performSync();
  }

  void stop() {
    _running = false;
    _syncTimer?.cancel();
    _syncTimer = null;
  }

  void dispose() {
    stop();
    _statsController.close();
  }
}
