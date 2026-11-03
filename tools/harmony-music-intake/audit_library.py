#!/usr/bin/env python3
"""Read-only local music attachment inventory; no downloads or tag rewriting."""

from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import unicodedata


AUDIO = {'.flac', '.wav', '.mp3', '.m4a', '.aac', '.ogg', '.opus'}
IMAGES = {'.jpg', '.jpeg', '.png', '.webp'}
DIRECTORY_COVERS = {'封面', 'cover', 'folder', 'front', 'album'}
ARTIST_COVERS = {'歌手封面', 'artist', 'portrait', '歌手'}
LINE_TIME = re.compile(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]')
WORD_TIME = re.compile(r'<(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?>')
MAX_LRC_BYTES = 1024 * 1024


def normalized(value: str) -> str:
    return unicodedata.normalize('NFC', value).casefold()


def linked(path: Path) -> bool:
    return path.is_symlink() or bool(
        getattr(path.lstat(), 'st_file_attributes', 0) & 0x400
    )


def inspect_lrc(path: Path) -> dict:
    with path.open('rb') as stream:
        raw = stream.read(MAX_LRC_BYTES + 1)
    if len(raw) > MAX_LRC_BYTES:
        return {'mode': 'not_checked', 'notes': ['lrc_over_size_limit']}
    encoding = 'utf-8-sig'
    try:
        text = raw.decode(encoding)
    except UnicodeDecodeError:
        encoding = 'gb18030'
        try:
            text = raw.decode(encoding)
        except UnicodeDecodeError:
            return {'mode': 'not_checked', 'notes': ['lrc_decode_failed']}
    line_tags = list(LINE_TIME.finditer(text))
    word_tags = list(WORD_TIME.finditer(text))
    notes = [] if encoding == 'utf-8-sig' else ['non_utf8_lrc']
    if any(int(tag.group(2)) >= 60 for tag in line_tags + word_tags):
        notes.append('invalid_timestamp_seconds')
    mode = ('enhanced_candidate' if word_tags else 'line_timed') if line_tags else 'untimed'
    if not line_tags:
        notes.append('no_line_timestamps')
    return {'mode': mode, 'encoding': encoding, 'notes': notes}


def stable_hash(path: Path) -> str:
    before = path.stat()
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    after = path.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise OSError('file_changed_during_hash')
    return digest.hexdigest()


