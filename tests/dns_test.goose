// dns: splitting "host:port" and looking a name up through the system resolver (localhost and an address literal need no network).
import std;
import goose_io_dns from "..";
import goose_io from "github.com/BHare1985/goose-io@apply-name-resolution";
import gslib from "SorinS/gslib@v0.9.3";

var failed = 0;
fn check(ok: bool, what: const u8[:]) { if !ok { print("FAIL: ", what); failed++; } }

fn main() {
    var n = goose_io_dns::Name { .. };
    check(goose_io_dns::parse("db.example:5432", 80, n) && n.host[..] == "db.example" && n.port == 5432, "host and port");
    check(goose_io_dns::parse("db.example", 80, n) && n.port == 80, "default port");
    check(!goose_io_dns::parse(":80", 80, n), "empty host");
    check(!goose_io_dns::parse("a:0", 80, n), "port 0");
    check(!goose_io_dns::parse("a:65536", 80, n), "port too big");
    check(!goose_io_dns::parse("a:", 80, n), "empty port");

    goose_io_dns::parse("127.0.0.1:9000", 80, n);
    let lit = goose_io_dns::lookup(n, 8);
    check(lit.len == 1 && lit[0].text[..] == "127.0.0.1:9000", "an address literal comes back as it is, with the port");
    goose_io_dns::parse("localhost:7", 80, n);
    let lo = goose_io_dns::lookup(n, 8);
    check(lo.len >= 1 && lo[0].text[..] == "127.0.0.1:7", "localhost");
    goose_io_dns::parse("no-such-name.invalid:80", 80, n);
    check(goose_io_dns::lookup(n, 8).len == 0, "a name that does not resolve gives nothing");
    check(goose_io_dns::same(lit[..], lit[..]) && !goose_io_dns::same(lit[..], lo[..]) || lo[0].text[..] == lit[0].text[..], "same compares answers");
    if failed > 0 { print(failed, " failed"); exit(1); }
    print("ok");
}
