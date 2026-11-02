"""Content-free retained identities and bounded fresh retirement observations."""

import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess

RECORD_KEYS = {'version', 'kind', 'deletion_id', 'purge_operation_id', 'identity',
               'processes', 'purge_manifest_hash', 'retirement_hash'}
PROCESS_KEYS = {'generation_or_run_id', 'unit', 'boot_id', 'invocation_id', 'cgroup',
                'descriptor_hash', 'profile_hash', 'preparation_hash', 'session_id',
                'start_operation_id', 'containment_operation_ids', 'never_started_proof_hash'}
FILES, FILE_BYTES, PROCESSES, OUTPUT_BYTES, COMMAND_SECONDS = 16384, 4 * 1024 * 1024, 4096, 262144, 2


def digest(value):
    # ensure_ascii stays on: retirement_hash was minted with the default encoder.
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':'), allow_nan=False).encode()).hexdigest()


def absolute(value):
    if not isinstance(value, (str, Path)) or not str(value) or any(c in str(value) for c in ('\0', '\n', '\r')):
        raise ValueError('invalid execution path')
    path = Path(value)
    if not path.is_absolute() or '..' in path.parts or any(p.is_symlink() for p in (path, *path.parents)):
        raise ValueError('absolute execution paths without symlinks required')
    return path


