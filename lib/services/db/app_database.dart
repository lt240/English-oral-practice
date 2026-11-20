import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../srs.dart';

export '../srs.dart' show Schedule, Srs, DailyPoint, ScoreSummary;

/// SQLite 本地数据库（v4）
///
/// P0-6：删除从未写入的 speeches / practice_sessions；补索引；聚合下推 SQL。
/// P1-2/3/4：新增 vocab（生词本）、review_cards（SM-2 排程）、
///           speech_progress（断点续读）三张表。
class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();

  Database? _db;

  Future<Database> get database async => _db ??= await _open();

  Future<Database> _open() async {
    final dbPath = await getDatabasesPath();
    return openDatabase(
      p.join(dbPath, 'ted_companion.db'),
      version: 4,
      onCreate: (db, version) async {
        await _createAttempts(db);
        await _createRetellRecords(db);
        await _createProgress(db);
        await _createVocab(db);
        await _createReviewCards(db);
        await _createIndexes(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) await _createAttempts(db);
        if (oldVersion < 3) await _createRetellRecords(db);
        if (oldVersion < 4) {
          // 两张从未写入过的表，安全删除
          await db.execute('DROP TABLE IF EXISTS speeches');
          await db.execute('DROP TABLE IF EXISTS practice_sessions');
          await _createProgress(db);
          await _createVocab(db);
          await _createReviewCards(db);
          await _createIndexes(db);
        }
      },
    );
  }

  Future<void> _createAttempts(Database db) => db.execute('''
    CREATE TABLE IF NOT EXISTS attempts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      speech_id TEXT NOT NULL,
      sentence_index INTEGER NOT NULL,
      practiced_at INTEGER NOT NULL,
      score INTEGER NOT NULL,
      total INTEGER NOT NULL,
      correct INTEGER NOT NULL,
      wrong INTEGER NOT NULL,
      missed INTEGER NOT NULL,
      extra INTEGER NOT NULL,
      wrong_words TEXT,
      repeat_count INTEGER NOT NULL DEFAULT 0,
      needs_review INTEGER NOT NULL DEFAULT 0
    );
  ''');

  Future<void> _createRetellRecords(Database db) => db.execute('''
    CREATE TABLE IF NOT EXISTS retell_records (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      speech_id TEXT NOT NULL,
      clip_index INTEGER NOT NULL,
      practiced_at INTEGER NOT NULL,
      score INTEGER NOT NULL,
      total_points INTEGER NOT NULL,
      covered_points INTEGER NOT NULL,
      recognized TEXT,
      missing_points TEXT
    );
  ''');

  Future<void> _createProgress(Database db) => db.execute('''
    CREATE TABLE IF NOT EXISTS speech_progress (
      speech_id TEXT PRIMARY KEY,
      last_index INTEGER NOT NULL DEFAULT 0,
      updated_at INTEGER NOT NULL,
      completed INTEGER NOT NULL DEFAULT 0
    );
  ''');

  Future<void> _createVocab(Database db) => db.execute('''
    CREATE TABLE IF NOT EXISTS vocab (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      word TEXT NOT NULL UNIQUE,
      phonetic TEXT,
      meaning TEXT,
      source_sentence TEXT,
      speech_id TEXT,
      created_at INTEGER NOT NULL,
      ease REAL NOT NULL DEFAULT 2.5,
      interval_days INTEGER NOT NULL DEFAULT 0,
      repetitions INTEGER NOT NULL DEFAULT 0,
      due_at INTEGER NOT NULL,
      lapses INTEGER NOT NULL DEFAULT 0
    );
  ''');

  Future<void> _createReviewCards(Database db) => db.execute('''
    CREATE TABLE IF NOT EXISTS review_cards (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      speech_id TEXT NOT NULL,
      sentence_index INTEGER NOT NULL,
      ease REAL NOT NULL DEFAULT 2.5,
      interval_days INTEGER NOT NULL DEFAULT 0,
      repetitions INTEGER NOT NULL DEFAULT 0,
      due_at INTEGER NOT NULL,
      last_score INTEGER NOT NULL DEFAULT 0,
      UNIQUE(speech_id, sentence_index)
    );
  ''');

  Future<void> _createIndexes(Database db) async {
    await db.execute('CREATE INDEX IF NOT EXISTS idx_attempts_time '
        'ON attempts(practiced_at)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_attempts_speech_time '
        'ON attempts(speech_id, practiced_at)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_attempts_review '
        'ON attempts(needs_review)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_review_due '
        'ON review_cards(due_at)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_vocab_due '
        'ON vocab(due_at)');
  }

  // ── 逐句尝试 ─────────────────────────────────────────────────
  Future<int> insertAttempt(Map<String, Object?> row) async {
    final db = await database;
    return db.insert('attempts', row);
  }

  Future<int> insertRetellRecord(Map<String, Object?> row) async {
    final db = await database;
    return db.insert('retell_records', row);
  }

  /// 同句历史成绩（P1-6：最优分 / 近 N 次滑动均值 / 置信度）
  Future<List<int>> sentenceHistory(String speechId, int index,
      {int limit = 5}) async {
    final db = await database;
    final rows = await db.query(
      'attempts',
      columns: ['score'],
      where: 'speech_id = ? AND sentence_index = ?',
      whereArgs: [speechId, index],
      orderBy: 'practiced_at DESC',
      limit: limit,
    );
    return [for (final r in rows) (r['score'] as num).toInt()];
  }

  /// 今日：句数 + 平均分 + 累计学习天数 + 连续打卡
  Future<({int count, double avg, int days, int streak})> overview() async {
    final db = await database;
    final now = DateTime.now();
    final startOfDay =
        DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;

    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS c, AVG(score) AS a FROM attempts '
      'WHERE practiced_at >= ?',
      [startOfDay],
    );
    final daysRows = await db.rawQuery(
      'SELECT COUNT(DISTINCT date(practiced_at/1000, "unixepoch", "localtime")) AS d '
      'FROM attempts',
    );
    final series = await dailySeries(400);
    return (
      count: (rows.first['c'] as int?) ?? 0,
      avg: (rows.first['a'] as num?)?.toDouble() ?? 0,
      days: (daysRows.first['d'] as int?) ?? 0,
      streak: streakFrom(series),
    );
  }

  /// 近 [days] 天每日句数与均分（P1-5：趋势曲线，聚合下推 SQL）
  Future<List<DailyPoint>> dailySeries(int days) async {
    final db = await database;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final from = today.subtract(Duration(days: days - 1));
    final rows = await db.rawQuery(
      'SELECT date(practiced_at/1000, "unixepoch", "localtime") AS d, '
      'COUNT(*) AS c, AVG(score) AS a FROM attempts '
      'WHERE practiced_at >= ? GROUP BY d',
      [from.millisecondsSinceEpoch],
    );
    final map = <String, DailyPoint>{};
    for (final r in rows) {
      final d = r['d'] as String;
      map[d] = DailyPoint(
        date: d,
        count: (r['c'] as int?) ?? 0,
        avg: (r['a'] as num?)?.toDouble() ?? 0,
      );
    }
    final out = <DailyPoint>[];
    for (var i = 0; i < days; i++) {
      final d = from.add(Duration(days: i));
      final key =
          '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      out.add(map[key] ?? DailyPoint(date: key, count: 0, avg: 0));
    }
    return out;
  }

  /// 连续打卡天数（委托纯函数，便于单测）
  static int streakFrom(List<DailyPoint> series) => streakFromSeries(series);

  /// 错词 TOP（P0-6：只取近 90 天，避免全表进内存）
  Future<List<MapEntry<String, int>>> topWrongWords({int limit = 10}) async {
    final db = await database;
    final from = DateTime.now()
        .subtract(const Duration(days: 90))
        .millisecondsSinceEpoch;
    final rows = await db.query(
      'attempts',
      columns: ['wrong_words'],
      where: 'practiced_at >= ? AND wrong_words IS NOT NULL',
      whereArgs: [from],
    );
    final counts = <String, int>{};
    for (final r in rows) {
      final raw = r['wrong_words'] as String?;
      if (raw == null || raw.isEmpty) continue;
      for (final w in json.decode(raw) as List) {
        final word = (w as String).toLowerCase();
        counts[word] = (counts[word] ?? 0) + 1;
      }
    }
    final list = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return list.take(limit).toList();
  }

  /// 待复习句子：优先读 SRS 队列；无排程数据时回退旧的布尔标记
  Future<List<Map<String, Object?>>> reviewItems({int limit = 30}) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    final scheduled = await db.query(
      'review_cards',
      where: 'due_at <= ?',
      whereArgs: [now],
      orderBy: 'due_at ASC',
      limit: limit,
    );
    if (scheduled.isNotEmpty) {
      return [
        for (final r in scheduled)
          {
            'speech_id': r['speech_id'],
            'sentence_index': r['sentence_index'],
            'wrong_words': '[]',
            'due_at': r['due_at'],
            'interval_days': r['interval_days'],
          }
      ];
    }
    return db.query(
      'attempts',
      where: 'needs_review = 1',
      orderBy: 'practiced_at DESC',
      limit: limit,
    );
  }

  Future<void> resolveReview(String speechId, int sentenceIndex) async {
    final db = await database;
    // 只处理该句最新一条，不再整篇同句全量更新
    await db.rawUpdate(
      'UPDATE attempts SET needs_review = 0 WHERE id IN '
      '(SELECT id FROM attempts WHERE speech_id = ? AND sentence_index = ? '
      'ORDER BY practiced_at DESC LIMIT 1)',
      [speechId, sentenceIndex],
    );
  }

  // ── 断点续读（P1-4）─────────────────────────────────────────
  Future<int> getProgress(String speechId) async {
    final db = await database;
    final rows = await db.query(
      'speech_progress',
      columns: ['last_index'],
      where: 'speech_id = ?',
      whereArgs: [speechId],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['last_index'] as num?)?.toInt() ?? 0;
  }

  Future<Map<String, int>> allProgress() async {
    final db = await database;
    final rows = await db.query('speech_progress');
    return {
      for (final r in rows)
        r['speech_id'] as String: (r['last_index'] as num?)?.toInt() ?? 0,
    };
  }

  Future<void> saveProgress(String speechId, int index,
      {bool completed = false}) async {
    final db = await database;
    await db.insert(
      'speech_progress',
      {
        'speech_id': speechId,
        'last_index': index,
        'updated_at': DateTime.now().millisecondsSinceEpoch,
        'completed': completed ? 1 : 0,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<Map<String, Object?>>> recentProgress({int limit = 5}) async {
    final db = await database;
    return db.query('speech_progress',
        orderBy: 'updated_at DESC', limit: limit);
  }

  // ── 生词本（P1-2）───────────────────────────────────────────
  Future<void> addVocab({
    required String word,
    String? phonetic,
    String? meaning,
    String? sourceSentence,
    String? speechId,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(
      'vocab',
      {
        'word': word.toLowerCase(),
        'phonetic': phonetic,
        'meaning': meaning,
        'source_sentence': sourceSentence,
        'speech_id': speechId,
        'created_at': now,
        'due_at': now,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  Future<void> removeVocab(String word) async {
    final db = await database;
    await db.delete('vocab', where: 'word = ?', whereArgs: [word.toLowerCase()]);
  }

  Future<bool> hasVocab(String word) async {
    final db = await database;
    final rows = await db.query('vocab',
        columns: ['id'], where: 'word = ?', whereArgs: [word.toLowerCase()]);
    return rows.isNotEmpty;
  }

  Future<List<VocabItem>> allVocab() async {
    final db = await database;
    final rows = await db.query('vocab', orderBy: 'created_at DESC');
    return [for (final r in rows) VocabItem.fromRow(r)];
  }

  Future<List<VocabItem>> dueVocab({int limit = 30}) async {
    final db = await database;
    final rows = await db.query(
      'vocab',
      where: 'due_at <= ?',
      whereArgs: [DateTime.now().millisecondsSinceEpoch],
      orderBy: 'due_at ASC',
      limit: limit,
    );
    return [for (final r in rows) VocabItem.fromRow(r)];
  }

  Future<void> updateVocabSchedule(int id, Schedule s) async {
    final db = await database;
    await db.update(
      'vocab',
      {
        'ease': s.ease,
        'interval_days': s.intervalDays,
        'repetitions': s.repetitions,
        'due_at': s.dueAt,
        'lapses': s.lapses,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ── SRS 复习卡片（P1-3）─────────────────────────────────────
  Future<void> upsertReviewCard(String speechId, int index, int score) async {
    final db = await database;
    final existing = await db.query(
      'review_cards',
      where: 'speech_id = ? AND sentence_index = ?',
      whereArgs: [speechId, index],
    );
    final prev = existing.isEmpty
        ? const Schedule(ease: 2.5, intervalDays: 0, repetitions: 0, dueAt: 0)
        : Schedule.fromRow(existing.first);
    final next = Srs.next(prev: prev, score: score);
    await db.insert(
      'review_cards',
      {
        'speech_id': speechId,
        'sentence_index': index,
        'ease': next.ease,
        'interval_days': next.intervalDays,
        'repetitions': next.repetitions,
        'due_at': next.dueAt,
        'last_score': score,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<int> dueReviewCount() async {
    final db = await database;
    final r = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM review_cards WHERE due_at <= ?',
      [DateTime.now().millisecondsSinceEpoch],
    );
    return (r.first['c'] as int?) ?? 0;
  }

  Future<void> clearAttempts() async {
    final db = await database;
    await db.delete('attempts');
    await db.delete('retell_records');
    await db.delete('review_cards');
    await db.delete('speech_progress');
  }
}

/// 生词本条目
class VocabItem {
  final int id;
  final String word;
  final String phonetic;
  final String meaning;
  final String sourceSentence;
  final String speechId;
  final Schedule schedule;

  const VocabItem({
    required this.id,
    required this.word,
    required this.phonetic,
    required this.meaning,
    required this.sourceSentence,
    required this.speechId,
    required this.schedule,
  });

  factory VocabItem.fromRow(Map<String, Object?> r) => VocabItem(
        id: (r['id'] as num?)?.toInt() ?? 0,
        word: r['word'] as String? ?? '',
        phonetic: r['phonetic'] as String? ?? '',
        meaning: r['meaning'] as String? ?? '',
        sourceSentence: r['source_sentence'] as String? ?? '',
        speechId: r['speech_id'] as String? ?? '',
        schedule: Schedule.fromRow(r),
      );
}
