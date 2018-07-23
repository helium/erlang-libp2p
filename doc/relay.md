# Relay Testing

## Setup Docker

1. Create Docker image:
```
docker rmi heliumsystems/p2p && docker build --force-rm -t heliumsystems/p2p .
```
2. Create network:
```
docker network rm p2p && docker network create -d bridge --subnet 172.20.0.0/16 p2p
```

## Setup Nodes

### Node A

```
docker run -it --rm --name p2p_a --ip 172.20.0.2 --network p2p heliumsystems/p2p /bin/sh -c "rebar3 shell"
```
```
SwarmOpts = [{libp2p_transport_tcp, [{nat, false}]}],
Version = "relaytest/1.0.0",
{ok, ASwarm} = libp2p_swarm:start(a, SwarmOpts),
ok = libp2p_swarm:listen(ASwarm, "/ip4/0.0.0.0/tcp/6602"),
libp2p_swarm:add_stream_handler(
    ASwarm
    ,Version
    ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), ASwarm]}
).
```

### Node R

```
docker run -it --rm --name p2p_r --ip 172.20.0.3 --network p2p heliumsystems/p2p /bin/sh -c "rebar3 shell"
```
```
SwarmOpts = [{libp2p_transport_tcp, [{nat, false}]}],
Version = "relaytest/1.0.0",
{ok, RSwarm} = libp2p_swarm:start(r, SwarmOpts),
ok = libp2p_swarm:listen(RSwarm, "/ip4/0.0.0.0/tcp/6603"),
libp2p_swarm:add_stream_handler(
    RSwarm
    ,Version
    ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), RSwarm]}
).
```

### Node B

```
docker run -it --rm --name p2p_b --ip 172.20.0.4 --network p2p heliumsystems/p2p /bin/sh -c "rebar3 shell"
```
```
SwarmOpts = [{libp2p_transport_tcp, [{nat, false}]}],
Version = "relaytest/1.0.0",
{ok, BSwarm} = libp2p_swarm:start(b, SwarmOpts),
ok = libp2p_swarm:listen(BSwarm, "/ip4/0.0.0.0/tcp/6604"),
libp2p_swarm:add_stream_handler(
    BSwarm
    ,Version
    ,{libp2p_framed_stream, server, [libp2p_stream_relay_test, self(), BSwarm]}
).
```

## Setup Relay


`A` requests a relay service from `R`.

### Node A

```
{ok, _} = libp2p_relay:dial_framed_stream(ASwarm, "/ip4/172.20.0.3/tcp/6603/", []).
["/ip4/172.20.0.2/tcp/6602", "/ip4/172.20.0.3/tcp/6603/p2p-circuit/ip4/172.20.0.2/tcp/6602"] = libp2p_swarm:listen_addrs(ASwarm).

```


## Test Relay

`B` tries to dial `A` via `p2p-circuit` address.

```
libp2p_swarm:dial_framed_stream(BSwarm, "/ip4/172.20.0.3/tcp/6603/p2p-circuit/ip4/172.20.0.2/tcp/6602", Version, libp2p_stream_relay_test, []).
```
