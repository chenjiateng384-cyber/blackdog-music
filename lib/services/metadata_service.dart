import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/song.dart';
import 'library_database.dart';

class MetadataService {
  MetadataService(this._database, {http.Client? client}) : _client = client ?? http.Client();

  final LibraryDatabase _database;
  final http.Client _client;
  Future<void> _queue = Future.value();
  DateTime? _lastMusicBrainzRequest;

  Future<Song> enrich(Song song) async {
    final cached = await _database.metadataFor(song.id);
    if (cached != null) return _mergeCache(song, cached);

    final completer = Completer<Song>();
    _queue = _queue.then((_) async {
      try {
        completer.complete(await _lookup(song));
      } catch (_) {
        completer.complete(song);
      }
    });
    return completer.future;
  }

  Song _mergeCache(Song song, MetadataCache cache) {
    if (!cache.matched) return song;
    return song.copyWith(
      title: cache.title,
      artist: cache.artist,
      album: cache.album,
      onlineArtwork: cache.artwork,
      metadataMatched: true,
    );
  }

  Future<Song> _lookup(Song song) async {
    await _respectRateLimit();
    final title = _escape(song.title);
    final hasArtist = song.artist != '未知歌手';
    final query = hasArtist
        ? 'recording:"$title" AND artist:"${_escape(song.artist)}"'
        : 'recording:"$title"';
    final uri = Uri.https(
      'musicbrainz.org',
      '/ws/2/recording/',
      {'query': query, 'fmt': 'json', 'limit': '1'},
    );
    _lastMusicBrainzRequest = DateTime.now();
    final response = await _client.get(uri, headers: const {
      'User-Agent': 'MyMusicLibrary/0.3.0 (personal-use Android app)',
      'Accept': 'application/json',
    }).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) return song;

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final recordings = json['recordings'] as List<dynamic>? ?? const [];
    if (recordings.isEmpty) return _rememberNoMatch(song);
    final recording = recordings.first as Map<String, dynamic>;
    final score = (recording['score'] as num?)?.toInt() ?? 0;
    if (score < (hasArtist ? 80 : 95)) return _rememberNoMatch(song);

    final matchedTitle = (recording['title'] as String?)?.trim();
    final credits = recording['artist-credit'] as List<dynamic>? ?? const [];
    final matchedArtist = credits.isEmpty
        ? null
        : (credits.first as Map<String, dynamic>)['name'] as String?;
    final releases = recording['releases'] as List<dynamic>? ?? const [];
    String? matchedAlbum;
    String? releaseId;
    if (releases.isNotEmpty) {
      final release = releases.first as Map<String, dynamic>;
      matchedAlbum = (release['title'] as String?)?.trim();
      releaseId = release['id'] as String?;
    }
    final artwork = releaseId == null ? null : await _downloadArtwork(releaseId);
    final enriched = song.copyWith(
      title: matchedTitle?.isNotEmpty == true ? matchedTitle : song.title,
      artist: matchedArtist?.trim().isNotEmpty == true ? matchedArtist!.trim() : song.artist,
      album: matchedAlbum?.isNotEmpty == true ? matchedAlbum : song.album,
      onlineArtwork: artwork,
      metadataMatched: true,
    );
    await _database.saveMetadata(
      song.id,
      title: enriched.title,
      artist: enriched.artist,
      album: enriched.album,
      artwork: artwork,
      matched: true,
    );
    return enriched;
  }

  Future<Song> _rememberNoMatch(Song song) async {
    await _database.saveMetadata(
      song.id,
      title: song.title,
      artist: song.artist,
      album: song.album,
      artwork: null,
      matched: false,
    );
    return song;
  }

  Future<Uint8List?> _downloadArtwork(String releaseId) async {
    try {
      final response = await _client
          .get(
            Uri.https('coverartarchive.org', '/release/$releaseId/front-250'),
            headers: const {'User-Agent': 'MyMusicLibrary/0.3.0'},
          )
          .timeout(const Duration(seconds: 15));
      final contentType = response.headers['content-type'] ?? '';
      if (response.statusCode == 200 &&
          contentType.startsWith('image/') &&
          response.bodyBytes.length <= 2 * 1024 * 1024) {
        return response.bodyBytes;
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  Future<void> _respectRateLimit() async {
    final last = _lastMusicBrainzRequest;
    if (last == null) return;
    final wait = const Duration(milliseconds: 1100) - DateTime.now().difference(last);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
  }

  String _escape(String value) => value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');

  void dispose() => _client.close();
}
