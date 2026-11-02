"""Unprivileged egress proxy for sandboxed agents (#76, L4).

Runs on the host as the invoking user (``python3 -I``). Sandboxed clients
reach the network only through it: HTTPS via ``CONNECT host:port`` (a raw
byte tunnel, TLS stays end-to-end) and plain HTTP via absolute-URI requests
(``GET http://host/path``). Every destination is resolved here and refused
with 403 when ANY resolved address is loopback, link-local / cloud metadata,
private LAN (RFC 1918, RFC 6598, ULA), multicast or reserved. IPv4 embedded
in IPv6 (IPv4-mapped, NAT64 well-known prefix, 6to4) is unwrapped and
checked as IPv4. The upstream socket connects to the verified address
itself, so no second lookup can rebind the name.

Listens on a UNIX domain socket (``--socket PATH``, mode 0600) and/or a
loopback TCP port (``--host 127.0.0.1 --port N``; 0 picks a free port).
Prints one ``READY tcp HOST:PORT`` / ``READY unix PATH`` line per listener
on stdout once bound; SIGINT/SIGTERM stop the listeners, remove the socket
file and exit 0. Errors go to stderr (exit 1). Logs name destinations and
outcomes only, never paths, queries, headers or payloads.

Wrapper wiring is separate: #77 (Linux bwrap), #78 (macOS sandbox-exec).
"""

import argparse
import http.client
import ipaddress
import logging
import os
import select
import signal
import socket
import socketserver
import stat
import sys
import threading
from http.server import BaseHTTPRequestHandler
from urllib.parse import urlsplit

LOG = logging.getLogger("ai_network_proxy")

BLOCKED_NETWORKS = tuple(ipaddress.ip_network(cidr) for cidr in (
    # Loopback
    "127.0.0.0/8", "::1/128",
    # Link-local, incl. cloud metadata (169.254.169.254)
    "169.254.0.0/16", "fe80::/10",
    # Private LAN: RFC 1918, RFC 6598 shared address space, IPv6 ULA
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7",
    # "This network" (0.0.0.0 reaches the host on Linux), multicast, reserved
    "0.0.0.0/8", "224.0.0.0/4", "240.0.0.0/4", "ff00::/8",
    # Unspecified and deprecated IPv4-compatible IPv6 (::a.b.c.d)
    "::/96",
))
NAT64_WELL_KNOWN_PREFIX = ipaddress.ip_network("64:ff9b::/96")
IPV4_LOW_BITS_MASK = 0xFFFFFFFF

DEFAULT_HOST = "127.0.0.1"
DEFAULT_TIMEOUT_SECONDS = 30.0
DEFAULT_HTTP_PORT = 80
MAX_PORT = 65535
RELAY_BUFFER_BYTES = 65536
MAX_CHUNK_LINE_BYTES = 8192
UNIX_SOCKET_UMASK = 0o177

# Hop-by-hop request headers never forwarded upstream (RFC 9110 § 7.6.1);
# Host is rewritten from the request URI, Expect is answered by the proxy.
# Transfer-Encoding is kept: chunked bodies are relayed with their framing.
DROPPED_REQUEST_HEADERS = frozenset((
    "connection", "keep-alive", "proxy-connection", "proxy-authorization",
    "proxy-authenticate", "te", "upgrade", "host", "expect",
))
# Response headers the proxy re-frames itself: the body is sent decoded and
# delimited by Content-Length or by closing the client connection.
DROPPED_RESPONSE_HEADERS = frozenset((
    "connection", "keep-alive", "proxy-connection", "proxy-authenticate",
    "te", "trailer", "transfer-encoding", "upgrade",
))


class DestinationBlocked(Exception):
    """The destination is (or resolves to) a blocked address."""


class DestinationUnresolvable(Exception):
    """The destination name does not resolve."""


