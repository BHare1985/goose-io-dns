# goose-io-dns

Host names for programs on [goose-io](https://github.com/BHare1985/goose-io), as a library beside the event loop, not a
loop and not part of goose-io. It asks the system resolver (gslib's `net::lookup_host`, `getaddrinfo`) for the IPv4
addresses of a name and returns `ip:port` text that `dial` and the tcpproxy targets take. `getaddrinfo` blocks, so call it
from a thread of its own, never from an event handler.

This is the thread-and-message way to resolve names on a loop that does not supply the `name-resolution` capability
(contract 0.5). A loop that supplies it needs none of this.

| | |
|---|---|
| `goose_io_dns::parse(text, default_port, name)` | `"host:port"` to a `Name` |
| `goose_io_dns::lookup(name, max)` | the addresses as `Endpoint`s (`"10.0.0.5:5432"`), system order, IPv4 only; empty if the name does not resolve |
| `goose_io_dns::same(a, b)` | whether two answers match (a refresh acts only when they differ) |

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
