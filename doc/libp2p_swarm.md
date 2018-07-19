

# Module libp2p_swarm #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-connect_opt">connect_opt()</a> ###


<pre><code>
connect_opt() = {unique_session, boolean()} | {unique_port, boolean()}
</code></pre>




### <a name="type-connect_opts">connect_opts()</a> ###


<pre><code>
connect_opts() = [<a href="#type-connect_opt">connect_opt()</a>]
</code></pre>




### <a name="type-swarm_opt">swarm_opt()</a> ###


<pre><code>
swarm_opt() = {key, {<a href="libp2p_crypto.md#type-public_key">libp2p_crypto:public_key()</a>, <a href="libp2p_crypto.md#type-sig_fun">libp2p_crypto:sig_fun()</a>}} | {base_dir, string()} | {group_agent, atom()} | {libp2p_transport_tcp, [<a href="libp2p_transport_tcp.md#type-opt">libp2p_transport_tcp:opt()</a>]} | {libp2p_peerbook, [<a href="libp2p_peerbook.md#type-opt">libp2p_peerbook:opt()</a>]} | {libp2p_yamux_stream, [<a href="libp2p_yamux_stream.md#type-opt">libp2p_yamux_stream:opt()</a>]} | {libp2p_group_gossip, [<a href="libp2p_group_gossip.md#type-opt">libp2p_group_gossip:opt()</a>]}
</code></pre>




### <a name="type-swarm_opts">swarm_opts()</a> ###


<pre><code>
swarm_opts() = [<a href="#type-swarm_opt">swarm_opt()</a>]
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add_connection_handler-3">add_connection_handler/3</a></td><td></td></tr><tr><td valign="top"><a href="#add_group-4">add_group/4</a></td><td></td></tr><tr><td valign="top"><a href="#add_stream_handler-3">add_stream_handler/3</a></td><td></td></tr><tr><td valign="top"><a href="#add_transport_handler-2">add_transport_handler/2</a></td><td></td></tr><tr><td valign="top"><a href="#address-1">address/1</a></td><td>Get cryptographic address for a swarm.</td></tr><tr><td valign="top"><a href="#connect-2">connect/2</a></td><td></td></tr><tr><td valign="top"><a href="#connect-4">connect/4</a></td><td></td></tr><tr><td valign="top"><a href="#dial-3">dial/3</a></td><td></td></tr><tr><td valign="top"><a href="#dial-5">dial/5</a></td><td></td></tr><tr><td valign="top"><a href="#dial_framed_stream-5">dial_framed_stream/5</a></td><td>Dial a remote swarm, negotiate a path and start a framed
stream client with the given Module as the handler.</td></tr><tr><td valign="top"><a href="#dial_framed_stream-7">dial_framed_stream/7</a></td><td></td></tr><tr><td valign="top"><a href="#group_agent-1">group_agent/1</a></td><td></td></tr><tr><td valign="top"><a href="#is_stopping-1">is_stopping/1</a></td><td></td></tr><tr><td valign="top"><a href="#keys-1">keys/1</a></td><td>Get the public key and signing function for a swarm.</td></tr><tr><td valign="top"><a href="#listen-2">listen/2</a></td><td></td></tr><tr><td valign="top"><a href="#listen_addrs-1">listen_addrs/1</a></td><td></td></tr><tr><td valign="top"><a href="#name-1">name/1</a></td><td>Get the name for a swarm.</td></tr><tr><td valign="top"><a href="#opts-1">opts/1</a></td><td>Get the options a swarm was started with.</td></tr><tr><td valign="top"><a href="#peerbook-1">peerbook/1</a></td><td>Get the peerbook for a swarm.</td></tr><tr><td valign="top"><a href="#sessions-1">sessions/1</a></td><td>Get a list of libp2p_session pids for all open sessions to
remote peers.</td></tr><tr><td valign="top"><a href="#start-1">start/1</a></td><td>Starts a swarm with a given name.</td></tr><tr><td valign="top"><a href="#start-2">start/2</a></td><td>Starts a swarm with a given name and sarm options.</td></tr><tr><td valign="top"><a href="#stop-1">stop/1</a></td><td>Stops the given swarm.</td></tr><tr><td valign="top"><a href="#stream_handlers-1">stream_handlers/1</a></td><td></td></tr><tr><td valign="top"><a href="#swarm-1">swarm/1</a></td><td>Get the swarm for a given ets table.</td></tr><tr><td valign="top"><a href="#tid-1">tid/1</a></td><td>Gets the ets table for for this swarm.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add_connection_handler-3"></a>