def embedded_ipv4(address):
    """Return the IPv4 address carried inside an IPv6 address, or None."""
    if address.version != 6:
        return None
    if address.ipv4_mapped is not None:
        return address.ipv4_mapped
    if address.sixtofour is not None:
        return address.sixtofour
    if address in NAT64_WELL_KNOWN_PREFIX:
        return ipaddress.IPv4Address(int(address) & IPV4_LOW_BITS_MASK)
    return None


def parse_ip(text):
    """Parse an IP literal, dropping an IPv6 zone (``fe80::1%eth0``)."""
    return ipaddress.ip_address(text.split("%", 1)[0])


class DestinationFilter:
    """Resolve destinations and refuse any that touch a blocked network."""

    def __init__(self, blocked_networks=BLOCKED_NETWORKS, resolver=socket.getaddrinfo):
        self._blocked_networks = tuple(blocked_networks)
        self._resolver = resolver

    def blocked_reason(self, address):
        """Return why ``address`` is blocked, or None when it is allowed."""
        for candidate in (address, embedded_ipv4(address)):
            if candidate is None:
                continue
            for network in self._blocked_networks:
                if candidate.version == network.version and candidate in network:
                    return "%s is in blocked range %s" % (address, network)
        return None

    def is_blocked(self, address_text):
        return self.blocked_reason(parse_ip(address_text)) is not None

    def resolve(self, host, port):
        """Return ``[(family, sockaddr), ...]`` for host:port, all allowed.

        Fails closed: raises DestinationBlocked if any resolved address is
        blocked or unparseable, DestinationUnresolvable if none resolve.
        """
        try:
            infos = self._resolver(host, port, socket.AF_UNSPEC, socket.SOCK_STREAM)
        except (OSError, UnicodeError, ValueError) as error:
            raise DestinationUnresolvable("cannot resolve %s: %s" % (host, error))
        if not infos:
            raise DestinationUnresolvable("cannot resolve %s: no addresses" % host)
        targets = []
        for family, _socktype, _proto, _canonname, sockaddr in infos:
            if family not in (socket.AF_INET, socket.AF_INET6):
                raise DestinationBlocked("%s resolved to a non-IP address family" % host)
            try:
                address = parse_ip(sockaddr[0])
            except ValueError:
                raise DestinationBlocked("%s resolved to unparseable address %r" % (host, sockaddr[0]))
            reason = self.blocked_reason(address)
            if reason is not None:
                raise DestinationBlocked("%s resolved to a blocked address: %s" % (host, reason))
            targets.append((family, sockaddr))
        return targets


def parse_authority(authority, default_port=None):
    """Split ``host:port`` / ``[v6]:port`` into (host, port); ValueError if bad."""
    parts = urlsplit("//" + authority)
    if parts.path or parts.query or parts.fragment or "@" in parts.netloc:
        raise ValueError("invalid authority %r" % authority)
    host = parts.hostname
    port = parts.port if parts.port is not None else default_port
    if not host or port is None or not 0 < port <= MAX_PORT:
        raise ValueError("invalid authority %r" % authority)
    return host, port


def connect_upstream(targets, timeout):
    """Connect to the first reachable verified sockaddr; OSError if none."""
    last_error = OSError("no addresses to connect to")
    for family, sockaddr in targets:
        upstream = socket.socket(family, socket.SOCK_STREAM)
        upstream.settimeout(timeout)
        try:
            upstream.connect(sockaddr)
        except OSError as error:
            upstream.close()
            last_error = error
            continue
        return upstream
    raise last_error


def pump(client, upstream, idle_timeout):
    """Relay bytes both ways until both sides close, an error, or idle timeout."""
    open_sources = [client, upstream]
    while open_sources:
        readable, _, _ = select.select(open_sources, [], [], idle_timeout)
        if not readable:
            LOG.info("tunnel idle for %ss, closing", idle_timeout)
            return
        for source in readable:
            sink = upstream if source is client else client
            try:
                data = source.recv(RELAY_BUFFER_BYTES)
            except OSError:
                return
            if not data:
                open_sources.remove(source)
                try:
                    sink.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
                continue
            try:
                sink.sendall(data)
            except OSError:
                return


