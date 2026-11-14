"""Build the Linux sandbox's terminal-injection seccomp filter.

Run by bin/ai_agent_universal_wrapper.bash on the host (``python3 -I``)
before every protected bubblewrap launch. Uses libseccomp (through ctypes)
to resolve the native ioctl syscall and compile a filter that fails
ioctl(TIOCSTI) and ioctl(TIOCLINUX) with EPERM and allows every other
syscall. The request argument is matched on its low 32 bits, because the
kernel truncates the ioctl command to an unsigned int: a request with high
bits set is the same ioctl to the kernel and must hit the same rule.

The compiled filter is checked before it is printed: in a forked child that
owns a private pseudo-terminal as its controlling tty, the exported BPF is
loaded the same way bwrap loads it, and TIOCSTI (plain and with high bits
set) and TIOCLINUX must fail with EPERM where they did not before, while
TIOCGWINSZ keeps working. Nothing is ever injected into the caller's
terminal; the child uses its own pty.

On success prints the filter as printf-%b escapes (\\xHH per byte) on
stdout and exits 0. On any failure prints one line on stderr and exits 1;
the wrapper then refuses the protected launch.
"""

import ctypes
import ctypes.util
import errno
import fcntl
import os
import sys
import termios

# libseccomp API constants (seccomp.h).
SCMP_ACT_ALLOW = 0x7FFF0000
SCMP_ACT_ERRNO_BASE = 0x00050000
SCMP_CMP_MASKED_EQ = 7
SCMP_ERROR_NR = -1
IOCTL_REQUEST_ARG = 1
IOCTL_REQUEST_MASK = 0xFFFFFFFF
# Kernel UAPI constants (linux/prctl.h, linux/seccomp.h).
PR_SET_SECCOMP = 22
PR_SET_NO_NEW_PRIVS = 38
SECCOMP_MODE_FILTER = 2
BPF_INSTRUCTION_SIZE = 8
BPF_MAXINSNS = 4096
HIGH_BIT_ALIAS = 1 << 32

DENIED_REQUESTS = {
    "TIOCSTI": termios.TIOCSTI,
    "TIOCLINUX": getattr(termios, "TIOCLINUX", None),
}

# 32-bit ABIs a 64-bit kernel also runs. Their syscalls carry a different
# audit arch (or, for x32, a flagged syscall number) and must meet the same
# rule; any arch not in the filter hits libseccomp's bad-arch action (kill).
COMPAT_ARCHES = {
    "x86_64": ("x86", "x32"),
    "aarch64": ("arm",),
}

# Self-test child exit codes.
SELFTEST_OK = 0
SELFTEST_NO_CTTY = 10
SELFTEST_BASELINE_EPERM = 11
SELFTEST_LOAD_FAILED = 12
SELFTEST_NOT_DENIED = 13
SELFTEST_TTY_BROKEN = 14
SELFTEST_ERROR = 15
SELFTEST_MESSAGES = {
    SELFTEST_NO_CTTY: "could not give the test process a private controlling terminal",
    SELFTEST_BASELINE_EPERM: "a terminal ioctl already fails with EPERM without the filter, so the filter cannot be verified",
    SELFTEST_LOAD_FAILED: "the kernel refused to load the filter (seccomp unavailable here?)",
    SELFTEST_NOT_DENIED: "the loaded filter did not deny TIOCSTI/TIOCLINUX with EPERM",
    SELFTEST_TTY_BROKEN: "the loaded filter broke an ordinary terminal ioctl (TIOCGWINSZ)",
    SELFTEST_ERROR: "the self-test failed unexpectedly",
}


class FilterError(Exception):
    pass


class ScmpArgCmp(ctypes.Structure):
    _fields_ = [
        ("arg", ctypes.c_uint),
        ("op", ctypes.c_int),
        ("datum_a", ctypes.c_uint64),
        ("datum_b", ctypes.c_uint64),
    ]


