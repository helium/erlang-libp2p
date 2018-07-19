

# Module libp2p_transport_tcp #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`libp2p_connection`](libp2p_connection.md).

<a name="types"></a>

## Data Types ##




### <a name="type-listen_opt">listen_opt()</a> ###


<pre><code>
listen_opt() = {backlog, non_neg_integer()} | {buffer, non_neg_integer()} | {delay_send, boolean()} | {dontroute, boolean()} | {exit_on_close, boolean()} | {fd, non_neg_integer()} | {high_msgq_watermark, non_neg_integer()} | {high_watermark, non_neg_integer()} | {keepalive, boolean()} | {linger, {boolean(), non_neg_integer()}} | {low_msgq_watermark, non_neg_integer()} | {low_watermark, non_neg_integer()} | {nodelay, boolean()} | {port, <a href="inet.md#type-port_number">inet:port_number()</a>} | {priority, integer()} | {raw, non_neg_integer(), non_neg_integer(), binary()} | {recbuf, non_neg_integer()} | {send_timeout, timeout()} | {send_timeout_close, boolean()} | {sndbuf, non_neg_integer()} | {tos, integer()}
</code></pre>




### <a name="type-opt">opt()</a> ###


<pre><code>
opt() = {listen, [<a href="#type-listen_opt">listen_opt()</a>]}
</code></pre>




### <a name="type-tcp_state">tcp_state()</a> ###


<pre><code>
tcp_state() = #tcp_state{addr_info = {string(), string()}, socket = <a href="gen_tcp.md#type-socket">gen_tcp:socket()</a>, transport = atom()}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#acknowledge-2">acknowledge/2</a></td><td></td></tr><tr><td valign="top"><a href="#addr_info-1">addr_info/1</a></td><td></td></tr><tr><td valign="top"><a href="#close-1">close/1</a></td><td></td></tr><tr><td valign="top"><a href="#close_state-1">close_state/1</a></td><td></td></tr><tr><td valign="top"><a href="#connect-5">connect/5</a></td><td></td></tr><tr><td valign="top"><a href="#controlling_process-2">controlling_process/2</a></td><td></td></tr><tr><td valign="top"><a href="#fdclr-1">fdclr/1</a></td><td></td></tr><tr><td valign="top"><a href="#fdset-1">fdset/1</a></td><td></td></tr><tr><td valign="top"><a href="#handle_call-3">handle_call/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_cast-2">handle_cast/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_info-2">handle_info/2</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#match_addr-1">match_addr/1</a></td><td></td></tr><tr><td valign="top"><a href="#new_connection-1">new_connection/1</a></td><td></td></tr><tr><td valign="top"><a href="#recv-3">recv/3</a></td><td></td></tr><tr><td valign="top"><a href="#send-3">send/3</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-1">start_link/1</a></td><td></td></tr><tr><td valign="top"><a href="#start_listener-2">start_listener/2</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="acknowledge-2"></a>

### acknowledge/2 ###

<pre><code>
acknowledge(Tcp_state::<a href="#type-tcp_state">tcp_state()</a>, Ref::reference()) -&gt; ok
</code></pre>
<br />

<a name="addr_info-1"></a>

### addr_info/1 ###

<pre><code>
addr_info(Tcp_state::<a href="#type-tcp_state">tcp_state()</a>) -&gt; {string(), string()}
</code></pre>
<br />

<a name="close-1"></a>

### close/1 ###

<pre><code>
close(Tcp_state::<a href="#type-tcp_state">tcp_state()</a>) -&gt; ok
</code></pre>
<br />

<a name="close_state-1"></a>

### close_state/1 ###

<pre><code>
close_state(Tcp_state::<a href="#type-tcp_state">tcp_state()</a>) -&gt; open | closed
</code></pre>
<br />

<a name="connect-5"></a>

### connect/5 ###

<pre><code>
connect(Pid::pid(), MAddr::string(), Options::<a href="libp2p_swarm.md#type-connect_opts">libp2p_swarm:connect_opts()</a>, Timeout::pos_integer(), TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; {ok, pid()} | {error, term()}
</code></pre>
<br />

<a name="controlling_process-2"></a>

### controlling_process/2 ###

<pre><code>
controlling_process(Tcp_state::<a href="#type-tcp_state">tcp_state()</a>, Pid::pid()) -&gt; ok | {error, closed | not_owner | atom()}
</code></pre>
<br />

<a name="fdclr-1"></a>

### fdclr/1 ###

<pre><code>
fdclr(Tcp_state::<a href="#type-tcp_state">tcp_state()</a>) -&gt; ok
</code></pre>
<br />

<a name="fdset-1"></a>

### fdset/1 ###

<pre><code>
fdset(Tcp_state::<a href="#type-tcp_state">tcp_state()</a>) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(Msg, From, State) -> any()`

<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(Msg, State) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Msg, State) -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="match_addr-1"></a>

### match_addr/1 ###

<pre><code>
match_addr(Addr::string()) -&gt; {ok, string()} | false
</code></pre>
<br />

<a name="new_connection-1"></a>

### new_connection/1 ###

<pre><code>
new_connection(Socket::<a href="inet.md#type-socket">inet:socket()</a>) -&gt; <a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>
</code></pre>
<br />

<a name="recv-3"></a>

### recv/3 ###

<pre><code>
recv(Tcp_state::<a href="#type-tcp_state">tcp_state()</a>, Length::non_neg_integer(), Timeout::pos_integer()) -&gt; {ok, binary()} | {error, term()}
</code></pre>
<br />

<a name="send-3"></a>

### send/3 ###

<pre><code>
send(Tcp_state::<a href="#type-tcp_state">tcp_state()</a>, Data::iodata(), Timeout::non_neg_integer()) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="start_link-1"></a>

### start_link/1 ###

`start_link(TID) -> any()`

<a name="start_listener-2"></a>

### start_listener/2 ###

<pre><code>
start_listener(Pid::pid(), Addr::string()) -&gt; {ok, [string()], pid()} | {error, term()}
</code></pre>
<br />

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

