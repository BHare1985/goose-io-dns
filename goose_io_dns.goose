// goose-io-dns: host names for programs built on goose-io. A library, not a loop and not part of goose-io: it asks the
// system resolver (gslib's net::lookup_host, getaddrinfo) for the addresses of a name and hands back `ip:port` text
// that `dial` and the tcpproxy targets take. getaddrinfo blocks and has no timeout, so call it from a thread of its own,
// never from inside a loop's event handler.
//
// `Resolving<Io>` is a layer over any loop that supplies the core (see below): it supplies the name-resolution capability
// (contract 0.5, change `add-name-resolution`) on top of a loop that does not. A loop that does supply it needs none of this.
namespace goose_io_dns;

import std;
import goose_io;
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

// --- the name-resolution capability, as a layer over a loop -----------------------------------------------------------
//
// `Resolving<Io>` presents the contract's name-resolution capability (`resolve`, `resolved_address`, `cancel_resolve`, the event
// `Resolved`) over a loop `Io` that does not supply it, and passes every other operation and event to the loop unchanged. The
// application composes it:
//
//     var base = iouring::Loop { .. };
//     var io = goose_io_dns::Resolving<iouring::Loop> { inner: base };
//     io.serve() { io, ev => ... };           // a library that `Uses if supplied: name-resolution` takes `io` as its loop
//
// It needs only the core. Each lookup runs getaddrinfo (`lookup`) on a thread of its own and the answer comes back on a typed
// queue. While a lookup is running the layer asks the loop for an event every POLL_MS (`tick_by`) and reads the queue on every event
// it passes on, so an answer is given within about POLL_MS of its arrival, with or without the loop's `wake` (a thread function
// cannot be generic in Goose, so a lookup thread cannot name the loop type it would ring). Several layers (a loop per core) can
// share a process: each tags its lookups and puts back the answers that are not its.
//
// An address is IPv4 only and at most MAX_ADDRESSES of them, in the order `lookup` gives. A lookup that is still running when the
// loop starts to drain ends Cancelled. `timeout_ms` of 0 asks for `default_timeout_ms` (5000 unless set).
let MAX_ADDRESSES: i64 = 8;
let POLL_MS:       i64 = 5;

// What crosses to a lookup thread, and what comes back: flat.
struct _Request { owner: i64 = 0, query: u32 = 0, port: i64 = 0, host: u8[..255] = [] }
struct _Answer { owner: i64 = 0, query: u32 = 0, count: i64 = 0, addrs: Endpoint[..8] = [] }

fn _answer(r: const _Request&) {
    var n = Name { .. };
    n.host.append(r.host[..]);
    n.port = r.port;
    let found = lookup(n, MAX_ADDRESSES);
    var a = _Answer { owner: r.owner, query: r.query, count: 0 };
    for e in found { a.addrs.push(e); }
    a.count = a.addrs.len;
    qput(a);
}

thread_fn _lookup_thread(r: _Request) { _answer(r); }

thread_fn _marker() {}

struct _Lookup {
    query:    u32                     = 0,
    deadline: i64                     = 0,
    running:  bool                    = false,
    status:   goose_io::ResolveStatus = goose_io::ResolveStatus.Failed,
    count:    i64                     = 0,
    addrs:    Endpoint[..8]           = [],
}

root struct Resolving<Io> {
    inner:              Io&,
    default_timeout_ms: i64          = 5000,
    owner:              i64          = 0,     // tags this layer's lookups; 0 until the first
    next:               u32          = 1,
    lookups:            _Lookup[>..] = [],
    current:            i64          = -1,    // the lookup whose Resolved is being handled
}

fn _owner<Io>(w: Resolving<Io>&) -> i64 {
    if w.owner == 0 { w.owner = thread_spawn(_marker) as i64 + 1; }
    return w.owner;
}

fn supplies_name_resolution<Io>(w: Resolving<Io>&) -> goose_io::Supplied { return goose_io::Supplied {}; }

fn resolve<Io>(w: Resolving<Io>&, host: const u8[:], port: i64, timeout_ms: i64) -> goose_io::Query {
    guard host.len > 0 && host.len <= 255 && port >= 0 && port <= 65535 && !w.inner.draining() else { return goose_io::Query { .. }; }
    let id = w.next;
    w.next++;
    let ms = if timeout_ms > 0 { timeout_ms } else { w.default_timeout_ms };
    var slot = -1;                                  // a finished slot is reused: the array only grows
    for i in w.lookups.len { if slot < 0 && !w.lookups[i].running && w.lookups[i].query == 0 { slot = i; } }
    if slot < 0 { w.lookups.push(_Lookup { .. }); slot = w.lookups.len - 1; }
    w.lookups[slot].query = id;
    w.lookups[slot].deadline = w.inner.now_ms() + ms;
    w.lookups[slot].running = true;
    w.lookups[slot].count = 0;
    w.lookups[slot].addrs.clear();
    w.inner.tick_by(w.inner.now_ms() + ms);
    var r = _Request { owner: w._owner(), query: id, port: port };
    r.host.append(host);
    thread_spawn(_lookup_thread, r);
    return goose_io::Query { id: id };
}

