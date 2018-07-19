

# Module libp2p_group_relcast #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-opt">opt()</a> ###


<pre><code>
opt() = {stream_clients, [<a href="libp2p_group.md#type-stream_client_spec">libp2p_group:stream_client_spec()</a>]}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#get_opt-3">get_opt/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_ack-2">handle_ack/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_input-2">handle_input/2</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-3">start_link/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="get_opt-3"></a>

### get_opt/3 ###

<pre><code>
get_opt(Opts::<a href="libp2p_config.md#type-opts">libp2p_config:opts()</a>, Key::atom(), Default::any()) -&gt; any()
</code></pre>
<br />

<a name="handle_ack-2"></a>

### handle_ack/2 ###

`handle_ack(GroupPid, Index) -> any()`

<a name="handle_input-2"></a>

### handle_input/2 ###

<pre><code>
handle_input(GroupPid::pid(), Msg::binary()) -&gt; ok
</code></pre>
<br />

<a name="start_link-3"></a>

### start_link/3 ###

<pre><code>
start_link(TID::<a href="ets.md#type-tab">ets:tab()</a>, GroupID::string(), Args::[any()]) -&gt; {ok, pid()} | {error, term()}
</code></pre>
<br />