### add_connection_handler/3 ###

<pre><code>
add_connection_handler(Sup::pid() | <a href="ets.md#type-tab">ets:tab()</a>, Key::string(), X3::{<a href="libp2p_transport.md#type-connection_handler">libp2p_transport:connection_handler()</a>, <a href="libp2p_transport.md#type-connection_handler">libp2p_transport:connection_handler()</a>}) -&gt; ok
</code></pre>
<br />

<a name="add_group-4"></a>

### add_group/4 ###

<pre><code>
add_group(Sup::pid() | <a href="ets.md#type-tab">ets:tab()</a>, GroupID::string(), Module::atom(), Args::[any()]) -&gt; {ok, pid()} | {error, term()}
</code></pre>
<br />

<a name="add_stream_handler-3"></a>

### add_stream_handler/3 ###

<pre><code>
add_stream_handler(Sup::pid() | <a href="ets.md#type-tab">ets:tab()</a>, Key::string(), HandlerDef::<a href="libp2p_session.md#type-stream_handler">libp2p_session:stream_handler()</a>) -&gt; ok
</code></pre>
<br />

<a name="add_transport_handler-2"></a>

### add_transport_handler/2 ###

<pre><code>
add_transport_handler(Sup::pid() | <a href="ets.md#type-tab">ets:tab()</a>, Transport::atom()) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="address-1"></a>

### address/1 ###

<pre><code>
address(Sup::<a href="ets.md#type-tab">ets:tab()</a> | pid()) -&gt; <a href="libp2p_crypto.md#type-address">libp2p_crypto:address()</a>
</code></pre>
<br />

Get cryptographic address for a swarm.

<a name="connect-2"></a>

### connect/2 ###

<pre><code>
connect(Sup::pid(), Addr::string()) -&gt; {ok, pid()} | {error, term()}
</code></pre>
<br />

<a name="connect-4"></a>

### connect/4 ###

<pre><code>
connect(Sup::pid() | <a href="ets.md#type-tab">ets:tab()</a>, Addr::string(), Options::<a href="#type-connect_opts">connect_opts()</a>, Timeout::pos_integer()) -&gt; {ok, pid()} | {error, term()}
</code></pre>
<br />

<a name="dial-3"></a>

### dial/3 ###

<pre><code>
dial(Sup::pid(), Addr::string(), Path::string()) -&gt; {ok, <a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>} | {error, term()}
</code></pre>
<br />

<a name="dial-5"></a>

### dial/5 ###

<pre><code>
dial(Sup::pid(), Addr::string(), Path::string(), Options::<a href="#type-connect_opts">connect_opts()</a>, Timeout::pos_integer()) -&gt; {ok, <a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>} | {error, term()}
</code></pre>
<br />

<a name="dial_framed_stream-5"></a>

### dial_framed_stream/5 ###

<pre><code>
dial_framed_stream(Sup::pid(), Addr::string(), Path::string(), Module::atom(), Args::[any()]) -&gt; {ok, pid()} | {error, term()}
</code></pre>
<br />

Dial a remote swarm, negotiate a path and start a framed
stream client with the given Module as the handler.

<a name="dial_framed_stream-7"></a>

### dial_framed_stream/7 ###

<pre><code>
dial_framed_stream(Sup::pid(), Addr::string(), Path::string(), Options::<a href="#type-connect_opts">connect_opts()</a>, Timeout::pos_integer(), Module::atom(), Args::[any()]) -&gt; {ok, pid()} | {error, term()}
</code></pre>
<br />

<a name="group_agent-1"></a>

### group_agent/1 ###

<pre><code>
group_agent(Sup::pid() | <a href="ets.md#type-tab">ets:tab()</a>) -&gt; pid()
</code></pre>
<br />