fn _find<Io>(w: Resolving<Io>&, query: goose_io::Query) -> i64 {
    for i in w.lookups.len { if w.lookups[i].query == query.id && query.id != 0 { return i; } }
    return -1;
}

fn cancel_resolve<Io>(w: Resolving<Io>&, query: goose_io::Query) {
    let i = w._find(query);
    if i >= 0 { w.lookups[i].running = false; w.lookups[i].status = goose_io::ResolveStatus.Cancelled; w.lookups[i].count = 0; w.lookups[i].query = 0; }
}

// Valid only while the Resolved event of `query` is being handled.
fn resolved_address<Io>(w: Resolving<Io>&, query: goose_io::Query, index: i64) -> goose_io::Address {
    var out = goose_io::Address { .. };
    guard w.current >= 0 && w.lookups[w.current].query == query.id && query.id != 0 else { return out; }
    guard index >= 0 && index < w.lookups[w.current].count else { return out; }
    out.text.append(w.lookups[w.current].addrs[index].text[..]);
    return out;
}

// Takes the answers that are this layer's; puts back the others.
fn _take_answers<Io>(w: Resolving<Io>&) {
    var back: _Answer[>..] = [];
    loop {
        let a, got = qpoll<_Answer>();
        if !got { break; }
        if a.owner != w.owner { back.push(a); continue; }
        let i = w._find(goose_io::Query { id: a.query });
        if i < 0 || !w.lookups[i].running { continue; }
        w.lookups[i].running = false;
        w.lookups[i].count = a.count;
        w.lookups[i].status = if a.count > 0 { goose_io::ResolveStatus.Found } else { goose_io::ResolveStatus.NotFound };
        for e in a.addrs { w.lookups[i].addrs.push(e); }
    }
    for a in back { qput(a); }
}

// Moves the lookups that have an answer, a timeout, or the drain to their final status.
fn _collect<Io>(w: Resolving<Io>&) {
    w._take_answers();
    let now = w.inner.now_ms();
    let drain = w.inner.draining();
    var waiting = false;
    for &l in w.lookups {
        guard l.running else { continue; }
        if drain { l.running = false; l.status = goose_io::ResolveStatus.Cancelled; l.count = 0; }
        else if now >= l.deadline { l.running = false; l.status = goose_io::ResolveStatus.TimedOut; l.count = 0; }
        else { waiting = true; }
    }
    if waiting { w.inner.tick_by(now + POLL_MS); }       // asks the loop for an event soon, to look at the queue again
}

// serve: the loop's events, with a Resolved event for each lookup that has finished given before the event the loop gave.
fn serve<Io, F>(w: Resolving<Io>&) {
    w.inner.serve() { io, ev =>
        if w.lookups.len > 0 {
            w._collect();
            var i = 0;
            while i < w.lookups.len {
                if !w.lookups[i].running && w.lookups[i].query != 0 {
                    w.current = i;
                    let given: goose_io::Event = goose_io::Event.Resolved { query: goose_io::Query { id: w.lookups[i].query }, status: w.lookups[i].status, count: w.lookups[i].count };
                    F(w, given);
                    w.current = -1;
                    w.lookups[i].query = 0;
                }
                i++;
            }
        }
        F(w, ev);
    };
}

// --- everything else is the loop's ---------------------------------------------------------------------------------