class ProxyRequestHandler(BaseHTTPRequestHandler):
    """CONNECT tunnels and absolute-URI HTTP forwarding, one request per connection."""

    # Unbuffered reads: nothing past the CONNECT head is consumed before the
    # raw tunnel takes over the socket.
    rbufsize = 0
    protocol_version = "HTTP/1.1"
    server_version = "ai-network-proxy"
    sys_version = ""

    def setup(self):
        self.timeout = self.server.idle_timeout
        super().setup()

    def log_message(self, format, *args):  # noqa: A002 (stdlib signature)
        # Default request logs carry the full URL; keep them at DEBUG only.
        LOG.debug(format, *args)

    def log_request(self, code="-", size="-"):
        pass

    def _reply(self, code, message):
        body = ("%d %s: %s\n" % (code, self.responses.get(code, ("",))[0], message)).encode("utf-8")
        self.close_connection = True
        self.send_response(code)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _open_upstream(self, host, port):
        """Resolve, filter and connect; reply with an error and return None on failure."""
        try:
            targets = self.server.destination_filter.resolve(host, port)
        except DestinationBlocked as error:
            LOG.warning("[BLOCKED] %s %s:%d (%s)", self.command, host, port, error)
            self._reply(403, "Destination blocked by sandbox network policy (%s)" % error)
            return None
        except DestinationUnresolvable as error:
            LOG.warning("[UNRESOLVED] %s %s:%d (%s)", self.command, host, port, error)
            self._reply(502, str(error))
            return None
        try:
            upstream = connect_upstream(targets, self.server.idle_timeout)
        except socket.timeout:
            LOG.warning("[TIMEOUT] %s %s:%d", self.command, host, port)
            self._reply(504, "Timed out connecting to %s:%d" % (host, port))
            return None
        except OSError as error:
            LOG.warning("[FAILED] %s %s:%d (%s)", self.command, host, port, error)
            self._reply(502, "Cannot connect to %s:%d: %s" % (host, port, error))
            return None
        LOG.info("[ALLOWED] %s %s:%d -> %s", self.command, host, port, upstream.getpeername()[0])
        return upstream

    def do_CONNECT(self):
        try:
            host, port = parse_authority(self.path)
        except ValueError:
            self._reply(400, "CONNECT needs host:port")
            return
        upstream = self._open_upstream(host, port)
        if upstream is None:
            return
        self.close_connection = True
        try:
            self.send_response(200, "Connection Established")
            self.end_headers()
            pump(self.connection, upstream, self.server.idle_timeout)
        finally:
            upstream.close()

    def _forward(self):
        url = urlsplit(self.path)
        if url.scheme.lower() != "http":
            self._reply(400, "Only absolute http:// URLs are proxied; use CONNECT for HTTPS")
            return
        authority = url.netloc.rpartition("@")[2]
        try:
            host, port = parse_authority(authority, DEFAULT_HTTP_PORT)
        except ValueError:
            self._reply(400, "Invalid host in request URL")
            return
        framing_error = self._body_framing_error()
        if framing_error is not None:
            self._reply(framing_error[0], framing_error[1])
            return
        upstream = self._open_upstream(host, port)
        if upstream is None:
            return
        self.close_connection = True
        try:
            upstream.sendall(self._upstream_head(url, authority))
            self._relay_body(upstream)
            self._relay_response(upstream)
        except (OSError, ValueError, http.client.HTTPException) as error:
            LOG.warning("[ABORTED] %s %s:%d (%s)", self.command, host, port, error)
        finally:
            upstream.close()

    do_GET = do_HEAD = do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _forward

    def _body_framing_error(self):
        """Return (code, message) for ambiguous or unsupported body framing."""
        lengths = self.headers.get_all("Content-Length", [])
        encodings = self.headers.get_all("Transfer-Encoding", [])
        if lengths and encodings:
            return 400, "Both Content-Length and Transfer-Encoding are set"
        if len(lengths) > 1 or len(encodings) > 1:
            return 400, "Repeated body framing header"
        if encodings and encodings[0].strip().lower() != "chunked":
            return 501, "Only chunked Transfer-Encoding is supported"
        if lengths and not lengths[0].strip().isdigit():
            return 400, "Invalid Content-Length"
        return None

    def _upstream_head(self, url, authority):
        connection_tokens = set()
        for value in self.headers.get_all("Connection", []):
            connection_tokens.update(token.strip().lower() for token in value.split(","))
        target = url.path or "/"
        if url.query:
            target += "?" + url.query
        lines = ["%s %s HTTP/1.1" % (self.command, target), "Host: %s" % authority]
        for name, value in self.headers.items():
            lowered = name.lower()
            if lowered in DROPPED_REQUEST_HEADERS or lowered in connection_tokens:
                continue
            lines.append("%s: %s" % (name, value))
        lines.append("Connection: close")
        return ("\r\n".join(lines) + "\r\n\r\n").encode("latin-1")

    def _copy_exact(self, upstream, remaining):
        while remaining > 0:
            data = self.rfile.read(min(remaining, RELAY_BUFFER_BYTES))
            if not data:
                raise ValueError("client closed before the request body ended")
            upstream.sendall(data)
            remaining -= len(data)

    def _relay_body(self, upstream):
        length = self.headers.get("Content-Length")
        if length is not None:
            self._copy_exact(upstream, int(length))
            return
        if self.headers.get("Transfer-Encoding") is None:
            return
        while True:
            size_line = self.rfile.readline(MAX_CHUNK_LINE_BYTES)
            if not size_line.endswith(b"\n"):
                raise ValueError("malformed chunk size line")
            upstream.sendall(size_line)
            chunk_size = int(size_line.split(b";", 1)[0].strip(), 16)
            if chunk_size == 0:
                break
            self._copy_exact(upstream, chunk_size + len(b"\r\n"))
        while True:
            trailer_line = self.rfile.readline(MAX_CHUNK_LINE_BYTES)
            if not trailer_line.endswith(b"\n"):
                raise ValueError("malformed chunked trailer")
            upstream.sendall(trailer_line)
            if trailer_line in (b"\r\n", b"\n"):
                return

    def _relay_response(self, upstream):
        # Parsed rather than copied raw: the response ends where its framing
        # says, even if the upstream ignores "Connection: close".
        response = http.client.HTTPResponse(upstream, method=self.command)
        try:
            response.begin()
            self.send_response_only(response.status, response.reason)
            for name, value in response.getheaders():
                lowered = name.lower()
                if lowered in DROPPED_RESPONSE_HEADERS or (response.chunked and lowered == "content-length"):
                    continue
                self.send_header(name, value)
            self.send_header("Connection", "close")
            self.end_headers()
            while True:
                data = response.read(RELAY_BUFFER_BYTES)
                if not data:
                    return
                self.wfile.write(data)
        finally:
            response.close()


