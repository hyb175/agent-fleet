"""Fail-closed filesystem and systemd generation boundary for owned workers."""

from dataclasses import asdict, dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time


class ProcessError(ValueError):
    pass


def _path(value, *, host=True):
    if not isinstance(value, (str, Path)) or any(c in str(value) for c in ('\0', '\n', '\r', '%')):
        raise ProcessError('invalid process path')
    path = Path(value)
    if not path.is_absolute() or '..' in path.parts or (host and any(p.is_symlink() for p in (path, *path.parents))):
        raise ProcessError('absolute paths without symlinks required')
    return path


def _inside(path, parent):
    return Path(path).is_relative_to(Path(parent))


def _json(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))


def boot_id():
    return Path('/proc/sys/kernel/random/boot_id').read_text().strip()


@dataclass(frozen=True)
class SandboxProfile:
    worktree: str
    git_directory: str
    common_directory: str
    private_objects: str
    home: str
    tmp: str
    executable: str
    runtime_roots: tuple[str, ...]
    read_binds: tuple[tuple[str, str], ...] = ()
    environment: tuple[tuple[str, str], ...] = ()
    search_path: tuple[str, ...] = ()

    def __post_init__(self):
        for field in ('worktree', 'git_directory', 'common_directory', 'private_objects', 'home', 'tmp', 'executable'):
            _path(getattr(self, field), host=field != 'executable' or self.executable not in {d for _, d in self.read_binds})
        writable = [self.worktree, self.git_directory, self.private_objects, self.home, self.tmp]
        if len(set(writable)) != len(writable) or any(a != b and (_inside(a, b) or _inside(b, a)) for a in writable for b in writable):
            raise ProcessError('writable paths must be disjoint')
        for path in writable:
            if _inside(Path.home(), path) or path in ('/tmp', '/var/tmp', '/run', '/etc', '/var', '/proc', '/sys', '/dev', '/nix', '/usr'):
                raise ProcessError('owner home and broad writable mounts are forbidden')
            if path != self.git_directory and _inside(path, self.common_directory):
                raise ProcessError('common Git metadata cannot contain worker writable mounts')
        if Path(self.git_directory).parent != Path(self.common_directory) / 'worktrees':
            raise ProcessError('a separate linked worktree Git directory is required')
        if any(_inside(self.common_directory, p) for p in writable):
            raise ProcessError('common Git metadata cannot be writable')
        allowed = ('/nix/store', '/usr/bin', '/usr/lib', '/usr/lib64', '/bin', '/lib', '/lib64')
        for root in self.runtime_roots:
            _path(root)
            if not any(_inside(root, p) for p in allowed):
                raise ProcessError('runtime roots must contain only system runtime')
        if not (any(_inside(self.executable, root) for root in self.runtime_roots)
                or self.executable in {destination for _, destination in self.read_binds}):
            raise ProcessError('executable must be in an explicit runtime root or exact read bind')
        for directory in self.search_path:
            _path(directory)
            if not any(_inside(directory, root) for root in self.runtime_roots):
                raise ProcessError('PATH must stay inside runtime roots')
        destinations = set()
        runtime_aliases = ('/bin/bash', '/bin/sh', '/usr/bin/env', '/lib64/ld-linux-x86-64.so.2')
        for source, destination in self.read_binds:
            _path(source)
            _path(destination, host=False)
            if not Path(source).is_file() or any(p in ('.ssh', '.aws', '.config', '.aios') for p in Path(source).parts):
                raise ProcessError('read binds require explicit regular provider/runtime files')
            if not (_inside(destination, '/opt') or _inside(destination, '/home/worker') or destination in (*runtime_aliases,
                    '/etc/ssl/certs/ca-certificates.crt', '/etc/resolv.conf', '/etc/hosts', '/etc/nsswitch.conf')):
                raise ProcessError('read bind destination is outside the profile')
            if destination in runtime_aliases and not any(_inside(source, root) for root in self.runtime_roots):
                raise ProcessError('runtime aliases require an explicit runtime source')
            if destination in destinations or destination in ('/opt', '/home/worker'):
                raise ProcessError('duplicate or broad read bind destination')
            destinations.add(destination)
        keys = set()
        for key, value in self.environment:
            if key not in ('LANG', 'LC_ALL', 'TZ', 'ANTHROPIC_MODEL', 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC',
                           'DISABLE_AUTOUPDATER', 'CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL') or key in keys:
                raise ProcessError('environment key is not allowlisted')
            if not isinstance(value, str) or '\0' in value:
                raise ProcessError('invalid environment value')
            keys.add(key)

    @property
    def digest(self):
        return hashlib.sha256(_json(asdict(self)).encode()).hexdigest()


