"""Unit tests for bin/ai_wrapper_data/ai_network_proxy.py (#76, L4).

Offline: name lookups go through a fake resolver, upstreams are local mock
servers on 127.0.0.1 (the proxies that must reach them use a filter with
only loopback unblocked), listeners use ephemeral ports and temp UNIX
socket paths. Linux and macOS. Run: python3 -I -B tests/test_network_proxy.py
"""

import ipaddress
import json
import logging
import os
import select
import shutil
import signal
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from http.server import BaseHTTPRequestHandler

HELPER_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "ai_wrapper_data")
HELPER_PATH = os.path.join(HELPER_DIR, "ai_network_proxy.py")
sys.dont_write_bytecode = True  # never leave __pycache__ in the deployed bin dir
sys.path.insert(0, HELPER_DIR)
import ai_network_proxy as proxy  # noqa: E402  (path set up above)

proxy.LOG.addHandler(logging.NullHandler())  # keep test output clean
proxy.LOG.propagate = False

SOCKET_TIMEOUT_SECONDS = 5.0
SERVER_POLL_INTERVAL_SECONDS = 0.05
STARTUP_TIMEOUT_SECONDS = 10.0
PROXY_IDLE_TIMEOUT_SECONDS = 5.0
LOOPBACK_V4 = ipaddress.ip_network("127.0.0.0/8")
UPSTREAM_NAME = "upstream.test"
METADATA_NAME = "metadata.test"
DUAL_STACK_LOOPBACK_NAME = "dual.test"

BLOCKED_ADDRESSES = (
    # Loopback
    "127.0.0.1", "127.0.0.53", "127.255.255.255", "::1",
    # Link-local / cloud metadata
    "169.254.169.254", "169.254.0.1", "fe80::1", "febf::1",
    # RFC 1918
    "10.0.0.1", "10.255.255.255", "172.16.0.1", "172.31.255.255", "192.168.0.1", "192.168.255.255",
    # RFC 6598
    "100.64.0.1", "100.127.255.255",
    # ULA
    "fc00::1", "fd00::1", "fdff:ffff::1",
    # Unspecified, "this network", multicast, reserved, IPv4-compatible
    "0.0.0.0", "0.1.2.3", "224.0.0.1", "239.255.255.250", "240.0.0.1", "255.255.255.255",
    "::", "ff02::1", "::127.0.0.1",
    # IPv4-mapped IPv6
    "::ffff:127.0.0.1", "::ffff:169.254.169.254", "::ffff:192.168.1.1", "::ffff:10.0.0.1",
    "::ffff:100.64.0.1",
    # NAT64 well-known prefix and 6to4 carrying a blocked IPv4
    "64:ff9b::7f00:1", "64:ff9b::a9fe:a9fe", "2002:7f00:1::1", "2002:a9fe:a9fe::1",
)
ALLOWED_ADDRESSES = (
    "8.8.8.8", "1.1.1.1", "93.184.216.34", "172.15.255.255", "172.32.0.1", "100.63.255.255",
    "100.128.0.1", "169.253.255.255", "11.0.0.1", "192.167.255.255",
    "2606:4700:4700::1111", "2001:4860:4860::8888", "fbff::1", "fec0::1",
    "::ffff:8.8.8.8", "64:ff9b::808:808", "2002:808:808::1",
)


def addrinfo(*addresses, port=80):
    """Build getaddrinfo-style results for literal addresses."""
    infos = []
    for text in addresses:
        address = ipaddress.ip_address(text.split("%", 1)[0])
        if address.version == 4:
            infos.append((socket.AF_INET, socket.SOCK_STREAM, 6, "", (text, port)))
        else:
            infos.append((socket.AF_INET6, socket.SOCK_STREAM, 6, "", (text, port, 0, 0)))
    return infos


class FakeResolver:
    """getaddrinfo stand-in: names map to address lists, numeric hosts pass through."""

    def __init__(self, names):
        self.names = names
        self.calls = []

    def __call__(self, host, port, family=0, socktype=0):
        self.calls.append((host, port))
        if host in self.names:
            return addrinfo(*self.names[host], port=port)
        try:
            ipaddress.ip_address(host)
        except ValueError:
            raise socket.gaierror(socket.EAI_NONAME, "Name or service not known")
        return addrinfo(host, port=port)