def scan_library(root: Path, *, hash_duplicates=False, excluded_dirs=()) -> dict:
    root = root.resolve(strict=True)
    if not root.is_dir() or root == root.parent:
        raise ValueError('Choose a music directory, not a file or disk root')
    excluded = set(excluded_dirs)
    folders = defaultdict(list)
    skipped, errors = [], []

    def relative(path):
        return path.relative_to(root).as_posix()

    def walk_error(error):
        errors.append({'path': relative(Path(error.filename)), 'code': 'directory_read_failed'})

    for directory, dirnames, filenames in os.walk(root, followlinks=False, onerror=walk_error):
        parent = Path(directory)
        for name in sorted(dirnames[:]):
            path = parent / name
            try:
                reason = ('excluded_directory' if name.startswith('.') or name in excluded
                          else 'linked_path' if linked(path) else None)
            except OSError:
                reason = 'directory_stat_failed'
                errors.append({'path': relative(path), 'code': reason})
            if reason:
                dirnames.remove(name)
                skipped.append({'path': relative(path), 'code': reason})
        dirnames.sort()
        for name in sorted(filenames):
            path = parent / name
            if path.suffix.lower() not in AUDIO | IMAGES | {'.lrc'}:
                continue
            try:
                if linked(path):
                    skipped.append({'path': relative(path), 'code': 'linked_path'})
                    continue
                folders[parent].append(path)
            except OSError:
                errors.append({'path': relative(path), 'code': 'file_stat_failed'})

    rows, by_size, lyric_counts = [], defaultdict(list), Counter()
    for parent, files in sorted(folders.items()):
        image_files = [p for p in files if p.suffix.lower() in IMAGES]
        lyrics_by_stem = defaultdict(list)
        for path in files:
            if path.suffix.lower() == '.lrc':
                lyrics_by_stem[normalized(path.stem)].append(path)
        for path in files:
            if path.suffix.lower() not in AUDIO:
                continue
            notes = []
            try:
                size = path.stat().st_size
            except OSError:
                errors.append({'path': relative(path), 'code': 'file_stat_failed'})
                continue
            if size == 0:
                notes.append('empty_audio_file')
            else:
                by_size[size].append(path)
            lrcs = lyrics_by_stem.get(normalized(path.stem), [])
            if not lrcs:
                notes.append('no_same_name_lrc')
            elif len(lrcs) > 1:
                notes.append('ambiguous_same_name_lrc')
            lrc_results = []
            for lrc in lrcs:
                try:
                    info = inspect_lrc(lrc)
                except OSError:
                    info = {'mode': 'not_checked', 'notes': ['lrc_read_failed']}
                    errors.append({'path': relative(lrc), 'code': 'lrc_read_failed'})
                lyric_counts[info['mode']] += 1
                lrc_results.append({'path': relative(lrc), **info})
            covers = [p for p in image_files if normalized(p.stem) in
                      DIRECTORY_COVERS | {normalized(path.stem)}]
            if not covers:
                ordinary = [p for p in image_files if normalized(p.stem) not in ARTIST_COVERS]
                if len(ordinary) == 1:
                    covers = ordinary
            if not covers:
                notes.append('no_external_cover_candidate_embedded_unknown')
            rows.append({'path': relative(path), 'bytes': size, 'lyrics': lrc_results,
                         'external_cover_candidates': [relative(p) for p in covers],
                         'notes': notes})

    duplicates = []
    if hash_duplicates:
        for group in by_size.values():
            if len(group) < 2:
                continue
            by_hash = defaultdict(list)
            for path in group:
                try:
                    by_hash[stable_hash(path)].append(relative(path))
                except OSError:
                    errors.append({'path': relative(path), 'code': 'hash_failed_or_file_changed'})
            duplicates.extend({'sha256': digest, 'paths': paths}
                              for digest, paths in sorted(by_hash.items()) if len(paths) > 1)
    return {
        'format_version': 1, 'created_at': datetime.now(timezone.utc).isoformat(),
        'root': str(root), 'scan_complete': not errors,
        'limits': ['filesystem_snapshot_not_transactional', 'no_embedded_metadata_probe',
                   'no_audio_decode_or_quality_verification', 'no_lyric_audio_sync_verification',
                   'same_name_sidecars_only', 'private_report_do_not_publish'],
        'hash_duplicates': hash_duplicates, 'excluded_dirs': sorted(excluded),
        'summary': {'audio_files': len(rows),
                    'without_same_name_lrc': sum(not row['lyrics'] for row in rows),
                    'without_external_cover_candidate': sum(not row['external_cover_candidates']
                                                            for row in rows),
                    'lrc_modes': dict(lyric_counts),
                    'exact_duplicate_groups': len(duplicates) if hash_duplicates else None},
        'files': rows, 'exact_duplicates': duplicates, 'skipped': skipped, 'errors': errors,
    }


def write_report(report: dict, output: Path) -> None:
    output = output.resolve()
    root = Path(report['root']).resolve()
    if output == root or root in output.parents:
        raise ValueError('Report must be outside the music directory')
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open('x', encoding='utf-8') as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write('\n')


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--music-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--hash-duplicates', action='store_true')
    parser.add_argument('--exclude-dir', action='append', default=[])
    args = parser.parse_args()
    try:
        # Check the output boundary before traversing a potentially large library.
        root, output = args.music_root.resolve(strict=True), args.output.resolve()
        if output == root or root in output.parents or output.exists():
            raise ValueError('Choose a new report path outside the music directory')
        report = scan_library(root, hash_duplicates=args.hash_duplicates,
                              excluded_dirs=args.exclude_dir)
        write_report(report, output)
        print(json.dumps({'summary': report['summary'], 'scan_complete': report['scan_complete']},
                         ensure_ascii=False))
        return 0 if report['scan_complete'] else 1
    except (OSError, ValueError) as error:
        print(f'Audit failed: {error}', file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