@dataclass(frozen=True)
class ProcessDescriptor:
    generation: str
    unit: str
    boot_id: str
    profile: SandboxProfile
    argv: tuple[str, ...]
    state_directory: str
    runtime_seconds: int

    def __post_init__(self):
        if not re.fullmatch(r'[a-zA-Z0-9_-]{1,128}', self.generation):
            raise ProcessError('invalid generation')
        if not re.fullmatch(r'aios-owned-[a-zA-Z0-9_-]{1,160}\.service', self.unit):
            raise ProcessError('invalid owned unit')
        if not re.fullmatch(r'[0-9a-f-]{36}', self.boot_id):
            raise ProcessError('invalid boot identity')
        if type(self.runtime_seconds) is not int or not 1 <= self.runtime_seconds <= 14400:
            raise ProcessError('runtime must be bounded by four hours')
        if not self.argv or self.argv[0] != self.profile.executable or any(not isinstance(a, str) or '\0' in a for a in self.argv):
            raise ProcessError('argv must start with the profile executable')
        state = _path(self.state_directory)
        for writable in (self.profile.worktree, self.profile.git_directory, self.profile.private_objects, self.profile.home, self.profile.tmp):
            if _inside(state, writable) or _inside(writable, state):
                raise ProcessError('trusted state must be outside worker writable mounts')
        for root in self.profile.runtime_roots:
            if _inside(state, root):
                raise ProcessError('trusted state must not be visible in runtime mounts')
        if any(_inside(self.state_directory, source) or _inside(source, self.state_directory) for source, _ in self.profile.read_binds):
            raise ProcessError('trusted state cannot be read bound')

    def to_dict(self):
        return asdict(self)

    @classmethod
    def from_dict(cls, value):
        value = dict(value)
        profile = dict(value.pop('profile'))
        for field in ('runtime_roots', 'read_binds', 'environment', 'search_path'):
            profile[field] = tuple(tuple(x) if isinstance(x, list) else x for x in profile.get(field, ()))
        return cls(profile=SandboxProfile(**profile), **{**value, 'argv': tuple(value['argv'])})

    @property
    def digest(self):
        return hashlib.sha256(_json(self.to_dict()).encode()).hexdigest()


def git_environment(profile):
    policy = [('core.hooksPath', '/dev/null'), ('core.fsmonitor', 'false'), ('commit.gpgSign', 'false'),
              ('tag.gpgSign', 'false'), ('core.attributesFile', '/dev/null'), ('credential.helper', ''),
              ('protocol.allow', 'never'), ('submodule.recurse', 'false'), ('core.logAllRefUpdates', 'false')]
    result = {'GIT_CONFIG_NOSYSTEM': '1', 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_NO_REPLACE_OBJECTS': '1',
              'GIT_OBJECT_DIRECTORY': profile.private_objects,
              'GIT_ALTERNATE_OBJECT_DIRECTORIES': str(Path(profile.common_directory) / 'objects'),
              'GIT_CONFIG_COUNT': str(len(policy))}
    for index, (key, value) in enumerate(policy):
        result['GIT_CONFIG_KEY_' + str(index)] = key
        result['GIT_CONFIG_VALUE_' + str(index)] = value
    return result


def bwrap_argv(profile, argv, *, config_path=None):
    if not argv or argv[0] != profile.executable:
        raise ProcessError('unexpected worker executable')
    if config_path is None:
        raise ProcessError('trusted controlled Git configuration is required')
    _path(config_path)
    command = [shutil.which('bwrap') or 'bwrap', '--die-with-parent', '--new-session', '--unshare-user',
               '--unshare-pid', '--unshare-ipc', '--unshare-uts', '--cap-drop', 'ALL', '--clearenv',
               '--proc', '/proc', '--dev', '/dev',
               '--bind', profile.home, '/home/worker', '--bind', profile.tmp, '/tmp']
    for root in profile.runtime_roots:
        command += ['--ro-bind', root, root]
    common = Path(profile.common_directory)
    command += ['--tmpfs', str(common), '--dir', str(common / 'hooks')]
    for name in ('objects', 'refs', 'HEAD', 'packed-refs', 'shallow'):
        source = common / name
        if source.exists():
            _path(source)
            command += ['--ro-bind', str(source), str(source)]
    command += ['--bind', profile.git_directory, profile.git_directory,
                '--ro-bind', str(config_path), str(common / 'config'),
                '--ro-bind', str(config_path), str(common / 'config.lock'),
                '--ro-bind', str(config_path), str(common / 'config.worktree'),
                '--ro-bind', str(config_path), str(Path(profile.git_directory) / 'config.worktree'),
                '--remount-ro', str(common)]
    for path in (profile.worktree, profile.private_objects):
        command += ['--bind', path, path]
    for source, destination in profile.read_binds:
        command += ['--ro-bind', source, destination]
    environment = {'HOME': '/home/worker', 'TMPDIR': '/tmp', 'PATH': ':'.join(profile.search_path or (str(Path(profile.executable).parent),)),
        'LANG': 'C.UTF-8', **dict(profile.environment), **git_environment(profile)}
    for key, value in environment.items():
        command += ['--setenv', key, value]
    return [*command, '--chdir', profile.worktree, '--', *argv]