def loopback_allowed_filter():
    """Default policy minus 127.0.0.0/8, so local mock upstreams are reachable."""
    resolver = FakeResolver({
        UPSTREAM_NAME: ["127.0.0.1"],
        METADATA_NAME: ["169.254.169.254"],
        DUAL_STACK_LOOPBACK_NAME: ["127.0.0.1", "fd00::1"],
    })
    networks = [network for network in proxy.BLOCKED_NETWORKS if network != LOOPBACK_V4]
    return proxy.DestinationFilter(networks, resolver)


class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            data = self.request.recv(proxy.RELAY_BUFFER_BYTES)
            if not data:
                return
            self.request.sendall(data)


class EchoServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


class RecordingHTTPHandler(BaseHTTPRequestHandler):
    """Answers with a JSON echo of what reached the upstream."""

    protocol_version = "HTTP/1.1"

    def log_message(self, format, *args):  # noqa: A002
        pass

    def _echo(self):
        if self.path == "/chunked-response":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"4\r\nabcd\r\n3\r\nefg\r\n0\r\n\r\n")
            return
        if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
            body = b""
            while True:
                size = int(self.rfile.readline().split(b";")[0], 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n"):
                        pass
                    break
                body += self.rfile.read(size)
                self.rfile.readline()
        else:
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        payload = json.dumps({
            "method": self.command,
            "path": self.path,
            "headers": [[name.lower(), value] for name, value in self.headers.items()],
            "body": body.decode("utf-8"),
        }).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "keep-alive")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(payload)

    do_GET = do_POST = do_HEAD = do_PUT = _echo


