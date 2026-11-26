// Runs the name-resolution part of goose-io's conformance suite against `Resolving<iouring::Loop>`, with real lookups:
//
//     goose build conformance.goose -o conformance && ./conformance <part> [<two-address name> <first> <second>]
//
// The layer is the event loop under test: the suite's links, listeners and dials go through it to the loop beneath, and the
// name-resolution checks are the layer's own. "localhost" is the name that exists and "no-such-name.invalid" the one that does not.
// The optional arguments name a host name with two addresses and its first and second address as "ip:80" texts, for the check of
// the order (conformance.sh asks getent); without them that check is skipped. The slow-name checks need a lookup that takes a chosen
// time, which a real resolver cannot give, so they run on goose-io's in-memory loop only.
import std;
import os;
import goose_io from "github.com/BHare1985/goose-io@apply-name-resolution";
import goose_io.conformance.suite;
import iouring from "github.com/BHare1985/goose-io-iouring@main";
import goose_io_dns from ".";
import gslib from "SorinS/gslib@v0.9.3";

fn main() {
    var part = 0;
    if arg_count() > 1 {
        var text: u8[>..] = [];
        arg(1, text);
        for c in text { if c >= '0' && c <= '9' { part = part * 10 + (c - '0'); } }
    }
    var pair_name:   u8[>..] = [];
    var pair_first:  u8[>..] = [];
    var pair_second: u8[>..] = [];
    if arg_count() > 4 { arg(2, pair_name); arg(3, pair_first); arg(4, pair_second); }

    var base = iouring::Loop { .. };
    var io = goose_io_dns::Resolving<iouring::Loop> { inner: base };
    goose_io::require_core(io);
    goose_io::require_name_resolution(io);
    let fixture = goose_io_conformance::Fixture { silent: "", held: "", refused: "", answers: "", unix: "", found: "localhost", missing: "no-such-name.invalid", pair: pair_name[..], pair_first: pair_first[..], pair_second: pair_second[..] };
    exit(goose_io_conformance::conformance_name_resolution_part(io, fixture, part));
}
