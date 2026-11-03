import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from audit_library import inspect_lrc, scan_library, stable_hash, write_report


class LibraryAuditTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.root = self.base / '音乐'
        self.root.mkdir()

    def put(self, name, content=b'fixture-not-real-audio'):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def test_audit_preserves_originals_and_matches_unicode_sidecars(self):
        self.put('歌手/专辑/01_你好 & Hello.FLAC')
        self.put('歌手/专辑/01_你好 & Hello.lrc', '[00:01.00]你好'.encode())
        self.put('歌手/专辑/cover.jpg', b'not-a-real-image')
        before = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        report = scan_library(self.root, hash_duplicates=True)
        after = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.assertEqual(before, after)
        self.assertEqual(report['summary']['audio_files'], 1)
        self.assertEqual(report['summary']['without_same_name_lrc'], 0)
        self.assertEqual(report['summary']['without_external_cover_candidate'], 0)
        self.assertIn('no_embedded_metadata_probe', report['limits'])

    def test_missing_sidecar_does_not_claim_embedded_artwork_missing(self):
        self.put('曲.wav')
        report = scan_library(self.root)
        self.assertIn('no_external_cover_candidate_embedded_unknown', report['files'][0]['notes'])

    def test_artist_image_is_not_used_as_single_image_album_fallback(self):
        self.put('歌手/曲.wav')
        self.put('歌手/歌手封面.jpg', b'image')
        self.assertEqual(scan_library(self.root)['summary']['without_external_cover_candidate'], 1)

    def test_hidden_and_explicit_exclusions_are_respected(self):
        self.put('.workbuddy/private.wav')
        self.put('UI设计/demo.wav')
        self.put('root.wav')
        report = scan_library(self.root, excluded_dirs=['UI设计'])
        self.assertEqual(report['summary']['audio_files'], 1)
        self.assertEqual(len(report['skipped']), 2)

    def test_duplicate_hash_only_reports_identical_bytes(self):
        self.put('a.wav', b'one')
        self.put('b.wav', b'one')
        self.put('c.wav', b'two')
        self.assertEqual(scan_library(self.root)['exact_duplicates'], [])
        self.assertIsNone(scan_library(self.root)['summary']['exact_duplicate_groups'])
        report = scan_library(self.root, hash_duplicates=True)
        self.assertEqual(report['exact_duplicates'][0]['paths'], ['a.wav', 'b.wav'])
        self.assertEqual(len(report['exact_duplicates']), 1)

    def test_empty_audio_and_plain_text_lyrics_are_not_silently_accepted(self):
        self.put('a.mp3', b'')
        self.put('a.lrc', '没有时间'.encode())
        row = scan_library(self.root, hash_duplicates=True)['files'][0]
        self.assertIn('empty_audio_file', row['notes'])
        self.assertEqual(row['lyrics'][0]['mode'], 'untimed')

    def test_enhanced_is_only_a_candidate_not_audio_alignment_proof(self):
        path = self.put('a.lrc', '[00:01.000]<00:01.000>你<00:01.500>'.encode())
        self.assertEqual(inspect_lrc(path)['mode'], 'enhanced_candidate')

    def test_gb18030_and_invalid_seconds_are_reported(self):
        path = self.put('a.lrc', '[00:70.00]你好'.encode('gb18030'))
        self.assertEqual(inspect_lrc(path)['notes'], ['non_utf8_lrc', 'invalid_timestamp_seconds'])

    def test_large_or_unreadable_text_is_not_loaded_without_bound(self):
        path = self.put('a.lrc', b'x' * (1024 * 1024 + 1))
        self.assertEqual(inspect_lrc(path)['mode'], 'not_checked')
        path.write_bytes(b'\xff')
        self.assertEqual(inspect_lrc(path)['notes'], ['lrc_decode_failed'])

    def test_report_never_writes_inside_music_root_or_overwrites(self):
        report = scan_library(self.root)
        with self.assertRaises(ValueError):
            write_report(report, self.root / 'report.json')
        target = self.base / 'reports' / 'audit.json'
        write_report(report, target)
        self.assertEqual(json.loads(target.read_text(encoding='utf-8'))['summary']['audio_files'], 0)
        with self.assertRaises(FileExistsError):
            write_report(report, target)

    def test_read_error_is_recorded_as_partial_scan(self):
        self.put('a.wav')
        self.put('a.lrc')
        with patch('audit_library.inspect_lrc', side_effect=PermissionError('locked')):
            report = scan_library(self.root)
        self.assertFalse(report['scan_complete'])
        self.assertEqual(report['errors'][0]['code'], 'lrc_read_failed')

    def test_link_is_skipped_even_when_it_points_inside_root(self):
        source = self.put('a.wav')
        link = self.root / 'b.wav'
        try:
            link.symlink_to(source)
        except OSError:
            self.skipTest('OS does not permit creating symlinks')
        report = scan_library(self.root)
        self.assertEqual(report['summary']['audio_files'], 1)
        self.assertEqual(report['skipped'][0]['code'], 'linked_path')

    def test_link_skip_logic_without_os_symlink_privileges(self):
        self.put('a.wav')
        self.put('linked.wav')
        self.put('linked_directory/hidden.wav')
        with patch('audit_library.linked', side_effect=lambda p: p.name.startswith('linked')):
            report = scan_library(self.root)
        self.assertEqual(report['summary']['audio_files'], 1)
        self.assertEqual(len(report['skipped']), 2)

    def test_report_output_link_cannot_escape_into_music_root(self):
        report = scan_library(self.root)
        # Resolve is mocked here because Windows may not permit creating symlinks.
        with patch.object(Path, 'resolve', side_effect=[self.root / 'report.json', self.root]):
            with self.assertRaises(ValueError):
                write_report(report, self.base / 'external-link.json')

    def test_hash_checks_for_changes_during_read(self):
        source = self.put('a.wav', b'one')
        before = source.stat()
        changed = type('ChangedStat', (), {'st_size': 4, 'st_mtime_ns': before.st_mtime_ns})()
        with patch.object(Path, 'stat', side_effect=[before, changed]):
            with self.assertRaisesRegex(OSError, 'file_changed'):
                stable_hash(source)
        self.assertEqual(stable_hash(source), hashlib.sha256(b'one').hexdigest())


if __name__ == '__main__':
    unittest.main()
