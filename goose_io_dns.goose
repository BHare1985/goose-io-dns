// goose-io-dns: host names for programs built on goose-io. A library, not a loop and not part of goose-io: it asks the
// system resolver (gslib's net::lookup_host, getaddrinfo) for the addresses of a name and hands back `ip:port` text
// that `dial` and the tcpproxy targets take. getaddrinfo blocks and has no timeout, so call it from a thread of its own,
// never from inside a loop's event handler.
//
// This is the thread-and-message way to have name resolution on a loop that does not supply the name-resolution
// capability (contract 0.5, change `add-name-resolution`): a loop that does supply it needs none of this.
namespace goose_io_dns;

import std;
import gslib.net;

// An address as text a goose-io `dial` takes: "10.0.0.5:80".
struct Endpoint { text: u8[..48] = [] }

// A name and a port, from "host:port". A bare host gets `default_port`.
struct Name {
    host: u8[..255] = [],
    port: i64       = 0,
}

// Splits "host:port" (or "host", with default_port). False for an empty host, a port outside 1..65535, or text a name
// cannot be (IPv6 literals in brackets are left to the caller: use addresses, not names, for those).
fn parse(text: const u8[:], default_port: i64, out: Name&) -> bool {
    out.host.clear();
    out.port = default_port;
    var colon = -1;
    for i in text.len { if text[i] == ':' { colon = i; } }
    var host_end = text.len;
    if colon >= 0 {
        host_end = colon;
        var port = 0;
        guard colon + 1 < text.len else { return false; }
        for i in colon + 1..text.len {
            guard text[i] >= '0' && text[i] <= '9' && port < 100000 else { return false; }
            port = port * 10 + (text[i] - '0');
        }
        out.port = port;
    }
    guard host_end > 0 && host_end <= 255 && out.port >= 1 && out.port <= 65535 else { return false; }
    out.host.append(text[..host_end]);
    return true;
}

// The IPv4 addresses of `name`, in the order the system gives them, each as "a.b.c.d:port", at most `max`. Empty when the
// name does not resolve. IPv6 answers are skipped (the tcpproxy targets take IPv4 text).
fn lookup(name: const Name&, max: i64) -> Endpoint[>..] {
    var out: Endpoint[>..] = [];
    let found, err = net::lookup_host(name.host[..]);
    if err < 0 { return out; }
    for a in found {
        if out.len >= max { break; }
        let v4 = net::unmap(a);
        if v4.kind != 4 { continue; }
        var e = Endpoint { .. };
        e.text.append(net::addr_string(v4));
        e.text.push(':');
        _push_decimal(e.text, name.port);
        out.push(e);
    }
    return out;
}

fn _push_decimal(out: u8[..48]&, n: i64) {
    var digits: u8[8] = [0; 8];
    var k = 0;
    var v = n;
    if v == 0 { out.push('0'); return; }
    while v > 0 { digits[k] = ('0' + (v % 10)) as u8; v = v / 10; k++; }
    while k > 0 { k--; out.push(digits[k]); }
}

// Whether two answers hold the same addresses in the same order (a refresh posts only when this is false).
fn same(a: const Endpoint[:], b: const Endpoint[:]) -> bool {
    guard a.len == b.len else { return false; }
    for i in a.len { if a[i].text[..] != b[i].text[..] { return false; } }
    return true;
}
