import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import '../constants.dart';

class DatabaseHelper {
  static DatabaseHelper? _instance;
  static Database? _database;

  DatabaseHelper._internal();

  factory DatabaseHelper() {
    _instance ??= DatabaseHelper._internal();
    return _instance!;
  }

  Future<Database> get database async {
    _database ??= await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = join(dir.path, AppConstants.dbName);
    return await openDatabase(
      path,
      version: AppConstants.dbVersion,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE patrols (
        id TEXT PRIMARY KEY,
        ranger_id TEXT NOT NULL,
        started_at REAL NOT NULL,
        ended_at REAL,
        origin_lat REAL,
        origin_lon REAL,
        status TEXT NOT NULL DEFAULT 'active',
        total_distance_m REAL DEFAULT 0.0,
        coverage_km2 REAL DEFAULT 0.0
      )
    ''');

    await db.execute('''
      CREATE TABLE breadcrumbs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        patrol_id TEXT NOT NULL,
        timestamp_s REAL NOT NULL,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        speed_kmh REAL NOT NULL,
        heading_deg REAL NOT NULL,
        mode TEXT NOT NULL,
        confidence_m REAL NOT NULL,
        is_outage INTEGER NOT NULL DEFAULT 0,
        is_snapped INTEGER NOT NULL DEFAULT 0,
        synced INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (patrol_id) REFERENCES patrols(id)
      )
    ''');

    await db.execute('''
      CREATE INDEX idx_breadcrumbs_patrol ON breadcrumbs(patrol_id)
    ''');
    await db.execute('''
      CREATE INDEX idx_breadcrumbs_synced ON breadcrumbs(synced)
    ''');
    await db.execute('''
      CREATE INDEX idx_breadcrumbs_timestamp ON breadcrumbs(timestamp_s)
    ''');

    await db.execute('''
      CREATE TABLE pending_sync (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        payload_type TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        created_at REAL NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_attempt_at REAL
      )
    ''');

    await db.execute('''
      CREATE TABLE sightings (
        id TEXT PRIMARY KEY,
        patrol_id TEXT,
        timestamp_s REAL NOT NULL,
        lat REAL NOT NULL,
        lon REAL NOT NULL,
        species TEXT NOT NULL,
        count INTEGER NOT NULL DEFAULT 1,
        description TEXT,
        synced INTEGER NOT NULL DEFAULT 0
      )
    ''');
  }

  Future<void> close() async {
    final db = _database;
    if (db != null && db.isOpen) {
      await db.close();
      _database = null;
    }
  }

  Future<void> deleteDatabase() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = join(dir.path, AppConstants.dbName);
    await databaseFactory.deleteDatabase(path);
    _database = null;
  }
}
