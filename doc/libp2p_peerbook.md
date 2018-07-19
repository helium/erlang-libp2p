

# Module libp2p_peerbook #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-opt">opt()</a> ###


<pre><code>
opt() = {stale_time, pos_integer()} | {peer_time, pos_integer()}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#changed_listener-1">changed_listener/1</a></td><td></td></tr><tr><td valign="top"><a href="#get-2">get/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_call-3">handle_call/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_cast-2">handle_cast/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_info-2">handle_info/2</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#is_key-2">is_key/2</a></td><td></td></tr><tr><td valign="top"><a href="#join_notify-2">join_notify/2</a></td><td></td></tr><tr><td valign="top"><a href="#keys-1">keys/1</a></td><td></td></tr><tr><td valign="top"><a href="#put-2">put/2</a></td><td></td></tr><tr><td valign="top"><a href="#register_session-4">register_session/4</a></td><td></td></tr><tr><td valign="top"><a href="#remove-2">remove/2</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-2">start_link/2</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td></td></tr><tr><td valign="top"><a href="#unregister_session-2">unregister_session/2</a></td><td></td></tr><tr><td valign="top"><a href="#update_nat_type-2">update_nat_type/2</a></td><td></td></tr><tr><td valign="top"><a href="#values-1">values/1</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="changed_listener-1"></a>

### changed_listener/1 ###

`changed_listener(Pid) -> any()`

<a name="get-2"></a>

### get/2 ###

<pre><code>
get(Pid::pid(), ID::<a href="libp2p_crypto.md#type-address">libp2p_crypto:address()</a>) -&gt; {ok, <a href="libp2p_peer.md#type-peer">libp2p_peer:peer()</a>} | {error, term()}
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

<a name="is_key-2"></a>

### is_key/2 ###

<pre><code>
is_key(Pid::pid(), ID::<a href="libp2p_crypto.md#type-address">libp2p_crypto:address()</a>) -&gt; boolean()
</code></pre>
<br />

<a name="join_notify-2"></a>

### join_notify/2 ###

<pre><code>
join_notify(Pid::pid(), Joiner::pid()) -&gt; ok
</code></pre>
<br />

<a name="keys-1"></a>

### keys/1 ###

<pre><code>
keys(Pid::pid()) -&gt; [<a href="libp2p_crypto.md#type-address">libp2p_crypto:address()</a>]
</code></pre>
<br />

<a name="put-2"></a>

### put/2 ###

<pre><code>
put(Pid::pid(), PeerList::[<a href="libp2p_peer.md#type-peer">libp2p_peer:peer()</a>]) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="register_session-4"></a>

### register_session/4 ###

<pre><code>
register_session(Pid::pid(), SessionPid::pid(), Identify::<a href="libp2p_identify.md#type-identify">libp2p_identify:identify()</a>, Kind::client | server) -&gt; ok
</code></pre>
<br />

<a name="remove-2"></a>

### remove/2 ###

<pre><code>
remove(Pid::pid(), ID::<a href="libp2p_crypto.md#type-address">libp2p_crypto:address()</a>) -&gt; ok | {error, no_delete}
</code></pre>
<br />

<a name="start_link-2"></a>

### start_link/2 ###

`start_link(TID, SigFun) -> any()`

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

<a name="unregister_session-2"></a>

### unregister_session/2 ###

<pre><code>
unregister_session(Pid::pid(), SessionPid::pid()) -&gt; ok
</code></pre>
<br />

<a name="update_nat_type-2"></a>

### update_nat_type/2 ###

<pre><code>
update_nat_type(Pid::pid(), NatType::<a href="libp2p_peer.md#type-nat_type">libp2p_peer:nat_type()</a>) -&gt; ok
</code></pre>
<br />

<a name="values-1"></a>

### values/1 ###

<pre><code>
values(Pid::pid()) -&gt; [<a href="libp2p_peer.md#type-peer">libp2p_peer:peer()</a>]
</code></pre>
<br />