def _private_directory(path):
    path = _path(path)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if not path.is_dir() or path.stat().st_uid != os.getuid() or stat.S_IMODE(path.stat().st_mode) != 0o700:
        raise ProcessError('private owned directory required')


def _write_once(path, value):
    path = Path(path)
    fd, temporary = tempfile.mkstemp(prefix='.pending-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(value.encode())
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, path, follow_symlinks=False)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        os.unlink(temporary)


def _private_file(path, *, contents=True):
    path = _path(path)
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise ProcessError('private owned file required')
    return path.read_text() if contents else None


def _ensure_file(path, value):
    try:
        _write_once(path, value)
    except FileExistsError:
        if _private_file(path) != value:
            raise ProcessError('prepared artifact changed: ' + Path(path).name)


def prepare(descriptor):
    state = Path(descriptor.state_directory)
    _private_directory(state)
    target = state / 'descriptor.json'
    profile = descriptor.profile
    try:
        common = (Path(profile.git_directory) / 'commondir').read_text().strip()
        actual_common = (Path(profile.git_directory) / common).resolve()
        actual_git = (Path(profile.worktree) / '.git').read_text().strip()
        if (actual_common != Path(profile.common_directory)
                or actual_git != 'gitdir: ' + profile.git_directory
                or (Path(profile.git_directory) / 'HEAD').read_text().startswith('ref:')):
            raise ProcessError('detached linked worktree identity required')
    except OSError as exc:
        raise ProcessError('linked worktree metadata unavailable') from exc
    intent_path = state / 'prepare-intent.json'
    if intent_path.exists():
        intent = json.loads(_private_file(intent_path))
        if intent['descriptor'] != json.loads(_json(descriptor.to_dict())):
            raise ProcessError('generation descriptor conflict')
    else:
        if any(not path.name.startswith('.pending-') for path in state.iterdir()):
            raise ProcessError('preparation lacks durable snapshot intent')
        intent = {'descriptor': descriptor.to_dict(), 'runner': Path(__file__).read_text(),
                  'gitconfig': '[user]\n name = AIOS worker\n email = worker@aios.invalid\n'}
        _write_once(intent_path, _json(intent))
    artifacts = {'descriptor.json': _json(intent['descriptor']), 'runner.py': intent['runner'],
                 'gitconfig': intent['gitconfig']}
    manifest = {'descriptor_hash': descriptor.digest,
                'artifacts': {name: hashlib.sha256(value.encode()).hexdigest() for name, value in artifacts.items()}}
    ready = state / 'ready.json'
    if ready.exists():
        if _private_file(ready) != _json(manifest):
            raise ProcessError('prepared manifest changed')
        for name, value in artifacts.items():
            if _private_file(state / name) != value:
                raise ProcessError('prepared artifact changed: ' + name)
        for name in ('stdout', 'stderr'):
            _private_file(state / name, contents=False)
        return target
    if (state / 'launch-intent').exists():
        raise ProcessError('launched generation lacks sealed preparation')
    for directory in (profile.home, profile.tmp, profile.private_objects):
        _private_directory(directory)
    for name, value in artifacts.items():
        _ensure_file(state / name, value)
    for name in ('stdout', 'stderr'):
        _ensure_file(state / name, '')
    _ensure_file(ready, _json(manifest))
    return target


def load_descriptor(path):
    path = _path(path)
    if path.stat().st_uid != os.getuid() or stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise ProcessError('private descriptor required')
    descriptor = ProcessDescriptor.from_dict(json.loads(path.read_text()))
    if path != Path(descriptor.state_directory) / 'descriptor.json':
        raise ProcessError('descriptor location changed')
    return descriptor


def _systemd_quote(value):
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('$', '$$') + '"'


