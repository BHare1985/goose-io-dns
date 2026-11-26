// Forward one TCP port to backends given by host name, on the unmodified goose-io-tcpproxy and goose-io-epoll-ext.
//
//     goose build examples/forward_by_name.goose
//     ./examples/forward_by_name 0.0.0.0:8080 db.internal:5432
//
// The first argument is the address to listen on, the second the backend as host:port (a name or an address). The backend's
// addresses are the target's slots, so a name with several addresses is balanced round robin. The
// proxy takes addresses only, so main resolves each name before the workers start and a thread of this program asks again
// every REFRESH_MS: when the answer changes it tells the workers with tcprouter's own message `SetAddr`, which replaces
// the address of a target slot while the router runs. The proxy is not changed and the router never sees a name.
//
// A name that answers with more than 8 addresses keeps the first 8, and a name that stops resolving keeps its last answer.
import tcprouter from "../../goose-io-tcpproxy";
import goose_io from "github.com/BHare1985/goose-io@apply-name-resolution";
import epoll_ext from "github.com/BHare1985/goose-io-epoll-ext@main";
import goose_io_dns from "..";
import gslib from "SorinS/gslib@v0.9.3";
import os;

let REFRESH_MS:   i64 = 30000;
let MAX_BACKENDS: i64 = 8;

struct Watch {
    names:   goose_io_dns::Name[..8]          = [],
    answers: goose_io_dns::Endpoint[..8][..8] = [],
}

thread_fn worker(cfg: tcprouter::Config, index: i64) {
    var io = epoll_ext::Loop { .. };
    var w = tcprouter::Worker { .. };
    if !w.start(io, cfg, index) {
        print("worker ", index, ": ", w.error);
        return;
    }
    io.attach(index);
    io.serve() { io, ev => w.on_event(io, ev); };
}

// Asks again for each name; on a change, posts the new addresses (an empty slot clears the ones that are gone).
thread_fn refresher(watch: Watch) {
    var io = epoll_ext::Loop { .. };                    // only names the wake operation; it never runs
    var w = watch;
    loop {
        sleep_ms(REFRESH_MS);
        for t in w.names.len {
            let now = goose_io_dns::lookup(w.names[t], MAX_BACKENDS);
            if now.len == 0 || goose_io_dns::same(now[..], w.answers[t][..]) { continue; }
            for slot in MAX_BACKENDS {
                var a = tcprouter::Addr { text: [] };
                if slot < now.len { a.text.append(now[slot].text[..]); }
                tcprouter::post(io, tcprouter::Message.SetAddr { target: t as u16, slot: slot as u8, addr: a });
            }
            w.answers[t].clear();
            for e in now { w.answers[t].push(e); }
        }
    }
}

fn main() {
    let a = args();
    if a.len != 3 {
        print("usage: forward_by_name LISTEN_ADDRESS HOST:PORT");
        exit(2);
    }
    var cfg = tcprouter::Config { .. };
    cfg.listeners.push(tcprouter::Listener { id: 1, addr: tcprouter::addr(a[1]) });
    var watch = Watch { .. };
    for i in 2..a.len {
        var n = goose_io_dns::Name { .. };
        if !goose_io_dns::parse(a[i], 0, n) || n.port == 0 { print("not host:port: ", a[i]); exit(2); }
        let found = goose_io_dns::lookup(n, MAX_BACKENDS);
        if found.len == 0 { print("does not resolve: ", a[i]); exit(2); }
        var t = tcprouter::Target { addrs: [] };
        for e in found { t.addrs.push(tcprouter::addr(e.text[..])); }
        tcprouter::add_target(cfg, t);
        watch.names.push(n);
        var answer: goose_io_dns::Endpoint[..8] = [];
        for e in found { answer.push(e); }
        watch.answers.push(answer);
    }
    cfg.routes.push(tcprouter::any_route(1, tcprouter::Action.Forward { to: 0 }));
    var problems: u8[>..] = [];
    if !tcprouter::check(cfg, problems) {
        print(problems);
        exit(2);
    }
    let n = epoll_ext::cpu_count();
    epoll_ext::spawn(n, cfg, worker);
    tcprouter::workers_ready(n);
    thread_spawn(refresher, watch);
    epoll_ext::wait_for_signal_then_drain(30000);
}