class RecordingHTTPServer(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


def start_server(server):
    thread = threading.Thread(target=server.serve_forever, args=(SERVER_POLL_INTERVAL_SECONDS,), daemon=True)
    thread.start()
    return thread


def stop_server(server, thread):
    server.shutdown()
    server.server_close()
    thread.join(SOCKET_TIMEOUT_SECONDS)


def read_until_closed(sock):
    chunks = []
    while True:
        data = sock.recv(proxy.RELAY_BUFFER_BYTES)
        if not data:
            return b"".join(chunks)
        chunks.append(data)


def read_head(sock):
    """Read up to and including the blank line that ends a response head."""
    data = b""
    while b"\r\n\r\n" not in data:
        chunk = sock.recv(1)
        if not chunk:
            break
        data += chunk
    return data


def split_response(raw):
    head, _, body = raw.partition(b"\r\n\r\n")
    status_line = head.split(b"\r\n", 1)[0].decode("latin-1")
    return int(status_line.split()[1]), head.decode("latin-1"), body


class AddressPolicyTests(unittest.TestCase):
    def setUp(self):
        self.filter = proxy.DestinationFilter()

    def test_blocked_ranges(self):
        for address in BLOCKED_ADDRESSES:
            with self.subTest(address=address):
                self.assertTrue(self.filter.is_blocked(address))

    def test_public_addresses_allowed(self):
        for address in ALLOWED_ADDRESSES:
            with self.subTest(address=address):
                self.assertFalse(self.filter.is_blocked(address))

    def test_zone_index_is_ignored(self):
        self.assertTrue(self.filter.is_blocked("fe80::1%eth0"))

    def test_every_required_range_is_listed(self):
        required = ("127.0.0.0/8", "::1/128", "169.254.0.0/16", "fe80::/10", "10.0.0.0/8",
                    "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7")
        listed = set(str(network) for network in proxy.BLOCKED_NETWORKS)
        for cidr in required:
            with self.subTest(cidr=cidr):
                self.assertIn(cidr, listed)

    def test_mapped_ipv4_is_unwrapped(self):
        self.assertEqual(proxy.embedded_ipv4(ipaddress.ip_address("::ffff:169.254.169.254")),
                         ipaddress.ip_address("169.254.169.254"))
        self.assertEqual(proxy.embedded_ipv4(ipaddress.ip_address("64:ff9b::7f00:1")),
                         ipaddress.ip_address("127.0.0.1"))
        self.assertIsNone(proxy.embedded_ipv4(ipaddress.ip_address("2606:4700:4700::1111")))
        self.assertIsNone(proxy.embedded_ipv4(ipaddress.ip_address("8.8.8.8")))

    def test_reason_names_range(self):
        reason = self.filter.blocked_reason(ipaddress.ip_address("::ffff:169.254.169.254"))
        self.assertIn("169.254.0.0/16", reason)


class ResolutionTests(unittest.TestCase):
    def make_filter(self, names):
        return proxy.DestinationFilter(resolver=FakeResolver(names))

    def test_public_dual_stack_host_allowed(self):
        name = "public-%s.test" % uuid.uuid4().hex
        destination_filter = self.make_filter({name: ["93.184.216.34", "2606:2800:220:1::1"]})
        targets = destination_filter.resolve(name, 443)
        self.assertEqual([sockaddr[0] for _family, sockaddr in targets],
                         ["93.184.216.34", "2606:2800:220:1::1"])
        self.assertEqual([family for family, _sockaddr in targets], [socket.AF_INET, socket.AF_INET6])

    def test_any_blocked_address_fails_closed(self):
        cases = (
            ["93.184.216.34", "::1"],
            ["2606:2800:220:1::1", "127.0.0.1"],
            ["8.8.8.8", "169.254.169.254"],
            ["8.8.8.8", "::ffff:10.0.0.1"],
            ["192.168.1.1", "8.8.8.8"],
        )
        for addresses in cases:
            name = "mixed-%s.test" % uuid.uuid4().hex
            with self.subTest(addresses=addresses):
                with self.assertRaises(proxy.DestinationBlocked) as raised:
                    self.make_filter({name: addresses}).resolve(name, 443)
                self.assertIn(name, str(raised.exception))

    def test_numeric_spellings_are_checked_after_resolution(self):
        # Real getaddrinfo, numeric hosts only: no DNS traffic.
        destination_filter = proxy.DestinationFilter()
        for host in ("127.0.0.1", "2130706433", "0x7f.1", "::ffff:127.0.0.1", "0"):
            with self.subTest(host=host):
                with self.assertRaises(proxy.DestinationBlocked):
                    destination_filter.resolve(host, 80)

    def test_unresolvable_host(self):
        with self.assertRaises(proxy.DestinationUnresolvable):
            self.make_filter({}).resolve("missing-%s.test" % uuid.uuid4().hex, 80)

    def test_empty_resolution(self):
        destination_filter = proxy.DestinationFilter(resolver=lambda *args: [])
        with self.assertRaises(proxy.DestinationUnresolvable):
            destination_filter.resolve("empty.test", 80)

    def test_unparseable_resolved_address_blocked(self):
        resolver = lambda *args: [(socket.AF_INET, socket.SOCK_STREAM, 6, "", ("not-an-ip", 80))]
        with self.assertRaises(proxy.DestinationBlocked):
            proxy.DestinationFilter(resolver=resolver).resolve("odd.test", 80)

    def test_non_ip_family_blocked(self):
        resolver = lambda *args: [(socket.AF_UNIX, socket.SOCK_STREAM, 0, "", ("/tmp/x",))]
        with self.assertRaises(proxy.DestinationBlocked):
            proxy.DestinationFilter(resolver=resolver).resolve("odd.test", 80)

    def test_invalid_host_text(self):
        with self.assertRaises(proxy.DestinationUnresolvable):
            proxy.DestinationFilter().resolve("bad\x00host", 80)


class AuthorityTests(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(proxy.parse_authority("Example.COM:443"), ("example.com", 443))
        self.assertEqual(proxy.parse_authority("[2606:4700::1]:8443"), ("2606:4700::1", 8443))
        self.assertEqual(proxy.parse_authority("example.com", 80), ("example.com", 80))

    def test_invalid(self):
        for authority in ("example.com", "example.com:0", "example.com:65536", "example.com:x",
                          "user@example.com:443", "example.com:443/path", ":443", "[::1:443"):
            with self.subTest(authority=authority):
                with self.assertRaises(ValueError):
                    proxy.parse_authority(authority)


class ProxyHarness(unittest.TestCase):
    """Starts a TCP proxy plus echo and HTTP upstreams on loopback."""

    destination_filter_factory = staticmethod(loopback_allowed_filter)

    def setUp(self):
        self.echo = EchoServer(("127.0.0.1", 0), EchoHandler)
        self.echo_thread = start_server(self.echo)
        self.http = RecordingHTTPServer(("127.0.0.1", 0), RecordingHTTPHandler)
        self.http_thread = start_server(self.http)
        self.proxy = proxy.ThreadingTCPProxyServer("127.0.0.1", 0, self.destination_filter_factory(),
                                                   PROXY_IDLE_TIMEOUT_SECONDS)
        self.proxy_thread = start_server(self.proxy)

    def tearDown(self):
        stop_server(self.proxy, self.proxy_thread)
        stop_server(self.http, self.http_thread)
        stop_server(self.echo, self.echo_thread)

    def connect(self):
        client = socket.create_connection(self.proxy.server_address[:2], SOCKET_TIMEOUT_SECONDS)
        self.addCleanup(client.close)
        return client

    def exchange(self, request):
        client = self.connect()
        client.sendall(request)
        return split_response(read_until_closed(client))


class ConnectTunnelTests(ProxyHarness):
    def test_tunnel_relays_both_ways(self):
        client = self.connect()
        client.sendall(("CONNECT %s:%d HTTP/1.1\r\nHost: x\r\n\r\n" % (UPSTREAM_NAME, self.echo.server_address[1])).encode())
        head = read_head(client)
        self.assertTrue(head.startswith(b"HTTP/1.1 200 Connection Established"), head)
        for _ in range(3):
            payload = uuid.uuid4().bytes * 1024
            client.sendall(payload)
            received = b""
            while len(received) < len(payload):
                received += client.recv(proxy.RELAY_BUFFER_BYTES)
            self.assertEqual(received, payload)

    def test_bytes_sent_with_connect_head_reach_upstream(self):
        client = self.connect()
        marker = uuid.uuid4().hex.encode()
        client.sendall(("CONNECT %s:%d HTTP/1.1\r\n\r\n" % (UPSTREAM_NAME, self.echo.server_address[1])).encode() + marker)
        head = read_head(client)
        self.assertIn(b" 200 ", head)
        received = b""
        while len(received) < len(marker):
            received += client.recv(proxy.RELAY_BUFFER_BYTES)
        self.assertEqual(received, marker)

    def test_half_close_is_propagated(self):
        client = self.connect()
        client.sendall(("CONNECT %s:%d HTTP/1.1\r\n\r\n" % (UPSTREAM_NAME, self.echo.server_address[1])).encode())
        read_head(client)
        client.sendall(b"last words")
        client.shutdown(socket.SHUT_WR)
        self.assertEqual(read_until_closed(client), b"last words")

    def test_blocked_destinations_get_403(self):
        for target in ("%s:443" % METADATA_NAME, "169.254.169.254:80", "[::ffff:169.254.169.254]:80",
                       "10.0.0.1:443", "[fd00::1]:443", "%s:443" % DUAL_STACK_LOOPBACK_NAME):
            with self.subTest(target=target):
                code, head, body = self.exchange(("CONNECT %s HTTP/1.1\r\n\r\n" % target).encode())
                self.assertEqual(code, 403)
                self.assertIn("Connection: close", head)
                self.assertIn(b"blocked by sandbox network policy", body)

    def test_unresolvable_gets_502(self):
        code, _head, body = self.exchange(b"CONNECT nowhere.test:443 HTTP/1.1\r\n\r\n")
        self.assertEqual(code, 502)
        self.assertIn(b"cannot resolve", body)

    def test_refused_upstream_gets_502(self):
        spare = socket.socket()
        spare.bind(("127.0.0.1", 0))
        closed_port = spare.getsockname()[1]
        spare.close()
        code, _head, _body = self.exchange(("CONNECT %s:%d HTTP/1.1\r\n\r\n" % (UPSTREAM_NAME, closed_port)).encode())
        self.assertEqual(code, 502)

    def test_bad_authority_gets_400(self):
        code, _head, _body = self.exchange(b"CONNECT example.com HTTP/1.1\r\n\r\n")
        self.assertEqual(code, 400)


class DefaultPolicyConnectTests(ProxyHarness):
    """Real default policy: the loopback upstream itself is unreachable."""

    destination_filter_factory = staticmethod(proxy.DestinationFilter)

    def test_loopback_upstream_refused(self):
        for host in ("127.0.0.1", "localhost", "2130706433"):
            with self.subTest(host=host):
                code, _head, _body = self.exchange(("CONNECT %s:%d HTTP/1.1\r\n\r\n" % (host, self.echo.server_address[1])).encode())
                self.assertIn(code, (403, 502))
                if host != "localhost":
                    self.assertEqual(code, 403)

    def test_loopback_http_refused(self):
        code, _head, _body = self.exchange(("GET http://127.0.0.1:%d/ HTTP/1.1\r\nHost: x\r\n\r\n" % self.http.server_address[1]).encode())
        self.assertEqual(code, 403)


class HTTPForwardingTests(ProxyHarness):
    def upstream_url(self, path):
        return "http://%s:%d%s" % (UPSTREAM_NAME, self.http.server_address[1], path)

    def test_get_forwarded_with_origin_form_and_clean_headers(self):
        request = (
            "GET %s HTTP/1.1\r\n"
            "Host: ignored.example\r\n"
            "Proxy-Authorization: Basic c2VjcmV0\r\n"
            "Proxy-Connection: keep-alive\r\n"
            "Connection: keep-alive, X-Hop\r\n"
            "X-Hop: drop-me\r\n"
            "X-Kept: %s\r\n\r\n" % (self.upstream_url("/a/b?q=1&r=2"), uuid.uuid4().hex)
        ).encode()
        code, head, body = self.exchange(request)
        self.assertEqual(code, 200, head)
        echoed = json.loads(body)
        headers = dict(echoed["headers"])
        self.assertEqual(echoed["method"], "GET")
        self.assertEqual(echoed["path"], "/a/b?q=1&r=2")
        self.assertEqual(headers["host"], "%s:%d" % (UPSTREAM_NAME, self.http.server_address[1]))
        self.assertEqual(headers["connection"], "close")
        for dropped in ("proxy-authorization", "proxy-connection", "x-hop"):
            self.assertNotIn(dropped, headers)
        self.assertIn("x-kept", headers)

    def test_proxy_closes_client_connection_after_response(self):
        client = self.connect()
        client.sendall(("GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % self.upstream_url("/")).encode())
        code, _head, _body = split_response(read_until_closed(client))
        self.assertEqual(code, 200)

    def test_empty_path_becomes_slash(self):
        url = "http://%s:%d" % (UPSTREAM_NAME, self.http.server_address[1])
        code, _head, body = self.exchange(("GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % url).encode())
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)["path"], "/")

    def test_post_content_length_body(self):
        payload = uuid.uuid4().hex * 100
        request = ("POST %s HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n%s"
                   % (self.upstream_url("/post"), len(payload), payload)).encode()
        code, _head, body = self.exchange(request)
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)["body"], payload)

    def test_put_chunked_body(self):
        request = ("PUT %s HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
                   "5\r\nhello\r\n6;ext=1\r\n world\r\n0\r\nX-Trailer: t\r\n\r\n" % self.upstream_url("/put")).encode()
        code, _head, body = self.exchange(request)
        self.assertEqual(code, 200)
        self.assertEqual(json.loads(body)["body"], "hello world")

    def test_expect_continue_is_answered_by_proxy(self):
        client = self.connect()
        payload = b"abc"
        client.sendall(("POST %s HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\nContent-Length: 3\r\n\r\n"
                        % self.upstream_url("/e")).encode())
        self.assertIn(b" 100 ", read_head(client))
        client.sendall(payload)
        code, _head, body = split_response(read_until_closed(client))
        self.assertEqual(code, 200)
        echoed = json.loads(body)
        self.assertEqual(echoed["body"], "abc")
        self.assertNotIn("expect", dict(echoed["headers"]))

    def test_chunked_response_is_decoded_and_close_delimited(self):
        code, head, body = self.exchange(("GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % self.upstream_url("/chunked-response")).encode())
        self.assertEqual(code, 200)
        self.assertNotIn("Transfer-Encoding", head)
        self.assertIn("Connection: close", head)
        self.assertEqual(body, b"abcdefg")

    def test_head_forwarded(self):
        code, _head, body = self.exchange(("HEAD %s HTTP/1.1\r\nHost: x\r\n\r\n" % self.upstream_url("/h")).encode())
        self.assertEqual(code, 200)
        self.assertEqual(body, b"")

    def test_blocked_http_destinations_get_403(self):
        for url in ("http://%s/latest/meta-data/" % METADATA_NAME, "http://169.254.169.254/",
                    "http://[fe80::1]/", "http://192.168.1.1:8080/", "http://%s/" % DUAL_STACK_LOOPBACK_NAME):
            with self.subTest(url=url):
                code, _head, body = self.exchange(("GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % url).encode())
                self.assertEqual(code, 403)
                self.assertIn(b"blocked by sandbox network policy", body)

    def test_blocked_userinfo_host(self):
        url = "http://%s@169.254.169.254/" % UPSTREAM_NAME
        code, _head, _body = self.exchange(("GET %s HTTP/1.1\r\nHost: x\r\n\r\n" % url).encode())
        self.assertEqual(code, 403)

    def test_rejected_requests(self):
        cases = (
            ("GET /relative HTTP/1.1\r\nHost: x\r\n\r\n", 400),
            ("GET https://example.com/ HTTP/1.1\r\nHost: x\r\n\r\n", 400),
            ("GET http:///nohost HTTP/1.1\r\nHost: x\r\n\r\n", 400),
            ("POST %s HTTP/1.1\r\nContent-Length: 3\r\nTransfer-Encoding: chunked\r\n\r\n" % self.upstream_url("/"), 400),
            ("POST %s HTTP/1.1\r\nContent-Length: 3\r\nContent-Length: 4\r\n\r\n" % self.upstream_url("/"), 400),
            ("POST %s HTTP/1.1\r\nContent-Length: -1\r\n\r\n" % self.upstream_url("/"), 400),
            ("POST %s HTTP/1.1\r\nTransfer-Encoding: gzip\r\n\r\n" % self.upstream_url("/"), 501),
        )
        for request, expected in cases:
            with self.subTest(request=request.split("\r\n", 1)[0], expected=expected):
                code, _head, _body = self.exchange(request.encode())
                self.assertEqual(code, expected)


class UnixSocketTests(unittest.TestCase):
    def setUp(self):
        # Short base: AF_UNIX paths are limited to ~104 bytes on macOS.
        self.directory = tempfile.mkdtemp(prefix="anp-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.directory, True)
        self.path = os.path.join(self.directory, "%s.sock" % uuid.uuid4().hex[:8])

    def test_serves_and_removes_owner_only_socket(self):
        server = proxy.ThreadingUnixProxyServer(self.path, proxy.DestinationFilter(), PROXY_IDLE_TIMEOUT_SECONDS)
        thread = start_server(server)
        try:
            self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
            client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            client.settimeout(SOCKET_TIMEOUT_SECONDS)
            try:
                client.connect(self.path)
                client.sendall(b"CONNECT 169.254.169.254:80 HTTP/1.1\r\n\r\n")
                code, _head, _body = split_response(read_until_closed(client))
            finally:
                client.close()
            self.assertEqual(code, 403)
            self.assertEqual(server.describe(), "unix %s" % self.path)
        finally:
            stop_server(server, thread)
        self.assertFalse(os.path.lexists(self.path))

    def test_replaces_stale_socket(self):
        stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            stale.bind(self.path)
        finally:
            stale.close()
        server = proxy.ThreadingUnixProxyServer(self.path, proxy.DestinationFilter())
        try:
            self.assertTrue(os.path.exists(self.path))
        finally:
            server.server_close()
        self.assertFalse(os.path.lexists(self.path))

    def test_refuses_to_replace_regular_file(self):
        with open(self.path, "w") as handle:
            handle.write("keep me")
        with self.assertRaises(OSError):
            proxy.ThreadingUnixProxyServer(self.path, proxy.DestinationFilter())
        with open(self.path) as handle:
            self.assertEqual(handle.read(), "keep me")

    def test_close_leaves_foreign_replacement(self):
        server = proxy.ThreadingUnixProxyServer(self.path, proxy.DestinationFilter())
        try:
            os.unlink(self.path)
            with open(self.path, "w") as handle:
                handle.write("other owner")
        finally:
            server.server_close()
        self.assertTrue(os.path.exists(self.path))


class TCPListenerTests(unittest.TestCase):
    def test_non_loopback_bind_refused(self):
        for host in ("0.0.0.0", "::", "192.168.1.10"):
            with self.subTest(host=host):
                with self.assertRaises(ValueError):
                    proxy.ThreadingTCPProxyServer(host, 0, proxy.DestinationFilter())

    def test_hostname_refused(self):
        with self.assertRaises(ValueError):
            proxy.ThreadingTCPProxyServer("localhost", 0, proxy.DestinationFilter())

    def test_ephemeral_port_described(self):
        server = proxy.ThreadingTCPProxyServer("127.0.0.1", 0, proxy.DestinationFilter())
        try:
            port = server.server_address[1]
            self.assertGreater(port, 0)
            self.assertEqual(server.describe(), "tcp 127.0.0.1:%d" % port)
        finally:
            server.server_close()


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp(prefix="anp-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.directory, True)
        self.path = os.path.join(self.directory, "%s.sock" % uuid.uuid4().hex[:8])

    def launch(self, *arguments):
        process = subprocess.Popen([sys.executable, "-I", "-B", HELPER_PATH] + list(arguments),
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
        self.addCleanup(self.reap, process)
        return process

    @staticmethod
    def reap(process):
        if process.poll() is None:
            process.kill()
        process.communicate()

    def read_ready_lines(self, process, count):
        lines = []
        deadline = time.monotonic() + STARTUP_TIMEOUT_SECONDS
        # Unbuffered pipe (bufsize=0): readline never pulls a second line
        # out of select()'s sight.
        while len(lines) < count and time.monotonic() < deadline:
            readable, _, _ = select.select([process.stdout], [], [], deadline - time.monotonic())
            if not readable:
                break
            line = process.stdout.readline()
            if not line:
                break
            lines.append(line.decode().strip())
        return lines

    def test_listens_on_both_and_stops_on_signal(self):
        for signum in (signal.SIGTERM, signal.SIGINT):
            with self.subTest(signal=signum):
                process = self.launch("--socket", self.path, "--port", "0")
                lines = self.read_ready_lines(process, 2)
                self.assertEqual(len(lines), 2, lines)
                self.assertEqual(lines[0], "READY unix %s" % self.path)
                self.assertRegex(lines[1], r"^READY tcp 127\.0\.0\.1:[0-9]+$")
                port = int(lines[1].rsplit(":", 1)[1])
                client = socket.create_connection(("127.0.0.1", port), SOCKET_TIMEOUT_SECONDS)
                try:
                    client.sendall(b"CONNECT 10.0.0.1:443 HTTP/1.1\r\n\r\n")
                    code, _head, _body = split_response(read_until_closed(client))
                finally:
                    client.close()
                self.assertEqual(code, 403)
                process.send_signal(signum)
                _stdout, stderr = process.communicate(timeout=STARTUP_TIMEOUT_SECONDS)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertIn(b"[BLOCKED] CONNECT 10.0.0.1:443", stderr)
                self.assertFalse(os.path.lexists(self.path))

    def test_requires_a_listener(self):
        process = self.launch()
        _stdout, stderr = process.communicate(timeout=STARTUP_TIMEOUT_SECONDS)
        self.assertEqual(process.returncode, 2)
        self.assertIn(b"--socket and/or --port", stderr)

    def test_non_loopback_host_fails(self):
        process = self.launch("--host", "0.0.0.0", "--port", "0")
        _stdout, stderr = process.communicate(timeout=STARTUP_TIMEOUT_SECONDS)
        self.assertEqual(process.returncode, 1)
        self.assertIn(b"non-loopback", stderr)


if __name__ == "__main__":
    unittest.main()