def unit_argv(descriptor, descriptor_path):
    state = Path(descriptor.state_directory)
    runner = [str(Path(sys.executable).resolve()), str(state / 'runner.py')]
    callback = [*runner, 'post', str(descriptor_path)]
    return [shutil.which('systemd-run') or 'systemd-run', '--user', '--quiet', '--collect',
            '--expand-environment=no', '--unit=' + descriptor.unit, '--property=Type=exec', '--property=KillMode=control-group',
            '--property=Description=AIOS owned ' + descriptor.digest, '--property=Restart=no', '--property=RuntimeMaxSec=' + str(descriptor.runtime_seconds),
            '--property=TimeoutStopSec=10', '--property=SendSIGKILL=yes',
            '--property=StandardOutput=append:' + str(state / 'stdout'),
            '--property=StandardError=append:' + str(state / 'stderr'),
            '--property=ExecStopPost=' + ' '.join(_systemd_quote(x) for x in callback),
            '--', *runner, 'start', str(descriptor_path)]


def _run(argv):
    return subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=15,
                          env={key: os.environ[key] for key in ('PATH', 'XDG_RUNTIME_DIR', 'DBUS_SESSION_BUS_ADDRESS') if key in os.environ})


def _show(descriptor, run):
    result = run([shutil.which('systemctl') or 'systemctl', '--user', 'show', descriptor.unit,
                  '--property=LoadState,ActiveState,SubState,InvocationID,ControlGroup,Description'])
    if result.returncode:
        return {}
    return dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)


def _bound_start(descriptor, invocation):
    value = json.loads(_private_file(Path(descriptor.state_directory) / 'start.json'))
    expected = {'descriptor_hash': descriptor.digest, 'generation': descriptor.generation,
                'unit': descriptor.unit, 'boot_id': descriptor.boot_id, 'invocation_id': invocation}
    if (any(value[key] != expected[key] for key in expected)
            or type(value['started_monotonic_ns']) is not int or value['started_monotonic_ns'] < 0):
        raise ProcessError('start generation identity or timing changed')
    return value


def receipt(descriptor, invocation_id=None):
    path = Path(descriptor.state_directory) / 'terminal.json'
    try:
        value = json.loads(_private_file(path))
        if (value['descriptor_hash'] != descriptor.digest or value['boot_id'] != descriptor.boot_id
                or value['unit'] != descriptor.unit or not re.fullmatch(r'[0-9a-f]{32}', value['invocation_id'])
                or value['quiescent'] is not True or (invocation_id and value['invocation_id'] != invocation_id)):
            return None
        timing = ('started_monotonic_ns', 'ended_monotonic_ns', 'elapsed_seconds')
        if not any(key in value for key in timing):
            return {**value, 'timing_status': 'unmeasured'}
        start = _bound_start(descriptor, value['invocation_id'])
        if (value['generation'] != descriptor.generation
                or type(value['started_monotonic_ns']) is not int
                or value['started_monotonic_ns'] != start['started_monotonic_ns']
                or type(value['ended_monotonic_ns']) is not int
                or value['ended_monotonic_ns'] < value['started_monotonic_ns']
                or type(value['elapsed_seconds']) not in (int, float)
                or value['elapsed_seconds'] != (value['ended_monotonic_ns'] - value['started_monotonic_ns']) / 1_000_000_000):
            return None
        return {**value, 'timing_status': 'measured'}
    except (OSError, ValueError, KeyError, TypeError, OverflowError):
        return None


def inspect(descriptor, invocation_id=None, *, run=_run):
    terminal = receipt(descriptor, invocation_id)
    if terminal:
        return {'status': 'quiescent', 'invocation_id': terminal['invocation_id'], 'receipt': terminal}
    if boot_id() != descriptor.boot_id:
        return {'status': 'quiescent', 'basis': 'changed_boot', 'boot_id': boot_id()}
    try:
        state = _show(descriptor, run)
    except (OSError, subprocess.TimeoutExpired):
        return {'status': 'uncertain'}
    current = state.get('InvocationID', '')
    if (state.get('Description') != 'AIOS owned ' + descriptor.digest or state.get('LoadState') != 'loaded' or not re.fullmatch(r'[0-9a-f]{32}', current)
            or (invocation_id and current != invocation_id)):
        return {'status': 'uncertain'}
    if state.get('ActiveState') in ('active', 'activating', 'deactivating'):
        return {'status': 'running', 'invocation_id': current, 'control_group': state.get('ControlGroup')}
    return {'status': 'uncertain', 'invocation_id': current}


def launch(descriptor, *, run=_run):
    path = prepare(descriptor)
    marker = Path(descriptor.state_directory) / 'launch-intent'
    try:
        _write_once(marker, descriptor.digest)
    except FileExistsError:
        return inspect(descriptor, run=run)
    if descriptor.boot_id != boot_id():
        return {'status': 'uncertain'}
    try:
        result = run(unit_argv(descriptor, path))
    except (OSError, subprocess.TimeoutExpired):
        return {'status': 'uncertain'}
    if result.returncode:
        return {'status': 'uncertain'}
    return inspect(descriptor, run=run)