class SockFprog(ctypes.Structure):
    _fields_ = [
        ("len", ctypes.c_ushort),
        ("filter", ctypes.c_char_p),
    ]


def load_libseccomp():
    name = ctypes.util.find_library("seccomp")
    if not name:
        raise FilterError("libseccomp not found (install the libseccomp runtime library, e.g. libseccomp2)")
    try:
        lib = ctypes.CDLL(name, use_errno=True)
    except OSError as exc:
        raise FilterError(f"cannot load {name}: {exc}") from exc
    signatures = {
        "seccomp_init": ([ctypes.c_uint32], ctypes.c_void_p),
        "seccomp_release": ([ctypes.c_void_p], None),
        "seccomp_arch_native": ([], ctypes.c_uint32),
        "seccomp_arch_resolve_name": ([ctypes.c_char_p], ctypes.c_uint32),
        "seccomp_arch_add": ([ctypes.c_void_p, ctypes.c_uint32], ctypes.c_int),
        "seccomp_syscall_resolve_name_arch": ([ctypes.c_uint32, ctypes.c_char_p], ctypes.c_int),
        "seccomp_rule_add_array": (
            [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int, ctypes.c_uint, ctypes.POINTER(ScmpArgCmp)],
            ctypes.c_int,
        ),
        "seccomp_export_bpf": ([ctypes.c_void_p, ctypes.c_int], ctypes.c_int),
    }
    for symbol, (argtypes, restype) in signatures.items():
        try:
            func = getattr(lib, symbol)
        except AttributeError as exc:
            raise FilterError(f"{name} lacks {symbol}") from exc
        func.argtypes = argtypes
        func.restype = restype
    return lib


def kernel_arch_name():
    machine = os.uname().machine
    if machine in ("i386", "i486", "i586", "i686"):
        return "x86"
    if machine.startswith("arm"):
        return "arm"
    return machine


def native_arch(lib):
    native = lib.seccomp_arch_native()
    kernel_name = kernel_arch_name()
    kernel_token = lib.seccomp_arch_resolve_name(kernel_name.encode())
    if kernel_token == 0:
        raise FilterError(f"libseccomp does not know the kernel architecture '{kernel_name}'")
    if kernel_token != native:
        raise FilterError(
            f"python3/libseccomp architecture (token 0x{native:x}) differs from the kernel's "
            f"'{kernel_name}' (0x{kernel_token:x}); use a native python3"
        )
    return kernel_name, native


def build_filter(lib):
    for label, request in DENIED_REQUESTS.items():
        if request is None:
            raise FilterError(f"python3 termios module lacks {label}")
    arch_name, native = native_arch(lib)
    ioctl_nr = lib.seccomp_syscall_resolve_name_arch(native, b"ioctl")
    if ioctl_nr == SCMP_ERROR_NR or ioctl_nr < 0:
        raise FilterError(f"libseccomp cannot resolve ioctl on {arch_name}")

    ctx = lib.seccomp_init(SCMP_ACT_ALLOW)
    if not ctx:
        raise FilterError("seccomp_init failed")
    try:
        for compat_name in COMPAT_ARCHES.get(arch_name, ()):
            token = lib.seccomp_arch_resolve_name(compat_name.encode())
            if token == 0:
                continue
            rc = lib.seccomp_arch_add(ctx, token)
            if rc not in (0, -errno.EEXIST):
                raise FilterError(f"seccomp_arch_add({compat_name}) failed: {os.strerror(-rc)}")
        action = SCMP_ACT_ERRNO_BASE | errno.EPERM
        for label, request in DENIED_REQUESTS.items():
            cmp = ScmpArgCmp(IOCTL_REQUEST_ARG, SCMP_CMP_MASKED_EQ, IOCTL_REQUEST_MASK, request)
            rc = lib.seccomp_rule_add_array(ctx, action, ioctl_nr, 1, ctypes.byref(cmp))
            if rc != 0:
                raise FilterError(f"seccomp_rule_add({label}) failed: {os.strerror(-rc)}")
        return export_bpf(lib, ctx)
    finally:
        lib.seccomp_release(ctx)


