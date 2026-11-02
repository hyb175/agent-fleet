from dataclasses import replace
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

from . import needs_sandbox, runtime_roots


class OwnedProcessTests(unittest.TestCase):
    def test_boundary_is_available(self):
        self.assertIsNotNone(importlib.util.find_spec('backends.owned.process'),
                             'owned process boundary must enforce filesystem and generation identity')

    def setUp(self):
        from backends.owned import process as op
        self.op = op
        self.tmp = tempfile.TemporaryDirectory(prefix='owned-process-')
        self.root = Path(self.tmp.name)
        self.owner = self.root / 'owner'
        self.owner.mkdir()
        self.git(self.owner, 'init', '-b', 'main')
        self.git(self.owner, 'config', 'user.name', 'Fixture')
        self.git(self.owner, 'config', 'user.email', 'fixture@example.invalid')
        (self.owner / 'tracked').write_text('before\n')
        self.git(self.owner, 'add', 'tracked')
        self.git(self.owner, '-c', 'commit.gpgSign=false', 'commit', '-m', 'initial')
        self.original = self.git(self.owner, 'rev-parse', 'HEAD')
        self.work = self.root / 'task'
        self.git(self.owner, 'worktree', 'add', '--detach', str(self.work), 'HEAD')
        self.common = self.owner / '.git'
        self.metadata = Path(self.git(self.work, 'rev-parse', '--absolute-git-dir'))
        import shutil
        self.shell = str(Path(shutil.which('bash')).resolve())
        self.git_bin = str(Path(shutil.which('git')).resolve().parent)
        self.profile = op.SandboxProfile(str(self.work), str(self.metadata), str(self.common),
            str(self.root / 'objects'), str(self.root / 'home'), str(self.root / 'tmp'), self.shell,
            runtime_roots(), search_path=(str(Path(self.shell).parent), self.git_bin))
        self.descriptor = op.ProcessDescriptor('fixture', 'aios-owned-fixture.service', op.boot_id(),
            self.profile, (self.shell, '-c', 'true'), str(self.root / 'state'), 20)

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, directory, *args):
        result = subprocess.run(['git', '-C', str(directory), *args], text=True, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_descriptor_is_private_immutable_and_excludes_worker_state(self):
        import stat
        op = self.op
        target = op.prepare(self.descriptor)
        self.assertEqual(op.load_descriptor(target), self.descriptor)
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
        self.assertEqual((target.parent / 'runner.py').read_text(), Path(op.__file__).read_text())
        self.assertEqual(op.prepare(self.descriptor), target)
        with self.assertRaisesRegex(op.ProcessError, 'conflict'):
            op.prepare(replace(self.descriptor, runtime_seconds=10))
        for writable in (self.profile.worktree, self.profile.home, self.profile.tmp):
            with self.assertRaisesRegex(op.ProcessError, 'outside'):
                replace(self.descriptor, state_directory=str(Path(writable) / 'state'))
        with self.assertRaisesRegex(op.ProcessError, 'runtime'):
            replace(self.profile, runtime_roots=('/',))
        with self.assertRaisesRegex(op.ProcessError, 'allowlisted'):
            replace(self.profile, environment=(('GITHUB_TOKEN', 'forbidden'),))
        with self.assertRaisesRegex(op.ProcessError, 'runtime roots'):
            replace(self.profile, search_path=(str(self.owner),))

    def test_missing_or_replaced_generation_never_proves_stop(self):
        from subprocess import CompletedProcess
        calls = []
        def boundary(argv):
            calls.append(argv)
            return CompletedProcess(argv, 0, 'LoadState=not-found\nActiveState=inactive\nInvocationID=\n', '')
        self.assertEqual(self.op.inspect(self.descriptor, run=boundary), {'status': 'uncertain'})
        self.assertEqual(self.op.stop(self.descriptor, 'a' * 32, run=boundary), {'status': 'uncertain'})
        self.assertFalse(any('stop' in call for call in calls))
        def replaced(argv):
            return CompletedProcess(argv, 0, 'LoadState=loaded\nActiveState=active\nInvocationID=' + 'b' * 32 + '\n', '')
        self.assertEqual(self.op.stop(self.descriptor, 'a' * 32, run=replaced), {'status': 'uncertain'})

    def test_lost_launch_is_never_automatically_repeated(self):
        calls = []
        def boundary(argv):
            calls.append(argv)
            if 'systemd-run' in Path(argv[0]).name:
                raise subprocess.TimeoutExpired(argv, 15)
            return subprocess.CompletedProcess(argv, 0, 'LoadState=not-found\n', '')
        self.assertEqual(self.op.launch(self.descriptor, run=boundary)['status'], 'uncertain')
        self.assertEqual(self.op.launch(self.descriptor, run=boundary)['status'], 'uncertain')
        self.assertEqual(sum('systemd-run' in Path(c[0]).name for c in calls), 1)

    def test_receipt_binds_exact_descriptor_and_invocation(self):
        import json
        op = self.op
        op.prepare(self.descriptor)
        value = {'descriptor_hash': self.descriptor.digest, 'boot_id': self.descriptor.boot_id,
                 'unit': self.descriptor.unit, 'invocation_id': 'a' * 32, 'quiescent': True}
        op._write_once(Path(self.descriptor.state_directory) / 'terminal.json', json.dumps(value))
        self.assertEqual(op.inspect(self.descriptor, 'a' * 32)['status'], 'quiescent')
        self.assertIsNone(op.receipt(self.descriptor, 'b' * 32))
        self.assertIsNone(op.receipt(replace(self.descriptor, runtime_seconds=19)))

    @needs_sandbox
    def test_bwrap_real_git_commit_and_readonly_owner_canaries(self):
        op = self.op
        op.prepare(self.descriptor)
        outside = self.root / 'outside'
        outside.write_text('owner secret')
        command = '''
set -eu
[ "${GITHUB_TOKEN-unset}" = unset ]
[ ! -e "OUTSIDE" ]
[ ! -e "STATE/descriptor.json" ]
printf 'after\\n' > tracked
git status --porcelain
git add tracked
git commit -m task
! printf bad > COMMON/refs/heads/main
! printf bad > COMMON/HEAD
! printf bad > COMMON/objects/canary
! printf bad > COMMON/config
printf 'OWNED_OK\\n'
'''.replace('OUTSIDE', str(outside)).replace('STATE', self.descriptor.state_directory).replace('COMMON', str(self.common))
        argv = op.bwrap_argv(self.profile, (self.shell, '-c', command), config_path=Path(self.descriptor.state_directory) / 'gitconfig')
        result = subprocess.run(argv, capture_output=True, text=True, timeout=10)
        if result.returncode and ('Operation not permitted' in result.stderr or 'Permission denied' in result.stderr) and 'bwrap:' in result.stderr:
            self.skipTest('host namespace policy disallows bubblewrap; separate host proof required: ' + result.stderr.strip())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('OWNED_OK', result.stdout)
        self.assertEqual(self.git(self.owner, 'rev-parse', 'HEAD'), self.original)
        self.assertEqual(outside.read_text(), 'owner secret')
        env = {**__import__('os').environ, **op.git_environment(self.profile)}
        commit = subprocess.run(['git', '-C', str(self.work), 'rev-parse', 'HEAD'], env=env, capture_output=True, text=True, timeout=5)
        self.assertEqual(commit.returncode, 0, commit.stderr)
        self.assertNotEqual(commit.stdout.strip(), self.original)
        self.assertFalse((self.common / 'objects' / commit.stdout[:2] / commit.stdout.strip()[2:]).exists())
        self.assertTrue((Path(self.profile.private_objects) / commit.stdout[:2] / commit.stdout.strip()[2:]).exists())

    def test_writable_mount_cannot_expose_owner_home_or_common_objects(self):
        import os
        with self.assertRaisesRegex(self.op.ProcessError, 'owner|broad'):
            replace(self.profile, home=os.path.expanduser('~'))
        with self.assertRaisesRegex(self.op.ProcessError, 'common'):
            replace(self.profile, private_objects=str(self.common / 'objects'))

    @unittest.skipUnless(__import__('os').environ.get('AIOS_OWNED_HOST_TEST') == '1', 'opt-in harmless user-systemd proof')
    def test_host_generation_stop_kills_descendants_and_retains_receipt(self):
        import time
        import uuid
        op = self.op
        unit = 'aios-owned-fixture-' + uuid.uuid4().hex + '.service'
        child = '(while :; do printf tick >> heartbeat; done) & wait'
        descriptor = replace(self.descriptor, unit=unit, argv=(self.shell, '-c', child))
        observation = op.launch(descriptor)
        try:
            for _ in range(100):
                if (self.work / 'heartbeat').exists():
                    break
                time.sleep(.02)
            self.assertEqual(observation['status'], 'running', observation)
            self.assertTrue((self.work / 'heartbeat').exists())
            stopped = op.stop(descriptor, observation['invocation_id'])
            self.assertEqual(stopped['status'], 'quiescent', stopped)
            self.assertEqual(stopped['receipt']['invocation_id'], observation['invocation_id'])
            self.assertEqual(stopped['receipt']['timing_status'], 'measured')
            self.assertGreater(stopped['receipt']['elapsed_seconds'], 0)
            self.assertGreaterEqual(stopped['receipt']['ended_monotonic_ns'], stopped['receipt']['started_monotonic_ns'])
            size = (self.work / 'heartbeat').stat().st_size
            time.sleep(.1)
            self.assertEqual((self.work / 'heartbeat').stat().st_size, size)
            late = op.inspect(descriptor, observation['invocation_id'])
            self.assertEqual(late['status'], 'quiescent')
            self.assertEqual(late['receipt'], stopped['receipt'])
        finally:
            subprocess.run(['systemctl', '--user', 'stop', unit], capture_output=True, timeout=15)

    @unittest.skipUnless(__import__('os').environ.get('AIOS_OWNED_HOST_TEST') == '1', 'opt-in harmless user-systemd proof')
    def test_host_runtime_limit_retains_exact_receipt_after_collection(self):
        import time
        import uuid
        op = self.op
        descriptor = replace(self.descriptor, unit='aios-owned-fixture-' + uuid.uuid4().hex + '.service',
            runtime_seconds=1, argv=(self.shell, '-c', "printf '%s' '$HOME' > literal; while :; do :; done"))
        first = op.launch(descriptor)
        try:
            self.assertEqual(first['status'], 'running', first)
            for _ in range(200):
                observation = op.inspect(descriptor, first['invocation_id'])
                if observation['status'] == 'quiescent':
                    break
                time.sleep(.02)
            self.assertEqual(observation['status'], 'quiescent', observation)
            self.assertEqual(observation['receipt']['service_result'], 'timeout')
            self.assertEqual(observation['receipt']['timing_status'], 'measured')
            self.assertGreater(observation['receipt']['elapsed_seconds'], 0)
            self.assertGreaterEqual(observation['receipt']['ended_monotonic_ns'], observation['receipt']['started_monotonic_ns'])
            self.assertEqual((self.work / 'literal').read_text(), '$HOME')
            self.assertEqual(op.receipt(descriptor, first['invocation_id']), observation['receipt'])
        finally:
            subprocess.run(['systemctl', '--user', 'stop', descriptor.unit], capture_output=True, timeout=15)

    @needs_sandbox
    def test_exact_provider_executable_read_bind_runs_without_owner_home(self):
        executable = '/opt/provider/fixture-shell'
        profile = replace(self.profile, executable=executable,
                          read_binds=((self.shell, executable),))
        descriptor = replace(self.descriptor, profile=profile, argv=(executable, '-c', 'printf provider-ok'))
        self.op.prepare(descriptor)
        command = self.op.bwrap_argv(profile, descriptor.argv,
                                    config_path=Path(descriptor.state_directory) / 'gitconfig')
        result = subprocess.run(command, capture_output=True, text=True, timeout=5)
        if result.returncode and 'bwrap:' in result.stderr and 'Operation not permitted' in result.stderr:
            self.skipTest('host namespace policy disallows bubblewrap')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'provider-ok')

    def test_attached_task_head_is_rejected_before_launch(self):
        (self.metadata / 'HEAD').write_text('ref: refs/heads/main\n')
        with self.assertRaisesRegex(self.op.ProcessError, 'detached'):
            self.op.prepare(self.descriptor)
        self.assertFalse((Path(self.descriptor.state_directory) / 'launch-intent').exists())

    @needs_sandbox
    def test_exact_nix_runtime_aliases_support_env_and_shell(self):
        import shutil
        env_binary = str(Path(shutil.which('env')).resolve())
        profile = replace(self.profile, executable='/usr/bin/env',
            read_binds=((env_binary, '/usr/bin/env'), (self.shell, '/bin/bash'), (self.shell, '/bin/sh')))
        descriptor = replace(self.descriptor, profile=profile,
                             argv=('/usr/bin/env', '/bin/bash', '-c', 'printf aliases-ok'))
        self.op.prepare(descriptor)
        result = subprocess.run(self.op.bwrap_argv(profile, descriptor.argv,
            config_path=Path(descriptor.state_directory) / 'gitconfig'), capture_output=True, text=True, timeout=5)
        if result.returncode and 'bwrap:' in result.stderr and 'Operation not permitted' in result.stderr:
            self.skipTest('host namespace policy disallows bubblewrap')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'aliases-ok')

    @needs_sandbox
    def test_common_and_sibling_worktree_configuration_is_not_exposed(self):
        sibling = self.root / 'sibling'
        self.git(self.owner, 'worktree', 'add', '--detach', str(sibling), 'HEAD')
        self.git(self.owner, 'config', 'extensions.worktreeConfig', 'true')
        secret = 'synthetic-fixture-credential'
        self.git(self.owner, 'config', '--worktree', 'http.extraHeader', secret)
        self.git(sibling, 'config', '--worktree', 'http.extraHeader', secret)
        sibling_git = self.git(sibling, 'rev-parse', '--absolute-git-dir')
        self.op.prepare(self.descriptor)
        command = '\n'.join(['set -eu',
            '[[ "$(< ' + str(self.common / 'config.worktree') + ')" == "$(< ' + str(self.common / 'config') + ')" ]]',
            '[ ! -e ' + sibling_git + '/config.worktree ]',
            'for hook in ' + str(self.common / 'hooks') + '/*; do [ ! -e "$hook" ]; done',
            '! git config --get http.extraHeader',
            "printf safe > tracked", 'git add tracked', 'git commit -m private'])
        result = subprocess.run(self.op.bwrap_argv(self.profile, (self.shell, '-c', command),
            config_path=Path(self.descriptor.state_directory) / 'gitconfig'), capture_output=True, text=True, timeout=10)
        self.assertNotIn(secret, result.stdout + result.stderr)
        self.assertEqual(result.returncode, 0, 'common or sibling configuration remained visible, or private Git failed')

    def test_prepare_resumes_every_interrupted_artifact_and_keeps_original_snapshot(self):
        from unittest.mock import patch
        op = self.op
        original = op._write_once
        for cut in range(1, 9):
            descriptor = replace(self.descriptor, state_directory=str(self.root / ('state-' + str(cut))))
            writes = []
            def interrupt(path, value):
                writes.append(Path(path).name)
                if len(writes) == cut:
                    raise OSError('injected preparation interruption')
                return original(path, value)
            with patch.object(op, '_write_once', interrupt):
                try:
                    op.prepare(descriptor)
                except OSError:
                    pass
            original_source = Path(op.__file__).read_text()
            newer = self.root / 'newer-module.py'
            newer.write_text('new source must not replace an old snapshot')
            if (Path(descriptor.state_directory) / 'prepare-intent.json').exists():
                with patch.object(op, '__file__', str(newer)):
                    target = op.prepare(descriptor)
                self.assertEqual((target.parent / 'runner.py').read_text(), original_source)
            else:
                target = op.prepare(descriptor)
            self.assertEqual(op.load_descriptor(target), descriptor)
            self.assertTrue((target.parent / 'ready.json').is_file())
            snapshot = (target.parent / 'runner.py').read_text()
            with patch.object(op, '__file__', str(newer)):
                op.prepare(descriptor)
            self.assertEqual((target.parent / 'runner.py').read_text(), snapshot)
            original(target.parent / 'launch-intent', descriptor.digest)
            (target.parent / 'stdout').write_bytes(b'retained worker output\xff')
            op.prepare(descriptor)
            self.assertEqual((target.parent / 'stdout').read_bytes(), b'retained worker output\xff')

    def test_wrong_unit_description_is_not_adopted_or_stopped(self):
        calls = []
        def boundary(argv):
            calls.append(argv)
            return subprocess.CompletedProcess(argv, 0,
                'LoadState=loaded\nActiveState=active\nInvocationID=' + 'a' * 32 + '\nDescription=unrelated unit\n', '')
        self.assertEqual(self.op.inspect(self.descriptor, run=boundary)['status'], 'uncertain')
        self.assertEqual(self.op.stop(self.descriptor, 'a' * 32, run=boundary)['status'], 'uncertain')
        self.assertFalse(any('stop' in command for command in calls))

    def test_changed_runner_is_rejected_without_replacement(self):
        self.op.prepare(self.descriptor)
        runner = Path(self.descriptor.state_directory) / 'runner.py'
        runner.write_text('changed snapshot')
        with self.assertRaisesRegex(self.op.ProcessError, 'artifact changed'):
            self.op.prepare(self.descriptor)
        self.assertEqual(runner.read_text(), 'changed snapshot')

    def test_new_provider_update_controls_are_explicitly_allowlisted(self):
        controls = (('DISABLE_AUTOUPDATER', '1'), ('CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL', '1'))
        profile = replace(self.profile, environment=controls)
        self.assertEqual(profile.environment, controls)

    @needs_sandbox
    def test_exact_nix_elf_loader_alias_is_available_without_host_runtime(self):
        import os
        loader = str(Path(os.environ.get('NIX_LD', '/lib64/ld-linux-x86-64.so.2')).resolve())
        profile = replace(self.profile, read_binds=((loader, '/lib64/ld-linux-x86-64.so.2'),))
        descriptor = replace(self.descriptor, profile=profile,
            argv=(self.shell, '-c', 'test -x /lib64/ld-linux-x86-64.so.2 && test ! -e /run/current-system && printf loader-ok'))
        self.op.prepare(descriptor)
        result = subprocess.run(self.op.bwrap_argv(profile, descriptor.argv,
            config_path=Path(descriptor.state_directory) / 'gitconfig'), capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'loader-ok')

    @needs_sandbox
    def test_native_sandbox_can_protect_an_empty_hooks_directory(self):
        (self.common / 'hooks' / 'owner-hook-secret').write_text('synthetic-only')
        script = 'set -eu; test -d COMMON/hooks; for file in COMMON/hooks/*; do test ! -e "$file"; done; test ! -w COMMON/hooks; printf empty-hooks-ok'
        descriptor = replace(self.descriptor, argv=(self.shell, '-c', script.replace('COMMON', str(self.common))))
        self.op.prepare(descriptor)
        result = subprocess.run(self.op.bwrap_argv(self.profile, descriptor.argv,
            config_path=Path(descriptor.state_directory) / 'gitconfig'), capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'empty-hooks-ok')

    @needs_sandbox
    def test_native_git_config_protection_targets_are_controlled_and_readonly(self):
        self.op.prepare(self.descriptor)
        script = 'set -eu; test -f COMMON/config.lock; test -f COMMON/config.worktree; test ! -w COMMON/config.lock; test ! -w COMMON/config.worktree; printf targets-ok'
        command = self.op.bwrap_argv(self.profile, (self.shell, '-c', script.replace('COMMON', str(self.common))),
            config_path=Path(self.descriptor.state_directory) / 'gitconfig')
        result = subprocess.run(command, capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'targets-ok')

    def test_unit_exec_starts_through_sealed_host_runner(self):
        path = self.op.prepare(self.descriptor)
        arguments = self.op.unit_argv(self.descriptor, path)
        executable = arguments[arguments.index('--') + 1:]
        self.assertEqual(executable[:3], [str(Path(__import__('sys').executable).resolve()),
            str(path.parent / 'runner.py'), 'start'])
        self.assertEqual(executable[3:], [str(path)])
        self.assertIn('--property=TimeoutStopSec=10', arguments)

    def test_legacy_receipt_is_explicitly_unmeasured(self):
        import json
        self.op.prepare(self.descriptor)
        value = dict(descriptor_hash=self.descriptor.digest, generation=self.descriptor.generation,
            unit=self.descriptor.unit, boot_id=self.descriptor.boot_id, invocation_id='a' * 32, quiescent=True)
        self.op._write_once(Path(self.descriptor.state_directory) / 'terminal.json', json.dumps(value))
        self.assertEqual(self.op.receipt(self.descriptor).get('timing_status'), 'unmeasured')
        self.assertNotIn('elapsed_seconds', self.op.receipt(self.descriptor))

    def execute_start(self, descriptor=None, invocation='a' * 32, *, execvpe):
        self.assertTrue(callable(getattr(self.op, '_exec_worker', None)),
                        'trusted start must persist its clock before exec and refuse a second execution')
        return self.op._exec_worker(descriptor or self.descriptor, invocation, execvpe=execvpe)

    def test_start_write_failure_prevents_worker_exec(self):
        self.op.prepare(self.descriptor)
        calls = []
        state = Path(self.descriptor.state_directory)
        state.chmod(0o500)
        try:
            with self.assertRaises(OSError):
                self.execute_start(execvpe=lambda *args: calls.append(args))
            self.assertFalse(calls)
            self.assertFalse((state / 'start.json').exists())
        finally:
            state.chmod(0o700)

    def test_start_is_private_bound_and_duplicate_never_executes(self):
        import json
        import os
        import stat
        self.op.prepare(self.descriptor)
        calls = []
        def execute(file, argv, environment):
            path = Path(self.descriptor.state_directory) / 'start.json'
            value = json.loads(path.read_text())
            self.assertEqual(value['descriptor_hash'], self.descriptor.digest)
            self.assertEqual(value['generation'], self.descriptor.generation)
            self.assertEqual(value['unit'], self.descriptor.unit)
            self.assertEqual(value['boot_id'], self.descriptor.boot_id)
            self.assertEqual(value['invocation_id'], 'a' * 32)
            self.assertIs(type(value['started_monotonic_ns']), int)
            self.assertGreater(value['started_monotonic_ns'], 0)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
            self.assertEqual(path.stat().st_uid, os.getuid())
            self.assertEqual(argv, self.op.bwrap_argv(self.profile, self.descriptor.argv,
                config_path=path.parent / 'gitconfig'))
            self.assertEqual(file, argv[0])
            self.assertIn('--clearenv', argv)
            calls.append(argv)
        self.execute_start(execvpe=execute)
        with self.assertRaises(FileExistsError):
            self.execute_start(execvpe=execute)
        self.assertEqual(len(calls), 1)

    def test_interrupted_start_is_not_automatically_reexecuted(self):
        self.op.prepare(self.descriptor)
        calls = []
        def interrupted(*arguments):
            calls.append(arguments)
            raise OSError('fixture interruption before exec')
        with self.assertRaisesRegex(OSError, 'interruption'):
            self.execute_start(execvpe=interrupted)
        with self.assertRaises(FileExistsError):
            self.execute_start(execvpe=lambda *args: calls.append(args))
        self.assertEqual(len(calls), 1)
        self.op._write_once(Path(self.descriptor.state_directory) / 'launch-intent', self.descriptor.digest)
        external_calls = []
        def boundary(argv):
            external_calls.append(argv)
            return subprocess.CompletedProcess(argv, 0, 'LoadState=not-found\n', '')
        observed = self.op.launch(self.descriptor, run=boundary)
        self.assertEqual(observed['status'], 'uncertain')
        self.assertFalse(any('systemd-run' in Path(argv[0]).name for argv in external_calls))

    def test_start_rejects_boot_invocation_and_cgroup_mismatches(self):
        from unittest.mock import patch
        self.assertTrue(callable(getattr(self.op, 'start', None)), 'sealed runner requires a trusted start callback')
        path = self.op.prepare(self.descriptor)
        calls = []
        with patch.dict('os.environ', {'INVOCATION_ID':''}):
            with self.assertRaisesRegex(self.op.ProcessError, 'identity'):
                self.op.start(path, execvpe=lambda *args: calls.append(args))
        old = replace(self.descriptor, boot_id='00000000-0000-0000-0000-000000000000',
            state_directory=str(self.root / 'old-boot-state'))
        old_path = self.op.prepare(old)
        with patch.dict('os.environ', {'INVOCATION_ID':'a' * 32}):
            with self.assertRaisesRegex(self.op.ProcessError, 'identity'):
                self.op.start(old_path, execvpe=lambda *args: calls.append(args))
            with self.assertRaisesRegex(self.op.ProcessError, 'cgroup'):
                self.op.start(path, execvpe=lambda *args: calls.append(args))
        self.assertFalse(calls)
        self.assertFalse((path.parent / 'start.json').exists())

    def timed_receipt(self, *, descriptor=None, start=1000000000, end=2250000000):
        import json
        descriptor = descriptor or self.descriptor
        state = Path(self.op.prepare(descriptor)).parent
        identity = dict(descriptor_hash=descriptor.digest, generation=descriptor.generation,
            unit=descriptor.unit, boot_id=descriptor.boot_id, invocation_id='a' * 32)
        self.op._write_once(state / 'start.json', json.dumps({**identity, 'started_monotonic_ns':start}))
        value = {**identity, 'started_monotonic_ns':start, 'ended_monotonic_ns':end,
                 'elapsed_seconds':(end-start)/1000000000, 'timing_status':'measured', 'quiescent':True}
        self.op._write_once(state / 'terminal.json', json.dumps(value))
        return state, value

    def test_timing_pair_stays_constant_after_late_inspection_and_old_boot(self):
        old = replace(self.descriptor, boot_id='00000000-0000-0000-0000-000000000000')
        state, expected = self.timed_receipt(descriptor=old)
        first = self.op.inspect(old, 'a' * 32)
        self.assertEqual(first['status'], 'quiescent')
        self.assertEqual(first['receipt']['timing_status'], 'measured')
        self.assertEqual(first['receipt']['elapsed_seconds'], 1.25)
        __import__('time').sleep(.03)
        self.assertEqual(self.op.inspect(old, 'a' * 32), first)
        self.assertEqual(first['receipt'], expected)

    def test_timing_receipt_rejects_wrong_pairs_and_identity(self):
        import json
        state, value = self.timed_receipt()
        changes = [dict(started_monotonic_ns=True), dict(ended_monotonic_ns=0),
            dict(ended_monotonic_ns='2250000000'), dict(elapsed_seconds=0), dict(elapsed_seconds=float('nan')),
            dict(generation='other'), dict(invocation_id='b' * 32), dict(boot_id='00000000-0000-0000-0000-000000000000')]
        for change in changes:
            with self.subTest(change=change):
                (state / 'terminal.json').write_text(json.dumps({**value, **change}))
                self.assertIsNone(self.op.receipt(self.descriptor))
        (state / 'terminal.json').write_text(json.dumps({key:val for key,val in value.items() if key != 'ended_monotonic_ns'}))
        self.assertIsNone(self.op.receipt(self.descriptor))
        (state / 'terminal.json').write_text(json.dumps(value))
        (state / 'start.json').unlink()
        self.assertIsNone(self.op.receipt(self.descriptor))

    def test_start_rejects_changed_sealed_snapshot_before_worker_exec(self):
        self.assertTrue(callable(getattr(self.op, 'start', None)), 'sealed runner requires a trusted start callback')
        path = self.op.prepare(self.descriptor)
        (path.parent / 'runner.py').write_text('untrusted replacement')
        calls = []
        with self.assertRaisesRegex(self.op.ProcessError, 'artifact|runner'):
            self.op.start(path, execvpe=lambda *args: calls.append(args))
        self.assertFalse(calls)

    def test_timing_receipt_does_not_clip_actual_overrun_to_runtime(self):
        descriptor = replace(self.descriptor, runtime_seconds=1)
        state, expected = self.timed_receipt(descriptor=descriptor, start=1000000000, end=15000000000)
        self.assertEqual(self.op.receipt(descriptor)['elapsed_seconds'], 14)

    @unittest.skipUnless(__import__('os').environ.get('AIOS_OWNED_HOST_TEST') == '1', 'opt-in harmless user-systemd proof')
    def test_host_trusted_start_records_private_git_commit_and_ends_before_late_inspect(self):
        import os
        import time
        import uuid
        op = self.op
        descriptor = replace(self.descriptor, unit='aios-owned-fixture-' + uuid.uuid4().hex + '.service',
            runtime_seconds=5, argv=(self.shell, '-c',
                "set -eu; printf after > tracked; git add tracked; git commit -qm task; printf trusted-git-ok"))
        first = op.launch(descriptor)
        try:
            for _ in range(200):
                observation = op.inspect(descriptor, first.get('invocation_id'))
                if observation['status'] == 'quiescent':
                    break
                time.sleep(.02)
            self.assertEqual(observation['status'], 'quiescent', observation)
            receipt = observation['receipt']
            self.assertEqual(receipt['timing_status'], 'measured')
            self.assertGreater(receipt['elapsed_seconds'], 0)
            self.assertEqual(receipt['exit_status'], '0')
            self.assertEqual((Path(descriptor.state_directory) / 'stdout').read_text(), 'trusted-git-ok')
            self.assertEqual(self.git(self.owner, 'rev-parse', 'HEAD'), self.original)
            env = {**os.environ, **op.git_environment(self.profile)}
            committed = subprocess.run(['git', '-C', str(self.work), 'rev-parse', 'HEAD'],
                env=env, capture_output=True, text=True, timeout=5)
            self.assertEqual(committed.returncode, 0, committed.stderr)
            commit = committed.stdout.strip()
            self.assertNotEqual(commit, self.original)
            self.assertTrue((Path(self.profile.private_objects) / commit[:2] / commit[2:]).is_file())
            time.sleep(.15)
            self.assertEqual(op.inspect(descriptor, receipt['invocation_id'])['receipt'], receipt)
            self.assertLessEqual(receipt['ended_monotonic_ns'], time.monotonic_ns() - 100000000)
        finally:
            subprocess.run(['systemctl', '--user', 'stop', descriptor.unit], capture_output=True, timeout=15)
