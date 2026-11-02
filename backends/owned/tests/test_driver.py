from dataclasses import replace
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

from . import runtime_roots

ENTRY = Path(__file__).resolve().parents[1] / 'agent-fleet-owned-driver'


class OwnedDriverTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(importlib.util.find_spec('backends.owned.driver'),
                             'owned launch must durably replay its original operation receipt')
        from backends.owned import driver as owned_driver, process as owned_process
        self.driver_module, self.op = owned_driver, owned_process
        self.temporary = tempfile.TemporaryDirectory(prefix='owned-driver-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root / 'xdg' / 'agent-fleet' / 'agent-fleet'
        self.cache.parent.mkdir(parents=True)
        self.attempt = self.cache / 'owned' / 'owner' / 'attempt'
        for directory in (self.cache, self.cache / 'owned', self.attempt.parent, self.attempt):
            directory.mkdir(mode=0o700)
        owner = self.root / 'repository'
        owner.mkdir()
        self.git(owner, 'init', '-b', 'main')
        self.git(owner, 'config', 'user.name', 'Fixture')
        self.git(owner, 'config', 'user.email', 'fixture@example.invalid')
        (owner / 'tracked').write_text('before\n')
        self.git(owner, 'add', 'tracked')
        self.git(owner, '-c', 'commit.gpgSign=false', 'commit', '-m', 'initial')
        task = self.attempt / 'task'
        self.git(owner, 'worktree', 'add', '--detach', str(task), 'HEAD')
        metadata = self.git(task, 'rev-parse', '--absolute-git-dir')
        shell = str(Path(shutil.which('bash')).resolve())
        profile = owned_process.SandboxProfile(str(task), metadata, str(owner / '.git'),
            str(self.attempt / 'objects'), str(self.attempt / 'home'), str(self.attempt / 'tmp'),
            shell, runtime_roots())
        self.descriptor = owned_process.ProcessDescriptor('first', owned_driver.generation_unit('owner', 'attempt', 'dispatch', 'first'),
            owned_process.boot_id(), profile, (shell, '-c', 'true'),
            str(self.attempt / 'generations' / 'first' / 'host'), 20)
        self.payload = dict(protocol_version=1, owner_namespace='owner', attempt_id='attempt', dispatch_id='dispatch',
            generation='first', operation_id='launch', descriptor=self.descriptor.to_dict(), session_id='session')
        self.calls = []
        self.invocation = 'a' * 32
        self.running = True
        self.fail_launch = False
        self.driver = owned_driver.OwnedDriver(str(self.root / 'fleet.sock'), str(self.cache), run=self.boundary)

    def git(self, path, *args):
        result = subprocess.run(['git', '-C', str(path), *args], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def boundary(self, argv):
        self.calls.append(argv)
        if 'systemd-run' in Path(argv[0]).name:
            state = json.loads((self.attempt / 'state.json').read_text())
            generation = state['current_generation']
            record = json.loads((self.attempt / 'generations' / generation / 'generation.json').read_text())
            self.assertIn('--unit=' + record['descriptor']['unit'], argv)
            operation = json.loads((self.attempt / 'operations' / (record['operation_id'] + '.json')).read_text())
            self.assertEqual(operation['stage'], 'active')
            self.assertEqual(state['current_operation'], record['operation_id'])
            if self.fail_launch:
                raise subprocess.TimeoutExpired(argv, 15)
            return subprocess.CompletedProcess(argv, 0, '', '')
        if 'stop' in argv:
            self.assertTrue((self.attempt / 'fence.json').exists(), 'stop fence must precede systemctl')
            self.running = False
            return subprocess.CompletedProcess(argv, 0, '', '')
        if getattr(self, 'missing_unit', False):
            return subprocess.CompletedProcess(argv, 0, 'LoadState=not-found\nActiveState=inactive\n', '')
        descriptor_hash = ''
        for path in (self.attempt / 'generations').glob('*/generation.json'):
            descriptor = self.op.ProcessDescriptor.from_dict(json.loads(path.read_text())['descriptor'])
            if descriptor.unit in argv:
                descriptor_hash = descriptor.digest
        return subprocess.CompletedProcess(argv, 0,
            'Description=AIOS owned ' + descriptor_hash + '\nLoadState=loaded\nActiveState=' + ('active' if self.running else 'inactive') +
            '\nInvocationID=' + self.invocation + '\nControlGroup=/owned\n', '')

    def request(self, **changes):
        result = {k:v for k,v in self.payload.items() if k != 'descriptor'}
        result.update(changes)
        return result

    def terminal(self, result, *, session='session', denials=None, status='0'):
        state = Path(self.descriptor.state_directory)
        self.op._write_once(state / 'terminal.json', json.dumps(dict(descriptor_hash=self.descriptor.digest,
            boot_id=self.descriptor.boot_id, unit=self.descriptor.unit, invocation_id='a' * 32,
            quiescent=True, service_result='success', exit_code='exited', exit_status=status)))
        (state / 'stdout').write_text(json.dumps(dict(type='result', session_id=session,
            structured_output=result, permission_denials=denials or [])) + '\n')

    def test_launch_replay_and_payload_conflict_survive_new_driver(self):
        first = self.start('launch', self.payload)
        self.assertEqual(first['status'], 'running')
        again = self.driver_module.OwnedDriver(str(self.root / 'fleet.sock'), str(self.cache), run=self.boundary)
        self.assertEqual(again.execute('launch', self.payload), first)
        self.assertEqual(sum('systemd-run' in Path(c[0]).name for c in self.calls), 1)
        changed = json.loads(json.dumps(self.payload))
        changed['descriptor']['runtime_seconds'] = 19
        with self.assertRaisesRegex(self.driver_module.DriverError, 'conflict'):
            again.execute('launch', changed)

    def test_lost_response_reconciles_without_launching_again(self):
        self.fail_launch = True
        first = self.start('launch', self.payload)
        self.assertEqual(first['status'], 'uncertain')
        self.assertEqual(self.start('launch', self.payload), first)
        observation = self.driver.execute('inspect', self.request(operation_id='inspect'))
        self.assertEqual(observation['status'], 'running')
        self.assertEqual(sum('systemd-run' in Path(c[0]).name for c in self.calls), 1)

    def test_stop_fences_before_external_effect_and_blocks_next_launch(self):
        self.start('launch', self.payload)
        stopped = self.driver.execute('stop', self.request(operation_id='stop', invocation_id='a' * 32))
        self.assertEqual(stopped['status'], 'uncertain')
        next_descriptor = replace(self.descriptor, generation='second', unit=self.driver_module.generation_unit('owner', 'attempt', 'dispatch', 'second'),
            state_directory=str(self.attempt / 'generations' / 'second' / 'host'))
        with self.assertRaisesRegex(self.driver_module.DriverError, 'fenced'):
            self.start('launch', {**self.payload, 'generation':'second', 'operation_id':'next',
                'descriptor':next_descriptor.to_dict(), 'session_id':'session'})

    def test_question_is_receipt_gated_and_answer_consumed_once(self):
        self.start('launch', self.payload)
        self.terminal(dict(kind='needs_input', text='choose', question='Which?', options=['A','B']))
        observation = self.driver.execute('inspect', self.request(operation_id='question'))
        self.assertEqual(observation['result']['kind'], 'needs_input')
        next_descriptor = replace(self.descriptor, generation='second', unit=self.driver_module.generation_unit('owner', 'attempt', 'dispatch', 'second'),
            state_directory=str(self.attempt / 'generations' / 'second' / 'host'),
            argv=(*self.descriptor.argv, 'answer'))
        answer = self.request(generation='second', operation_id='answer', previous_generation='first',
            question_id=observation['question_id'], observation_revision=observation['observation_revision'],
            answer='A', descriptor=next_descriptor.to_dict(), session_id='session')
        self.assertEqual(self.start('answer', answer)['status'], 'running')
        self.assertEqual(self.start('answer', answer)['status'], 'running')
        previous = self.driver.execute('inspect', self.request(operation_id='old-question'))
        self.assertNotIn('question_id', previous)
        with self.assertRaisesRegex(self.driver_module.DriverError, 'current|consumed|preparation'):
            self.start('answer', {**answer, 'operation_id':'answer-again'})
        self.assertEqual(sum('systemd-run' in Path(c[0]).name for c in self.calls), 2)

    def test_arbitrary_state_path_and_attached_task_rejected(self):
        changed = json.loads(json.dumps(self.payload))
        changed['descriptor']['state_directory'] = str(self.root / 'arbitrary')
        with self.assertRaisesRegex(self.driver_module.DriverError, 'state'):
            self.start('launch', changed)
        (Path(self.descriptor.profile.git_directory) / 'HEAD').write_text('ref: refs/heads/main\n')
        with self.assertRaisesRegex(self.op.ProcessError, 'detached'):
            self.start('launch', self.payload)
        self.assertFalse(self.calls)

    def test_permission_denials_and_wrong_session_are_attention(self):
        self.start('launch', self.payload)
        self.terminal(dict(kind='needs_input', question='Permission?'), denials=[{'tool':'Bash'}])
        observation = self.driver.execute('inspect', self.request(operation_id='inspect'))
        self.assertEqual(observation['attention'], 'permission_denials')
        self.assertNotIn('question_id', observation)
        state = Path(self.descriptor.state_directory)
        (state / 'stdout').write_text(json.dumps(dict(type='result', session_id='other',
            structured_output=dict(kind='completed', text='done'))) + '\n')
        observation = self.driver.execute('inspect', self.request(operation_id='inspect-again'))
        self.assertEqual(observation['attention'], 'session_mismatch')

    def test_other_attempt_activity_does_not_change_revision(self):
        self.start('launch', self.payload)
        before = self.driver.execute('inspect', self.request(operation_id='inspect'))
        other = self.cache / 'owned' / 'owner' / 'other'
        other.mkdir()
        (other / 'unrelated').write_text('activity')
        after = self.driver.execute('inspect', self.request(operation_id='inspect-again'))
        self.assertEqual(before['observation_revision'], after['observation_revision'])

    def test_claim_binding_cannot_be_changed(self):
        self.start('launch', self.payload)
        for changes in ({'dispatch_id':'another'}, {'protocol_version':2}, {'generation':'../escape'}):
            with self.assertRaises(self.driver_module.DriverError):
                self.driver.execute('inspect', self.request(operation_id='bad', **changes))
        other = self.driver_module.OwnedDriver(str(self.root / 'other.sock'), str(self.cache), run=self.boundary)
        with self.assertRaisesRegex(self.driver_module.DriverError, 'claim'):
            other.execute('inspect', self.request(operation_id='other-socket'))

    def test_stop_after_unknown_launch_never_adopts_replaced_invocation(self):
        self.fail_launch = True
        self.start('launch', self.payload)
        self.invocation = 'b' * 32
        stopped = self.driver.execute('stop', self.request(operation_id='stop', invocation_id='a' * 32))
        self.assertEqual(stopped['status'], 'uncertain')
        observed = self.driver.execute('inspect', self.request(operation_id='inspect'))
        self.assertEqual(observed['status'], 'uncertain')
        self.assertFalse(any('stop' in call for call in self.calls))

    def test_unfinished_stop_intent_retries_exact_stop_after_restart(self):
        self.start('launch', self.payload)
        payload = self.request(operation_id='stop', invocation_id='a' * 32)
        operation = self.attempt / 'operations' / 'stop.json'
        self.driver_module._write(operation, dict(payload_hash=self.driver_module._hash({'action':'stop', 'payload':payload}),
            action='stop', payload=payload))
        self.driver_module._write(self.attempt / 'fence.json', dict(generation='first', operation_id='stop'))
        observation = self.driver.execute('stop', payload)
        self.assertTrue(any('stop' in call for call in self.calls))
        self.assertEqual(observation['status'], 'uncertain')

    def test_output_requires_receipt_and_success_and_is_bounded(self):
        self.start('launch', self.payload)
        state = Path(self.descriptor.state_directory)
        (state / 'stdout').write_text(json.dumps(dict(type='result', session_id='session',
            structured_output=dict(kind='completed', text='done'))) + '\n')
        running = self.driver.execute('inspect', self.request(operation_id='running'))
        self.assertNotIn('result', running)
        self.terminal(dict(kind='completed', text='done'), status='1')
        failed = self.driver.execute('inspect', self.request(operation_id='failed'))
        self.assertEqual(failed['attention'], 'process_failed')
        terminal = json.loads((state / 'terminal.json').read_text())
        terminal['exit_status'] = '0'
        (state / 'terminal.json').write_text(json.dumps(terminal))
        with (state / 'stdout').open('wb') as stream:
            stream.write(b' ' * (self.driver_module.OUTPUT_LIMIT + 1))
        bounded = self.driver.execute('inspect', self.request(operation_id='bounded'))
        self.assertEqual(bounded['attention'], 'output_truncated')

    def test_cli_inspects_receipt_without_external_process(self):
        self.start('launch', self.payload)
        self.terminal(dict(kind='completed', text='untrusted proposal'))
        cli = subprocess.run([__import__('sys').executable, str(ENTRY),
            '--fleet-socket', str(self.root / 'fleet.sock'), '--fleet-cache', str(self.cache), 'inspect'],
            input=json.dumps(self.request(operation_id='cli')), capture_output=True, text=True, timeout=5)
        self.assertEqual(cli.returncode, 0, cli.stderr + cli.stdout)
        response = json.loads(cli.stdout)
        self.assertEqual(response['status'], 'quiescent')
        self.assertEqual(response['result']['text'], 'untrusted proposal')
        self.assertEqual(response['descriptor_hash'], self.descriptor.digest)

    def test_755_fleet_cache_is_allowed_but_owned_state_stays_private(self):
        self.cache.chmod(0o755)
        self.assertEqual(self.start('launch', self.payload)['status'], 'running')
        self.assertEqual(self.cache.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.attempt.stat().st_mode & 0o777, 0o700)

    def test_parallel_same_operation_launches_one_process(self):
        from concurrent.futures import ThreadPoolExecutor
        self.preparation()
        drivers = [self.driver_module.OwnedDriver(str(self.root / 'fleet.sock'), str(self.cache), run=self.boundary)
                   for _ in range(2)]
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda driver: driver.execute('launch', self.payload), drivers))
        self.assertEqual(results[0], results[1])
        self.assertEqual(sum('systemd-run' in Path(c[0]).name for c in self.calls), 1)

    def test_new_question_rejects_stale_revision_and_running_previous_turn(self):
        self.start('launch', self.payload)
        next_descriptor = replace(self.descriptor, generation='second',
            unit=self.driver_module.generation_unit('owner', 'attempt', 'dispatch', 'second'),
            state_directory=str(self.attempt / 'generations' / 'second' / 'host'))
        answer = self.request(generation='second', operation_id='answer', previous_generation='first',
            question_id='unknown', observation_revision='old', answer='A', session_id='session',
            descriptor=next_descriptor.to_dict())
        with self.assertRaisesRegex(self.driver_module.DriverError, 'question'):
            self.start('answer', answer)
        self.terminal(dict(kind='needs_input', text='choose', question='Which?'))
        question = self.driver.execute('inspect', self.request(operation_id='question'))
        stale_descriptor = replace(next_descriptor, generation='third',
            unit=self.driver_module.generation_unit('owner', 'attempt', 'dispatch', 'third'),
            state_directory=str(self.attempt / 'generations' / 'third' / 'host'))
        with self.assertRaisesRegex(self.driver_module.DriverError, 'question'):
            self.start('answer', {**answer, 'generation':'third', 'operation_id':'stale-answer',
                'descriptor':stale_descriptor.to_dict(), 'question_id':question['question_id']})
        self.assertEqual(sum('systemd-run' in Path(c[0]).name for c in self.calls), 1)

    def test_fleet_default_socket_name_reaches_real_driver(self):
        import os
        fleet = Path(os.environ.get('AIOS_FLEET_TEST_CLI', ''))
        if not fleet.is_file():
            self.skipTest('set AIOS_FLEET_TEST_CLI to a bin/agent-fleet that has the owned verb')
        self.driver = self.driver_module.OwnedDriver('agent-fleet', str(self.cache), run=self.boundary)
        self.start('launch', self.payload)
        self.terminal(dict(kind='completed', text='harmless receipt'))
        environment = {**os.environ, 'XDG_CACHE_HOME':str(self.root / 'xdg'),
                       'AGENT_FLEET_SOCKET':'agent-fleet'}
        cli = subprocess.run([str(fleet), 'owned', '--driver',
            str(ENTRY), 'inspect'],
            input=json.dumps(self.request(operation_id='fleet-cli')), env=environment,
            capture_output=True, text=True, timeout=5)
        self.assertEqual(cli.returncode, 0, cli.stderr + cli.stdout)
        self.assertEqual(json.loads(cli.stdout)['result']['text'], 'harmless receipt')
        self.assertEqual(json.loads((self.attempt / 'claim.json').read_text())['fleet_socket'], 'agent-fleet')

    def test_socket_identity_has_no_spelling_normalization_collision(self):
        for socket in ('', '.', '..', 'bad name', 'relative/path', '/tmp//socket', '/tmp/./socket'):
            with self.subTest(socket=socket), self.assertRaises(ValueError):
                self.driver_module.OwnedDriver(socket, str(self.cache))

    def test_lost_stop_keeps_exact_operation_payload(self):
        self.start('launch', self.payload)
        original = self.driver.run
        payload = self.request(operation_id='stop', invocation_id='a' * 32)
        def interrupted(argv):
            if 'stop' in argv:
                record = json.loads((self.attempt / 'operations' / 'stop.json').read_text())
                self.assertIsInstance(record, dict, 'stop operation identity must survive before the effect')
                self.assertEqual(record['payload_hash'], self.driver_module._hash({'action':'stop', 'payload':payload}))
                raise KeyboardInterrupt('lost stop response')
            return original(argv)
        self.driver.run = interrupted
        with self.assertRaises(KeyboardInterrupt):
            self.driver.execute('stop', payload)
        with self.assertRaisesRegex(self.driver_module.DriverError, 'conflict'):
            self.driver.execute('stop', {**payload, 'invocation_id':'b' * 32})
        self.driver.run = original
        self.assertEqual(self.driver.execute('stop', payload)['status'], 'uncertain')

    def interrupt_start(self, stage, *, action='launch', payload=None):
        from unittest.mock import patch
        payload = payload or self.payload
        expected = self.driver_module._hash({'action':action, 'payload':self.driver._base(payload)})
        if payload.get('preparation_hash') != expected:
            self.preparation(payload, action)
        generation = payload['generation']
        target = self.attempt / 'generations' / generation
        original_write = self.driver_module._write
        original_directory = self.op._private_directory
        original_prepare = self.op.prepare
        original_once = self.op._write_once
        interrupted = []
        def crash():
            if not interrupted:
                interrupted.append(True)
                raise KeyboardInterrupt('fixture interruption at ' + stage)
        def write(path, value):
            if stage == 'before-response' and Path(path).name == payload['operation_id'] + '.json' and 'response' in value:
                crash()
            original_write(path, value)
            if stage == 'intent' and Path(path).name == payload['operation_id'] + '.json' and value.get('stage') == 'intent':
                crash()
            if stage == 'record' and Path(path) == target / 'generation.json':
                crash()
            if stage == 'state' and Path(path) == self.attempt / 'state.json':
                crash()
        def directory(path):
            original_directory(path)
            if stage == 'directory' and Path(path) == target:
                crash()
        def prepare(descriptor):
            result = original_prepare(descriptor)
            if stage == 'prepared' and descriptor.generation == generation:
                crash()
            return result
        def once(path, value):
            original_once(path, value)
            if stage == 'partial-prepare' and Path(path) == target / 'host' / 'runner.py':
                crash()
        with patch.object(self.driver_module, '_write', side_effect=write), \
                patch.object(self.op, '_private_directory', side_effect=directory), \
                patch.object(self.op, 'prepare', side_effect=prepare), \
                patch.object(self.op, '_write_once', side_effect=once):
            with self.assertRaises(KeyboardInterrupt):
                self.driver.execute(action, payload)
        self.assertTrue(interrupted)

    def resume_interrupted_launch(self, stage):
        self.interrupt_start(stage)
        response = self.start('launch', self.payload)
        self.assertEqual(response['status'], 'running')
        self.assertEqual(self.start('launch', self.payload), response)
        self.assertEqual(sum('systemd-run' in Path(c[0]).name for c in self.calls), 1)
        state = json.loads((self.attempt / 'state.json').read_text())
        self.assertEqual(state['current_generation'], 'first')

    def test_resume_after_durable_intent(self):
        self.resume_interrupted_launch('intent')

    def test_resume_after_generation_directory(self):
        self.resume_interrupted_launch('directory')

    def test_resume_after_partial_preparation(self):
        self.resume_interrupted_launch('partial-prepare')

    def test_resume_after_complete_preparation(self):
        self.resume_interrupted_launch('prepared')

    def test_resume_after_generation_record(self):
        self.resume_interrupted_launch('record')

    def test_resume_after_active_state(self):
        self.resume_interrupted_launch('state')

    def test_resume_after_launch_before_response(self):
        self.resume_interrupted_launch('before-response')

    def resume_interrupted_answer(self, stage):
        self.start('launch', self.payload)
        self.terminal(dict(kind='needs_input', text='choose', question='Which?'))
        question = self.driver.execute('inspect', self.request(operation_id='question'))
        next_descriptor = replace(self.descriptor, generation='second',
            unit=self.driver_module.generation_unit('owner', 'attempt', 'dispatch', 'second'),
            state_directory=str(self.attempt / 'generations' / 'second' / 'host'))
        answer = self.request(generation='second', operation_id='answer', previous_generation='first',
            question_id=question['question_id'], observation_revision=question['observation_revision'],
            answer='A', session_id='session', descriptor=next_descriptor.to_dict())
        self.interrupt_start(stage, action='answer', payload=answer)
        with self.assertRaisesRegex(self.driver_module.DriverError, 'pending|current|consumed|preparation'):
            self.start('answer', {**answer, 'operation_id':'other-answer'})
        self.assertEqual(self.start('answer', answer)['status'], 'running')
        state = json.loads((self.attempt / 'state.json').read_text())
        self.assertEqual(state['consumed_questions'], [question['question_id']])
        self.assertEqual(sum('systemd-run' in Path(c[0]).name for c in self.calls), 2)

    def test_answer_intent_reserves_question_until_resumed(self):
        self.resume_interrupted_answer('intent')

    def test_answer_after_state_consumes_question_exactly_once(self):
        self.resume_interrupted_answer('state')

    def test_unknown_external_launch_after_lost_response_never_repeats(self):
        self.fail_launch = True
        self.running = False
        self.interrupt_start('before-response')
        observed = self.start('launch', self.payload)
        self.assertEqual(observed['status'], 'uncertain')
        self.assertEqual(self.start('launch', self.payload), observed)
        self.assertEqual(sum('systemd-run' in Path(c[0]).name for c in self.calls), 1)

    def test_prepared_generation_remains_fenced_after_stop(self):
        self.interrupt_start('state')
        self.driver.execute('stop', self.request(operation_id='stop', invocation_id='a' * 32))
        observed = self.start('launch', self.payload)
        self.assertTrue(observed['fenced'])
        self.assertFalse(any('systemd-run' in Path(c[0]).name for c in self.calls))

    def fence_interrupted_start(self, stage):
        self.interrupt_start(stage)
        payload = self.request(operation_id='fence')
        stopped = self.driver.execute('stop', payload)
        self.assertEqual(stopped['status'], 'uncertain')
        self.assertTrue(stopped['fenced'])
        self.assertTrue((self.attempt / 'fence.json').is_file())
        self.assertEqual(self.driver.execute('stop', payload), stopped)
        resumed = self.start('launch', self.payload)
        self.assertEqual(resumed['status'], 'uncertain')
        self.assertTrue(resumed['fenced'])
        self.assertFalse(self.calls, 'a fenced prelaunch generation cannot start or stop a process')
        with self.assertRaisesRegex(self.driver_module.DriverError, 'conflict'):
            self.driver.execute('stop', {**payload, 'invocation_id':'a' * 32})

    def test_fence_only_stop_after_launch_intent_before_generation_directory(self):
        self.fence_interrupted_start('intent')

    def test_fence_only_stop_after_generation_directory_before_record(self):
        self.fence_interrupted_start('directory')

    def test_fence_only_stop_learns_identity_without_stopping_unknown_launch(self):
        self.fail_launch = True
        self.assertEqual(self.start('launch', self.payload)['status'], 'uncertain')
        record = self.attempt / 'generations' / 'first' / 'generation.json'
        self.assertNotIn('invocation_id', json.loads(record.read_text()))
        fenced = self.driver.execute('stop', self.request(operation_id='fence'))
        self.assertEqual(fenced['status'], 'running')
        self.assertTrue(fenced['fenced'])
        self.assertEqual(fenced['invocation_id'], 'a' * 32)
        self.assertFalse(any('stop' in call for call in self.calls))
        stopped = self.driver.execute('stop', self.request(operation_id='exact-stop', invocation_id=fenced['invocation_id']))
        self.assertEqual(stopped['status'], 'uncertain')
        self.assertTrue(stopped['fenced'])
        self.assertEqual(sum('stop' in call for call in self.calls), 1)

    def test_fence_only_stop_missing_unit_remains_uncertain(self):
        self.fail_launch = True
        self.missing_unit = True
        self.start('launch', self.payload)
        observed = self.driver.execute('stop', self.request(operation_id='fence'))
        self.assertEqual(observed['status'], 'uncertain')
        self.assertTrue(observed['fenced'])
        self.assertFalse(any('stop' in call for call in self.calls))

    def test_malformed_or_conflicting_stop_identity_still_fences_attempt(self):
        self.start('launch', self.payload)
        malformed = self.request(operation_id='malformed', invocation_id='not-an-invocation')
        with self.assertRaisesRegex(self.driver_module.DriverError, 'invocation'):
            self.driver.execute('stop', malformed)
        self.assertTrue((self.attempt / 'fence.json').is_file())
        with self.assertRaisesRegex(self.driver_module.DriverError, 'conflict'):
            self.driver.execute('stop', {**malformed, 'invocation_id':'a' * 32})
        with self.assertRaisesRegex(self.driver_module.DriverError, 'conflict'):
            self.driver.execute('stop', self.request(operation_id='conflicting', invocation_id='b' * 32))
        self.assertFalse(any('stop' in call for call in self.calls))
        self.driver.execute('stop', self.request(operation_id='valid-stop', invocation_id='a' * 32))
        self.assertEqual(sum('stop' in call for call in self.calls), 1)

    def interrupt_stop_record(self, *, after_fence):
        from unittest.mock import patch
        if not (self.attempt / 'claim.json').exists():
            self.preparation()
        payload = self.request(operation_id='stop-crash')
        original_write = self.driver_module._write
        interrupted = []
        def write(path, value):
            original_write(path, value)
            expected = self.attempt / ('fence.json' if after_fence else 'operations/stop-crash.json')
            if Path(path) == expected and not interrupted:
                interrupted.append(True)
                raise KeyboardInterrupt('stop record interruption')
        with patch.object(self.driver_module, '_write', side_effect=write):
            with self.assertRaises(KeyboardInterrupt):
                self.driver.execute('stop', payload)
        self.assertTrue(interrupted)
        return payload

    def test_stop_crash_after_fence_preserves_original_operation_payload(self):
        self.start('launch', self.payload)
        payload = self.interrupt_stop_record(after_fence=True)
        self.assertTrue((self.attempt / 'fence.json').exists())
        with self.assertRaisesRegex(self.driver_module.DriverError, 'conflict'):
            self.driver.execute('stop', {**payload, 'invocation_id':'a' * 32})
        self.assertFalse(any('stop' in call for call in self.calls))
        observed = self.driver.execute('stop', payload)
        self.assertTrue(observed['fenced'])
        self.assertFalse(any('stop' in call for call in self.calls))

    def test_stop_crash_before_fence_blocks_pending_launch_replay(self):
        self.interrupt_start('intent')
        payload = self.interrupt_stop_record(after_fence=False)
        self.assertFalse((self.attempt / 'fence.json').exists())
        observed = self.start('launch', self.payload)
        self.assertEqual(observed['status'], 'uncertain')
        self.assertTrue(observed['fenced'])
        self.assertFalse(self.calls)
        stopped = self.driver.execute('stop', payload)
        self.assertTrue(stopped['fenced'])
        self.assertEqual(stopped['status'], 'uncertain')

    def test_stop_crash_before_fence_blocks_new_launch(self):
        payload = self.interrupt_stop_record(after_fence=False)
        self.assertFalse((self.attempt / 'fence.json').exists())
        with self.assertRaisesRegex(self.driver_module.DriverError, 'fenced|pending'):
            self.start('launch', self.payload)
        self.assertTrue((self.attempt / 'fence.json').exists())
        self.assertFalse(self.calls)
        observed = self.driver.execute('stop', payload)
        self.assertTrue(observed['fenced'])
        self.assertEqual(observed['status'], 'uncertain')

    def test_observation_exposes_current_head_without_adopting_observed_generation(self):
        first = self.start('launch', self.payload)
        self.assertEqual(first.get('current_generation'), 'first')
        state_path = self.attempt / 'state.json'
        state = json.loads(state_path.read_text())
        state['current_generation'] = 'newer-generation'
        self.driver_module._write(state_path, state)
        later = self.driver.execute('inspect', self.request(operation_id='observe-old'))
        self.assertEqual(later['generation'], 'first')
        self.assertEqual(later['current_generation'], 'newer-generation')
        self.assertNotEqual(first['observation_revision'], later['observation_revision'])
        unrelated = self.cache / 'owned' / 'different-owner'
        unrelated.mkdir()
        (unrelated / 'activity').write_text('unrelated task changed')
        again = self.driver.execute('inspect', self.request(operation_id='observe-old-again'))
        self.assertEqual(later['observation_revision'], again['observation_revision'])

    def start(self, action, payload):
        expected = self.driver_module._hash({'action':action, 'payload':self.driver._base(payload)})
        if payload.get('preparation_hash') != expected:
            self.preparation(payload, action)
        return self.driver.execute(action, payload)

    def preparation(self, payload=None, action='launch', operation_id=None):
        payload = payload or self.payload
        base = {key:value for key,value in payload.items() if key not in ('claim_epoch', 'preparation_hash')}
        request = self.request(generation=payload['generation'], operation_id=operation_id or 'prepare-' + payload['operation_id'],
            prepare_start={'action':action, 'payload':base})
        request.pop('preparation_hash', None)
        if payload.get('claim_epoch'):
            request['claim_epoch'] = payload['claim_epoch']
        response = self.driver.execute('inspect', request)
        witness = response['preparation_witness']
        payload.update(claim_epoch=witness['claim_epoch'], preparation_hash=witness['preparation_hash'])
        return response

    def test_preparation_witness_is_durable_and_does_not_start_or_change_head(self):
        prepared = self.preparation()
        self.assertEqual(prepared['status'], 'prepared')
        witness = prepared['preparation_witness']
        self.assertEqual(witness['descriptor_hash'], self.descriptor.digest)
        self.assertEqual(witness['start_operation_id'], 'launch')
        self.assertFalse(self.calls)
        self.assertFalse((self.attempt / 'state.json').exists())
        claim = json.loads((self.attempt / 'claim.json').read_text())
        self.assertEqual(claim['generations']['first']['phase'], 'prepared')
        self.assertEqual(self.preparation(), prepared)

    def test_unwitnessed_launch_has_no_authority(self):
        with self.assertRaisesRegex(self.driver_module.DriverError, 'claim|prepar'):
            self.driver.execute('launch', self.payload)
        self.assertFalse(self.calls)

    def test_missing_claim_cannot_be_recreated_by_bound_operation(self):
        self.preparation()
        (self.attempt / 'claim.json').unlink()
        with self.assertRaisesRegex(self.driver_module.DriverError, 'claim'):
            self.driver.execute('launch', self.payload)
        self.assertFalse((self.attempt / 'claim.json').exists())
        self.assertFalse(self.calls)

    def abandoned(self, payload=None, action='launch', operation_id='abandon'):
        payload = payload or self.payload
        self.missing_unit = True
        return {**self.request(generation=payload['generation'], operation_id=operation_id),
                'claim_epoch':payload['claim_epoch'], 'preparation_hash':payload['preparation_hash'],
                'abandoned_start':{'action':action, 'payload':payload}}

    def test_prepared_bound_generation_can_be_fenced_and_proved_unstarted(self):
        self.preparation()
        stopped = self.driver.execute('stop', self.abandoned())
        self.assertEqual(stopped['status'], 'never_started')
        proof = stopped['unstarted_generation']
        self.assertEqual(proof['claim_epoch'], self.payload['claim_epoch'])
        self.assertEqual(proof['start_payload_hash'], self.driver_module._hash(self.payload))
        self.assertEqual(proof['receipt_hash'], self.driver_module._hash({key:value for key,value in proof.items() if key != 'receipt_hash'}))
        self.assertNotIn('invocation_id', stopped)
        self.assertNotIn('receipt', stopped)
        self.assertEqual(stopped['attempt_observation']['basis'], 'empty_fenced_attempt')
        inspected = self.driver.execute('inspect', self.request(operation_id='fresh-unstarted'))
        self.assertEqual(inspected['unstarted_generation'], proof)
        with self.assertRaisesRegex(self.driver_module.DriverError, 'fenced'):
            self.driver.execute('launch', self.payload)
        self.assertFalse(any('systemd-run' in Path(call[0]).name for call in self.calls))

    def test_all_reachable_prelaunch_crash_intervals_allow_exact_zero_proof(self):
        for stage in ('intent', 'directory', 'partial-prepare', 'prepared', 'record', 'state'):
            with self.subTest(stage=stage):
                fixture = type(self)('runTest')
                fixture.setUp()
                try:
                    fixture.interrupt_start(stage)
                    response = fixture.driver.execute('stop', fixture.abandoned())
                    self.assertEqual(response['status'], 'never_started')
                    fresh = fixture.driver.execute('inspect', fixture.request(operation_id='fresh'))
                    self.assertEqual(fresh['unstarted_generation'], response['unstarted_generation'])
                finally:
                    fixture.doCleanups()

    def test_armed_before_primitive_call_is_uncertain_and_never_relaunched(self):
        from unittest.mock import patch
        self.preparation()
        with patch.object(self.op, 'launch', side_effect=KeyboardInterrupt('after arm')):
            with self.assertRaises(KeyboardInterrupt):
                self.driver.execute('launch', self.payload)
        claim = json.loads((self.attempt / 'claim.json').read_text())
        self.assertEqual(claim['generations']['first']['phase'], 'armed')
        self.missing_unit = True
        self.assertEqual(self.driver.execute('launch', self.payload)['status'], 'uncertain')
        self.assertEqual(self.driver.execute('stop', self.abandoned())['status'], 'uncertain')
        self.assertFalse(any('systemd-run' in Path(call[0]).name for call in self.calls))

    def test_whole_cache_loss_after_lost_launch_response_cannot_reinitialize_claim(self):
        self.fail_launch = True
        self.start('launch', self.payload)
        shutil.rmtree(self.cache)
        for action, payload in (('launch', self.payload), ('inspect', self.request(operation_id='lost-inspect')),
                                ('stop', self.abandoned())):
            with self.subTest(action=action), self.assertRaisesRegex(self.driver_module.DriverError, 'claim'):
                self.driver.execute(action, payload)
        self.assertFalse(self.cache.exists())
        self.assertEqual(sum('systemd-run' in Path(call[0]).name for call in self.calls), 1)

    def test_armed_ledger_survives_host_and_generation_file_deletion(self):
        self.fail_launch = True
        self.start('launch', self.payload)
        shutil.rmtree(self.attempt / 'generations' / 'first')
        self.assertEqual(self.driver.execute('stop', self.abandoned())['status'], 'uncertain')
        self.assertFalse((self.attempt / 'generations' / 'first').exists())
        self.assertEqual(sum('systemd-run' in Path(call[0]).name for call in self.calls), 1)

    def test_missing_or_mismatched_epoch_cannot_start_prepared_generation(self):
        self.preparation()
        for epoch in (None, 'b' * 32):
            payload = dict(self.payload)
            if epoch is None:
                payload.pop('claim_epoch')
            else:
                payload['claim_epoch'] = epoch
            with self.subTest(epoch=epoch), self.assertRaisesRegex(self.driver_module.DriverError, 'epoch'):
                self.driver.execute('launch', payload)
        self.assertFalse(self.calls)

    def test_lock_replacement_before_launch_prevents_external_effect(self):
        from unittest.mock import patch
        self.preparation()
        original = self.driver_module._write
        def replaced(path, value):
            original(path, value)
            if Path(path) == self.attempt / 'claim.json' and value['generations']['first']['phase'] == 'armed':
                (self.attempt / 'lock').unlink()
                (self.attempt / 'lock').touch(mode=0o600)
        with patch.object(self.driver_module, '_write', side_effect=replaced):
            with self.assertRaisesRegex(self.driver_module.DriverError, 'lock'):
                self.driver.execute('launch', self.payload)
        self.assertFalse(any('systemd-run' in Path(call[0]).name for call in self.calls))

    def test_prepared_witness_requires_absent_unit_consistency_not_just_absent_files(self):
        self.preparation()
        payload = self.abandoned()
        self.missing_unit = False
        self.assertEqual(self.driver.execute('stop', payload)['status'], 'uncertain')
        self.assertTrue((self.attempt / 'fence.json').exists())
        self.assertFalse((self.attempt / 'generations' / 'first' / 'unstarted.json').exists())

    def test_unit_lookup_error_or_identity_conflict_cannot_prove_unstarted(self):
        self.preparation()
        payload = self.abandoned()
        for result in (subprocess.CompletedProcess([], 1, '', 'bus unavailable'),
                       subprocess.CompletedProcess([], 0, 'LoadState=loaded\nActiveState=active\nDescription=foreign\nInvocationID=' + 'a' * 32 + '\n', '')):
            self.driver.run = lambda argv, result=result: result
            payload = {**payload, 'operation_id':payload['operation_id'] + '-next'}
            self.assertEqual(self.driver.execute('stop', payload)['status'], 'uncertain')

    def test_any_launch_marker_shape_forbids_zero_proof(self):
        for marker in ('malformed', '', '{}'):
            with self.subTest(marker=marker):
                fixture = type(self)('runTest')
                fixture.setUp()
                try:
                    fixture.interrupt_start('state')
                    (Path(fixture.descriptor.state_directory) / 'launch-intent').write_text(marker)
                    self.assertEqual(fixture.driver.execute('stop', fixture.abandoned())['status'], 'uncertain')
                finally:
                    fixture.doCleanups()

    def test_cached_stop_does_not_make_fresh_inspection_ignore_changed_head(self):
        self.preparation()
        payload = self.abandoned()
        stopped = self.driver.execute('stop', payload)
        inspect = self.request(operation_id='same-inspection')
        self.assertEqual(self.driver.execute('inspect', inspect)['status'], 'never_started')
        self.driver_module._write(self.attempt / 'state.json', {'current_generation':'foreign'})
        self.assertEqual(self.driver.execute('stop', payload), stopped)
        self.assertEqual(self.driver.execute('inspect', inspect)['status'], 'uncertain')

    def test_reachable_preparation_and_start_payload_tampering_is_uncertain(self):
        self.interrupt_start('state')
        payload = self.abandoned()
        operation_path = self.attempt / 'operations' / 'launch.json'
        operation = json.loads(operation_path.read_text())
        operation['payload']['session_id'] = 'changed'
        self.driver_module._write(operation_path, operation)
        self.assertEqual(self.driver.execute('stop', payload)['status'], 'uncertain')

    def test_stop_fence_crash_replay_preserves_exact_unstarted_receipt(self):
        from unittest.mock import patch
        self.preparation()
        payload = self.abandoned()
        original = self.driver_module._write
        def crash(path, value):
            original(path, value)
            if Path(path) == self.attempt / 'fence.json':
                raise KeyboardInterrupt('after durable fence')
        with patch.object(self.driver_module, '_write', side_effect=crash):
            with self.assertRaises(KeyboardInterrupt):
                self.driver.execute('stop', payload)
        with self.assertRaisesRegex(self.driver_module.DriverError, 'fenced'):
            self.driver.execute('launch', self.payload)
        stopped = self.driver.execute('stop', payload)
        self.assertEqual(stopped['status'], 'never_started')
        self.assertEqual(self.driver.execute('stop', payload), stopped)

    def test_unstarted_answer_keeps_question_revision_and_requires_positive_predecessor_quiet(self):
        self.start('launch', self.payload)
        self.terminal(dict(kind='needs_input', text='choose', question='Which?'))
        question = self.driver.execute('inspect', self.request(operation_id='question'))
        descriptor = replace(self.descriptor, generation='second',
            unit=self.driver_module.generation_unit('owner', 'attempt', 'dispatch', 'second'),
            state_directory=str(self.attempt / 'generations' / 'second' / 'host'))
        answer = self.request(generation='second', operation_id='answer', previous_generation='first',
            question_id=question['question_id'], observation_revision=question['observation_revision'],
            answer='A', descriptor=descriptor.to_dict())
        self.preparation(answer, 'answer')
        after = self.driver.execute('inspect', self.request(operation_id='question-after-preparation'))
        self.assertEqual(after['observation_revision'], question['observation_revision'])
        self.assertEqual(after['question_id'], question['question_id'])
        stopped = self.driver.execute('stop', self.abandoned(answer, 'answer'))
        self.assertEqual(stopped['status'], 'never_started')
        self.assertEqual(stopped['attempt_observation']['current_generation'], 'first')
        self.assertEqual(stopped['attempt_observation']['basis'], 'predecessor_terminal')
        (Path(self.descriptor.state_directory) / 'terminal.json').unlink()
        self.assertEqual(self.driver.execute('inspect', {**self.request(generation='second', operation_id='no-predecessor-proof'),
            'preparation_hash':answer['preparation_hash']})['status'], 'uncertain')

    def test_bound_inspection_and_stop_require_epoch(self):
        self.preparation()
        for action in ('inspect', 'stop'):
            request = self.request(operation_id='without-epoch-' + action)
            request.pop('claim_epoch')
            with self.subTest(action=action), self.assertRaisesRegex(self.driver_module.DriverError, 'epoch'):
                self.driver.execute(action, request)

    def test_fence_from_earlier_stop_does_not_hide_later_unstarted_receipt(self):
        self.preparation()
        self.driver.execute('stop', self.request(operation_id='first-fence'))
        self.assertEqual(self.driver.execute('stop', self.abandoned())['status'], 'never_started')
        self.assertEqual(self.driver.execute('inspect', self.request(operation_id='fresh'))['status'], 'never_started')

    def test_armed_replay_does_not_recreate_deleted_generation_files(self):
        from unittest.mock import patch
        self.preparation()
        with patch.object(self.op, 'launch', side_effect=KeyboardInterrupt('armed')):
            with self.assertRaises(KeyboardInterrupt):
                self.driver.execute('launch', self.payload)
        shutil.rmtree(self.attempt / 'generations' / 'first')
        response = self.driver.execute('launch', self.payload)
        self.assertEqual(response['status'], 'uncertain')
        self.assertFalse((self.attempt / 'generations' / 'first').exists())

    def test_preparation_crash_intervals_replay_exact_witness_without_launch(self):
        from unittest.mock import patch
        for stage in ('claim', 'preparation-intent', 'ledger', 'response'):
            with self.subTest(stage=stage):
                fixture = type(self)('runTest')
                fixture.setUp()
                original = fixture.driver_module._write
                crashed = []
                def crash(path, value):
                    original(path, value)
                    matches = ((stage == 'claim' and Path(path).name == 'claim.json' and not value['generations'])
                        or (stage == 'ledger' and Path(path).name == 'claim.json' and value['generations'])
                        or (stage == 'preparation-intent' and Path(path).name == 'prepare-launch.json' and 'response' not in value)
                        or (stage == 'response' and Path(path).name == 'prepare-launch.json' and 'response' in value))
                    if matches and not crashed:
                        crashed.append(True)
                        raise KeyboardInterrupt(stage)
                try:
                    with patch.object(fixture.driver_module, '_write', side_effect=crash):
                        with self.assertRaises(KeyboardInterrupt):
                            fixture.preparation()
                    if stage == 'preparation-intent':
                        with self.assertRaisesRegex(fixture.driver_module.DriverError, 'ledger'):
                            fixture.preparation()
                        self.assertFalse(fixture.calls)
                        self.assertEqual(json.loads((fixture.attempt / 'claim.json').read_text())['generations'], {})
                        continue
                    prepared = fixture.preparation()
                    self.assertEqual(prepared['status'], 'prepared')
                    self.assertEqual(fixture.preparation(), prepared)
                    self.assertFalse(fixture.calls)
                    self.assertFalse((fixture.attempt / 'state.json').exists())
                finally:
                    fixture.doCleanups()

    def test_claim_loss_with_surviving_generation_files_never_migrates_start_authority(self):
        self.fail_launch = True
        self.start('launch', self.payload)
        (self.attempt / 'claim.json').unlink()
        self.assertTrue((self.attempt / 'generations' / 'first' / 'generation.json').exists())
        with self.assertRaisesRegex(self.driver_module.DriverError, 'claim'):
            self.driver.execute('stop', self.abandoned())
        self.assertFalse((self.attempt / 'claim.json').exists())

    def test_reinitialized_prebinding_cache_cannot_ignore_surviving_exact_unit(self):
        self.fail_launch = True
        self.start('launch', self.payload)
        old_epoch = self.payload['claim_epoch']
        shutil.rmtree(self.cache)
        self.payload.pop('claim_epoch')
        self.payload.pop('preparation_hash')
        self.preparation()
        self.assertNotEqual(self.payload['claim_epoch'], old_epoch)
        payload = self.abandoned()
        self.driver.run = lambda argv: subprocess.CompletedProcess(argv, 0,
            'Description=AIOS owned ' + self.descriptor.digest + '\nLoadState=loaded\nActiveState=active\nInvocationID=' + self.invocation + '\n', '')
        self.assertEqual(self.driver.execute('stop', payload)['status'], 'uncertain')
        self.assertFalse((self.attempt / 'generations' / 'first' / 'unstarted.json').exists())

    def test_legacy_claim_remains_inspectable_and_stoppable_but_cannot_prepare_or_start(self):
        self.start('launch', self.payload)
        claim_path = self.attempt / 'claim.json'
        claim = json.loads(claim_path.read_text())
        claim.pop('claim_epoch')
        claim.pop('generations')
        self.driver_module._write(claim_path, claim)
        legacy = {key:value for key,value in self.payload.items() if key not in ('claim_epoch', 'preparation_hash')}
        request = {key:value for key,value in self.request(operation_id='legacy-inspect').items() if key not in ('claim_epoch', 'preparation_hash')}
        self.assertEqual(self.driver.execute('inspect', request)['status'], 'running')
        with self.assertRaisesRegex(self.driver_module.DriverError, 'epoch'):
            self.driver.execute('launch', {**legacy, 'operation_id':'legacy-launch'})
        self.payload = legacy
        with self.assertRaisesRegex(self.driver_module.DriverError, 'legacy'):
            self.preparation(operation_id='legacy-prepare')
        stopped = self.driver.execute('stop', {**request, 'operation_id':'legacy-stop', 'invocation_id':self.invocation})
        self.assertTrue(stopped['fenced'])
        self.assertEqual(sum('stop' in call for call in self.calls), 1)

    def test_fresh_unstarted_inspection_revalidates_each_immutable_record(self):
        for changed in ('receipt', 'fence', 'preparation', 'ledger', 'marker'):
            with self.subTest(changed=changed):
                fixture = type(self)('runTest')
                fixture.setUp()
                try:
                    fixture.preparation()
                    fixture.driver.execute('stop', fixture.abandoned())
                    if changed == 'receipt':
                        path = fixture.attempt / 'generations' / 'first' / 'unstarted.json'
                        value = json.loads(path.read_text())
                        value['session_id'] = 'other'
                    elif changed == 'fence':
                        path = fixture.attempt / 'fence.json'
                        value = {'operation_id':'missing-stop', 'generation':'first'}
                    elif changed == 'preparation':
                        path = fixture.attempt / 'operations' / 'prepare-launch.json'
                        value = json.loads(path.read_text())
                        value['response']['preparation_witness']['claim_epoch'] = 'b' * 32
                    elif changed == 'ledger':
                        path = fixture.attempt / 'claim.json'
                        value = json.loads(path.read_text())
                        value['generations']['first']['phase'] = 'armed'
                    else:
                        directory = Path(fixture.descriptor.state_directory)
                        directory.mkdir(mode=0o700)
                        (directory / 'launch-intent').write_text('malformed')
                        path = None
                    if path:
                        fixture.driver_module._write(path, value)
                    self.assertEqual(fixture.driver.execute('inspect', fixture.request(operation_id='fresh'))['status'], 'uncertain')
                finally:
                    fixture.doCleanups()

    def test_target_head_unstarted_answer_still_requires_quiet_predecessor(self):
        self.start('launch', self.payload)
        self.terminal(dict(kind='needs_input', text='choose', question='Which?'))
        question = self.driver.execute('inspect', self.request(operation_id='question'))
        descriptor = replace(self.descriptor, generation='second',
            unit=self.driver_module.generation_unit('owner', 'attempt', 'dispatch', 'second'),
            state_directory=str(self.attempt / 'generations' / 'second' / 'host'))
        answer = self.request(generation='second', operation_id='answer', previous_generation='first',
            question_id=question['question_id'], observation_revision=question['observation_revision'],
            answer='A', descriptor=descriptor.to_dict())
        self.interrupt_start('state', action='answer', payload=answer)
        stopped = self.driver.execute('stop', self.abandoned(answer, 'answer'))
        self.assertEqual(stopped['status'], 'never_started')
        self.assertEqual(stopped['attempt_observation']['current_generation'], 'second')
        self.assertEqual(stopped['attempt_observation']['basis'], 'predecessor_terminal')
        (Path(self.descriptor.state_directory) / 'terminal.json').unlink()
        self.assertEqual(self.driver.execute('inspect', {**self.request(generation='second', operation_id='fresh'),
            'preparation_hash':answer['preparation_hash']})['status'], 'uncertain')

    def test_root_replacement_during_preparation_prevents_launch(self):
        from unittest.mock import patch
        self.preparation()
        original = self.op.prepare
        def replace_root(descriptor):
            result = original(descriptor)
            self.attempt.rename(self.attempt.with_name('old-attempt'))
            self.attempt.mkdir(mode=0o700)
            (self.attempt / 'lock').touch(mode=0o600)
            return result
        with patch.object(self.op, 'prepare', side_effect=replace_root):
            with self.assertRaisesRegex(self.driver_module.DriverError, 'root identity'):
                self.driver.execute('launch', self.payload)
        self.assertFalse(any('systemd-run' in Path(call[0]).name for call in self.calls))

    def test_completed_stop_intent_remains_permanent_when_fence_file_is_deleted(self):
        self.preparation()
        self.driver.execute('stop', self.request(operation_id='stop'))
        (self.attempt / 'fence.json').unlink()
        with self.assertRaisesRegex(self.driver_module.DriverError, 'fenced'):
            self.driver.execute('launch', self.payload)
        self.assertTrue((self.attempt / 'fence.json').exists())
        self.assertFalse(any('systemd-run' in Path(call[0]).name for call in self.calls))

    def test_fresh_unstarted_inspection_rejects_fence_generation_conflict(self):
        self.preparation()
        self.driver.execute('stop', self.abandoned())
        path = self.attempt / 'fence.json'
        value = json.loads(path.read_text())
        value['generation'] = 'other'
        self.driver_module._write(path, value)
        self.assertEqual(self.driver.execute('inspect', self.request(operation_id='fresh'))['status'], 'uncertain')

    def test_preparation_replay_after_fence_retains_only_historical_identity(self):
        prepared = self.preparation()
        self.driver.execute('stop', self.abandoned())
        self.assertEqual(self.preparation(), prepared)
        with self.assertRaisesRegex(self.driver_module.DriverError, 'fenced'):
            self.driver.execute('launch', self.payload)
        self.assertFalse(any('systemd-run' in Path(call[0]).name for call in self.calls))

    def test_absent_unit_accepts_systemd_default_exact_unit_description(self):
        self.preparation()
        payload = self.abandoned()
        self.driver.run = lambda argv: subprocess.CompletedProcess(argv, 0,
            'Description=' + self.descriptor.unit + '\nLoadState=not-found\nActiveState=inactive\nInvocationID=\n', '')
        self.assertEqual(self.driver.execute('stop', payload)['status'], 'never_started')
        self.assertEqual(self.driver.execute('inspect', self.request(operation_id='fresh'))['status'], 'never_started')

    def test_absent_unit_with_foreign_description_remains_uncertain(self):
        self.preparation()
        payload = self.abandoned()
        self.driver.run = lambda argv: subprocess.CompletedProcess(argv, 0,
            'Description=foreign.service\nLoadState=not-found\nActiveState=inactive\nInvocationID=\n', '')
        self.assertEqual(self.driver.execute('stop', payload)['status'], 'uncertain')

    def next_payload(self, generation, operation_id, **changes):
        descriptor = replace(self.descriptor, generation=generation,
            unit=self.driver_module.generation_unit('owner', 'attempt', 'dispatch', generation),
            state_directory=str(self.attempt / 'generations' / generation / 'host'))
        return {**self.request(generation=generation, operation_id=operation_id),
                'descriptor':descriptor.to_dict(), **changes}

    def test_lost_head_cannot_authorize_another_initial_launch_preparation(self):
        self.start('launch', self.payload)
        (self.attempt / 'state.json').unlink()
        payload = self.next_payload('different', 'other-launch')
        with self.assertRaisesRegex(self.driver_module.DriverError, 'initial|history'):
            self.preparation(payload)
        self.assertEqual(sum('systemd-run' in Path(call[0]).name for call in self.calls), 1)

    def test_legacy_prepared_initial_cannot_hide_armed_writer_after_head_loss(self):
        self.start('launch', self.payload)
        (self.attempt / 'state.json').unlink()
        payload = self.next_payload('different', 'other-launch')
        # Restore the second initial preparation formerly accepted by this protocol.
        base = self.driver._base(payload)
        descriptor = self.op.ProcessDescriptor.from_dict(base['descriptor'])
        entry = dict(preparation_hash=self.driver_module._hash({'action':'launch', 'payload':base}),
            start_action='launch', start_operation_id=base['operation_id'], descriptor_hash=descriptor.digest,
            profile_hash=descriptor.profile.digest, session_id=base['session_id'], payload=base, phase='prepared')
        claim_path = self.attempt / 'claim.json'
        claim = json.loads(claim_path.read_text())
        claim['generations']['different'] = entry
        self.driver_module._write(claim_path, claim)
        request = self.request(generation='different', operation_id='prepare-other-launch',
            prepare_start={'action':'launch', 'payload':base})
        request.pop('preparation_hash')
        self.driver_module._write(self.attempt / 'operations' / 'prepare-other-launch.json',
            {'action':'inspect', 'payload':request, 'payload_hash':self.driver._operation_hash('inspect', request)})
        payload.update(preparation_hash=entry['preparation_hash'])
        stop = self.abandoned(payload)
        def boundary(argv):
            if descriptor.unit in argv:
                return subprocess.CompletedProcess(argv, 0,
                    'LoadState=not-found\nActiveState=inactive\nInvocationID=\nDescription=' + descriptor.unit + '\n', '')
            return self.boundary(argv)
        self.missing_unit = False
        self.driver.run = boundary
        response = self.driver.execute('stop', stop)
        self.assertEqual(response['status'], 'uncertain')
        self.assertNotIn('attempt_observation', response)

    def test_unstarted_answer_revalidates_older_armed_generations_beyond_predecessor(self):
        self.start('launch', self.payload)
        self.terminal(dict(kind='needs_input', text='choose', question='First?'))
        first_terminal = Path(self.descriptor.state_directory) / 'terminal.json'
        question = self.driver.execute('inspect', self.request(operation_id='question-first'))
        second = self.next_payload('second', 'answer-second', previous_generation='first',
            question_id=question['question_id'], observation_revision=question['observation_revision'], answer='A')
        self.start('answer', second)
        self.descriptor = self.op.ProcessDescriptor.from_dict(second['descriptor'])
        self.terminal(dict(kind='needs_input', text='choose', question='Second?'))
        question = self.driver.execute('inspect', self.request(generation='second', operation_id='question-second'))
        third = self.next_payload('third', 'answer-third', previous_generation='second',
            question_id=question['question_id'], observation_revision=question['observation_revision'], answer='B')
        self.preparation(third, 'answer')
        self.assertEqual(self.driver.execute('stop', self.abandoned(third, 'answer'))['status'], 'never_started')
        first_terminal.unlink()
        third_unit = third['descriptor']['unit']
        self.missing_unit = False
        def boundary(argv):
            if third_unit in argv:
                return subprocess.CompletedProcess(argv, 0,
                    'LoadState=not-found\nActiveState=inactive\nInvocationID=\nDescription=' + third_unit + '\n', '')
            return self.boundary(argv)
        self.driver.run = boundary
        fresh = self.driver.execute('inspect', {**self.request(generation='third', operation_id='fresh-third'),
            'preparation_hash':third['preparation_hash']})
        self.assertEqual(fresh['status'], 'uncertain')
        self.assertTrue(any(self.payload['descriptor']['unit'] in call for call in self.calls))

    def test_initial_launch_preparation_rejects_persisted_head_without_ledger_history(self):
        self.preparation()
        claim_path = self.attempt / 'claim.json'
        claim = json.loads(claim_path.read_text())
        claim['generations'] = {}
        self.driver_module._write(claim_path, claim)
        self.driver_module._write(self.attempt / 'state.json', {'current_generation':'unaccounted'})
        with self.assertRaisesRegex(self.driver_module.DriverError, 'initial|history'):
            self.preparation(self.next_payload('different', 'other-launch'))

    def test_existing_prepared_initial_cannot_start_beside_armed_history(self):
        self.start('launch', self.payload)
        (self.attempt / 'state.json').unlink()
        payload = self.next_payload('different', 'other-launch')
        entry = self.driver._preparation_entry(self.attempt, 'launch', payload)
        claim_path = self.attempt / 'claim.json'
        claim = json.loads(claim_path.read_text())
        claim['generations']['different'] = {**entry, 'phase':'prepared'}
        self.driver_module._write(claim_path, claim)
        payload.update(preparation_hash=entry['preparation_hash'])
        with self.assertRaisesRegex(self.driver_module.DriverError, 'initial|history'):
            self.driver.execute('launch', payload)
        self.assertEqual(sum('systemd-run' in Path(call[0]).name for call in self.calls), 1)

    def test_preparation_replay_cannot_recreate_a_lost_generation_ledger_entry(self):
        self.preparation()
        claim_path = self.attempt / 'claim.json'
        claim = json.loads(claim_path.read_text())
        del claim['generations']['first']
        self.driver_module._write(claim_path, claim)
        with self.assertRaisesRegex(self.driver_module.DriverError, 'preparation|ledger'):
            self.preparation()
        self.assertEqual(json.loads(claim_path.read_text())['generations'], {})
        self.assertFalse(self.calls)

    def test_unicode_preparation_hash_matches_the_service_protocol(self):
        import hashlib
        def encode(value):
            return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'), allow_nan=False)
        self.descriptor = replace(self.descriptor, argv=(*self.descriptor.argv, 'réparer 日本語 🚀'))
        self.payload['descriptor'] = self.descriptor.to_dict()
        base = json.loads(json.dumps(self.payload))
        prepared = self.preparation()
        expected = hashlib.sha256(encode({'action':'launch', 'payload':base}).encode()).hexdigest()
        self.assertEqual(prepared['preparation_witness']['preparation_hash'], expected)
        self.interrupt_start('prepared')
        self.missing_unit = True
        stopped = self.driver.execute('stop', self.abandoned())
        self.assertEqual(stopped['status'], 'never_started')

    def cli(self, *flags):
        return subprocess.run([__import__('sys').executable, str(ENTRY), '--fleet-socket', str(self.root / 'fleet.sock'),
            *flags, 'inspect'], input=json.dumps(self.request(operation_id='state-cli')),
            capture_output=True, text=True, timeout=5)

    def test_fleet_state_replaces_the_cache_as_the_owned_root(self):
        self.start('launch', self.payload)
        self.terminal(dict(kind='completed', text='from state'))
        empty = self.root / 'empty'
        empty.mkdir(mode=0o700)
        missing = self.cli('--fleet-cache', str(self.cache), '--fleet-state', str(empty))
        self.assertEqual(missing.returncode, 1)
        self.assertIn('existing owned claim required', json.loads(missing.stdout)['error'])
        self.assertFalse((empty / 'owned').exists())
        found = self.cli('--fleet-cache', str(empty), '--fleet-state', str(self.cache))
        self.assertEqual(found.returncode, 0, found.stderr + found.stdout)
        self.assertEqual(json.loads(found.stdout)['result']['text'], 'from state')
        self.assertEqual(json.loads((self.attempt / 'claim.json').read_text())['fleet_cache'], str(self.cache))

    def test_retired_attempt_answers_inspect_without_aios(self):
        import os
        import stat
        import sys
        from backends.owned import retirement
        self.start('launch', self.payload)
        claim = json.loads((self.attempt / 'claim.json').read_text())
        record = dict(version=1, kind='owned', deletion_id='delete-1', purge_operation_id='purge-1',
            identity={key:claim[key] for key in ('owner_namespace', 'attempt_id', 'dispatch_id', 'claim_epoch')},
            processes=[dict(generation_or_run_id='first', unit=self.descriptor.unit, boot_id=self.op.boot_id(),
                invocation_id=self.invocation, cgroup='/owned', descriptor_hash=self.descriptor.digest,
                profile_hash=self.descriptor.profile.digest, preparation_hash=claim['generations']['first']['preparation_hash'],
                session_id='session', start_operation_id='launch', containment_operation_ids=[], never_started_proof_hash=None)],
            purge_manifest_hash='b' * 64)
        record['retirement_hash'] = retirement.digest(record)
        self.driver_module._write(self.attempt / 'retired.json', record)
        proc = self.root / 'proc'
        (proc / 'sys/kernel/random').mkdir(parents=True)
        (proc / 'sys/kernel/random/boot_id').write_text(self.op.boot_id() + '\n')
        systemctl = self.root / 'systemctl'
        systemctl.write_text('#!/bin/sh\nprintf "Id=%s\\nLoadState=loaded\\nActiveState=inactive\\nSubState=dead\\n'
            'InvocationID=%s\\nControlGroup=\\nDescription=AIOS owned %s\\nMainPID=0\\n"\n' % (
                self.descriptor.unit, self.invocation, self.descriptor.digest))
        systemctl.chmod(0o755)
        (self.root / 'cgroup').mkdir()
        driver = self.driver_module.OwnedDriver(str(self.root / 'fleet.sock'), str(self.cache),
            systemctl=str(systemctl), proc_root=str(proc), cgroup_root=str(self.root / 'cgroup'))
        response = driver.execute('inspect', self.request(operation_id='retired'))
        self.assertEqual(response['status'], 'quiescent')
        self.assertEqual(response['retirement']['retirement_hash'], record['retirement_hash'])
        self.assertEqual(response['retirement']['processes'][0]['reason'], 'fresh_retired_quiescence')
        self.assertNotIn('aios', sys.modules)
        with self.assertRaisesRegex(self.driver_module.DriverError, 'retired'):
            driver.execute('launch', self.payload)
        repository = Path(__file__).resolve().parents[3]
        probe = subprocess.run([sys.executable, '-c', 'import sys, backends.owned.driver, backends.owned.retirement\n'
            'assert not [m for m in sys.modules if m.split(".")[0] == "aios"]'],
            cwd=repository, env={key: value for key, value in os.environ.items() if key != 'PYTHONPATH'},
            capture_output=True, text=True, timeout=10)
        self.assertEqual(probe.returncode, 0, probe.stderr)
