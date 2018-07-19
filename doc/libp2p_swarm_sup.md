

# Module libp2p_swarm_sup #
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`supervisor`](supervisor.md).

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#address-1">address/1</a></td><td></td></tr><tr><td valign="top"><a href="#group_agent-1">group_agent/1</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#name-1">name/1</a></td><td></td></tr><tr><td valign="top"><a href="#opts-1">opts/1</a></td><td></td></tr><tr><td valign="top"><a href="#peerbook-1">peerbook/1</a></td><td></td></tr><tr><td valign="top"><a href="#register_group_agent-1">register_group_agent/1</a></td><td></td></tr><tr><td valign="top"><a href="#register_peerbook-1">register_peerbook/1</a></td><td></td></tr><tr><td valign="top"><a href="#register_server-1">register_server/1</a></td><td></td></tr><tr><td valign="top"><a href="#server-1">server/1</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-1">start_link/1</a></td><td></td></tr><tr><td valign="top"><a href="#sup-1">sup/1</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="address-1"></a>

### address/1 ###

<pre><code>
address(TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; <a href="libp2p_crypto.md#type-address">libp2p_crypto:address()</a>
</code></pre>
<br />

<a name="group_agent-1"></a>

### group_agent/1 ###

<pre><code>
group_agent(TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; pid()
</code></pre>
<br />

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="name-1"></a>

### name/1 ###

<pre><code>
name(TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; atom()
</code></pre>
<br />

<a name="opts-1"></a>

### opts/1 ###

<pre><code>
opts(TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; <a href="libp2p_config.md#type-opts">libp2p_config:opts()</a> | any()
</code></pre>
<br />

<a name="peerbook-1"></a>

### peerbook/1 ###

<pre><code>
peerbook(TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; pid()
</code></pre>
<br />

<a name="register_group_agent-1"></a>

### register_group_agent/1 ###

`register_group_agent(TID) -> any()`

<a name="register_peerbook-1"></a>

### register_peerbook/1 ###

`register_peerbook(TID) -> any()`

<a name="register_server-1"></a>

### register_server/1 ###

`register_server(TID) -> any()`

<a name="server-1"></a>

### server/1 ###

<pre><code>
server(Sup::<a href="ets.md#type-tab">ets:tab()</a> | pid()) -&gt; pid()
</code></pre>
<br />

<a name="start_link-1"></a>

### start_link/1 ###

`start_link(Args) -> any()`

<a name="sup-1"></a>

### sup/1 ###

<pre><code>
sup(TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; pid()
</code></pre>
<br />

