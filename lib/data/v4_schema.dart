import 'package:sqflite/sqflite.dart';

typedef SchemaFaultInjector = void Function(
  int statementIndex,
  String statement,
)?;

class V4Schema {
  const V4Schema._();

  // Product generation remains V4. SQLite schema versions continue to
  // increase for safe additive migrations inside that product generation.
  static const version = 6;

  static const legacyTables = <String>[
    'favorites',
    'categories',
    'category_songs',
    'metadata_cache',
    'song_overrides',
  ];

  static const v4Tables = <String>[
    'artists',
    'artist_profiles',
    'albums',
    'scan_roots',
    'scan_rules',
    'scan_runs',
    'tracks',
    'media_files',
    'media_file_relations',
    'file_metadata_raw',
    'inferred_metadata',
    'online_metadata',
    'artwork_assets',
    'track_overrides',
    'track_artists',
    'track_preferences',
    'track_stats',
    'play_events',
    'lyrics',
    'playlists',
    'playlist_tracks',
    'migration_state',
    'legacy_song_map',
    'migration_orphans',
  ];

  static Future<void> createLegacyTables(DatabaseExecutor db) async {
    await db.execute(
      'CREATE TABLE IF NOT EXISTS favorites(song_id INTEGER PRIMARY KEY)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS categories('
      'id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL UNIQUE)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS category_songs('
      'category_id INTEGER NOT NULL, song_id INTEGER NOT NULL, '
      'PRIMARY KEY(category_id, song_id))',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS metadata_cache('
      'song_id INTEGER PRIMARY KEY, title TEXT NOT NULL, artist TEXT NOT NULL, '
      'album TEXT NOT NULL, artwork BLOB, matched INTEGER NOT NULL, checked_at INTEGER NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE IF NOT EXISTS song_overrides('
      'song_id INTEGER PRIMARY KEY, title TEXT NOT NULL, artist TEXT NOT NULL, album TEXT NOT NULL)',
    );
  }

  static Future<void> createV4Tables(
    DatabaseExecutor db, {
    SchemaFaultInjector faultInjector,
  }) async {
    for (var index = 0; index < _statements.length; index++) {
      final statement = _statements[index];
      faultInjector?.call(index, statement);
      await db.execute(statement);
    }
  }

  static Future<void> createFileIdentityTables(DatabaseExecutor db) async {
    for (final statement in _fileIdentityStatements) {
      await db.execute(statement);
    }
    final trackColumns = await db.rawQuery('PRAGMA table_info(tracks)');
    if (!trackColumns.any((row) => row['name'] == 'preferred_file_source')) {
      await db.execute(
        '''ALTER TABLE tracks ADD COLUMN preferred_file_source TEXT NOT NULL
DEFAULT 'automatic' CHECK(preferred_file_source IN ('automatic','manual'))''',
      );
    }
  }

  static Future<void> createArtistProfilesTable(DatabaseExecutor db) async {
    await db.execute(_artistProfilesStatement);
    await db.execute(_artistProfilesPathIndex);
  }

  static const _fileIdentityStatements = <String>[
    '''CREATE TABLE IF NOT EXISTS media_file_relations(
      relation_id TEXT PRIMARY KEY CHECK(length(relation_id) = 36),
      file_a_id TEXT NOT NULL REFERENCES media_files(file_id) ON DELETE CASCADE,
      file_b_id TEXT NOT NULL REFERENCES media_files(file_id) ON DELETE CASCADE,
      relation_type TEXT NOT NULL
        CHECK(relation_type IN ('exactDuplicate','suspectedVersion','confirmedVersion','rejectedVersion')),
      similarity_score REAL NOT NULL DEFAULT 0 CHECK(similarity_score BETWEEN 0 AND 1),
      reason_json TEXT NOT NULL DEFAULT '{}',
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      CHECK(file_a_id <> file_b_id),
      UNIQUE(file_a_id, file_b_id)
    )''',
    'CREATE INDEX IF NOT EXISTS idx_media_file_relations_type '
        'ON media_file_relations(relation_type, similarity_score DESC)',
    'CREATE INDEX IF NOT EXISTS idx_media_file_relations_file_b '
        'ON media_file_relations(file_b_id)',
  ];

  static const _statements = <String>[
    '''CREATE TABLE IF NOT EXISTS artists(
      artist_id TEXT PRIMARY KEY CHECK(length(artist_id) = 36),
      display_name TEXT NOT NULL,
      normalized_name TEXT NOT NULL,
      sort_name TEXT,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''',
    _artistProfilesStatement,
    _artistProfilesPathIndex,
    '''CREATE TABLE IF NOT EXISTS albums(
      album_id TEXT PRIMARY KEY CHECK(length(album_id) = 36),
      title TEXT NOT NULL,
      normalized_title TEXT NOT NULL,
      album_artist_id TEXT REFERENCES artists(artist_id) ON DELETE SET NULL,
      year INTEGER CHECK(year IS NULL OR year BETWEEN 1000 AND 9999),
      album_type TEXT NOT NULL DEFAULT 'unknown'
        CHECK(album_type IN ('studio','ep','single','live','compilation','unknown')),
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS scan_roots(
      root_id TEXT PRIMARY KEY CHECK(length(root_id) = 36),
      tree_uri TEXT NOT NULL UNIQUE,
      display_name TEXT NOT NULL,
      volume_name TEXT,
      relative_path_hint TEXT,
      access_type TEXT NOT NULL CHECK(access_type IN ('safTree','mediaStore')),
      is_primary INTEGER NOT NULL DEFAULT 0 CHECK(is_primary IN (0,1)),
      permission_persisted INTEGER NOT NULL DEFAULT 0 CHECK(permission_persisted IN (0,1)),
      enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0,1)),
      last_scan_at INTEGER,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS scan_rules(
      rule_id TEXT PRIMARY KEY CHECK(length(rule_id) = 36),
      root_id TEXT NOT NULL REFERENCES scan_roots(root_id) ON DELETE CASCADE,
      rule_type TEXT NOT NULL CHECK(rule_type IN ('ignore','excludeRecommendation','needsReview')),
      relative_path_pattern TEXT NOT NULL,
      recursive INTEGER NOT NULL DEFAULT 1 CHECK(recursive IN (0,1)),
      created_at INTEGER NOT NULL,
      UNIQUE(root_id, rule_type, relative_path_pattern)
    )''',
    '''CREATE TABLE IF NOT EXISTS scan_runs(
      scan_id TEXT PRIMARY KEY CHECK(length(scan_id) = 36),
      root_id TEXT REFERENCES scan_roots(root_id) ON DELETE SET NULL,
      status TEXT NOT NULL CHECK(status IN ('running','completed','failed','cancelled')),
      discovered_count INTEGER NOT NULL DEFAULT 0,
      processed_count INTEGER NOT NULL DEFAULT 0,
      hash_pending_count INTEGER NOT NULL DEFAULT 0,
      checkpoint TEXT,
      started_at INTEGER NOT NULL,
      finished_at INTEGER,
      error TEXT
    )''',
    '''CREATE TABLE IF NOT EXISTS tracks(
      track_id TEXT PRIMARY KEY CHECK(length(track_id) = 36),
      title TEXT NOT NULL,
      artist_display TEXT NOT NULL DEFAULT '未知歌手',
      album_artist_display TEXT NOT NULL DEFAULT '未知歌手',
      album_display TEXT NOT NULL DEFAULT '未知专辑',
      album_id TEXT REFERENCES albums(album_id) ON DELETE SET NULL,
      year INTEGER CHECK(year IS NULL OR year BETWEEN 1000 AND 9999),
      disc_number INTEGER CHECK(disc_number IS NULL OR disc_number > 0),
      track_number INTEGER CHECK(track_number IS NULL OR track_number > 0),
      duration_ms INTEGER NOT NULL DEFAULT 0 CHECK(duration_ms >= 0),
      preferred_media_file_id TEXT REFERENCES media_files(file_id) ON DELETE SET NULL
        DEFERRABLE INITIALLY DEFERRED,
      preferred_file_source TEXT NOT NULL DEFAULT 'automatic'
        CHECK(preferred_file_source IN ('automatic','manual')),
      metadata_state TEXT NOT NULL DEFAULT 'unknown'
        CHECK(metadata_state IN ('complete','needsReview','unknown')),
      added_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL,
      deleted_at INTEGER
    )''',
    '''CREATE TABLE IF NOT EXISTS media_files(
      file_id TEXT PRIMARY KEY CHECK(length(file_id) = 36),
      track_id TEXT NOT NULL REFERENCES tracks(track_id) ON DELETE CASCADE,
      scan_root_id TEXT REFERENCES scan_roots(root_id) ON DELETE SET NULL,
      media_store_volume TEXT,
      media_store_id INTEGER,
      content_uri TEXT,
      document_uri TEXT,
      relative_path TEXT,
      parent_folder TEXT,
      filename TEXT NOT NULL,
      normalized_filename TEXT NOT NULL,
      extension TEXT NOT NULL DEFAULT '',
      mime_type TEXT NOT NULL DEFAULT '',
      size_bytes INTEGER NOT NULL DEFAULT 0 CHECK(size_bytes >= 0),
      modified_at INTEGER,
      duration_ms INTEGER NOT NULL DEFAULT 0 CHECK(duration_ms >= 0),
      bitrate INTEGER CHECK(bitrate IS NULL OR bitrate >= 0),
      sample_rate INTEGER CHECK(sample_rate IS NULL OR sample_rate >= 0),
      bit_depth INTEGER CHECK(bit_depth IS NULL OR bit_depth >= 0),
      sha256 TEXT CHECK(sha256 IS NULL OR length(sha256) = 64),
      hash_size INTEGER CHECK(hash_size IS NULL OR hash_size >= 0),
      hash_modified_at INTEGER,
      hash_state TEXT NOT NULL DEFAULT 'pending'
        CHECK(hash_state IN ('pending','ready','failed','stale')),
      duplicate_of_file_id TEXT REFERENCES media_files(file_id) ON DELETE SET NULL,
      last_seen_scan_id TEXT REFERENCES scan_runs(scan_id) ON DELETE SET NULL,
      missing_since INTEGER,
      status TEXT NOT NULL DEFAULT 'active'
        CHECK(status IN ('active','missing','duplicate','unsupported')),
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''',
    '''CREATE TRIGGER IF NOT EXISTS tracks_preferred_file_insert
      BEFORE INSERT ON tracks
      WHEN NEW.preferred_media_file_id IS NOT NULL
      BEGIN
        SELECT CASE WHEN NOT EXISTS(
          SELECT 1 FROM media_files
          WHERE file_id = NEW.preferred_media_file_id AND track_id = NEW.track_id
        ) THEN RAISE(ABORT, 'preferred media file must belong to track') END;
      END''',
    '''CREATE TRIGGER IF NOT EXISTS tracks_preferred_file_update
      BEFORE UPDATE OF preferred_media_file_id ON tracks
      WHEN NEW.preferred_media_file_id IS NOT NULL
      BEGIN
        SELECT CASE WHEN NOT EXISTS(
          SELECT 1 FROM media_files
          WHERE file_id = NEW.preferred_media_file_id AND track_id = NEW.track_id
        ) THEN RAISE(ABORT, 'preferred media file must belong to track') END;
      END''',
    '''CREATE TABLE IF NOT EXISTS file_metadata_raw(
      file_id TEXT PRIMARY KEY REFERENCES media_files(file_id) ON DELETE CASCADE,
      title TEXT,
      artist TEXT,
      album_artist TEXT,
      album TEXT,
      year INTEGER,
      disc_number INTEGER,
      track_number INTEGER,
      embedded_lyrics TEXT,
      embedded_artwork_key TEXT,
      tag_format TEXT,
      raw_payload TEXT,
      read_status TEXT NOT NULL CHECK(read_status IN ('complete','partial','failed')),
      read_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS inferred_metadata(
      file_id TEXT PRIMARY KEY REFERENCES media_files(file_id) ON DELETE CASCADE,
      title TEXT,
      artist TEXT,
      album_artist TEXT,
      album TEXT,
      year INTEGER,
      disc_number INTEGER,
      track_number INTEGER,
      inference_method TEXT NOT NULL,
      field_confidence_json TEXT NOT NULL,
      needs_review INTEGER NOT NULL DEFAULT 0 CHECK(needs_review IN (0,1)),
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS online_metadata(
      online_metadata_id TEXT PRIMARY KEY CHECK(length(online_metadata_id) = 36),
      track_id TEXT NOT NULL REFERENCES tracks(track_id) ON DELETE CASCADE,
      provider TEXT NOT NULL,
      provider_recording_id TEXT,
      provider_release_id TEXT,
      title TEXT,
      artist TEXT,
      album_artist TEXT,
      album TEXT,
      year INTEGER,
      disc_number INTEGER,
      track_number INTEGER,
      duration_ms INTEGER,
      confidence REAL NOT NULL DEFAULT 0 CHECK(confidence BETWEEN 0 AND 1),
      confirmed INTEGER NOT NULL DEFAULT 0 CHECK(confirmed IN (0,1)),
      rejected INTEGER NOT NULL DEFAULT 0 CHECK(rejected IN (0,1)),
      artwork_key TEXT,
      fetched_at INTEGER NOT NULL,
      UNIQUE(track_id, provider, provider_recording_id, provider_release_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS artwork_assets(
      artwork_id TEXT PRIMARY KEY CHECK(length(artwork_id) = 36),
      track_id TEXT REFERENCES tracks(track_id) ON DELETE CASCADE,
      file_id TEXT REFERENCES media_files(file_id) ON DELETE SET NULL,
      source TEXT NOT NULL CHECK(source IN ('manual','embedded','online','default')),
      cache_path TEXT,
      content_uri TEXT,
      mime_type TEXT,
      sha256 TEXT CHECK(sha256 IS NULL OR length(sha256) = 64),
      confidence REAL NOT NULL DEFAULT 1 CHECK(confidence BETWEEN 0 AND 1),
      created_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS track_overrides(
      track_id TEXT PRIMARY KEY REFERENCES tracks(track_id) ON DELETE CASCADE,
      title TEXT,
      artist TEXT,
      album_artist TEXT,
      album TEXT,
      year INTEGER,
      disc_number INTEGER,
      track_number INTEGER,
      custom_artwork_id TEXT REFERENCES artwork_assets(artwork_id) ON DELETE SET NULL,
      updated_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS track_artists(
      track_id TEXT NOT NULL REFERENCES tracks(track_id) ON DELETE CASCADE,
      artist_id TEXT NOT NULL REFERENCES artists(artist_id) ON DELETE CASCADE,
      role TEXT NOT NULL DEFAULT 'primary',
      position INTEGER NOT NULL DEFAULT 0 CHECK(position >= 0),
      PRIMARY KEY(track_id, artist_id, role)
    )''',
    '''CREATE TABLE IF NOT EXISTS track_preferences(
      track_id TEXT PRIMARY KEY REFERENCES tracks(track_id) ON DELETE CASCADE,
      liked INTEGER NOT NULL DEFAULT 0 CHECK(liked IN (0,1)),
      liked_at INTEGER,
      recommendation_excluded INTEGER NOT NULL DEFAULT 0 CHECK(recommendation_excluded IN (0,1)),
      exclusion_reason TEXT,
      updated_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS track_stats(
      track_id TEXT PRIMARY KEY REFERENCES tracks(track_id) ON DELETE CASCADE,
      play_count INTEGER NOT NULL DEFAULT 0 CHECK(play_count >= 0),
      completed_count INTEGER NOT NULL DEFAULT 0 CHECK(completed_count >= 0),
      skip_count INTEGER NOT NULL DEFAULT 0 CHECK(skip_count >= 0),
      manually_selected_count INTEGER NOT NULL DEFAULT 0 CHECK(manually_selected_count >= 0),
      total_play_duration_ms INTEGER NOT NULL DEFAULT 0 CHECK(total_play_duration_ms >= 0),
      last_played_at INTEGER,
      last_skipped_at INTEGER,
      first_played_at INTEGER,
      updated_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS play_events(
      event_id TEXT PRIMARY KEY CHECK(length(event_id) = 36),
      track_id TEXT NOT NULL REFERENCES tracks(track_id) ON DELETE CASCADE,
      media_file_id TEXT REFERENCES media_files(file_id) ON DELETE SET NULL,
      session_id TEXT,
      started_at INTEGER NOT NULL,
      ended_at INTEGER,
      listened_duration_ms INTEGER NOT NULL DEFAULT 0 CHECK(listened_duration_ms >= 0),
      track_duration_ms INTEGER NOT NULL DEFAULT 0 CHECK(track_duration_ms >= 0),
      completed INTEGER NOT NULL DEFAULT 0 CHECK(completed IN (0,1)),
      skipped INTEGER NOT NULL DEFAULT 0 CHECK(skipped IN (0,1)),
      manually_selected INTEGER NOT NULL DEFAULT 0 CHECK(manually_selected IN (0,1)),
      context_type TEXT NOT NULL DEFAULT 'library',
      context_id TEXT,
      playback_mode TEXT NOT NULL DEFAULT 'sequential'
    )''',
    '''CREATE TABLE IF NOT EXISTS lyrics(
      lyrics_id TEXT PRIMARY KEY CHECK(length(lyrics_id) = 36),
      track_id TEXT NOT NULL REFERENCES tracks(track_id) ON DELETE CASCADE,
      media_file_id TEXT REFERENCES media_files(file_id) ON DELETE SET NULL,
      scan_root_id TEXT REFERENCES scan_roots(root_id) ON DELETE SET NULL,
      content_uri TEXT,
      document_uri TEXT,
      relative_path TEXT,
      filename TEXT,
      source TEXT NOT NULL CHECK(source IN ('sidecarLrc','embedded','manual','online')),
      match_method TEXT NOT NULL,
      matched INTEGER NOT NULL DEFAULT 0 CHECK(matched IN (0,1)),
      confidence REAL NOT NULL DEFAULT 0 CHECK(confidence BETWEEN 0 AND 1),
      offset_ms INTEGER NOT NULL DEFAULT 0,
      size_bytes INTEGER,
      modified_at INTEGER,
      sha256 TEXT CHECK(sha256 IS NULL OR length(sha256) = 64),
      is_selected INTEGER NOT NULL DEFAULT 0 CHECK(is_selected IN (0,1)),
      created_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS playlists(
      playlist_id TEXT PRIMARY KEY CHECK(length(playlist_id) = 36),
      name TEXT NOT NULL,
      type TEXT NOT NULL DEFAULT 'user' CHECK(type IN ('user','system','dailyRecommendation')),
      legacy_category_id INTEGER UNIQUE,
      created_at INTEGER NOT NULL,
      updated_at INTEGER NOT NULL
    )''',
    '''CREATE TABLE IF NOT EXISTS playlist_tracks(
      playlist_id TEXT NOT NULL REFERENCES playlists(playlist_id) ON DELETE CASCADE,
      track_id TEXT NOT NULL REFERENCES tracks(track_id) ON DELETE CASCADE,
      position INTEGER NOT NULL DEFAULT 0 CHECK(position >= 0),
      added_at INTEGER NOT NULL,
      PRIMARY KEY(playlist_id, track_id)
    )''',
    '''CREATE TABLE IF NOT EXISTS migration_state(
      migration_id INTEGER PRIMARY KEY CHECK(migration_id = 1),
      source_version INTEGER NOT NULL,
      target_version INTEGER NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('ready','awaiting_scan','linking','completed','failed')),
      backup_manifest_path TEXT,
      started_at INTEGER NOT NULL,
      completed_at INTEGER,
      last_error TEXT,
      retry_count INTEGER NOT NULL DEFAULT 0
    )''',
    '''CREATE TABLE IF NOT EXISTS legacy_song_map(
      legacy_song_id INTEGER PRIMARY KEY,
      track_id TEXT REFERENCES tracks(track_id) ON DELETE SET NULL,
      file_id TEXT REFERENCES media_files(file_id) ON DELETE SET NULL,
      match_status TEXT NOT NULL DEFAULT 'awaiting_scan'
        CHECK(match_status IN ('awaiting_scan','matched','needsReview','orphaned')),
      matched_at INTEGER
    )''',
    '''CREATE TABLE IF NOT EXISTS migration_orphans(
      orphan_id TEXT PRIMARY KEY CHECK(length(orphan_id) = 36),
      legacy_song_id INTEGER NOT NULL UNIQUE,
      reason TEXT NOT NULL,
      legacy_data_json TEXT NOT NULL,
      candidate_track_id TEXT REFERENCES tracks(track_id) ON DELETE SET NULL,
      status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','resolved','dismissed')),
      created_at INTEGER NOT NULL,
      resolved_at INTEGER
    )''',
    ..._fileIdentityStatements,
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_scan_roots_primary '
        'ON scan_roots(is_primary) WHERE is_primary = 1 AND enabled = 1',
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_media_files_media_store '
        'ON media_files(media_store_volume, media_store_id) WHERE media_store_id IS NOT NULL',
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_media_files_content_uri '
        'ON media_files(content_uri) WHERE content_uri IS NOT NULL',
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_media_files_document_uri '
        'ON media_files(document_uri) WHERE document_uri IS NOT NULL',
    'CREATE INDEX IF NOT EXISTS idx_media_files_track ON media_files(track_id)',
    'CREATE INDEX IF NOT EXISTS idx_media_files_sha256 ON media_files(sha256)',
    'CREATE INDEX IF NOT EXISTS idx_media_files_path ON media_files(scan_root_id, relative_path)',
    'CREATE INDEX IF NOT EXISTS idx_media_files_filename ON media_files(normalized_filename)',
    'CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album_id, disc_number, track_number)',
    'CREATE INDEX IF NOT EXISTS idx_tracks_added_at ON tracks(added_at DESC)',
    'CREATE INDEX IF NOT EXISTS idx_artists_normalized_name ON artists(normalized_name)',
    'CREATE INDEX IF NOT EXISTS idx_albums_normalized_title ON albums(normalized_title)',
    'CREATE INDEX IF NOT EXISTS idx_track_stats_last_played ON track_stats(last_played_at DESC)',
    'CREATE INDEX IF NOT EXISTS idx_play_events_started ON play_events(started_at DESC)',
    'CREATE INDEX IF NOT EXISTS idx_play_events_track_started ON play_events(track_id, started_at DESC)',
    'CREATE INDEX IF NOT EXISTS idx_playlist_tracks_position '
        'ON playlist_tracks(playlist_id, position)',
    'CREATE UNIQUE INDEX IF NOT EXISTS idx_lyrics_selected '
        'ON lyrics(track_id) WHERE is_selected = 1',
    'CREATE INDEX IF NOT EXISTS idx_online_metadata_track ON online_metadata(track_id, confidence DESC)',
  ];

  static const _artistProfilesStatement =
      '''CREATE TABLE IF NOT EXISTS artist_profiles(
      artist_id TEXT PRIMARY KEY REFERENCES artists(artist_id) ON DELETE CASCADE,
      scan_root_id TEXT REFERENCES scan_roots(root_id) ON DELETE SET NULL,
      relative_directory TEXT NOT NULL,
      artwork_cache_path TEXT,
      artwork_mime_type TEXT,
      artwork_sha256 TEXT CHECK(artwork_sha256 IS NULL OR length(artwork_sha256) = 64),
      updated_at INTEGER NOT NULL
    )''';

  static const _artistProfilesPathIndex =
      'CREATE INDEX IF NOT EXISTS idx_artist_profiles_root_path '
      'ON artist_profiles(scan_root_id, relative_directory)';
}