def stop(descriptor, invocation_id, *, run=_run):
    if not isinstance(invocation_id, str) or not re.fullmatch(r'[0-9a-f]{32}', invocation_id):
        return {'status': 'uncertain'}
    observation = inspect(descriptor, invocation_id, run=run)
    if observation['status'] != 'running':
        return observation
    try:
        result = run([shutil.which('systemctl') or 'systemctl', '--user', 'stop', descriptor.unit])
    except (OSError, subprocess.TimeoutExpired):
        return {'status': 'uncertain'}
    if result.returncode:
        return {'status': 'uncertain'}
    return inspect(descriptor, invocation_id, run=run)


def _generation_context(descriptor):
    invocation = os.environ.get('INVOCATION_ID', '')
    if boot_id() != descriptor.boot_id or not re.fullmatch(r'[0-9a-f]{32}', invocation):
        raise ProcessError('owned generation identity unavailable')
    groups = [line.split(':', 2)[2] for line in Path('/proc/self/cgroup').read_text().splitlines() if line.startswith('0::')]
    if len(groups) != 1 or Path(groups[0]).name != descriptor.unit:
        raise ProcessError('callback outside owned cgroup')
    return invocation, groups[0]


def _exec_worker(descriptor, invocation, *, execvpe=os.execvpe):
    value = {'descriptor_hash': descriptor.digest, 'generation': descriptor.generation, 'unit': descriptor.unit,
             'boot_id': descriptor.boot_id, 'invocation_id': invocation, 'started_monotonic_ns': time.monotonic_ns()}
    _write_once(Path(descriptor.state_directory) / 'start.json', _json(value))
    command = bwrap_argv(descriptor.profile, descriptor.argv,
                         config_path=Path(descriptor.state_directory) / 'gitconfig')
    execvpe(command[0], command, {key: os.environ[key] for key in ('PATH',) if key in os.environ})


def start(descriptor_path, *, execvpe=os.execvpe):
    """Persist trusted timing in the owned cgroup, then replace this PID with bubblewrap."""
    descriptor = load_descriptor(descriptor_path)
    state = Path(descriptor.state_directory)
    manifest = json.loads(_private_file(state / 'ready.json'))
    if manifest['artifacts']['runner.py'] != hashlib.sha256(Path(__file__).read_bytes()).hexdigest():
        raise ProcessError('sealed runner identity changed')
    prepare(descriptor)
    invocation, _ = _generation_context(descriptor)
    _exec_worker(descriptor, invocation, execvpe=execvpe)


def terminal_receipt(descriptor):
    """Run only as the trusted host ExecStopPost command, after control-group kill."""
    invocation, control_group = _generation_context(descriptor)
    group = Path('/sys/fs/cgroup') / control_group.lstrip('/')
    files = [group / 'cgroup.procs', *group.rglob('cgroup.procs')]
    members = {int(pid) for file in files for pid in file.read_text().split()}
    if members != {os.getpid()}:
        raise ProcessError('owned descendants are not quiescent')
    value = {'descriptor_hash': descriptor.digest, 'generation': descriptor.generation, 'unit': descriptor.unit,
             'boot_id': descriptor.boot_id, 'invocation_id': invocation, 'control_group': control_group,
             'quiescent': True, 'service_result': os.environ.get('SERVICE_RESULT'),
             'exit_code': os.environ.get('EXIT_CODE'), 'exit_status': os.environ.get('EXIT_STATUS'), 'observed_at': time.time(),
             'timing_status': 'unmeasured'}
    try:
        started = _bound_start(descriptor, invocation)['started_monotonic_ns']
    except FileNotFoundError:
        pass
    else:
        ended = time.monotonic_ns()
        if ended < started:
            raise ProcessError('terminal monotonic timing changed')
        value.update(started_monotonic_ns=started, ended_monotonic_ns=ended,
                     elapsed_seconds=(ended - started) / 1_000_000_000, timing_status='measured')
    _write_once(Path(descriptor.state_directory) / 'terminal.json', _json(value))
    return value


if __name__ == '__main__':
    if len(sys.argv) != 3 or sys.argv[1] not in ('start', 'post'):
        raise SystemExit('usage: process.py start|post DESCRIPTOR')
    if sys.argv[1] == 'start':
        start(sys.argv[2])
    else:
        terminal_receipt(load_descriptor(sys.argv[2]))
