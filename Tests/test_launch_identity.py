"""Exercise the actual process replacement without creating UI or requesting access."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(sys.platform == 'darwin', 'macOS launch responsibility')
class LaunchIdentityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='awake-launch-')
        cls.addClassCleanup(cls.directory.cleanup)
        root = Path(cls.directory.name)
        source = root / 'main.swift'
        source.write_text('''import Foundation
import Darwin
do {
    try LaunchIdentity.prepare()
    try LaunchIdentity.prepare() // Already independent: must not replace itself again.
    let value: [String: Any] = [
        "pid": getpid(), "responsible": LaunchIdentity.responsiblePID ?? -1,
        "arguments": Array(CommandLine.arguments.dropFirst()),
        "cwd": FileManager.default.currentDirectoryPath,
        "environment": ProcessInfo.processInfo.environment["AWAKE_TEST_VALUE"] ?? "",
        "guardPresent": getenv("AWAKE_IDENTITY_REEXEC") != nil,
        "input": readLine() ?? ""]
    print(String(data: try JSONSerialization.data(withJSONObject: value), encoding: .utf8)!)
} catch {
    print("Launch failed: \\(error)")
    exit(1)
}
''')
        cls.probe = root / 'launch-probe'
        production = Path(__file__).resolve().parents[1] / 'Sources/AwakeRuntime/LaunchIdentity.swift'
        subprocess.run(['swiftc', '-swift-version', '6', '-package-name', 'awake',
                        str(production), str(source), '-o', str(cls.probe)],
                       check=True, capture_output=True, text=True, timeout=60)

    def test_reexec_becomes_responsible_and_preserves_process_contract(self):
        arguments = ['space in argument', 'Кофе', '$(literal)']
        env = dict(os.environ, AWAKE_TEST_VALUE='unchanged value')
        env.pop('AWAKE_IDENTITY_REEXEC', None)
        process = subprocess.Popen([str(self.probe), *arguments], cwd=self.directory.name,
                                   env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: process.kill() if process.poll() is None else None)
        stdout, stderr = process.communicate('standard input\n', timeout=10)
        self.assertEqual(process.returncode, 0, stderr or stdout)
        state = json.loads(stdout)
        self.assertEqual(state['pid'], process.pid)
        self.assertEqual(state['responsible'], process.pid)
        self.assertEqual(state['arguments'], arguments)
        self.assertEqual(Path(state['cwd']).resolve(), Path(self.directory.name).resolve())
        self.assertEqual(state['environment'], env['AWAKE_TEST_VALUE'])
        self.assertEqual(state['input'], 'standard input')
        self.assertFalse(state['guardPresent'])

    def test_an_inherited_retry_cannot_loop_or_silently_continue(self):
        # The normal test launcher retains responsibility, so an existing retry
        # marker must fail before UI can be registered under that launcher.
        result = subprocess.run([str(self.probe)], input='', capture_output=True, text=True,
                                env=dict(os.environ, AWAKE_IDENTITY_REEXEC='1'), timeout=10)
        if result.returncode == 0:
            state = json.loads(result.stdout)
            self.assertEqual(state['responsible'], state['pid'])
            self.assertFalse(state['guardPresent'])
            self.skipTest('The test launcher already gives children their own responsibility')
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn('still belongs to its launcher', result.stdout)


if __name__ == '__main__':
    unittest.main()
