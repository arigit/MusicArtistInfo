#!/usr/bin/env python3
"""
Find artist pictures saved under the raw "Family, Given" tag (eg. "Davis, Miles.jpg" or
"Davis Miles.jpg") when a "Given Family" picture (eg. "Miles Davis.jpg") exists, too.
With mai-artist-names.patch in place those raw-name pictures are redundant (and often
show the wrong person). They'd keep being used for contributors that already have them.

Uses the LMS library to know which names are tagged "Family, Given" - file names alone
can't tell "Davis Miles" from "Miles Davis".

Dry run by default. --apply MOVES the duplicates to a backup folder (nothing is deleted).
Run it after a scan has finished, then rescan so LMS drops the moved pictures.

    sudo python3 mai-dedupe-artist-pics.py                 # show what would be moved
    sudo python3 mai-dedupe-artist-pics.py --apply         # move them

--orphans also moves raw-name pictures that have no "Given Family" counterpart, so the
next scan looks them up again (online) under the "Given Family" name. That needs a
"Clear library and rescan everything" scan.

--restore puts moved orphans back if that scan found no "Given Family" picture for them,
so no composer ends up without a picture (dry run too, add --apply):

    sudo python3 mai-dedupe-artist-pics.py --restore
    sudo python3 mai-dedupe-artist-pics.py --restore --apply

--placeholders also moves copies of Deezer's generic "no picture" silhouette, which older
lookups saved as if they were real photos. They block any further lookup for that artist.
After "Clear library and rescan everything" MAI looks those artists up again.

Every move is recorded in <backup>/manifest.tsv.
"""

import argparse
import hashlib
import os
import re
import shutil
import sqlite3
import sys

EXTENSIONS = ('jpg', 'png', 'jpeg', 'JPG', 'PNG', 'JPEG')   # same order as LMS' picture scan
MANIFEST = 'manifest.tsv'
PLACEHOLDER_MD5 = {'cf0b6a5247e606f67470140451774cb5', '3a0adf20e5abdafa2c1f954ca4537f36'}   # Deezer's "no picture" silhouette
SUFFIX = re.compile(r'^(?:jr|sr|[ivx]+)\.?$', re.I)


def normalize_artist_name(name):
    """Mirror of Plugins::MusicArtistInfo::Common::normalizeArtistName()"""
    if ',' not in name:
        return name

    m = re.match(r'^\s*([^,]+?)\s*,\s*([^,]+?)\s*(?:,\s*([^,]+?)\s*)?$', name)
    if not m:
        return name

    family, given, suffix = m.groups()
    if suffix and not SUFFIX.match(suffix):
        return name
    if SUFFIX.match(given):                                     # "Harry Connick, Jr."
        return name
    if re.match(r'^(?:the|a|an)\s', given, re.I):               # "Tyler, The Creator"
        return name
    if re.search(r'&|\+|/|\band\b|\d', f'{family} {given}', re.I):
        return name
    if family[:1].isupper() and re.match(r'^\S*\s+\S', family) and re.search(r'\S\s+\S', given):   # list of artists
        return name

    return ' '.join(p for p in (given, family, suffix) if p)


def ignore_punct(s):
    """Mirror of Slim::Utils::Text::ignorePunct()"""
    out = re.sub(r'[!-/:-@\[-`{-~]+', ' ', s)
    out = re.sub(r'  +', ' ', out).strip(' ')
    return out or s


def cleanup_filename(s):
    """Mirror of Slim::Utils::Misc::cleanupFilename()"""
    s = re.sub(r'[:\x00-\x1f/\\]+', ' ', s)
    return s[1:] if s.startswith('.') else s


def name_variants(name):
    """Mirror of Slim::Music::ContributorPictureScan::sanitizedNameVariants() (minus transliteration)"""
    name = re.sub(r'[:?*]', '', name)
    seen = []
    for n in (cleanup_filename(name), name):
        for v in (n, ignore_punct(n)):
            if v not in seen:
                seen.append(v)
    return seen


def pictures_for(name, files):
    return [f'{v}.{ext}' for v in name_variants(name) for ext in EXTENSIONS if f'{v}.{ext}' in files]