def export_bpf(lib, ctx):
    memfd = os.memfd_create("ai-wrapper-tty-filter")
    try:
        rc = lib.seccomp_export_bpf(ctx, memfd)
        if rc != 0:
            raise FilterError(f"seccomp_export_bpf failed: {os.strerror(-rc)}")
        size = os.lseek(memfd, 0, os.SEEK_END)
        os.lseek(memfd, 0, os.SEEK_SET)
        data = b""
        while len(data) < size:
            chunk = os.read(memfd, size - len(data))
            if not chunk:
                break
            data += chunk
    finally:
        os.close(memfd)
    if not data or len(data) != size or len(data) % BPF_INSTRUCTION_SIZE:
        raise FilterError(f"exported filter is empty or truncated ({len(data)} bytes)")
    if len(data) // BPF_INSTRUCTION_SIZE > BPF_MAXINSNS:
        raise FilterError("exported filter is too long")
    return data


def ioctl_errno(libc, fd, request, arg):
    ctypes.set_errno(0)
    rc = libc.ioctl(fd, ctypes.c_ulong(request), arg)
    return 0 if rc == 0 else ctypes.get_errno()


def selftest_child(data):
    """Runs in a forked child; returns a SELFTEST_* exit code."""
    libc = ctypes.CDLL(None, use_errno=True)
    libc.ioctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_void_p]
    libc.prctl.argtypes = [ctypes.c_int, ctypes.c_ulong, ctypes.c_void_p, ctypes.c_ulong, ctypes.c_ulong]
    os.setsid()
    _master, slave = os.openpty()
    try:
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    except OSError:
        return SELFTEST_NO_CTTY
    char = ctypes.c_char(b"\n")
    subcode = ctypes.c_char(b"\0")
    winsize = ctypes.create_string_buffer(8)
    requests = [(termios.TIOCSTI, char), (DENIED_REQUESTS["TIOCLINUX"], subcode)]
    if ctypes.sizeof(ctypes.c_ulong) > 4:
        requests.append((HIGH_BIT_ALIAS | termios.TIOCSTI, char))
    for request, arg in requests:
        if ioctl_errno(libc, slave, request, ctypes.byref(arg)) == errno.EPERM:
            return SELFTEST_BASELINE_EPERM
    if libc.prctl(PR_SET_NO_NEW_PRIVS, 1, None, 0, 0) != 0:
        return SELFTEST_LOAD_FAILED
    prog = SockFprog(len(data) // BPF_INSTRUCTION_SIZE, data)
    if libc.prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, ctypes.cast(ctypes.byref(prog), ctypes.c_void_p), 0, 0) != 0:
        return SELFTEST_LOAD_FAILED
    for request, arg in requests:
        if ioctl_errno(libc, slave, request, ctypes.byref(arg)) != errno.EPERM:
            return SELFTEST_NOT_DENIED
    if ioctl_errno(libc, slave, termios.TIOCGWINSZ, winsize) != 0:
        return SELFTEST_TTY_BROKEN
    return SELFTEST_OK


def selftest(data):
    pid = os.fork()
    if pid == 0:
        code = SELFTEST_ERROR
        try:
            code = selftest_child(data)
        finally:
            os._exit(code)
    _pid, status = os.waitpid(pid, 0)
    if not os.WIFEXITED(status):
        raise FilterError(f"filter self-test terminated abnormally (wait status {status})")
    code = os.WEXITSTATUS(status)
    if code != SELFTEST_OK:
        raise FilterError("filter self-test: " + SELFTEST_MESSAGES.get(code, f"exit code {code}"))


def main():
    try:
        lib = load_libseccomp()
        data = build_filter(lib)
        selftest(data)
    except FilterError as exc:
        print(f"terminal filter: {exc}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"terminal filter: {exc}", file=sys.stderr)
        return 1
    sys.stdout.write("".join(f"\\x{byte:02x}" for byte in data) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
