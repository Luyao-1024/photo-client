#!/usr/bin/env python3
"""Prepare local build dependencies without installing system packages.

libmpv development files use the system package or Fedora RPMs unpacked into
ignored .tooling. A verified pillow-heif wheel supplies ONLY native libheif /
HEVC libraries when the system decoder is unavailable; Python is not required
by the built application. No downloads occur while browsing local media.
"""
from pathlib import Path
import ctypes
import hashlib
import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RUNTIME = ROOT / '.tooling' / 'media-runtime'
PACKAGES = ['mpv-libs.x86_64', 'mpv-devel.x86_64', 'mujs.x86_64',
            'compat-lua-libs.x86_64', 'vapoursynth-libs.x86_64', 'libXpresent.x86_64']
HEIF_VERSION = '1.8.1'
HEIF_WHEEL = 'pillow_heif-1.8.1-cp313-cp313-manylinux_2_27_x86_64.manylinux_2_28_x86_64.whl'
HEIF_SHA256 = 'cf1f60ee05d1280f98c00a052829963e57790dce0ca8203828658b14f8c0cf7b'


def system_hevc_decoder():
    try:
        library = ctypes.CDLL('libheif.so.1')
        library.heif_context_alloc.restype = ctypes.c_void_p
        context = library.heif_context_alloc()
        if not context:
            return False
        library.heif_have_decoder_for_format.argtypes = [ctypes.c_int]
        found = library.heif_have_decoder_for_format(1) != 0  # heif_compression_HEVC
        library.heif_context_free.argtypes = [ctypes.c_void_p]
        library.heif_context_free(context)
        return found
    except (OSError, AttributeError):
        return False


def prepare_heif():
    library_dir = RUNTIME / 'usr/lib64'
    if (library_dir / 'libheif.so.1').exists() or system_hevc_decoder():
        return
    wheels = ROOT / '.tooling/media-wheels'
    wheels.mkdir(parents=True, exist_ok=True)
    wheel = wheels / HEIF_WHEEL
    if not wheel.exists():
        with urllib.request.urlopen(f'https://pypi.org/pypi/pillow-heif/{HEIF_VERSION}/json', timeout=30) as response:
            release = json.load(response)
        asset = next(entry for entry in release['urls'] if entry['filename'] == HEIF_WHEEL)
        if asset['digests']['sha256'] != HEIF_SHA256:
            raise RuntimeError('Unexpected HEIF release digest')
        pending = wheel.with_suffix('.download')
        print('Preparing native HEIF/HEVC decoder (build-time only)...', flush=True)
        with urllib.request.urlopen(asset['url'], timeout=30) as response, pending.open('wb') as output:
            shutil.copyfileobj(response, output)
        pending.replace(wheel)
    if hashlib.sha256(wheel.read_bytes()).hexdigest() != HEIF_SHA256:
        raise RuntimeError('HEIF decoder archive digest mismatch')
    library_dir.mkdir(parents=True, exist_ok=True)
    licenses = RUNTIME / 'usr/share/licenses/pillow-heif'
    licenses.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(wheel) as archive:
        for entry in archive.namelist():
            if entry.endswith('/'):
                continue
            if '.libs/' in entry and '.so' in entry:
                target = library_dir / Path(entry).name
                target.write_bytes(archive.read(entry))
                target.chmod(0o755)
            elif '/licenses/' in entry:
                (licenses / Path(entry).name).write_bytes(archive.read(entry))
    heif = next(library_dir.glob('libheif-*.so*'))
    (library_dir / 'libheif.so.1').symlink_to(heif.name)