fn listen<Io>(w: Resolving<Io>&, address: const u8[:]) -> goose_io::Listener, goose_io::ListenError { return w.inner.listen(address); }
fn listen_shared<Io>(w: Resolving<Io>&, address: const u8[:]) -> goose_io::Listener, goose_io::ListenError { return w.inner.listen_shared(address); }
fn listener_port<Io>(w: Resolving<Io>&, l: goose_io::Listener) -> u16 { return w.inner.listener_port(l); }
fn stop_listening<Io>(w: Resolving<Io>&, l: goose_io::Listener) { w.inner.stop_listening(l); }
fn dial<Io>(w: Resolving<Io>&, address: const u8[:], connect_ms: i64) -> goose_io::Link { return w.inner.dial(address, connect_ms); }
fn peer_address<Io>(w: Resolving<Io>&, link: goose_io::Link) -> goose_io::Address { return w.inner.peer_address(link); }
fn send_room<Io>(w: Resolving<Io>&, link: goose_io::Link) -> i64 { return w.inner.send_room(link); }
fn max_send<Io>(w: Resolving<Io>&) -> i64 { return w.inner.max_send(); }
fn pause_reading<Io>(w: Resolving<Io>&, link: goose_io::Link, paused: bool) { w.inner.pause_reading(link, paused); }
fn set_keep_open_on_eof<Io>(w: Resolving<Io>&, link: goose_io::Link, keep: bool) { w.inner.set_keep_open_on_eof(link, keep); }
fn shutdown_write<Io>(w: Resolving<Io>&, link: goose_io::Link) { w.inner.shutdown_write(link); }
fn now_ms<Io>(w: Resolving<Io>&) -> i64 { return w.inner.now_ms(); }
fn tick_by<Io>(w: Resolving<Io>&, at_ms: i64) { w.inner.tick_by(at_ms); }
fn stop<Io>(w: Resolving<Io>&, grace_ms: i64) { w.inner.stop(grace_ms); }
fn draining<Io>(w: Resolving<Io>&) -> bool { return w.inner.draining(); }
fn send<Io>(w: Resolving<Io>&, link: goose_io::Link, bytes: const u8[:]) -> goose_io::SendStatus { return w.inner.send(link, bytes); }
fn send2<Io>(w: Resolving<Io>&, link: goose_io::Link, first: const u8[:], second: const u8[:]) -> goose_io::SendStatus { return w.inner.send2(link, first, second); }
fn close<Io>(w: Resolving<Io>&, link: goose_io::Link) { w.inner.close(link); }
fn reset<Io>(w: Resolving<Io>&, link: goose_io::Link) { w.inner.reset(link); }
fn relay<Io>(w: Resolving<Io>&, a: goose_io::Link, b: goose_io::Link) -> goose_io::RelayStatus { return w.inner.relay(a, b); }
fn relayed_bytes<Io>(w: Resolving<Io>&, link: goose_io::Link) -> i64 { return w.inner.relayed_bytes(link); }
fn peek<Io>(w: Resolving<Io>&, link: goose_io::Link) -> const u8[:] { return w.inner.peek(link); }
fn wait_input<Io>(w: Resolving<Io>&, link: goose_io::Link, n: i64) { w.inner.wait_input(link, n); }
fn discard_input<Io>(w: Resolving<Io>&, link: goose_io::Link, n: i64) -> i64 { return w.inner.discard_input(link, n); }
fn discard_unsent<Io>(w: Resolving<Io>&, link: goose_io::Link) -> i64 { return w.inner.discard_unsent(link); }
fn write_deadline<Io>(w: Resolving<Io>&, link: goose_io::Link, at_ms: i64) { w.inner.write_deadline(link, at_ms); }
fn waker<Io>(w: Resolving<Io>&) -> goose_io::Waker { return w.inner.waker(); }
fn wake<Io>(w: Resolving<Io>&, k: goose_io::Waker, value: i64) { w.inner.wake(k, value); }
fn wake_with<Io>(w: Resolving<Io>&, k: goose_io::Waker, value: i64, body: const u8[:]) { w.inner.wake_with(k, value, body); }
fn set_limit<Io>(w: Resolving<Io>&, link: goose_io::Link, kind: goose_io::Limit, ms: i64) { w.inner.set_limit(link, kind, ms); }

fn supplies_half_close<Io>(w: Resolving<Io>&) { return goose_io::has_half_close(w.inner); }
fn supplies_sizing<Io>(w: Resolving<Io>&) { return goose_io::has_sizing(w.inner); }
fn supplies_abort<Io>(w: Resolving<Io>&) { return goose_io::has_abort(w.inner); }
fn supplies_inspection<Io>(w: Resolving<Io>&) { return goose_io::has_inspection(w.inner); }
fn supplies_batching<Io>(w: Resolving<Io>&) { return goose_io::has_batching(w.inner); }
fn supplies_unix<Io>(w: Resolving<Io>&) { return goose_io::has_unix(w.inner); }
fn supplies_relay<Io>(w: Resolving<Io>&) { return goose_io::has_relay(w.inner); }
fn supplies_peek<Io>(w: Resolving<Io>&) { return goose_io::has_peek(w.inner); }
fn supplies_revoke<Io>(w: Resolving<Io>&) { return goose_io::has_revoke(w.inner); }
fn supplies_wake<Io>(w: Resolving<Io>&) { return goose_io::has_wake(w.inner); }
fn supplies_limits<Io>(w: Resolving<Io>&) { return goose_io::has_limits(w.inner); }
fn supplies_shared_listen<Io>(w: Resolving<Io>&) { return goose_io::has_shared_listen(w.inner); }