<a name="is_stopping-1"></a>

### is_stopping/1 ###

`is_stopping(Sup) -> any()`

<a name="keys-1"></a>

### keys/1 ###

<pre><code>
keys(Sup::<a href="ets.md#type-tab">ets:tab()</a> | pid()) -&gt; {ok, <a href="libp2p_crypto.md#type-public_key">libp2p_crypto:public_key()</a>, <a href="libp2p_crypto.md#type-sig_fun">libp2p_crypto:sig_fun()</a>} | {error, term()}
</code></pre>
<br />

Get the public key and signing function for a swarm

<a name="listen-2"></a>

### listen/2 ###

<pre><code>
listen(Sup::pid() | <a href="ets.md#type-tab">ets:tab()</a>, Port::string() | non_neg_integer()) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="listen_addrs-1"></a>

### listen_addrs/1 ###

<pre><code>
listen_addrs(Sup::pid() | <a href="ets.md#type-tab">ets:tab()</a>) -&gt; [string()]
</code></pre>
<br />

<a name="name-1"></a>

### name/1 ###

<pre><code>
name(Sup::<a href="ets.md#type-tab">ets:tab()</a> | pid()) -&gt; atom()
</code></pre>
<br />

Get the name for a swarm.

<a name="opts-1"></a>

### opts/1 ###

<pre><code>
opts(Sup::<a href="ets.md#type-tab">ets:tab()</a> | pid()) -&gt; <a href="#type-swarm_opts">swarm_opts()</a> | any()
</code></pre>
<br />

Get the options a swarm was started with.

<a name="peerbook-1"></a>

### peerbook/1 ###

<pre><code>
peerbook(Sup::<a href="ets.md#type-tab">ets:tab()</a> | pid()) -&gt; pid()
</code></pre>
<br />

Get the peerbook for a swarm.

<a name="sessions-1"></a>

### sessions/1 ###

<pre><code>
sessions(Sup::<a href="ets.md#type-tab">ets:tab()</a> | pid()) -&gt; [pid()]
</code></pre>
<br />

Get a list of libp2p_session pids for all open sessions to
remote peers.

<a name="start-1"></a>

### start/1 ###

<pre><code>
start(Name::atom()) -&gt; {ok, pid()} | ignore | {error, term()}
</code></pre>
<br />

Starts a swarm with a given name. This starts a swarm with no
listeners. The swarm name is used to distinguish the data folder
for the swarm from other started swarms on the same node.

<a name="start-2"></a>

### start/2 ###

<pre><code>
start(Name::atom(), Opts::<a href="#type-swarm_opts">swarm_opts()</a>) -&gt; {ok, pid()} | ignore | {error, term()}
</code></pre>
<br />

Starts a swarm with a given name and sarm options. This starts
a swarm with no listeners. The options can be used to configure and
control behavior of various subsystems of the swarm.

<a name="stop-1"></a>

### stop/1 ###

<pre><code>
stop(Sup::pid()) -&gt; ok
</code></pre>
<br />

Stops the given swarm.

<a name="stream_handlers-1"></a>

### stream_handlers/1 ###

<pre><code>
stream_handlers(Sup::pid() | <a href="ets.md#type-tab">ets:tab()</a>) -&gt; [{string(), <a href="libp2p_session.md#type-stream_handler">libp2p_session:stream_handler()</a>}]
</code></pre>
<br />

<a name="swarm-1"></a>

### swarm/1 ###

<pre><code>
swarm(TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; pid()
</code></pre>
<br />

Get the swarm for a given ets table. A swarm is represented by
the supervisor for the services it contains. Many internal
processes get started with the ets table that stores data about a
swarm. This function makes it easy to get back to the swarm from a
given swarm ets table.

<a name="tid-1"></a>

### tid/1 ###

<pre><code>
tid(Sup::pid()) -&gt; <a href="ets.md#type-tab">ets:tab()</a>
</code></pre>
<br />

Gets the ets table for for this swarm. This is the opposite of
swarm/1 and used by a number of internal swarm functions and
services to find other services in the given swarm.