def prepare():
    system_mpv = subprocess.run(['pkg-config', '--exists', 'mpv']).returncode == 0
    if not system_mpv:
        pc = RUNTIME / 'usr/lib64/pkgconfig/mpv.pc'
        if not pc.exists():
            if not shutil.which('dnf5'):
                raise RuntimeError('Install the libmpv development package before building on this distribution.')
            rpms = ROOT / '.tooling/media-rpms'
            rpms.mkdir(parents=True, exist_ok=True)
            subprocess.run(['dnf5', '--disable-repo=terra*', 'download', '--destdir', str(rpms), *PACKAGES], check=True)
            RUNTIME.mkdir(parents=True, exist_ok=True)
            for rpm in sorted(rpms.glob('*.x86_64.rpm')):
                unpack = subprocess.Popen(['rpm2cpio', str(rpm)], stdout=subprocess.PIPE)
                try:
                    subprocess.run(['cpio', '-idm', '--quiet'], stdin=unpack.stdout, cwd=RUNTIME, check=True)
                finally:
                    unpack.stdout.close()
                    if unpack.wait():
                        raise RuntimeError(f'Could not unpack {rpm.name}')
        text = pc.read_text()
        text = '\n'.join(f'prefix={RUNTIME / "usr"}' if line.startswith('prefix=') else line
                         for line in text.splitlines() if not line.startswith(('Requires.private:', 'Libs.private:'))) + '\n'
        pc.write_text(text)
    prepare_heif()
    return RUNTIME if RUNTIME.exists() else None


def prepare_heif_linker():
    """Supply -lheif's linker name even when only the runtime is installed.

    Prefer our bundled decoder. Otherwise ask the host compiler for the system
    runtime, without assuming Fedora's /lib64 or Debian's multiarch layout.
    Keep the development-only alias out of the application bundle.
    """
    library = RUNTIME / 'usr/lib64/libheif.so.1'
    if not library.is_file():
        compiler = shlex.split(os.environ.get('CC', 'cc'))
        result = subprocess.run(
            [*compiler, '-print-file-name=libheif.so.1'],
            check=True, capture_output=True, text=True,
        )
        library = Path(result.stdout.strip())
        if not library.is_absolute() or not library.is_file():
            raise RuntimeError('Cannot locate libheif.so.1; install the libheif development package.')
    library = library.resolve()
    directory = ROOT / '.tooling/media-link'
    directory.mkdir(parents=True, exist_ok=True)
    link = directory / 'libheif.so'
    if not link.is_symlink() or os.readlink(link) != str(library):
        # Atomic replacement also allows two build commands to prepare together.
        with tempfile.TemporaryDirectory(dir=directory) as pending:
            temporary = Path(pending) / link.name
            temporary.symlink_to(library)
            temporary.replace(link)
    return directory


def environment(env=None):
    result = dict(os.environ if env is None else env)
    runtime = prepare()
    linker = prepare_heif_linker()
    library_paths = [str(linker)]
    if runtime:
        library_paths.append(str(runtime / 'usr/lib64'))
        for key, value in [('PKG_CONFIG_PATH', str(runtime / 'usr/lib64/pkgconfig')),
                           ('LD_LIBRARY_PATH', str(runtime / 'usr/lib64'))]:
            result[key] = value + (os.pathsep + result[key] if result.get(key) else '')
    if result.get('LIBRARY_PATH'):
        library_paths.append(result['LIBRARY_PATH'])
    result['LIBRARY_PATH'] = os.pathsep.join(library_paths)
    return result, runtime


def bundle_runtime(bundle, runtime):
    if not runtime:
        return
    target = Path(bundle) / 'lib'
    target.mkdir(parents=True, exist_ok=True)
    for lib in (runtime / 'usr/lib64').glob('*.so*'):
        if not lib.is_file():
            continue
        destination = target / lib.name
        if destination.exists() or destination.is_symlink():
            destination.unlink()
        if lib.is_symlink():
            destination.symlink_to(Path(os.readlink(lib)).name)
        else:
            shutil.copy2(lib, destination)
    licenses = runtime / 'usr/share/licenses'
    if licenses.is_dir():
        shutil.copytree(licenses, Path(bundle) / 'data/licenses/media', dirs_exist_ok=True)


if __name__ == '__main__':
    try:
        if len(sys.argv) > 2 and sys.argv[1] == 'exec':
            env, _ = environment()
            os.execvpe(sys.argv[2], sys.argv[2:], env)
        path = prepare()
        print(path or 'system')
    except (RuntimeError, subprocess.CalledProcessError, OSError) as exc:
        print(f'media-runtime: {exc}', file=sys.stderr)
        sys.exit(1)
