"""Durable, attempt-scoped owned fleet protocol over contained process generations."""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import shutil
import subprocess
import sys
import tempfile
import threading
import uuid

from . import process
from . import retirement

OUTPUT_LIMIT = 16 * 1024 * 1024


class DriverError(ValueError):
    pass


def _json(value, *, ensure_ascii=True):
    return json.dumps(value, ensure_ascii=ensure_ascii, sort_keys=True, separators=(',', ':'), allow_nan=False)


def _hash(value):
    return hashlib.sha256(_json(value, ensure_ascii=False).encode()).hexdigest()


def _id(value):
    if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', value):
        raise DriverError('invalid owned identity')
    return value


def _read(path):
    process._path(path)
    info = path.stat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o600:
        raise DriverError('private owned record required')
    return json.loads(path.read_text())


def _write(path, value):
    process._path(path)
    fd, temporary = tempfile.mkstemp(prefix='.record-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(_json(value))
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def generation_unit(owner_namespace, attempt_id, dispatch_id, generation):
    identity = [_id(value) for value in (owner_namespace, attempt_id, dispatch_id, generation)]
    return 'aios-owned-' + _hash(identity) + '.service'


class OwnedDriver:
    def __init__(self, socket, cache, *, run=process._run, systemctl=None, proc_root='/proc', cgroup_root='/sys/fs/cgroup'):
        if isinstance(socket, str) and re.fullmatch(r'[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}', socket):
            self.socket = socket
        elif isinstance(socket, str) and socket.startswith('/') and str(process._path(socket)) == socket:
            self.socket = socket
        else:
            raise DriverError('exact socket name or canonical absolute path required')
        self.cache = process._path(cache)
        self.run = run
        self.systemctl = systemctl or shutil.which('systemctl') or 'systemctl'
        self.proc_root, self.cgroup_root = proc_root, cgroup_root
        self._held = threading.local()

    @contextmanager
    def _locked(self, payload, *, preparing=False):
        if not isinstance(payload, dict) or type(payload.get('protocol_version')) is not int or payload['protocol_version'] != 1:
            raise DriverError('unsupported owned protocol version')
        for key in ('owner_namespace', 'attempt_id', 'dispatch_id', 'generation', 'operation_id'):
            _id(payload.get(key))
        root = self.cache / 'owned' / payload['owner_namespace'] / payload['attempt_id']
        creating = preparing and 'claim_epoch' not in payload
        directories = (self.cache, self.cache / 'owned', root.parent, root)
        if not creating and not (root / 'claim.json').exists():
            raise DriverError('existing owned claim required')
        if creating:
            self.cache.mkdir(mode=0o700, parents=True, exist_ok=True)
        process._path(self.cache)
        if not self.cache.is_dir() or self.cache.stat().st_uid != os.getuid() or self.cache.stat().st_mode & 0o022:
            raise DriverError('owned fleet cache must not be writable by others')
        for directory in directories[1:]:
            if creating:
                process._private_directory(directory)
            else:
                process._path(directory)
                info = directory.stat()
                if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                    raise DriverError('private owned directory required')
        identities = {path:(path.stat().st_dev, path.stat().st_ino) for path in directories}
        fd = os.open(root / 'lock', os.O_RDWR | (os.O_CREAT if creating else 0) | os.O_NOFOLLOW, 0o600)
        try:
            if os.fstat(fd).st_uid != os.getuid() or stat.S_IMODE(os.fstat(fd).st_mode) != 0o600:
                raise DriverError('private owned lock required')
            fcntl.flock(fd, fcntl.LOCK_EX)
            self._held.value = (root, fd, identities)
            self._validate_lock(root)
            expected = {key:payload[key] for key in ('owner_namespace', 'attempt_id', 'dispatch_id')}
            expected.update(fleet_socket=self.socket, fleet_cache=str(self.cache))
            target = root / 'claim.json'
            if target.exists():
                claim = _read(target)
                if not isinstance(claim, dict) or any(claim.get(key) != value for key,value in expected.items()):
                    raise DriverError('owned claim conflict')
                epoch = claim.get('claim_epoch')
                if epoch is not None and (not isinstance(epoch, str) or not re.fullmatch(r'[0-9a-f]{32}', epoch)
                        or not isinstance(claim.get('generations'), dict)):
                    raise DriverError('invalid owned claim epoch or ledger')
                if (('claim_epoch' in payload and payload['claim_epoch'] != epoch)
                        or (epoch and not preparing and payload.get('claim_epoch') != epoch)):
                    raise DriverError('owned claim epoch conflict')
            elif creating:
                self._commit(root, target, {**expected, 'claim_epoch':uuid.uuid4().hex, 'generations':{}})
            else:
                raise DriverError('existing owned claim required')
            for directory in (() if (root / 'retired.json').exists() else (root / 'operations', root / 'generations')):
                self._validate_lock(root)
                process._private_directory(directory)
            yield root
        finally:
            self._held.value = None
            os.close(fd)

    def _validate_lock(self, root):
        held = getattr(self._held, 'value', None)
        if not held or held[0] != root:
            raise DriverError('owned lock required')
        _, fd, identities = held
        for path, identity in identities.items():
            process._path(path)
            info = path.stat()
            if (info.st_dev, info.st_ino) != identity:
                raise DriverError('owned root identity changed')
            if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                    or (info.st_mode & 0o022 if path == self.cache else stat.S_IMODE(info.st_mode) != 0o700)):
                raise DriverError('private owned root required')
        info, current = os.fstat(fd), (root / 'lock').lstat()
        if (not stat.S_ISREG(current.st_mode) or current.st_uid != os.getuid()
                or stat.S_IMODE(current.st_mode) != 0o600 or (info.st_dev, info.st_ino) != (current.st_dev, current.st_ino)):
            raise DriverError('owned lock identity changed')

    def _commit(self, root, path, value):
        self._validate_lock(root)
        _write(path, value)

    def _operation_hash(self, action, payload):
        if action == 'inspect' and 'prepare_start' in payload:
            payload = {key:value for key,value in payload.items() if key != 'claim_epoch'}
        return _hash({'action':action, 'payload':payload})

    def _base(self, payload):
        return json.loads(_json({key:value for key,value in payload.items() if key not in ('claim_epoch', 'preparation_hash')}))

    def _preparation_entry(self, root, action, payload):
        descriptor, session = self._descriptor(root, payload)
        base = self._base(payload)
        return dict(preparation_hash=_hash({'action':action, 'payload':base}),
            start_action=action, start_operation_id=base['operation_id'],
            descriptor_hash=descriptor.digest, profile_hash=descriptor.profile.digest,
            session_id=session, payload=base)

    def _bound_entry(self, root, action, payload):
        claim = _read(root / 'claim.json')
        if not claim.get('claim_epoch') or payload.get('claim_epoch') != claim['claim_epoch']:
            raise DriverError('matching owned claim epoch required')
        entry = claim.get('generations', {}).get(payload['generation'])
        expected = self._preparation_entry(root, action, payload)
        if (not isinstance(entry, dict) or entry.get('phase') not in ('prepared', 'armed')
                or any(entry.get(key) != value for key,value in expected.items())
                or payload.get('preparation_hash') != expected['preparation_hash']):
            raise DriverError('owned preparation conflict')
        return claim, entry

    def _prepare_start(self, root, payload, operation, intent):
        request = payload['prepare_start']
        if not isinstance(request, dict) or set(request) != {'action', 'payload'} or request['action'] not in ('launch', 'answer'):
            raise DriverError('invalid preparation request')
        base = request['payload']
        if (not isinstance(base, dict) or 'claim_epoch' in base or 'preparation_hash' in base
                or any(base.get(key) != payload[key] for key in ('protocol_version', 'owner_namespace', 'attempt_id', 'dispatch_id', 'generation'))):
            raise DriverError('preparation scope conflict')
        _id(base.get('operation_id'))
        expected = self._preparation_entry(root, request['action'], base)
        claim = _read(root / 'claim.json')
        if not claim.get('claim_epoch') or not isinstance(claim.get('generations'), dict):
            raise DriverError('legacy owned claim has no preparation authority')
        entry = claim['generations'].get(payload['generation'])
        if entry is None and operation.exists():
            raise DriverError('preparation replay lost its generation ledger entry')
        if entry is not None and (not isinstance(entry, dict) or entry.get('phase') not in ('prepared', 'armed')
                or any(entry.get(key) != value for key,value in expected.items())):
            raise DriverError('owned preparation conflict')
        if self._attempt_fenced(root) and (entry is None or not operation.exists()):
            raise DriverError('owned attempt is fenced')
        if (entry is None and request['action'] == 'launch'
                and (claim['generations'] or (root / 'state.json').exists())):
            raise DriverError('initial launch conflicts with owned generation history')
        if entry is None and claim['generations'] and payload.get('claim_epoch') != claim['claim_epoch']:
            raise DriverError('matching owned claim epoch required')
        self._commit(root, operation, intent)
        if entry is None:
            claim['generations'][payload['generation']] = {**expected, 'phase':'prepared'}
            self._commit(root, root / 'claim.json', claim)
        return {'status':'prepared', 'preparation_witness':self._witness(payload, claim, expected)}

    def _descriptor(self, root, payload):
        try:
            descriptor = process.ProcessDescriptor.from_dict(payload['descriptor'])
        except (KeyError, TypeError, ValueError) as exc:
            raise DriverError('invalid process descriptor') from exc
        generation = payload['generation']
        if descriptor.unit != generation_unit(*(payload[key] for key in ('owner_namespace', 'attempt_id', 'dispatch_id', 'generation'))):
            raise DriverError('owned unit identity conflict')
        if descriptor.generation != generation:
            raise DriverError('generation descriptor conflict')
        expected = root / 'generations' / generation / 'host'
        if Path(descriptor.state_directory) != expected:
            raise DriverError('owned state directory conflict')
        profile = descriptor.profile
        for field, name in (('worktree', 'task'), ('home', 'home'), ('tmp', 'tmp'), ('private_objects', 'objects')):
            if Path(getattr(profile, field)) != root / name:
                raise DriverError('owned profile directory conflict')
        session = _id(payload.get('session_id'))
        return descriptor, session

    def _generation(self, root, generation):
        path = root / 'generations' / _id(generation) / 'generation.json'
        if not path.exists():
            raise DriverError('unknown owned generation')
        record = _read(path)
        descriptor = process.ProcessDescriptor.from_dict(record['descriptor'])
        if (descriptor.generation != generation or Path(descriptor.state_directory) != path.parent / 'host'):
            raise DriverError('generation record conflict')
        return path, record, descriptor

    def _observe(self, root, generation, observation=None):
        path, record, descriptor = self._generation(root, generation)
        if observation is None:
            observation = process.inspect(descriptor, record.get('invocation_id'), run=self.run)
        invocation = observation.get('invocation_id')
        if invocation and not record.get('invocation_id'):
            record['invocation_id'] = invocation
            self._commit(root, path, record)
        response = dict(observation, generation=generation, session_id=record['session_id'],
            descriptor_hash=descriptor.digest, profile_hash=descriptor.profile.digest,
            output_paths={name:str(Path(descriptor.state_directory) / name) for name in ('stdout', 'stderr')})
        if observation['status'] == 'quiescent' and observation.get('receipt'):
            receipt = observation['receipt']
            if (receipt.get('service_result') == 'success' and receipt.get('exit_code') == 'exited'
                    and receipt.get('exit_status') == '0'):
                response.update(self._output(descriptor, record['session_id']))
            else:
                response['attention'] = 'process_failed'
        state_path = root / 'state.json'
        state = _read(state_path) if state_path.exists() else {}
        response['current_generation'] = state.get('current_generation')
        response['fenced'] = (root / 'fence.json').exists()
        revision = _hash({'observation':response, 'current_generation':state.get('current_generation'),
                          'consumed_questions':state.get('consumed_questions', [])})
        response['observation_revision'] = revision
        if (response.get('result', {}).get('kind') == 'needs_input' and not response.get('attention')
                and not response['fenced'] and state.get('current_generation') == generation):
            response['question_id'] = _hash([generation, response['output_hash'], revision])
        return response

    def _output(self, descriptor, session):
        path = Path(descriptor.state_directory) / 'stdout'
        process._path(path)
        with path.open('rb') as stream:
            raw = stream.read(OUTPUT_LIMIT + 1)
        if len(raw) > OUTPUT_LIMIT:
            return {'attention':'output_truncated'}
        digest = hashlib.sha256(raw).hexdigest()
        try:
            values = [json.loads(line) for line in raw.decode('utf-8').splitlines() if line.strip()]
        except (ValueError, UnicodeError):
            return {'attention':'invalid_output', 'output_hash':digest}
        results = [value for value in values if isinstance(value, dict) and value.get('type') == 'result']
        if len(results) != 1 or not values or values[-1] != results[0]:
            return {'attention':'missing_terminal_result', 'output_hash':digest}
        result = results[0]
        if result.get('session_id') != session:
            return {'attention':'session_mismatch', 'output_hash':digest}
        if result.get('permission_denials'):
            return {'attention':'permission_denials', 'output_hash':digest}
        structured = result.get('structured_output')
        if result.get('is_error') or not isinstance(structured, dict) or structured.get('kind') not in ('needs_input', 'completed', 'failed'):
            return {'attention':'invalid_structured_output', 'output_hash':digest}
        if not isinstance(structured.get('text'), str) or (structured['kind'] == 'needs_input' and
                (not isinstance(structured.get('question'), str) or not structured['question'].strip()
                 or not isinstance(structured.get('options', []), list)
                 or any(not isinstance(option, str) for option in structured.get('options', [])))):
            return {'attention':'invalid_structured_output', 'output_hash':digest}
        return {'result':structured, 'output_hash':digest}

    def _attempt_fenced(self, root):
        fence = root / 'fence.json'
        if fence.exists():
            return True
        for path in (root / 'operations').glob('*.json'):
            operation = _read(path)
            if not isinstance(operation, dict):
                raise DriverError('invalid owned operation record')
            if operation.get('action') != 'stop':
                continue
            payload = operation['payload']
            claim = _read(root / 'claim.json')
            if (operation['payload_hash'] != _hash({'action':'stop', 'payload':payload})
                    or path.stem != payload['operation_id']
                    or any(payload[key] != claim[key] for key in ('owner_namespace', 'attempt_id', 'dispatch_id'))):
                raise DriverError('permanent stop identity conflict')
            self._commit(root, fence, {'operation_id':payload['operation_id'], 'generation':_id(payload['generation'])})
            return True
        return False

    def _start(self, root, payload, operation, intent, *, answer=False):
        if self._attempt_fenced(root):
            raise DriverError('owned attempt is fenced')
        for pending in (root / 'operations').glob('*.json'):
            value = _read(pending)
            if not isinstance(value, dict):
                raise DriverError('invalid owned operation record')
            if value.get('action') in ('launch', 'answer') and 'response' not in value:
                raise DriverError('owned attempt has a pending generation operation')
        claim, entry = self._bound_entry(root, 'answer' if answer else 'launch', payload)
        if entry['phase'] == 'armed':
            return {'status':'uncertain'}
        if not answer and (set(claim['generations']) != {payload['generation']} or (root / 'state.json').exists()):
            raise DriverError('initial launch conflicts with owned generation history')
        descriptor, session = self._descriptor(root, payload)
        generation_path = root / 'generations' / descriptor.generation
        state_path = root / 'state.json'
        before = _read(state_path) if state_path.exists() else {}
        state = {**before, 'consumed_questions':list(before.get('consumed_questions', []))}
        current = state.get('current_generation')
        if answer:
            previous = _id(payload.get('previous_generation'))
            if current != previous:
                raise DriverError('answer is not for the current generation')
            observation = self._observe(root, previous)
            if (observation['status'] != 'quiescent' or not observation.get('question_id')
                    or observation.get('question_id') != payload.get('question_id')
                    or observation['observation_revision'] != payload.get('observation_revision')
                    or payload['question_id'] in state['consumed_questions']):
                raise DriverError('current question changed or consumed')
            if not isinstance(payload.get('answer'), str) or not payload['answer'].strip():
                raise DriverError('ordinary answer required')
            _, prior, previous_descriptor = self._generation(root, previous)
            if session != prior['session_id'] or descriptor.profile != previous_descriptor.profile:
                raise DriverError('answer session or workspace conflict')
            if descriptor.unit == previous_descriptor.unit:
                raise DriverError('answer requires a distinct generation unit')
            state['consumed_questions'].append(payload['question_id'])
        elif current:
            raise DriverError('owned attempt already has a generation; answer requires a current question')
        if generation_path.exists():
            raise DriverError('generation already exists')
        state.update(current_generation=descriptor.generation, current_operation=payload['operation_id'])
        intent.update(stage='intent', state_before=before, state_after=state)
        self._commit(root, operation, intent)
        return self._resume_start(root, payload, operation, intent)

    def _advance(self, root, operation, intent, stage):
        stages = ('intent', 'directory', 'prepared', 'recorded', 'active')
        if stages.index(intent['stage']) < stages.index(stage):
            intent['stage'] = stage
            self._commit(root, operation, intent)

    def _resume_start(self, root, payload, operation, intent):
        generation = payload['generation']
        generation_path = root / 'generations' / generation
        if self._attempt_fenced(root):
            if (generation_path / 'generation.json').exists():
                return self._observe(root, generation)
            return {'status':'uncertain', 'fenced':True}
        if 'stage' not in intent:
            # Older incomplete intents carry no preparation authority.
            return self._observe(root, generation) if (generation_path / 'generation.json').exists() else {'status':'uncertain'}
        claim, entry = self._bound_entry(root, intent['action'], payload)
        if intent['action'] == 'launch' and set(claim['generations']) != {generation}:
            raise DriverError('initial launch conflicts with owned generation history')
        if entry['phase'] == 'armed':
            return self._observe(root, generation) if (generation_path / 'generation.json').exists() else {'status':'uncertain'}
        descriptor, session = self._descriptor(root, payload)
        state_path = root / 'state.json'
        state = _read(state_path) if state_path.exists() else {}
        if state not in (intent['state_before'], intent['state_after']):
            raise DriverError('generation state conflict')
        self._validate_lock(root)
        process._private_directory(generation_path)
        self._advance(root, operation, intent, 'directory')
        self._validate_lock(root)
        process.prepare(descriptor)
        self._advance(root, operation, intent, 'prepared')
        record = {'descriptor':descriptor.to_dict(), 'session_id':session, 'operation_id':payload['operation_id']}
        record_path = generation_path / 'generation.json'
        if record_path.exists():
            existing = _read(record_path)
            if any(_json(existing.get(key)) != _json(value) for key, value in record.items()):
                raise DriverError('generation preparation conflict')
        else:
            self._commit(root, record_path, record)
        self._advance(root, operation, intent, 'recorded')
        if state != intent['state_after']:
            self._commit(root, state_path, intent['state_after'])
        self._advance(root, operation, intent, 'active')
        if (Path(descriptor.state_directory) / 'launch-intent').exists():
            return self._observe(root, generation)
        entry['phase'] = 'armed'
        self._commit(root, root / 'claim.json', claim)
        self._validate_lock(root)
        launched = process.launch(descriptor, run=self.run)
        return self._observe(root, generation, launched)

    def _preparation_files(self, root, descriptor, start):
        directory = Path(descriptor.state_directory)
        if os.path.lexists(directory / 'launch-intent'):
            raise DriverError('launch marker forbids never-started proof')
        record = directory.parent / 'generation.json'
        if record.exists():
            value = _read(record)
            if (not start or _json(value.get('descriptor')) != _json(descriptor.to_dict())
                    or value.get('session_id') != start['session_id']
                    or value.get('operation_id') != start['operation_id'] or value.get('invocation_id')):
                raise DriverError('generation preparation conflict')
        if not directory.exists():
            return
        process._path(directory)
        paths = {path.name:path for path in directory.iterdir() if not path.name.startswith('.pending-')}
        if not paths:
            return
        if not start or 'prepare-intent.json' not in paths:
            raise DriverError('preparation lacks durable identity')
        intent = _read(paths['prepare-intent.json'])
        if (_json(intent.get('descriptor')) != _json(descriptor.to_dict())
                or intent.get('runner') != Path(process.__file__).read_text()
                or intent.get('gitconfig') != '[user]\n name = AIOS worker\n email = worker@aios.invalid\n'):
            raise DriverError('host preparation identity conflict')
        artifacts = {'descriptor.json':_json(intent['descriptor']), 'runner.py':intent['runner'], 'gitconfig':intent['gitconfig']}
        manifest = {'descriptor_hash':descriptor.digest,
            'artifacts':{key:hashlib.sha256(value.encode()).hexdigest() for key,value in artifacts.items()}}
        if set(paths) - set(artifacts) - {'prepare-intent.json', 'ready.json', 'stdout', 'stderr'}:
            raise DriverError('unexpected host launch evidence')
        for name, value in artifacts.items():
            if name in paths and process._private_file(paths[name]) != value:
                raise DriverError('host preparation artifact conflict')
        for name in ('stdout', 'stderr'):
            if name in paths and process._private_file(paths[name]) != '':
                raise DriverError('unexpected process output')
        if 'ready.json' in paths:
            if _read(paths['ready.json']) != manifest or not set(artifacts).union({'stdout', 'stderr'}).issubset(paths):
                raise DriverError('host preparation manifest conflict')

    def _other_generations_quiet(self, root, payload, claim, action, start):
        previous = start.get('previous_generation') if action == 'answer' else None
        if action == 'answer' and (previous == payload['generation'] or previous not in claim['generations']):
            raise DriverError('answer predecessor ledger required')
        for generation, entry in claim['generations'].items():
            if generation == payload['generation']:
                continue
            _id(generation)
            if not isinstance(entry, dict) or entry.get('start_action') not in ('launch', 'answer'):
                raise DriverError('other generation ledger conflict')
            bound = {**entry['payload'], 'claim_epoch':claim['claim_epoch'], 'preparation_hash':entry['preparation_hash']}
            if (bound.get('generation') != generation or any(bound.get(key) != payload[key] for key in
                    ('protocol_version', 'owner_namespace', 'attempt_id', 'dispatch_id'))):
                raise DriverError('other generation scope conflict')
            self._bound_entry(root, entry['start_action'], bound)
            descriptor, session = self._descriptor(root, bound)
            if entry['phase'] == 'prepared':
                self._preparation_files(root, descriptor, bound)
                continue
            if action == 'launch':
                raise DriverError('initial launch has another armed generation')
            _, record, recorded_descriptor = self._generation(root, generation)
            if (recorded_descriptor != descriptor or record['session_id'] != session
                    or record['operation_id'] != entry['start_operation_id']):
                raise DriverError('other armed generation identity conflict')
            if generation == previous:
                continue
            observation = process.inspect(descriptor, record.get('invocation_id'), run=self.run)
            if (observation.get('status') != 'quiescent'
                    or not (observation.get('receipt') or observation.get('basis') == 'changed_boot')):
                raise DriverError('other armed generation quiescence required')

    def _unstarted_evidence(self, root, payload, abandoned):
        if not isinstance(abandoned, dict) or set(abandoned) != {'action', 'payload'} or abandoned['action'] not in ('launch', 'answer'):
            raise DriverError('invalid abandoned start')
        start = abandoned['payload']
        if not isinstance(start, dict) or any(start.get(key) != payload.get(key) for key in
                ('protocol_version', 'owner_namespace', 'attempt_id', 'dispatch_id', 'generation', 'claim_epoch', 'preparation_hash')):
            raise DriverError('abandoned start scope conflict')
        _id(start.get('operation_id'))
        claim, entry = self._bound_entry(root, abandoned['action'], start)
        if entry['phase'] != 'prepared':
            raise DriverError('armed generation cannot prove never-started')
        descriptor, _ = self._descriptor(root, start)
        self._other_generations_quiet(root, payload, claim, abandoned['action'], start)
        fence = _read(root / 'fence.json')
        stop_path = root / 'operations' / (_id(fence['operation_id']) + '.json')
        stop = _read(stop_path)
        if (set(fence) != {'operation_id', 'generation'} or fence['generation'] != stop['payload'].get('generation')
                or stop['payload'].get('claim_epoch') != claim['claim_epoch']
                or stop.get('action') != 'stop' or stop.get('payload_hash') != self._operation_hash('stop', stop['payload'])
                or stop['payload'].get('operation_id') != fence['operation_id']
                or any(stop['payload'].get(key) != payload.get(key) for key in ('owner_namespace', 'attempt_id', 'dispatch_id'))):
            raise DriverError('permanent fence identity conflict')
        preparation_found, start_operation = False, None
        for path in (root / 'operations').glob('*.json'):
            operation = _read(path)
            request = operation['payload']
            if (not isinstance(request, dict) or path.stem != request.get('operation_id')
                    or operation['payload_hash'] != self._operation_hash(operation['action'], request)
                    or any(request.get(key) != payload.get(key) for key in ('owner_namespace', 'attempt_id', 'dispatch_id'))):
                raise DriverError('reachable operation identity conflict')
            if request.get('generation') != payload['generation']:
                continue
            if operation['action'] == 'inspect' and 'prepare_start' in request:
                if request['prepare_start'] != {'action':abandoned['action'], 'payload':entry['payload']}:
                    raise DriverError('reachable preparation conflict')
                if request.get('claim_epoch', claim['claim_epoch']) != claim['claim_epoch']:
                    raise DriverError('reachable preparation epoch conflict')
                response = operation.get('response')
                if response and response.get('preparation_witness') != self._witness(payload, claim, entry):
                    raise DriverError('reachable preparation witness conflict')
                preparation_found = True
            if operation['action'] in ('launch', 'answer'):
                if operation['action'] != abandoned['action'] or _json(request) != _json(start) or 'response' in operation:
                    raise DriverError('reachable start operation conflict')
                if operation.get('stage') not in ('intent', 'directory', 'prepared', 'recorded', 'active'):
                    raise DriverError('reachable start stage conflict')
                start_operation = operation
        if not preparation_found:
            raise DriverError('durable preparation operation required')
        self._preparation_files(root, descriptor, start if start_operation else None)
        state_path = root / 'state.json'
        state = _read(state_path) if state_path.exists() else {}
        current = state.get('current_generation')
        if start_operation:
            if state not in (start_operation['state_before'], start_operation['state_after']):
                raise DriverError('abandoned generation head conflict')
            before, after = start_operation['state_before'], start_operation['state_after']
            expected = {**before, 'consumed_questions':list(before.get('consumed_questions', [])),
                        'current_generation':payload['generation'], 'current_operation':start['operation_id']}
            if abandoned['action'] == 'answer':
                expected['consumed_questions'].append(start['question_id'])
            if start_operation['stage'] == 'active' and state != after:
                raise DriverError('active preparation lost current head')
            if after != expected:
                raise DriverError('abandoned generation state intent conflict')
        allowed = (None, payload['generation']) if abandoned['action'] == 'launch' else (start.get('previous_generation'), payload['generation'])
        if current not in allowed or (abandoned['action'] == 'answer' and not start.get('previous_generation')):
            raise DriverError('abandoned generation current head conflict')
        if not start_operation and current == payload['generation']:
            raise DriverError('current head lacks start intent')
        # Unit absence is only a consistency check after the intact durable witness.
        result = self.run([shutil.which('systemctl') or 'systemctl', '--user', 'show', descriptor.unit,
            '--property=LoadState,ActiveState,InvocationID,Description'])
        unit = dict(line.split('=', 1) for line in result.stdout.splitlines() if '=' in line)
        if (result.returncode not in (0, 1) or unit.get('LoadState') != 'not-found'
                or unit.get('ActiveState') != 'inactive' or unit.get('InvocationID')
                or unit.get('Description', '') not in ('', descriptor.unit)
                or (result.returncode and result.stderr.strip())):
            raise DriverError('unit absence consistency unavailable')
        attempt = {'current_generation':current, 'quiescent':True,
                   'basis':'empty_fenced_attempt' if current is None else 'unstarted_current_generation'}
        if abandoned['action'] == 'answer':
            previous = _id(start.get('previous_generation'))
            if previous == payload['generation']:
                raise DriverError('answer predecessor identity conflict')
            predecessor = self._observe(root, previous)
            if predecessor.get('status') != 'quiescent' or not (predecessor.get('receipt') or predecessor.get('basis') == 'changed_boot'):
                raise DriverError('positive predecessor quiescence required')
            _, prior, previous_descriptor = self._generation(root, previous)
            if start['session_id'] != prior['session_id'] or descriptor.profile != previous_descriptor.profile:
                raise DriverError('answer predecessor session conflict')
            attempt.update(predecessor_observation=predecessor,
                basis='predecessor_changed_boot' if predecessor.get('basis') == 'changed_boot' else 'predecessor_terminal')
        attempt['observation_revision'] = _hash({'state':state, 'attempt':attempt, 'fence':fence})
        return claim, entry, start, fence, attempt

    def _witness(self, payload, claim, entry):
        witness = {key:payload[key] for key in ('owner_namespace', 'attempt_id', 'dispatch_id', 'generation')}
        witness.update(version=1, claim_epoch=claim['claim_epoch'], **{key:entry[key] for key in
            ('preparation_hash', 'start_action', 'start_operation_id', 'descriptor_hash', 'profile_hash', 'session_id')})
        return witness

    def _unstarted(self, root, payload, abandoned, *, existing=None):
        try:
            claim, entry, start, fence, attempt = self._unstarted_evidence(root, payload, abandoned)
            proof = self._witness(payload, claim, entry)
            proof.update(start_payload_hash=_hash(start), basis='fenced_before_launch', fence_operation_id=fence['operation_id'])
            proof['receipt_hash'] = _hash(proof)
            if existing is not None and existing != proof:
                raise DriverError('unstarted receipt identity conflict')
            path = root / 'generations' / payload['generation'] / 'unstarted.json'
            if existing is None:
                self._validate_lock(root)
                process._private_directory(path.parent)
                if path.exists() and _read(path) != proof:
                    raise DriverError('immutable unstarted receipt conflict')
                if not path.exists():
                    self._commit(root, path, proof)
            return {'status':'never_started', 'fenced':True, 'current_generation':attempt['current_generation'],
                    'unstarted_generation':proof, 'attempt_observation':attempt,
                    'observation_revision':attempt['observation_revision']}
        except (DriverError, process.ProcessError, OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired):
            return {'status':'uncertain', 'fenced':True}

    def _inspect(self, root, payload):
        receipt = root / 'generations' / payload['generation'] / 'unstarted.json'
        if receipt.exists():
            try:
                proof = _read(receipt)
                claim = _read(root / 'claim.json')
                entry = claim['generations'][payload['generation']]
                start = {**entry['payload'], 'claim_epoch':claim['claim_epoch'], 'preparation_hash':entry['preparation_hash']}
                return self._unstarted(root, payload, {'action':entry['start_action'], 'payload':start}, existing=proof)
            except (DriverError, process.ProcessError, OSError, ValueError, KeyError, TypeError):
                return {'status':'uncertain', 'fenced':True}
        return self._observe(root, payload['generation'])

    def _stop(self, root, payload, operation, intent):
        self._commit(root, operation, intent)
        if not (root / 'fence.json').exists():
            self._commit(root, root / 'fence.json', {'operation_id':payload['operation_id'], 'generation':payload['generation']})
        if 'abandoned_start' in payload:
            return self._unstarted(root, payload, payload['abandoned_start'])
        invocation = payload.get('invocation_id')
        if 'invocation_id' in payload and (not isinstance(invocation, str) or not re.fullmatch(r'[0-9a-f]{32}', invocation)):
            raise DriverError('exact invocation identity required')
        generation_path = root / 'generations' / payload['generation'] / 'generation.json'
        state_path = root / 'state.json'
        if not generation_path.exists() or not state_path.exists():
            return {'status':'uncertain', 'fenced':True}
        path, record, descriptor = self._generation(root, payload['generation'])
        if _read(state_path)['current_generation'] != payload['generation']:
            if invocation is not None:
                raise DriverError('stop requires current generation')
            return {'status':'uncertain', 'fenced':True}
        if invocation is None:
            return self._observe(root, payload['generation'])
        if record.get('invocation_id') and record['invocation_id'] != invocation:
            raise DriverError('invocation identity conflict')
        record['invocation_id'] = invocation
        self._commit(root, path, record)
        self._validate_lock(root)
        stopped = process.stop(descriptor, invocation, run=self.run)
        return self._observe(root, payload['generation'], stopped)

    def execute(self, action, payload):
        if action not in ('launch', 'inspect', 'answer', 'stop'):
            raise DriverError('unknown owned action')
        preparing = action == 'inspect' and 'prepare_start' in payload
        with self._locked(payload, preparing=preparing) as root:
            if (root / 'retired.json').exists():
                reader = retirement.Read()
                record = reader.json(root / 'retired.json')
                record = retirement.read_retirement(root / 'retired.json', expected_record=record, reader=reader)
                claim = _read(root / 'claim.json')
                if (record['kind'] != 'owned' or record['identity'] != {
                        key: claim[key] for key in ('owner_namespace', 'attempt_id', 'dispatch_id', 'claim_epoch')}
                        or {item['generation_or_run_id'] for item in record['processes']} != set(claim['generations'])):
                    raise DriverError('retirement claim identity conflict')
                if action in ('launch', 'answer') or preparing:
                    raise DriverError('owned attempt is retired')
                if payload['generation'] not in claim['generations']:
                    raise DriverError('unknown retired generation')
                observation = retirement.observe_retirement(record, reader=reader, systemctl=self.systemctl,
                    proc_root=self.proc_root, cgroup_root=self.cgroup_root)
                self._validate_lock(root)
                return {**{key:payload[key] for key in ('protocol_version', 'owner_namespace', 'attempt_id', 'dispatch_id', 'generation')},
                    'status':'quiescent' if observation['quiescent'] else 'uncertain', 'retirement':observation}
            operation = root / 'operations' / (payload['operation_id'] + '.json')
            identity = self._operation_hash(action, payload)
            prior = _read(operation) if operation.exists() else None
            if prior is not None and not isinstance(prior, dict):
                raise DriverError('invalid owned operation record')
            intent = {'payload_hash':identity, 'action':action, 'payload':payload}
            if prior is not None:
                if prior['payload_hash'] != identity:
                    raise DriverError('operation payload conflict')
                # Inspection is always a fresh observation, even under a replayed ID.
                if 'response' in prior and action != 'inspect':
                    return prior['response']
                intent = prior
            if preparing:
                response = self._prepare_start(root, payload, operation, intent)
            elif action in ('launch', 'answer'):
                self._bound_entry(root, action, payload)
                response = (self._resume_start(root, payload, operation, intent) if prior is not None
                            else self._start(root, payload, operation, intent, answer=action == 'answer'))
            elif action == 'stop':
                response = self._stop(root, payload, operation, intent)
            else:
                response = self._inspect(root, payload)
            response = {**{key:payload[key] for key in ('protocol_version', 'owner_namespace', 'attempt_id', 'dispatch_id', 'generation')}, **response}
            self._commit(root, operation, {**intent, 'response':response})
            return response


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument('--fleet-socket', required=True)
    parser.add_argument('--fleet-cache', required=True)
    parser.add_argument('--fleet-state')
    parser.add_argument('action', choices=('launch', 'inspect', 'answer', 'stop'))
    args = parser.parse_args(argv)
    try:
        raw = sys.stdin.buffer.read(OUTPUT_LIMIT + 1)
        if len(raw) > OUTPUT_LIMIT:
            raise DriverError('request exceeds size limit')
        payload = json.loads(raw)
        # The owned/ tree is durable state when given, otherwise the disposable cache.
        response = OwnedDriver(args.fleet_socket, args.fleet_state or args.fleet_cache).execute(args.action, payload)
    except (DriverError, process.ProcessError, OSError, ValueError, KeyError, TypeError) as exc:
        print(_json({'protocol_version':1, 'status':'error', 'error':str(exc)}))
        return 1
    print(_json(response))
    return 0
