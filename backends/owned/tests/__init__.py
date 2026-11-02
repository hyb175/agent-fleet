import shutil
import subprocess
import unittest
from pathlib import Path

SHELL = str(Path(shutil.which('bash')).resolve())


def runtime_roots():
    return ('/nix/store',) if SHELL.startswith('/nix/store/') else ('/usr/bin', '/usr/lib')


def _bwrap_works():
    # A host that forbids unprivileged namespaces (or has no bwrap) must skip, not fail.
    try:
        probe = subprocess.run([shutil.which('bwrap') or 'bwrap', '--unshare-user', '--ro-bind', '/', '/', 'true'],
                               capture_output=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return False
    return probe.returncode == 0


# The sandbox fixtures bind the Nix store as the only runtime; other layouts lack the ELF loader alias.
needs_sandbox = unittest.skipUnless(SHELL.startswith('/nix/store/') and _bwrap_works(),
                                    'bubblewrap unusable here or runtime is not the Nix store')