def identifier(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', value):
        raise ValueError('invalid installation or namespace identity')
    return value


class Read:
    """Bounded reads only: regular files, capped sizes, capped directory and command output."""

    def __init__(self):
        self.count = 0

    def read(self, path, *, private=False):
        path = absolute(path)
        self.count += 1
        if self.count > FILES:
            raise ValueError('census file limit exceeded')
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                raise ValueError('census input is not a regular file')
            if private and (info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
                raise ValueError('census record is not private')
            raw = b''
            while len(raw) <= FILE_BYTES:
                chunk = os.read(fd, min(65536, FILE_BYTES + 1 - len(raw)))
                if not chunk:
                    break
                raw += chunk
            if len(raw) > FILE_BYTES:
                raise ValueError('census input byte limit exceeded')
            return raw
        finally:
            os.close(fd)

    def json(self, path):
        value = json.loads(self.read(path, private=True), parse_constant=lambda _: (_ for _ in ()).throw(ValueError('nonfinite JSON')))
        if not isinstance(value, dict):
            raise ValueError('census record is not an object')
        return value

    def entries(self, path):
        entries = []
        with os.scandir(absolute(path)) as stream:
            for item in stream:
                if len(entries) >= FILES:
                    raise ValueError('census directory limit exceeded')
                entries.append(item.name)
        return sorted(entries)

    def run(self, argv):
        env = {key: os.environ[key] for key in ('PATH', 'XDG_RUNTIME_DIR', 'DBUS_SESSION_BUS_ADDRESS') if key in os.environ}
        env.update(LANG='C', LC_ALL='C')
        try:
            result = subprocess.run(argv, stdin=subprocess.DEVNULL, capture_output=True, env=env, timeout=COMMAND_SECONDS)
        except subprocess.TimeoutExpired:
            raise ValueError('census command exceeded limit') from None
        if len(result.stdout) + len(result.stderr) > OUTPUT_BYTES:
            raise ValueError('census command output exceeded limit')
        return result.returncode, result.stdout.decode(), result.stderr.decode()


def _hex(value, size):
    if not isinstance(value, str) or re.fullmatch('[0-9a-f]{' + str(size) + '}', value) is None:
        raise ValueError('invalid retirement hash or invocation identity')


def validate_retirement(record):
    from .driver import generation_unit
    if (not isinstance(record, dict) or set(record) != RECORD_KEYS
            or type(record['version']) is not int or record['version'] != 1
            or record['kind'] != 'owned'):
        raise ValueError('invalid retirement record')
    for key in ('deletion_id', 'purge_operation_id'):
        if not isinstance(record[key], str) or re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]{0,255}', record[key]) is None:
            raise ValueError('invalid retirement journal identity')
    identity = record['identity']
    if not isinstance(identity, dict) or set(identity) != {'owner_namespace', 'attempt_id', 'dispatch_id', 'claim_epoch'}:
        raise ValueError('invalid retirement owner identity')
    for key, value in identity.items():
        _hex(value, 32) if key == 'claim_epoch' else identifier(value)
    processes = record['processes']
    if not isinstance(processes, list) or not 1 <= len(processes) <= 2048:
        raise ValueError('invalid retirement process inventory')
    seen, units = set(), set()
    for item in processes:
        if not isinstance(item, dict) or set(item) != PROCESS_KEYS:
            raise ValueError('invalid retirement process record')
        generation = identifier(item['generation_or_run_id'])
        if not isinstance(item['unit'], str):
            raise ValueError('invalid retirement unit identity')
        if generation in seen or item['unit'] in units:
            raise ValueError('duplicate retirement process identity')
        seen.add(generation)
        units.add(item['unit'])
        expected = generation_unit(identity['owner_namespace'], identity['attempt_id'], identity['dispatch_id'], generation)
        for key in ('profile_hash', 'preparation_hash'):
            _hex(item[key], 64)
        for key in ('session_id', 'start_operation_id'):
            identifier(item[key])
        if item['unit'] != expected:
            raise ValueError('retirement unit identity conflict')
        if not isinstance(item['boot_id'], str) or re.fullmatch('[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}', item['boot_id']) is None:
            raise ValueError('invalid retirement boot identity')
        _hex(item['descriptor_hash'], 64)
        proof = item['never_started_proof_hash']
        if proof is not None:
            _hex(proof, 64)
        if item['invocation_id'] is None:
            if proof is None:
                raise ValueError('retirement lacks validated never-started proof')
        else:
            _hex(item['invocation_id'], 32)
            if proof is not None:
                raise ValueError('started retirement contradicts never-started proof')
        group = item['cgroup']
        if group is not None:
            if (not isinstance(group, str) or not group.startswith('/') or group == '/'
                    or '..' in Path(group).parts or str(Path(group)) != group
                    or any(c in group for c in ('\0', '\n', '\r'))):
                raise ValueError('invalid retirement cgroup')
        elif item['invocation_id'] is not None:
            raise ValueError('started retirement lacks cgroup identity')
        containment = item['containment_operation_ids']
        if not isinstance(containment, list) or len(containment) > 2048:
            raise ValueError('invalid retirement containment identities')
        for operation in containment:
            identifier(operation)
        if len(set(containment)) != len(containment):
            raise ValueError('duplicate retirement containment identities')
    _hex(record['purge_manifest_hash'], 64)
    _hex(record['retirement_hash'], 64)
    if digest({key: value for key, value in record.items() if key != 'retirement_hash'}) != record['retirement_hash']:
        raise ValueError('retirement hash conflict')
    encoded = json.dumps(record, allow_nan=False)
    if len(encoded.encode()) > 4 * 1024 * 1024:
        raise ValueError('retirement record exceeds byte limit')
    return json.loads(encoded)


def _marker_path(value, path):
    path = absolute(path)
    root = path.parent.parent.parent.parent
    identity = value['identity']
    if path != absolute(root) / 'owned' / identity['owner_namespace'] / identity['attempt_id'] / 'retired.json':
        raise ValueError('retirement marker path identity conflict')
    info = root.stat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError('private retirement cache required')
    for directory in (path.parent.parent.parent, path.parent.parent, path.parent):
        info = directory.stat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o700):
            raise ValueError('private retirement directory required')
    return path


def read_retirement(path, *, expected_record, reader):
    expected = validate_retirement(expected_record)
    path = _marker_path(expected, path)
    actual = validate_retirement(reader.json(path))
    if actual != expected:
        raise ValueError('retirement marker differs from canonical record')
    return actual


def _boot(proc_root, reader):
    value = reader.read(Path(proc_root) / 'sys/kernel/random/boot_id').decode().strip()
    if not re.fullmatch(r'[0-9a-f-]{36}', value):
        raise ValueError('boot identity is unavailable')
    return value


def _proc_stat(reader, root, pid):
    raw = reader.read(root / str(pid) / 'stat').decode()
    suffix = raw[raw.rfind(')') + 2:].split()
    if len(suffix) < 20 or not re.fullmatch(r'[A-Za-z]', suffix[0]) or not suffix[1].isdigit() or not suffix[19].isdigit():
        raise ValueError('invalid process identity')
    return {'pid': int(pid), 'ppid': int(suffix[1]), 'start_ticks': int(suffix[19])}


