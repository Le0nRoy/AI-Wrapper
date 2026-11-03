"""Tests for bin/ai_wrapper_data/ai_sandbox_net_forwarder.py (#77, L4).

Runs on the host, no sandbox: a real ai_network_proxy.py on a temp UNIX
socket, the forwarder on an ephemeral loopback port, and a client command
the forwarder execs. Only blocked destinations are used (the proxy's
default policy refuses loopback), so a 403 from the proxy proves the whole
chain; nothing leaves the machine. Called from
tests/test_linux_network_isolation.bash. Run: python3 -I -B tests/test_sandbox_net_forwarder.py
"""

import os
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import uuid

HELPER_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "ai_wrapper_data")
FORWARDER_PATH = os.path.join(HELPER_DIR, "ai_sandbox_net_forwarder.py")
PROXY_PATH = os.path.join(HELPER_DIR, "ai_network_proxy.py")

STARTUP_TIMEOUT_SECONDS = 10.0
POLL_INTERVAL_SECONDS = 0.05

# Client run by the forwarder: one CONNECT through the forwarder port,
# prints the proxy's status line, then the PID it ran as.
CLIENT = (
    "import os, socket, sys\n"
    "s = socket.create_connection(('127.0.0.1', int(sys.argv[1])), 5)\n"
    "s.sendall(b'CONNECT 127.0.0.1:9 HTTP/1.1\\r\\n\\r\\n')\n"
    "print(s.recv(4096).split(b'\\r\\n', 1)[0].decode(), flush=True)\n"
    "print('PID', os.getpid(), flush=True)\n"
)


def free_port():
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        probe.bind(("127.0.0.1", 0))
        return probe.getsockname()[1]
    finally:
        probe.close()


def port_open(port):
    try:
        socket.create_connection(("127.0.0.1", port), 1).close()
    except OSError:
        return False
    return True


def wait_until(predicate):
    deadline = time.monotonic() + STARTUP_TIMEOUT_SECONDS
    while not predicate() and time.monotonic() < deadline:
        time.sleep(POLL_INTERVAL_SECONDS)
    return predicate()


class ForwarderTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="asnf-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.directory, True)
        self.socket_path = os.path.join(self.directory, "%s.sock" % uuid.uuid4().hex[:8])
        self.proxy = subprocess.Popen([sys.executable, "-I", "-B", PROXY_PATH, "--socket", self.socket_path],
                                      stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, bufsize=0)
        self.addCleanup(self.stop_proxy)
        readable, _, _ = select.select([self.proxy.stdout], [], [], STARTUP_TIMEOUT_SECONDS)
        self.assertTrue(readable, "proxy did not start")
        self.assertEqual(self.proxy.stdout.readline().decode().strip(), "READY unix %s" % self.socket_path)
        self.port = free_port()

    def stop_proxy(self):
        if self.proxy.poll() is None:
            self.proxy.terminate()
        self.proxy.communicate(timeout=STARTUP_TIMEOUT_SECONDS)

    def run_forwarder(self, *command, socket_path=None):
        arguments = [sys.executable, "-I", "-B", FORWARDER_PATH, "--socket", socket_path or self.socket_path,
                     "--port", str(self.port), "--"] + list(command)
        result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=STARTUP_TIMEOUT_SECONDS)
        self.addCleanup(wait_until, lambda: not port_open(self.port))
        return result

    def test_relays_to_the_proxy_and_execs_in_place(self):
        before = time.monotonic()
        result = self.run_forwarder(sys.executable, "-I", "-c", CLIENT, str(self.port))
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.decode().splitlines()
        self.assertEqual(lines[0], "HTTP/1.1 403 Forbidden", "proxy reply relayed through the forwarder")
        self.assertTrue(lines[1].startswith("PID "))
        self.assertLess(time.monotonic() - before, STARTUP_TIMEOUT_SECONDS)

    def test_exit_status_is_the_commands(self):
        result = self.run_forwarder("/bin/sh", "-c", "exit 7")
        self.assertEqual(result.returncode, 7)

    def test_forwarder_stops_after_the_command(self):
        result = self.run_forwarder("/bin/sh", "-c", "exit 0")
        self.assertEqual(result.returncode, 0)
        self.assertTrue(wait_until(lambda: not port_open(self.port)), "forwarder outlived the command")

    def test_detached_forwarder_is_not_a_child_of_the_command(self):
        # `wait` in a shell waits for its own children: it must not hang on
        # the forwarder.
        result = self.run_forwarder("/bin/bash", "-c", "wait; echo WAITED")
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"WAITED", result.stdout)

    def test_command_holds_no_extra_descriptor(self):
        result = self.run_forwarder(sys.executable, "-I", "-c",
                                    "import os; print(len([n for n in os.listdir('/proc/self/fd') if int(n) > 2]))")
        self.assertEqual(result.returncode, 0, result.stderr)
        # Only the descriptor listdir itself opened (closed by the time it is printed).
        self.assertLessEqual(int(result.stdout), 1)

    def test_missing_command_is_127(self):
        result = self.run_forwarder("no-such-command-%s" % uuid.uuid4().hex)
        self.assertEqual(result.returncode, 127)
        self.assertIn(b"cannot run", result.stderr)

    def test_port_in_use_fails_before_running_the_command(self):
        holder = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        holder.bind(("127.0.0.1", self.port))
        holder.listen(1)
        try:
            marker = os.path.join(self.directory, "ran")
            result = self.run_forwarder("/bin/sh", "-c", "touch '%s'" % marker)
        finally:
            holder.close()
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"cannot listen", result.stderr)
        self.assertFalse(os.path.exists(marker))

    def test_missing_proxy_socket_fails_before_running_the_command(self):
        marker = os.path.join(self.directory, "ran")
        result = self.run_forwarder("/bin/sh", "-c", "touch '%s'" % marker,
                                    socket_path=os.path.join(self.directory, "absent.sock"))
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"not a socket", result.stderr)
        self.assertFalse(os.path.exists(marker))

    def test_usage_errors(self):
        for arguments in ([], ["--socket", self.socket_path, "--port", "1"],
                          ["--socket", self.socket_path, "--port", "x", "--", "true"]):
            with self.subTest(arguments=arguments):
                result = subprocess.run([sys.executable, "-I", "-B", FORWARDER_PATH] + arguments,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                        timeout=STARTUP_TIMEOUT_SECONDS)
                self.assertEqual(result.returncode, 2)


if __name__ == "__main__":
    unittest.main()
