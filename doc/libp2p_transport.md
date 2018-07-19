

# Module libp2p_transport #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

__This module defines the `libp2p_transport` behaviour.__<br /> Required callback functions: `start_link/1`, `start_listener/2`, `connect/5`, `match_addr/1`.

<a name="types"></a>

## Data Types ##




### <a name="type-connection_handler">connection_handler()</a> ###


<pre><code>
connection_handler() = {atom(), atom()}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#connect_to-4">connect_to/4</a></td><td>Connect through a transport service.</td></tr><tr><td valign="top"><a href="#find_session-3">find_session/3</a></td><td>Find a existing session for one of a given list of
multiaddrs.</td></tr><tr><td valign="top"><a href="#for_addr-2">for_addr/2</a></td><td></td></tr><tr><td valign="top"><a href="#start_client_session-3">start_client_session/3</a></td><td></td></tr><tr><td valign="top"><a href="#start_server_session-3">start_server_session/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="connect_to-4"></a>

### connect_to/4 ###

<pre><code>
connect_to(Addr::string(), Options::<a href="libp2p_swarm.md#type-connect_opts">libp2p_swarm:connect_opts()</a>, Timeout::pos_integer(), TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; {ok, string(), pid()} | {error, term()}
</code></pre>
<br />

Connect through a transport service. This is a convenience
function that verifies the given multiaddr, finds the right
transport, and checks if a session already exists for the given
multiaddr. The existing session is returned if it already exists,
or a `connect` call is made to transport service to perform the
actual connect.

<a name="find_session-3"></a>

### find_session/3 ###

<pre><code>
find_session(Tail::[string()], Options::<a href="libp2p_config.md#type-opts">libp2p_config:opts()</a>, TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; {ok, string(), pid()} | {error, term()}
</code></pre>
<br />

Find a existing session for one of a given list of
multiaddrs. Returns `{error not_found}` if no session is found.

<a name="for_addr-2"></a>

### for_addr/2 ###

<pre><code>
for_addr(TID::<a href="ets.md#type-tab">ets:tab()</a>, Addr::string()) -&gt; {ok, string(), {atom(), pid()}} | {error, term()}
</code></pre>
<br />

<a name="start_client_session-3"></a>

### start_client_session/3 ###

<pre><code>
start_client_session(TID::<a href="ets.md#type-tab">ets:tab()</a>, Addr::string(), Connection::<a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>) -&gt; {ok, pid()} | {error, term()}
</code></pre>
<br />

<a name="start_server_session-3"></a>

### start_server_session/3 ###

<pre><code>
start_server_session(Ref::reference(), TID::<a href="ets.md#type-tab">ets:tab()</a>, Connection::<a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>) -&gt; {ok, pid()} | {error, term()}
</code></pre>
<br />

