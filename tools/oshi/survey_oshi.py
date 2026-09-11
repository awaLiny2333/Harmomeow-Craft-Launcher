#!/usr/bin/env python3
"""Survey which oshi-core version each Minecraft release requires (via BMCLAPI).

Usage:  python3 survey_oshi.py [min-version]        # default: 1.17

Output: one line per distinct oshi-core version, listing the MC releases that use it.

Why: MC bundles oshi-core, and each oshi version needs its own patched jar (see
build_oshi_meow.sh). This maps MC version -> oshi version so we know exactly which
jars to build. 1.16.5 and older do not depend on oshi.

Note: uses `curl` (system CA) rather than urllib, because python's SSL stack fails
behind the local proxy on this machine.
"""
import json
import subprocess
import sys
from collections import OrderedDict

BASE = 'https://bmclapi2.bangbang93.com'
MIN = tuple(int(x) for x in (sys.argv[1] if len(sys.argv) > 1 else '1.17').split('.'))


def get(url):
    return subprocess.run(['curl', '-sL', '--max-time', '30', '--retry', '3',
                           '--retry-delay', '2', url],
                          capture_output=True, check=True).stdout


def vt(v):
    return tuple(int(x) for x in v.split('.') if x.isdigit())


def main():
    manifest = json.loads(get(BASE + '/mc/game/version_manifest_v2.json'))
    rels = [x['id'] for x in manifest['versions']
            if x['type'] == 'release' and vt(x['id']) >= MIN]
    print('releases >= %s: %d' % ('.'.join(map(str, MIN)), len(rels)))

    groups = OrderedDict()
    for v in rels:
        try:
            data = json.loads(get(BASE + '/version/' + v + '/json'))
            oshi = None
            for lib in data.get('libraries', []):
                if lib.get('name', '').startswith('com.github.oshi:oshi-core:'):
                    oshi = lib['name'].split(':')[-1]
            groups.setdefault(oshi, []).append(v)
        except Exception as e:  # noqa: BLE001
            groups.setdefault('ERROR:' + str(e), []).append(v)

    print()
    for oshi, vs in groups.items():
        print('%-10s (%d): %s' % (oshi, len(vs), ' '.join(vs)))


if __name__ == '__main__':
    main()
