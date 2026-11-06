#!/usr/bin/env python3
"""Verify final APK, Mac ZIP, and corresponding-source assets before publication."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import subprocess
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def verify(directory, allow_dirty):
    def asset(pattern):
        found = list(directory.glob(pattern))
        require(len(found) == 1, f'Expected one {pattern}, found {len(found)}')
        return found[0]
    apk = asset('disproid-receiver-*.apk')
    mac = asset('disproid-helper-*.zip')
    source = asset('disproid-source-*.tar.gz')
    with tarfile.open(source) as src, zipfile.ZipFile(apk) as android, zipfile.ZipFile(mac) as helper:
        def read(name):
            return src.extractfile('disproid/' + name).read()
        build = json.loads(read('SOURCE_BUILD.json'))
        require(allow_dirty or not build['dirty'], 'Source archive contains uncommitted changes')
        require(build['commit'] == subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT).decode().strip(), 'Source commit differs from verifier checkout')
        require(source.name == build['source_archive'], 'Source archive filename mismatch')
        required = ['LICENSE', 'THIRD_PARTY_NOTICES.md', 'DISTRIBUTION.md', 'licenses/LGPL-2.1.txt',
                    'licenses/Apache-2.0.txt', 'SOURCES.txt', 'VENDORED_NOTICES.txt', 'index.html']
        for artifact, prefix in [(android, 'assets/oss/'), (helper, 'Disproid Helper.app/Contents/Resources/oss/')]:
            binary_build = json.loads(artifact.read(prefix + 'build.json'))
            require(binary_build == {key: build[key] for key in binary_build}, 'Binary/source build identity mismatch')
            for name in required:
                data = artifact.read(prefix + name)
                require(data, f'Empty bundled notice: {name}')
                if name in ['LICENSE', 'THIRD_PARTY_NOTICES.md', 'DISTRIBUTION.md', 'licenses/LGPL-2.1.txt', 'licenses/Apache-2.0.txt']:
                    require(data == read(name), f'Binary/source notice differs: {name}')
            headers = artifact.read(prefix + 'VENDORED_NOTICES.txt')
            for attribution in [b'Tom Cocagne', b'Serge A. Zaitsev', b'Michael G Schwern', b'Permission is hereby granted']:
                require(attribution in headers, f'Missing MIT attribution: {attribution}')
        dependencies = json.loads(read('dependency-sources/dependencies.json'))
        require(dependencies, 'Missing runtime dependency sources')
        binaries = json.loads(android.read('assets/oss/runtime-dependencies.json'))
        require({d['binary_sha256'] for d in dependencies} == {d['sha256'] for d in binaries}, 'Dependency sources do not cover exactly all APK inputs')
        for dep in dependencies:
            for kind in ['source', 'pom']:
                require(hashlib.sha256(read('dependency-sources/' + dep[kind])).hexdigest() == dep[kind + '_sha256'], f'Dependency {kind} mismatch: {dep["coordinate"]}')
        require(b'MAJOR=3' in read('android/native-deps/src/openssl/VERSION.dat'), 'OpenSSL sources missing')
        for name in ['android/app/src/main/cpp/CMakeLists.txt', 'android/native-deps/src/openssl/crypto/aes/aes_core.c',
                     'android/app/src/main/kotlin/io/disproid/receiver/MainActivity.kt',
                     'mac/Sources/disproid-helper/App.swift', 'mac/make-app.sh', 'scripts/distribution.py']:
            require(read(name), f'Missing source input: {name}')
        require(not any('/.build/' in p.name for p in src.getmembers()), 'Build cache leaked into source archive')
    print(f'PASS: APK, Mac ZIP, corresponding source; {len(dependencies)} resolved runtime source packages')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=ROOT / 'dist')
    parser.add_argument('--allow-dirty', action='store_true')
    args = parser.parse_args()
    verify(args.directory, args.allow_dirty)