class _ProxyServerMixin(socketserver.ThreadingMixIn):
    daemon_threads = True

    def _init_proxy(self, destination_filter, idle_timeout):
        self.destination_filter = destination_filter
        self.idle_timeout = idle_timeout


class ThreadingTCPProxyServer(_ProxyServerMixin, socketserver.TCPServer):
    """Proxy on a loopback TCP address; refuses any non-loopback bind."""

    allow_reuse_address = True

    def __init__(self, host, port, destination_filter, idle_timeout=DEFAULT_TIMEOUT_SECONDS):
        address = ipaddress.ip_address(host)
        if not address.is_loopback:
            raise ValueError("refusing to listen on non-loopback address %s" % host)
        self.address_family = socket.AF_INET6 if address.version == 6 else socket.AF_INET
        self._init_proxy(destination_filter, idle_timeout)
        socketserver.TCPServer.__init__(self, (host, port), ProxyRequestHandler)

    def describe(self):
        host, port = self.server_address[:2]
        return "tcp %s:%d" % ("[%s]" % host if ":" in host else host, port)


class ThreadingUnixProxyServer(_ProxyServerMixin, socketserver.UnixStreamServer):
    """Proxy on an owner-only UNIX domain socket, removed again on close."""

    def __init__(self, path, destination_filter, idle_timeout=DEFAULT_TIMEOUT_SECONDS):
        self._socket_identity = None
        self._init_proxy(destination_filter, idle_timeout)
        socketserver.UnixStreamServer.__init__(self, path, ProxyRequestHandler)

    def server_bind(self):
        path = self.server_address
        try:
            existing = os.lstat(path)
        except FileNotFoundError:
            existing = None
        if existing is not None:
            if not stat.S_ISSOCK(existing.st_mode):
                raise OSError("refusing to replace non-socket %s" % path)
            os.unlink(path)
        previous_umask = os.umask(UNIX_SOCKET_UMASK)
        try:
            socketserver.UnixStreamServer.server_bind(self)
        finally:
            os.umask(previous_umask)
        bound = os.lstat(path)
        self._socket_identity = (bound.st_dev, bound.st_ino)

    def server_close(self):
        socketserver.UnixStreamServer.server_close(self)
        if self._socket_identity is None:
            return
        try:
            current = os.lstat(self.server_address)
        except FileNotFoundError:
            return
        if (current.st_dev, current.st_ino) == self._socket_identity:
            os.unlink(self.server_address)
        self._socket_identity = None

    def describe(self):
        return "unix %s" % self.server_address


