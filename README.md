# goose-io-dns

Host names for programs on [goose-io](https://github.com/BHare1985/goose-io), as a library beside the event loop, not a
loop and not part of goose-io. It asks the system resolver (gslib's `net::lookup_host`, `getaddrinfo`) for the IPv4
addresses of a name and returns `ip:port` text that `dial` and the tcpproxy targets take.

It does this in two forms:

- **`goose_io_dns::Resolving<Io>`**, a layer over any loop that supplies the core. The loop says it does not supply `name-resolution`;
  the layer does, so an application that links goose-io-dns builds `Resolving<TheLoop>` and a library that `Uses if supplied:
  name-resolution` takes the layer as its loop. Everything but `resolve`, `resolved_address`, `cancel_resolve` and the event
  `Resolved` passes through to the loop, with every capability it supplies.
- **`parse` / `lookup` / `same`**, the plain functions for a program that wants an answer on a thread of its own.

| Needs | Uses if supplied |
|---|---|
| core | nothing it requires: it forwards the loop's other capabilities; it does not use `wake` (see below) |

| | |
|---|---|
| `goose_io_dns::Resolving<Io> { inner: base }` | the layer; `base` is the loop (a variable of the application) |
| `goose_io_dns::parse(text, default_port, name)` | `"host:port"` to a `Name` |
| `goose_io_dns::lookup(name, max)` | the addresses as `Endpoint`s (`"10.0.0.5:5432"`), system order, IPv4 only; empty if the name does not resolve |
| `goose_io_dns::same(a, b)` | whether two answers match (a refresh acts only when they differ) |

Each lookup runs on a thread of its own and the answer comes back on a typed queue. While a lookup runs the layer asks the loop for an
event every 5 ms (`tick_by`), so an answer reaches the library within about 5 ms of its arrival. It does not use the loop's `wake`: a
Goose thread function cannot be generic, so a lookup thread cannot name the loop type it would ring. A lookup is capped at 8 IPv4
addresses; `timeout_ms` 0 means 5000 ms; a lookup still running when the loop starts to drain ends `Cancelled`. Several layers (a loop
per core) may share a process: each tags its lookups and puts back the answers that are not its.

## On goose-io-iouring

[goose-io-iouring](https://github.com/BHare1985/goose-io-iouring) supplies what goose-io-epoll supplies and no name-resolution.
[`examples/dial_by_name_iouring.goose`](examples/dial_by_name_iouring.goose) builds `Resolving<iouring::Loop>` and dials a name
through goose-io's own `dial_by_name` example, which does not know whether the loop or a layer supplies the capability:

    goose build examples/dial_by_name_iouring.goose -o /tmp/dial_by_name_iouring
    /tmp/dial_by_name_iouring localhost 22

`./conformance.sh` runs goose-io's name-resolution conformance part over the layer on real lookups: a name that exists, one that does
not, a cancel, a bad host, a dial by name. The checks that need a slow name (the timeout) or a name with two addresses (the order)
run on goose-io's in-memory loop; here the order check is skipped unless `PAIR_NAME` names a host that has two.

## Forwarding to a host name without changing the proxy

[`examples/forward_by_name.goose`](examples/forward_by_name.goose) runs goose-io-tcpproxy on goose-io-epoll-ext as they
are. The proxy takes addresses only; the program resolves the name before the workers start, and a thread asks again every
30 s and tells the workers with the proxy's own `SetAddr` message when the answer changes.

    goose build examples/forward_by_name.goose
    ./examples/forward_by_name 0.0.0.0:8080 db.internal:5432

The example imports the proxy by path (`../../goose-io-tcpproxy`, branch `dogfood-goose-io`); point it at
`github.com/BHare1985/goose-io-tcpproxy@dogfood-goose-io` when you use it from elsewhere.

## Test

    goose build tests/dns_test.goose -o /tmp/dns_test && /tmp/dns_test

Licensed under MIT or Apache-2.0, at your option.
