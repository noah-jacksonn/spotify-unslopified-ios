#!/usr/bin/env python3
"""Read-only index of Suno IDs already present in one imported playlist."""
import argparse
import json
import re
from pathlib import Path
from urllib.parse import urlsplit

AUDIO = {'.mp3', '.m4a', '.aac', '.wav', '.aif', '.aiff', '.flac', '.ogg', '.opus', '.mp4', '.caf'}
UUID = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', re.I)


def suno_id(value):
    if not isinstance(value, str):
        return None
    try:
        url = urlsplit(value)
        parts = url.path.strip('/').split('/')
        if url.scheme == 'https' and url.netloc.lower() == 'suno.com' and len(parts) == 2 and parts[0] == 'song' and UUID.fullmatch(parts[1]):
            return parts[1].lower()
    except ValueError:
        pass
    return None


def inventory(playlist):
    playlist = Path(playlist).expanduser()
    if not playlist.is_dir():
        raise ValueError('Playlist folder does not exist: ' + str(playlist))
    songs, warnings, linked_files = [], [], set()
    if (playlist / 'Unslopified.archive.json').exists() or (playlist / '.Unslopified.archive.json.icloud').exists():
        warnings.append({'file': 'Unslopified.archive.json', 'issue': 'playlist_archived'})
    for sidecar in sorted(playlist.glob('*.json')):
        audio = sidecar.with_suffix('')
        if audio.suffix.lower() not in AUDIO:
            continue
        if sidecar.is_symlink() or audio.is_symlink():
            warnings.append({'file': sidecar.name, 'issue': 'symlink_skipped'})
            continue
        try:
            info = json.loads(sidecar.read_text())
            if not isinstance(info, dict):
                raise ValueError('Expected an object')
        except (OSError, ValueError) as error:
            warnings.append({'file': sidecar.name, 'issue': 'unreadable_metadata', 'error': type(error).__name__})
            continue
        placeholder = playlist / ('.' + audio.name + '.icloud')
        present = audio.is_file() or placeholder.is_file()
        if not present:
            warnings.append({'file': sidecar.name, 'issue': 'audio_missing'})
        else:
            linked_files.add(audio.name)
        songs.append({'file': audio.name, 'suno_id': suno_id(info.get('sourceURL')),
                      'title': info.get('title') if isinstance(info.get('title'), str) else None,
                      'has_lyrics': isinstance(info.get('lyrics'), str) and bool(info['lyrics'].strip()),
                      'audio_entry_present': present})
    for item in sorted(playlist.iterdir()):
        if item.name.startswith('.') and item.name.endswith('.json.icloud') and Path(item.name[:-7]).suffix == '.json':
            audio_name = item.name[1:-len('.json.icloud')]
            if Path(audio_name).suffix.lower() in AUDIO:
                warnings.append({'file': item.name, 'issue': 'metadata_downloading'})
    unlinked = sorted(item.name for item in playlist.iterdir()
                      if item.is_file() and not item.is_symlink() and item.suffix.lower() in AUDIO
                      and item.name not in linked_files)
    return {'playlist': str(playlist), 'known_suno_ids': sorted({song['suno_id'] for song in songs if song['audio_entry_present'] and song['suno_id']}),
            'songs': songs, 'audio_without_readable_sidecar': unlinked, 'warnings': warnings}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--playlist', required=True)
    args = parser.parse_args()
    try:
        result = inventory(args.playlist)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    print(json.dumps(result, indent=2, ensure_ascii=False))
