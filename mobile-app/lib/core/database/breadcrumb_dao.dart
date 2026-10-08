import 'package:sqflite/sqflite.dart';
import 'database_helper.dart';

class BreadcrumbRecord {
  final int? id;
  final String patrolId;
  final double timestampS;
  final double lat;
  final double lon;
  final double speedKmh;
  final double headingDeg;
  final String mode;
  final double confidenceM;
  final bool isOutage;
  final bool isSnapped;
  final bool synced;

  BreadcrumbRecord({
    this.id,
    required this.patrolId,
    required this.timestampS,
    required this.lat,
    required this.lon,
    required this.speedKmh,
    required this.headingDeg,
    required this.mode,
    required this.confidenceM,
    this.isOutage = false,
    this.isSnapped = false,
    this.synced = false,
  });

  Map<String, dynamic> toMap() => {
        'patrol_id': patrolId,
        'timestamp_s': timestampS,
        'lat': lat,
        'lon': lon,
        'speed_kmh': speedKmh,
        'heading_deg': headingDeg,
        'mode': mode,
        'confidence_m': confidenceM,
        'is_outage': isOutage ? 1 : 0,
        'is_snapped': isSnapped ? 1 : 0,
        'synced': synced ? 1 : 0,
      };

  factory BreadcrumbRecord.fromMap(Map<String, dynamic> map) => BreadcrumbRecord(
        id: map['id'] as int?,
        patrolId: map['patrol_id'] as String,
        timestampS: (map['timestamp_s'] as num).toDouble(),
        lat: (map['lat'] as num).toDouble(),
        lon: (map['lon'] as num).toDouble(),
        speedKmh: (map['speed_kmh'] as num).toDouble(),
        headingDeg: (map['heading_deg'] as num).toDouble(),
        mode: map['mode'] as String,
        confidenceM: (map['confidence_m'] as num).toDouble(),
        isOutage: (map['is_outage'] as int) == 1,
        isSnapped: (map['is_snapped'] as int) == 1,
        synced: (map['synced'] as int) == 1,
      );
}

class BreadcrumbDao {
  final DatabaseHelper _dbHelper;

  BreadcrumbDao({DatabaseHelper? dbHelper})
      : _dbHelper = dbHelper ?? DatabaseHelper();

  Future<int> insertBreadcrumb(BreadcrumbRecord record) async {
    final db = await _dbHelper.database;
    return await db.insert(
      'breadcrumbs',
      record.toMap(),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> insertBatch(List<BreadcrumbRecord> records) async {
    final db = await _dbHelper.database;
    final batch = db.batch();
    for (final record in records) {
      batch.insert('breadcrumbs', record.toMap(),
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<List<BreadcrumbRecord>> getUnsyncedBreadcrumbs({int limit = 500}) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'breadcrumbs',
      where: 'synced = 0',
      orderBy: 'timestamp_s ASC',
      limit: limit,
    );
    return maps.map((m) => BreadcrumbRecord.fromMap(m)).toList();
  }

  Future<void> markAsSynced(List<int> ids) async {
    if (ids.isEmpty) return;
    final db = await _dbHelper.database;
    final placeholders = ids.map((_) => '?').join(',');
    await db.rawUpdate(
      'UPDATE breadcrumbs SET synced = 1 WHERE id IN ($placeholders)',
      ids,
    );
  }

  Future<List<BreadcrumbRecord>> getBreadcrumbsForPatrol(String patrolId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'breadcrumbs',
      where: 'patrol_id = ?',
      whereArgs: [patrolId],
      orderBy: 'timestamp_s ASC',
    );
    return maps.map((m) => BreadcrumbRecord.fromMap(m)).toList();
  }

  Future<int> getCount() async {
    final db = await _dbHelper.database;
    final result = await db.rawQuery('SELECT COUNT(*) as cnt FROM breadcrumbs');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> getUnsyncedCount() async {
    final db = await _dbHelper.database;
    final result = await db.rawQuery(
        'SELECT COUNT(*) as cnt FROM breadcrumbs WHERE synced = 0');
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<int> deleteOlderThan(double timestampS) async {
    final db = await _dbHelper.database;
    return await db.delete(
      'breadcrumbs',
      where: 'timestamp_s < ? AND synced = 1',
      whereArgs: [timestampS],
    );
  }

  Future<List<BreadcrumbRecord>> getRecentBreadcrumbs({int limit = 100}) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'breadcrumbs',
      orderBy: 'timestamp_s DESC',
      limit: limit,
    );
    return maps.map((m) => BreadcrumbRecord.fromMap(m)).toList();
  }
}
