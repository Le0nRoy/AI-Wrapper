"""Unit tests for bin/ai_wrapper_data/linux_tty_seccomp.py (#64, L5).

Linux only. Builds real filters with the host libseccomp and loads them in
forked children that own a private pseudo-terminal; nothing touches the
terminal running the tests. Failure paths (missing library, symbol,
architecture mismatch, filters that do not deny or do not load) are forced
with mocks. Run: python3 -I -B tests/test_linux_tty_seccomp.py
"""

import contextlib
import ctypes
import errno
import fcntl
import io
import os
import re
import struct
import sys
import termios
import unittest
from unittest import mock

HELPER_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "ai_wrapper_data")
sys.dont_write_bytecode = True  # never leave __pycache__ in the deployed bin dir
sys.path.insert(0, HELPER_DIR)
import linux_tty_seccomp as helper  # noqa: E402  (path set up above)

BPF_RET_K = 0x06
SCMP_CMP_EQ = 4
CHILD_REPORT_BYTES = 64


def bpf_program(*instructions):
    return b"".join(struct.pack("=HBBI", code, jt, jf, k) for code, jt, jf, k in instructions)


def errnos_under(data):
    """Load DATA in a forked child owning a private pty as controlling tty.

    Returns {name: errno} for plain TIOCSTI, the high-bit alias, TIOCLINUX
    and TIOCGWINSZ, measured after the filter is loaded (0 = success).
    """
    read_fd, write_fd = os.pipe()
    pid = os.fork()
    if pid == 0:
        os.close(read_fd)
        report = "error"
        try:
            libc = ctypes.CDLL(None, use_errno=True)
            libc.ioctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_void_p]
            libc.prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong]
            os.setsid()
            _master, slave = os.openpty()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
            libc.prctl(helper.PR_SET_NO_NEW_PRIVS, 1, None, 0, 0)
            prog = helper.SockFprog(len(data) // 8, data)
            if libc.prctl(helper.PR_SET_SECCOMP, helper.SECCOMP_MODE_FILTER,
                          ctypes.cast(ctypes.byref(prog), ctypes.c_void_p), 0, 0) != 0:
                report = "load-failed"
            else:
                char = ctypes.c_char(b"\n")
                sub = ctypes.c_char(b"\0")
                win = ctypes.create_string_buffer(8)
                results = {
                    "TIOCSTI": helper.ioctl_errno(libc, slave, termios.TIOCSTI, ctypes.byref(char)),
                    "TIOCSTI_HIGH": helper.ioctl_errno(libc, slave, helper.HIGH_BIT_ALIAS | termios.TIOCSTI,
                                                       ctypes.byref(char)),
                    "TIOCLINUX": helper.ioctl_errno(libc, slave, termios.TIOCLINUX, ctypes.byref(sub)),
                    "TIOCGWINSZ": helper.ioctl_errno(libc, slave, termios.TIOCGWINSZ, win),
                }
                report = ",".join(f"{k}={v}" for k, v in results.items())
        finally:
            os.write(write_fd, report.encode()[:CHILD_REPORT_BYTES * 2])
            os._exit(0)
    os.close(write_fd)
    try:
        raw = os.read(read_fd, CHILD_REPORT_BYTES * 2).decode()
    finally:
        os.close(read_fd)
        os.waitpid(pid, 0)
    if "=" not in raw:
        return raw
    return {k: int(v) for k, v in (item.split("=") for item in raw.split(","))}


def build_with_cmp(op, datum_a, datum_b):
    """A filter like the helper's but with a caller-chosen comparison."""
    lib = helper.load_libseccomp()
    native = lib.seccomp_arch_native()
    ctx = lib.seccomp_init(helper.SCMP_ACT_ALLOW)
    try:
        nr = lib.seccomp_syscall_resolve_name_arch(native, b"ioctl")
        for request in (termios.TIOCSTI, termios.TIOCLINUX):
            a, b = (datum_a, request) if op == helper.SCMP_CMP_MASKED_EQ else (request, datum_b)
            cmp = helper.ScmpArgCmp(1, op, a, b)
            assert lib.seccomp_rule_add_array(ctx, helper.SCMP_ACT_ERRNO_BASE | errno.EPERM, nr, 1,
                                              ctypes.byref(cmp)) == 0
        return helper.export_bpf(lib, ctx)
    finally:
        lib.seccomp_release(ctx)


@unittest.skipUnless(sys.platform.startswith("linux"), "Linux-only helper")
class HelperTests(unittest.TestCase):
    def test_main_prints_escaped_whole_program(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(helper.main(), 0)
        text = out.getvalue().strip()
        self.assertRegex(text, r"^(\\x[0-9a-f]{2})+$")
        self.assertEqual((len(text) // 4) % 8, 0)

    def test_filter_denies_injection_and_keeps_tty(self):
        data = helper.build_filter(helper.load_libseccomp())
        res = errnos_under(data)
        self.assertEqual(res["TIOCSTI"], errno.EPERM)
        self.assertEqual(res["TIOCSTI_HIGH"], errno.EPERM, "high-bit alias of TIOCSTI must be denied")
        self.assertEqual(res["TIOCLINUX"], errno.EPERM)
        self.assertEqual(res["TIOCGWINSZ"], 0)

    def test_allow_all_baseline_is_not_eperm(self):
        # Control: without a deny rule the same calls do not fail with
        # EPERM (EIO/0 for TIOCSTI depending on dev.tty.legacy_tiocsti,
        # ENOTTY/EINVAL for TIOCLINUX on a pty), so EPERM above proves the
        # filter acted, not the kernel.
        res = errnos_under(bpf_program((BPF_RET_K, 0, 0, helper.SCMP_ACT_ALLOW)))
        self.assertNotEqual(res["TIOCSTI"], errno.EPERM)
        self.assertNotEqual(res["TIOCSTI_HIGH"], errno.EPERM)
        self.assertNotEqual(res["TIOCLINUX"], errno.EPERM)
        self.assertEqual(res["TIOCGWINSZ"], 0)

    @unittest.skipUnless(ctypes.sizeof(ctypes.c_ulong) > 4, "64-bit request width only")
    def test_unmasked_match_misses_high_bit_alias(self):
        # Control for the masked comparison: an exact 64-bit match is
        # bypassed by setting high bits, which the kernel ignores.
        res = errnos_under(build_with_cmp(SCMP_CMP_EQ, 0, 0))
        self.assertEqual(res["TIOCSTI"], errno.EPERM)
        self.assertNotEqual(res["TIOCSTI_HIGH"], errno.EPERM)
        with self.assertRaisesRegex(helper.FilterError, "did not deny"):
            helper.selftest(build_with_cmp(SCMP_CMP_EQ, 0, 0))

    def test_selftest_rejects_allow_all(self):
        with self.assertRaisesRegex(helper.FilterError, "did not deny"):
            helper.selftest(bpf_program((BPF_RET_K, 0, 0, helper.SCMP_ACT_ALLOW)))

    def test_selftest_rejects_unloadable_filter(self):
        bad_opcode = 0xFFFF
        with self.assertRaisesRegex(helper.FilterError, "refused to load"):
            helper.selftest(bpf_program((bad_opcode, 0, 0, 0)))

    def test_selftest_rejects_filter_breaking_tty(self):
        deny_all = helper.SCMP_ACT_ERRNO_BASE | errno.EPERM
        lib = helper.load_libseccomp()
        ctx = lib.seccomp_init(helper.SCMP_ACT_ALLOW)
        try:
            nr = lib.seccomp_syscall_resolve_name_arch(lib.seccomp_arch_native(), b"ioctl")
            self.assertEqual(lib.seccomp_rule_add_array(ctx, deny_all, nr, 0, None), 0)
            data = helper.export_bpf(lib, ctx)
        finally:
            lib.seccomp_release(ctx)
        with self.assertRaisesRegex(helper.FilterError, "TIOCGWINSZ"):
            helper.selftest(data)

    def test_compat_arches_in_filter(self):
        arch = helper.kernel_arch_name()
        lib = helper.load_libseccomp()
        lib.seccomp_export_pfc.argtypes = [ctypes.c_void_p, ctypes.c_int]
        real_export = helper.export_bpf
        captured = []

        def export_and_capture(lib_, ctx):
            captured.append(_pfc(lib_, ctx))
            return real_export(lib_, ctx)

        with mock.patch.object(helper, "export_bpf", side_effect=export_and_capture):
            helper.build_filter(lib)
        pfc = captured[0]
        self.assertIn(f"filter for arch {arch} ", pfc)
        for compat in helper.COMPAT_ARCHES.get(arch, ()):
            self.assertIn(f"filter for arch {compat} ", pfc)
        self.assertIn("invalid architecture action\naction KILL", pfc)
        self.assertRegex(pfc, re.compile(r"& 0xffffffff == %d" % termios.TIOCSTI))

    def test_missing_library(self):
        with mock.patch("ctypes.util.find_library", return_value=None):
            with self.assertRaisesRegex(helper.FilterError, "libseccomp not found"):
                helper.load_libseccomp()

    def test_missing_symbol(self):
        class NoSymbols:
            def __getattr__(self, name):
                raise AttributeError(name)

        with mock.patch("ctypes.CDLL", return_value=NoSymbols()):
            with self.assertRaisesRegex(helper.FilterError, "lacks seccomp_"):
                helper.load_libseccomp()

    def test_architecture_mismatch(self):
        lib = helper.load_libseccomp()
        other = "aarch64" if helper.kernel_arch_name() != "aarch64" else "x86_64"
        with mock.patch.object(helper, "kernel_arch_name", return_value=other):
            with self.assertRaisesRegex(helper.FilterError, "differs from the kernel"):
                helper.build_filter(lib)

    def test_unknown_architecture(self):
        lib = helper.load_libseccomp()
        with mock.patch.object(helper, "kernel_arch_name", return_value="no-such-arch"):
            with self.assertRaisesRegex(helper.FilterError, "does not know"):
                helper.build_filter(lib)

    def test_main_reports_failure_on_stderr(self):
        err = io.StringIO()
        out = io.StringIO()
        with mock.patch("ctypes.util.find_library", return_value=None), \
                contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
            self.assertEqual(helper.main(), 1)
        self.assertEqual(out.getvalue(), "")
        self.assertIn("libseccomp not found", err.getvalue())


def _pfc(lib, ctx):
    memfd = os.memfd_create("pfc")
    try:
        lib.seccomp_export_pfc(ctx, memfd)
        os.lseek(memfd, 0, os.SEEK_SET)
        return os.read(memfd, 1 << 16).decode()
    finally:
        os.close(memfd)


if __name__ == "__main__":
    unittest.main()