def read_pref(prefs_file, key):
    try:
        with open(prefs_file, encoding='utf-8') as fh:
            for line in fh:
                m = re.match(rf"^{key}:\s*['\"]?(.*?)['\"]?\s*$", line)
                if m:
                    return m.group(1)
    except OSError:
        pass
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--lyrion', default='/home/homeassistant/lyrion', help='Lyrion Docker /config folder on the host (default: %(default)s)')
    ap.add_argument('--folder', help='artist picture folder (default: MAI\'s artistImageFolder setting)')
    ap.add_argument('--backup', help='where --apply moves duplicates (default: <lyrion>/mai-removed-duplicates)')
    ap.add_argument('--apply', action='store_true', help='actually move the duplicates')
    ap.add_argument('--orphans', action='store_true', help='also move raw-name pictures without a "Given Family" picture, to have them looked up again')
    ap.add_argument('--placeholders', action='store_true', help='also move copies of Deezer\'s generic "no picture" silhouette, to have them looked up again')
    ap.add_argument('--restore', action='store_true', help='move back orphans which still have no "Given Family" picture after the rescan')
    args = ap.parse_args()

    db = os.path.join(args.lyrion, 'cache', 'library.db')
    folder = args.folder or read_pref(os.path.join(args.lyrion, 'prefs', 'plugin', 'musicartistinfo.prefs'), 'artistImageFolder')
    if folder and folder.startswith('/config/') and not os.path.isdir(folder):
        folder = os.path.join(args.lyrion, folder[len('/config/'):])    # container path -> host path
    backup = args.backup or os.path.join(args.lyrion, 'mai-removed-duplicates')

    if not folder or not os.path.isdir(folder):
        sys.exit(f'Artist picture folder not found: {folder!r} - pass it with --folder')
    if args.restore:
        return restore(folder, backup, args.apply)

    if not os.path.isfile(db):
        sys.exit(f'Library database not found: {db}')

    con = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
    names = sorted({r[0] for r in con.execute("SELECT name FROM contributors WHERE name LIKE '%,%'")})
    con.close()

    files = set(os.listdir(folder))
    print(f'Folder: {folder}\n{len(names)} contributors with a comma, {len(files)} files\n')

    moves, orphans = {}, []
    for raw in names:
        good_name = normalize_artist_name(raw)
        if good_name == raw:
            continue

        good = pictures_for(good_name, files)
        if not good:
            orphans += [(raw, f) for f in pictures_for(raw, files)]
            continue

        for dup in pictures_for(raw, files):
            if dup in good:
                continue
            same = os.path.getsize(os.path.join(folder, dup)) == os.path.getsize(os.path.join(folder, good[0]))
            print(f'{raw!r}: {dup!r} -> use {good[0]!r}{"  (same size)" if same else ""}')
            moves[dup] = ('duplicate', raw, good_name)

    if orphans:
        print(f'\nRaw-name pictures without a "Given Family" picture{"" if args.orphans else " (kept - use --orphans to move them too)"}:')
        for raw, f in orphans:
            print(f'{raw!r}: {f!r}')
        if args.orphans:
            for raw, f in orphans:
                moves[f] = ('orphan', raw, normalize_artist_name(raw))

    if args.placeholders:
        placeholders = []
        for f in sorted(files):
            path = os.path.join(folder, f)
            # artist.jpg is MAI's configured fallback picture - it may well be this very silhouette
            if os.path.splitext(f)[0].lower() in ('artist', 'composer'):
                continue
            if f not in moves and os.path.isfile(path) and os.path.getsize(path) < 100_000:
                with open(path, 'rb') as fh:
                    if hashlib.md5(fh.read()).hexdigest() in PLACEHOLDER_MD5:
                        placeholders.append(f)
        print(f'\n{len(placeholders)} placeholder silhouette(s): {", ".join(placeholders[:10])}{", ..." if len(placeholders) > 10 else ""}')
        for f in placeholders:
            stem = os.path.splitext(f)[0]
            moves[f] = ('placeholder', stem, stem)

    print(f'\n{len(moves)} picture(s) to move.')

    if not moves:
        return
    if not args.apply:
        print('Dry run - nothing changed. Re-run with --apply to move them to', backup)
        return

    os.makedirs(backup, exist_ok=True)
    with open(os.path.join(backup, MANIFEST), 'a', encoding='utf-8') as manifest:
        for f, (kind, raw, good_name) in sorted(moves.items()):
            # don't overwrite what an earlier run moved there
            target, n = f, 1
            while os.path.exists(os.path.join(backup, target)):
                target, n = f'{f}.{n}', n + 1
            shutil.move(os.path.join(folder, f), os.path.join(backup, target))
            manifest.write('\t'.join((kind, raw, good_name, f, target)) + '\n')

    print(f'Moved to {backup}.')
    if args.orphans or args.placeholders:
        print('Now run "Clear library and rescan everything" in LMS' + (', then --restore.' if args.orphans else '.'))
    else:
        print('Now rescan in LMS so the composers pick up the "Given Family" pictures.')


def restore(folder, backup, apply):
    path = os.path.join(backup, MANIFEST)
    if not os.path.isfile(path):
        sys.exit(f'Nothing to restore - no {path}')

    with open(path, encoding='utf-8') as fh:
        entries = [line.rstrip('\n').split('\t') for line in fh if line.strip()]

    files = set(os.listdir(folder))
    keep, back = [], []
    for entry in entries:
        kind, raw, good_name, f, target = entry
        if (kind == 'orphan' and os.path.isfile(os.path.join(backup, target))
                and not pictures_for(good_name, files) and f not in files):
            back.append(entry)
        else:
            keep.append(entry)

    for kind, raw, good_name, f, target in back:
        print(f'{raw!r}: no {good_name!r} picture found - restore {f!r}')

    orphans = sum(1 for e in entries if e[0] == 'orphan')
    print(f'\n{len(back)} of {orphans} moved orphan(s) still have no "Given Family" picture.')

    if not back:
        return
    if not apply:
        print('Dry run - nothing changed. Re-run with --restore --apply to move them back to', folder)
        return

    for kind, raw, good_name, f, target in back:
        shutil.move(os.path.join(backup, target), os.path.join(folder, f))

    with open(path, 'w', encoding='utf-8') as fh:
        fh.writelines('\t'.join(e) + '\n' for e in keep)

    print(f'Restored to {folder}. Rescan in LMS to have them used again.')


if __name__ == '__main__':
    main()
