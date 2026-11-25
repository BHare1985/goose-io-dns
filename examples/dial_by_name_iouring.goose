// Dial a host name on goose-io-iouring, which supplies the name-resolution capability (contract 0.5): the loop looks the name up
// itself, so this needs no thread and no goose-io-dns library. It runs goose-io's own dial_by_name example (resolve, then try each
// address in turn), prints the outcome and stops.
//
//     goose build examples/dial_by_name_iouring.goose -o /tmp/dial_by_name_iouring
//     /tmp/dial_by_name_iouring localhost 22          # prints "open after 1 dial(s)", or "failed"
import std;
import os;
import goose_io from "github.com/BHare1985/goose-io@apply-name-resolution";
import goose_io.examples.capabilities.dial_by_name;
import iouring from "github.com/BHare1985/goose-io-iouring@main";

fn main() {
    guard arg_count() > 2 else { print("usage: dial_by_name_iouring <host> <port>"); exit(2); }
    var host:      u8[>..] = [];
    var port_text: u8[>..] = [];
    arg(1, host);
    arg(2, port_text);
    var port = 0;
    for ch in port_text { if ch >= '0' && ch <= '9' { port = port * 10 + (ch - '0'); } }

    var io = iouring::Loop { .. };
    goose_io::require_core(io);
    goose_io::require_name_resolution(io);
    var client = dial_by_name::DialByName { .. };
    if !client.start(io, host[..], port, 2000, 1000) { print("bad name"); exit(2); }
    io.serve() { io, ev =>
        client.dial_event(io, ev);
        if !io.draining() && (client.is_open() || client.failed()) { io.stop(100); }
    };
    if client.is_open() { print("open after ", client.dial_count(), " dial(s)"); } else { print("failed"); exit(1); }
}
