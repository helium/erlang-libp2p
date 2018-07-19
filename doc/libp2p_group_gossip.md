

# Module libp2p_group_gossip #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-opt">opt()</a> ###


<pre><code>
opt() = {peerbook_connections, pos_integer()} | {drop_timeout, pos_integer()} | {stream_clients, [<a href="libp2p_group.md#type-stream_client_spec">libp2p_group:stream_client_spec()</a>]} | {seed_nodes, [MultiAddr::string()]}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#get_opt-3">get_opt/3</a></td><td></td></tr><tr><td valign="top"><a href="#group_agent_spec-2">group_agent_spec/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="get_opt-3"></a>

### get_opt/3 ###

<pre><code>
get_opt(Opts::<a href="libp2p_config.md#type-opts">libp2p_config:opts()</a>, Key::atom(), Default::any()) -&gt; any()
</code></pre>
<br />

<a name="group_agent_spec-2"></a>

### group_agent_spec/2 ###

<pre><code>
group_agent_spec(Id::term(), TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; <a href="supervisor.md#type-child_spec">supervisor:child_spec()</a>
</code></pre>
<br />

