#!/usr/bin/env python3
"""Bounded staged-source audit. Never print matched credential values.

--strip-metadata performs lossless metadata-only sanitization of staged branding
assets; it preserves PNG compressed pixel chunks and JPEG scan bytes. Re-stage
after sanitization. This is not a complete security or rights audit.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys


def sanitize_image(data):
    if data.startswith(b'\x89PNG\r\n\x1a\n'):
        output = bytearray(data[:8])
        pixels_before, pixels_after = [], []
        cursor = 8
        while cursor < len(data):
            length = struct.unpack('>I', data[cursor:cursor + 4])[0]
            chunk = data[cursor:cursor + length + 12]
            kind = chunk[4:8]
            if kind == b'IDAT':
                pixels_before.append(chunk)
            if kind not in (b'tEXt', b'iTXt', b'zTXt', b'eXIf', b'tIME'):
                output.extend(chunk)
                if kind == b'IDAT':
                    pixels_after.append(chunk)
            cursor += length + 12
        assert pixels_before == pixels_after
        return bytes(output)
    if data.startswith(b'\xff\xd8'):
        output = bytearray(data[:2])
        cursor = 2
        while cursor < len(data):
            assert data[cursor] == 0xff
            marker = data[cursor + 1]
            if marker == 0xda:  # Start of Scan: preserve every remaining byte.
                output.extend(data[cursor:])
                return bytes(output)
            length = int.from_bytes(data[cursor + 2:cursor + 4], 'big')
            segment = data[cursor:cursor + 2 + length]
            if marker not in (0xe1, 0xed, 0xfe):  # EXIF/XMP, IPTC, comments.
                output.extend(segment)
            cursor += 2 + length
        raise ValueError('JPEG has no pixel scan')
    return data


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--strip-metadata', action='store_true')
    args = parser.parse_args()
    root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip())
    paths = [p for p in subprocess.check_output(['git', 'ls-files', '--cached', '-z'], cwd=root).decode().split('\0') if p]
    if not paths:
        raise SystemExit('No staged/tracked source to audit')
    issues, sanitized, reviewed, assets = [], [], [], []
    hard_patterns = {
        'personal_absolute_path': rb'/(?:Users|home)/[A-Za-z0-9_-]+',
        'provider_or_git_key': rb'(?:sk-(?:proj-|ant-)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{30,}|AKIA[A-Z0-9]{16}|LTAI[A-Za-z0-9]{16,})',
        'private_key': rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----',
    }
    assignment = rb'''(?i)(?:api[_-]?key|access[_-]?token|secret|password)\s*[:=]\s*["']([^"'\r\n]{8,})["']'''
    fixture_values = {b'test-password', b'test-password-123'}
    for rel in paths:
        path = root / rel
        if path.is_symlink():
            issues.append({'file': rel, 'rule': 'symlink'})
            continue
        if any(part in {'.git', '.build', '.next', 'node_modules', 'downloads', 'dist', 'qa', 'work', 'outputs', 'output'} for part in path.relative_to(root).parts):
            issues.append({'file': rel, 'rule': 'private_or_generated_directory'})
        if path.name.startswith('.env') and rel != 'upstream/.env.example':
            issues.append({'file': rel, 'rule': 'environment_file'})
        data = path.read_bytes()
        indexed = subprocess.check_output(['git', 'show', ':' + rel], cwd=root)
        if not args.strip_metadata and data != indexed:
            issues.append({'file': rel, 'rule': 'unstaged_change_not_audited_in_index'})
        if path.suffix.lower() in {'.gif', '.mp4', '.mov', '.wav', '.mp3', '.pdf', '.dmg', '.pem', '.p12', '.key', '.log', '.zip', '.gz'}:
            issues.append({'file': rel, 'rule': 'media_archive_or_private_material'})
        is_image = rel.startswith('upstream/public/') and path.suffix in {'.png', '.jpg', '.ico'}
        if is_image:
            clean = sanitize_image(data)
            if clean != data:
                if args.strip_metadata:
                    path.write_bytes(clean)  # Bulk, lossless metadata sanitization.
                    sanitized.append(rel)
                    data = clean
                else:
                    issues.append({'file': rel, 'rule': 'image_metadata'})
            assets.append({'file': rel, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
        elif b'\x00' in data[:8192]:
            issues.append({'file': rel, 'rule': 'unexpected_binary'})
        for label, pattern in hard_patterns.items():
            for match in re.finditer(pattern, data):
                issues.append({'file': rel, 'line': data[:match.start()].count(b'\n') + 1, 'rule': label})
        if not is_image:
            for match in re.finditer(assignment, data):
                item = {'file': rel, 'line': data[:match.start()].count(b'\n') + 1, 'rule': 'literal_credential_assignment'}
                if (rel.startswith('tests/') or '.test.' in rel) and match.group(1) in fixture_values:
                    reviewed.append(item)
                else:
                    issues.append(item)
    staged_diff = subprocess.run(['git', 'diff', '--cached', '--check'], cwd=root, capture_output=True)
    if staged_diff.returncode:
        issues.append({'rule': 'staged_whitespace_check'})
    print(json.dumps({'files': len(paths), 'issues': issues, 'sanitized': sanitized, 'synthetic_fixture_matches': reviewed, 'assets': assets}, ensure_ascii=False, indent=2))
    return 1 if issues else 0


if __name__ == '__main__':
    sys.exit(main())