def _properties(reader, systemctl, unit):
    code, output, _ = reader.run([systemctl, '--user', 'show', unit,
        '--property=Id,LoadState,ActiveState,SubState,InvocationID,ControlGroup,Description,MainPID'])
    if code:
        raise ValueError('validation unit inspection unavailable')
    result = {}
    for line in output.splitlines():
        key, sep, value = line.partition('=')
        if not sep or key in result:
            raise ValueError('malformed validation unit observation')
        result[key] = value
    return result


def _members(reader, cgroup_root, group, proc_root):
    pending, seen, members = [absolute(Path(cgroup_root) / group.lstrip('/'))], 0, []
    while pending:
        directory = pending.pop()
        seen += 1
        if seen > FILES:
            raise ValueError('validation cgroup directory limit exceeded')
        pending += [directory / name for name in reader.entries(directory) if (directory / name).is_dir()]
        for pid in reader.read(directory / 'cgroup.procs').decode().splitlines():
            if not pid.isdigit() or int(pid) <= 0 or len(members) >= PROCESSES:
                raise ValueError('invalid or excessive validation cgroup process census')
            try:
                members.append(_proc_stat(reader, Path(proc_root), int(pid)))
            except FileNotFoundError:
                if (Path(proc_root) / pid).exists():
                    raise
    return members


def observe_retirement(record, *, reader, systemctl, proc_root='/proc', cgroup_root='/sys/fs/cgroup'):
    value = validate_retirement(record)
    boot = _boot(proc_root, reader)
    root = absolute(proc_root)
    names = tuple(name for name in reader.entries(root) if name.isdigit())
    if len(names) > PROCESSES:
        raise ValueError('retirement process census limit exceeded')
    identities = {}
    groups = {}
    for name in names:
        identities[name] = _proc_stat(reader, root, int(name))
        groups[name] = reader.read(root / name / 'cgroup').decode()
    observations = []
    for item in value['processes']:
        actual = _properties(reader, systemctl, item['unit'])
        absent = actual.get('LoadState') == 'not-found'
        group = item['cgroup']
        members = []
        if group and (absolute(cgroup_root) / group.lstrip('/')).exists():
            members = _members(reader, cgroup_root, group, proc_root)
        host_members = [int(name) for name, text in groups.items() if group and any(
            line.split(':', 2)[-1] == group or line.split(':', 2)[-1].startswith(group + '/') for line in text.splitlines())]
        matched = boot == item['boot_id']
        if absent:
            matched = matched and bool(item['containment_operation_ids'] or item['never_started_proof_hash'])
            terminal = (actual.get('ActiveState') == 'inactive' and actual.get('MainPID') == '0'
                and actual.get('InvocationID') == '')
        else:
            matched = (matched and actual.get('LoadState') == 'loaded' and actual.get('Id') == item['unit']
                and actual.get('Description') == 'AIOS ' + value['kind'] + ' ' + item['descriptor_hash']
                and item['invocation_id'] is not None and actual.get('InvocationID') == item['invocation_id']
                and actual.get('ControlGroup') in (group, ''))
            terminal = actual.get('ActiveState') in ('inactive', 'failed') and actual.get('MainPID') == '0'
        quiet = bool(matched and terminal and not members and not host_members)
        observations.append(dict(unit=item['unit'], identity_verified=bool(matched), quiescent=quiet,
            boot_id=boot, invocation_id=actual.get('InvocationID') or None,
            process_ids=sorted(set(host_members + [row['pid'] for row in members])),
            reason='fresh_retired_quiescence' if quiet else 'retired_identity_or_liveness_unresolved'))
        if _properties(reader, systemctl, item['unit']) != actual:
            raise ValueError('retired unit changed during census')
    if tuple(name for name in reader.entries(root) if name.isdigit()) != names:
        raise ValueError('retirement process listing changed')
    for name in names:
        if (_proc_stat(reader, root, int(name)) != identities[name]
                or reader.read(root / name / 'cgroup').decode() != groups[name]):
            raise ValueError('retirement process identity changed')
    if _boot(proc_root, reader) != boot:
        raise ValueError('retirement boot identity changed')
    return dict(version=1, retirement_hash=value['retirement_hash'],
                quiescent=all(row['quiescent'] for row in observations), processes=observations)
