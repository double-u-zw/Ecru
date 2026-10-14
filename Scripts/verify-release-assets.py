"""Verify every downloaded draft asset against the accepted local package."""
from pathlib import Path
import hashlib, sys

def verify(local, downloaded):
    local, downloaded = Path(local), Path(downloaded)
    names = {f'Ecru-{local.name}-arm64.dmg', 'SHA256SUMS.txt', 'INSTALL.txt', 'RELEASE_NOTES.md'}
    actual = {p.name for p in downloaded.iterdir()}
    if actual != names:
        raise ValueError('Downloaded draft assets do not match the required asset set.')
    for name in names:
        a, b = local/name, downloaded/name
        if a.is_symlink() or b.is_symlink() or not a.is_file() or not b.is_file():
            raise ValueError('Release assets must be regular files: '+name)
        if hashlib.sha256(a.read_bytes()).digest() != hashlib.sha256(b.read_bytes()).digest():
            raise ValueError('Downloaded draft differs from accepted local asset: '+name)
    return names

if __name__ == '__main__':
    verify(*sys.argv[1:]); print('PASS: all four draft assets downloaded and verified byte for byte')
