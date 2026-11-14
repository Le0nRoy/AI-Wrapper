"""Loopback forwarder inside the Linux sandbox's private network (#77, L4).

The sandbox runs with ``bwrap --unshare-net``: only its own loopback
exists, and the host proxy (ai_network_proxy.py) is reachable through a
UNIX socket bound into the sandbox. Clients (Node, curl, git, reqwest,
pip) only take ``http://HOST:PORT`` proxies, so this helper is the
sandbox's first program: it listens on ``127.0.0.1:PORT`` inside the
sandbox, starts a detached forwarder that relays each connection to the
proxy socket byte for byte, then execs the client command in its own
place (same PID, descriptors, terminal and exit status). The proxy, not
this helper, decides which destinations are allowed.

The forwarder runs in a session of its own (Ctrl+C does not reach it), is
not a child of the command (a shell's ``wait`` does not hang on it), and
stops once the command's PID is gone; bubblewrap's PID namespace also
ends it with the sandbox. Fails before the command runs (exit 1) when the
socket is missing or the port cannot be bound; a command that cannot be
run exits 127 (126 when not executable).

Usage: python3 -I ai_sandbox_net_forwarder.py --socket PATH --port N -- CMD [ARGS...]
"""

import argparse
import os
import select
import socket
import stat
import sys
import threading

LOOPBACK_HOST = "127.0.0.1"
LISTEN_BACKLOG = 128
RELAY_BUFFER_BYTES = 65536
COMMAND_POLL_INTERVAL_SECONDS = 1.0
MAX_PORT = 65535
EXIT_SETUP_FAILED = 1
EXIT_NOT_EXECUTABLE = 126
EXIT_NOT_FOUND = 127


def parse_args(argv):
    if "--" not in argv:
        argv = argv + ["--"]
    split = argv.index("--")
    parser = argparse.ArgumentParser(description="Relay sandbox loopback connections to the host proxy socket.")
    parser.add_argument("--socket", required=True, help="host proxy UNIX socket, as bound in the sandbox")
    parser.add_argument("--port", type=int, required=True, help="loopback port to listen on")
    args = parser.parse_args(argv[:split])
    args.command = argv[split + 1:]
    if not args.command:
        parser.error("give the command to run after --")
    if not 0 < args.port <= MAX_PORT:
        parser.error("--port must be 1-%d" % MAX_PORT)
    return args


def relay(client, socket_path):
    """Copy bytes both ways between ``client`` and the proxy socket until both close."""
    upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        upstream.connect(socket_path)
        open_sources = [client, upstream]
        while open_sources:
            readable, _, _ = select.select(open_sources, [], [])
            for source in readable:
                sink = upstream if source is client else client
                data = source.recv(RELAY_BUFFER_BYTES)
                if data:
                    sink.sendall(data)
                    continue
                open_sources.remove(source)
                sink.shutdown(socket.SHUT_WR)
    except OSError:
        pass
    finally:
        upstream.close()
        client.close()


def watch_command(command_pid):
    """Exit the forwarder once the command's PID no longer exists."""
    stop = threading.Event()
    while not stop.wait(COMMAND_POLL_INTERVAL_SECONDS):
        try:
            os.kill(command_pid, 0)
        except ProcessLookupError:
            os._exit(0)
        except PermissionError:
            pass


def serve(listener, socket_path, command_pid):
    threading.Thread(target=watch_command, args=(command_pid,), daemon=True).start()
    while True:
        client, _address = listener.accept()
        threading.Thread(target=relay, args=(client, socket_path), daemon=True).start()


def start_detached_forwarder(listener, socket_path):
    """Double-fork a forwarder in its own session; the caller keeps its PID."""
    command_pid = os.getpid()
    intermediate = os.fork()
    if intermediate == 0:
        try:
            if os.fork() == 0:
                os.setsid()
                null_fd = os.open(os.devnull, os.O_RDWR)
                for stdio_fd in (0, 1, 2):
                    os.dup2(null_fd, stdio_fd)
                # Drop every inherited descriptor (pipes the caller waits on
                # for EOF, the terminal) except the listener.
                os.closerange(3, listener.fileno())
                os.closerange(listener.fileno() + 1, os.sysconf("SC_OPEN_MAX"))
                serve(listener, socket_path, command_pid)
        finally:
            os._exit(0)
    os.waitpid(intermediate, 0)


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        if not stat.S_ISSOCK(os.stat(args.socket).st_mode):
            raise OSError("not a socket")
    except OSError as error:
        print("ai_sandbox_net_forwarder: proxy socket %s is not a socket (%s)" % (args.socket, error), file=sys.stderr)
        return EXIT_SETUP_FAILED
    # Python sockets are non-inheritable: the command never holds the listener.
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((LOOPBACK_HOST, args.port))
        listener.listen(LISTEN_BACKLOG)
    except OSError as error:
        listener.close()
        print("ai_sandbox_net_forwarder: cannot listen on %s:%d: %s" % (LOOPBACK_HOST, args.port, error),
              file=sys.stderr)
        return EXIT_SETUP_FAILED
    start_detached_forwarder(listener, args.socket)
    listener.close()
    try:
        os.execvp(args.command[0], args.command)
    except OSError as error:
        print("ai_sandbox_net_forwarder: cannot run %s: %s" % (args.command[0], error), file=sys.stderr)
        return EXIT_NOT_EXECUTABLE if isinstance(error, PermissionError) else EXIT_NOT_FOUND
    return EXIT_SETUP_FAILED


if __name__ == "__main__":
    sys.exit(main())