def parse_args(argv):
    parser = argparse.ArgumentParser(description="Sandbox egress proxy (CONNECT + HTTP) with destination filtering.")
    parser.add_argument("--socket", help="listen on this UNIX domain socket path")
    parser.add_argument("--host", default=DEFAULT_HOST, help="loopback TCP address (default %(default)s)")
    parser.add_argument("--port", type=int, help="TCP port; 0 picks a free one")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_SECONDS,
                        help="upstream connect and idle timeout in seconds (default %(default)s)")
    parser.add_argument("--log-level", default="INFO", choices=("DEBUG", "INFO", "WARNING", "ERROR"))
    args = parser.parse_args(argv)
    if args.socket is None and args.port is None:
        parser.error("give --socket and/or --port")
    if args.port is not None and not 0 <= args.port <= MAX_PORT:
        parser.error("--port must be 0-%d" % MAX_PORT)
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    return args


def build_servers(args, destination_filter):
    servers = []
    try:
        if args.socket is not None:
            servers.append(ThreadingUnixProxyServer(args.socket, destination_filter, args.timeout))
        if args.port is not None:
            servers.append(ThreadingTCPProxyServer(args.host, args.port, destination_filter, args.timeout))
    except BaseException:
        for server in servers:
            server.server_close()
        raise
    return servers


def main(argv=None):
    args = parse_args(argv)
    logging.basicConfig(stream=sys.stderr, level=args.log_level,
                        format="ai_network_proxy: %(levelname)s %(message)s")
    try:
        servers = build_servers(args, DestinationFilter())
    except (OSError, ValueError) as error:
        print("ai_network_proxy: cannot listen: %s" % error, file=sys.stderr)
        return 1
    stop = threading.Event()
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, lambda _signum, _frame: stop.set())
    threads = [threading.Thread(target=server.serve_forever, daemon=True) for server in servers]
    try:
        for thread in threads:
            thread.start()
        for server in servers:
            print("READY %s" % server.describe(), flush=True)
        stop.wait()
        LOG.info("shutting down")
    finally:
        for server, thread in zip(servers, threads):
            if thread.is_alive():
                server.shutdown()
            server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
