

# Module libp2p_identify #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-identify">identify()</a> ###


__abstract datatype__: `identify()`

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#address-1">address/1</a></td><td></td></tr><tr><td valign="top"><a href="#agent_version-1">agent_version/1</a></td><td></td></tr><tr><td valign="top"><a href="#decode-1">decode/1</a></td><td></td></tr><tr><td valign="top"><a href="#encode-1">encode/1</a></td><td></td></tr><tr><td valign="top"><a href="#listen_addrs-1">listen_addrs/1</a></td><td></td></tr><tr><td valign="top"><a href="#new-4">new/4</a></td><td></td></tr><tr><td valign="top"><a href="#new-5">new/5</a></td><td></td></tr><tr><td valign="top"><a href="#observed_addr-1">observed_addr/1</a></td><td></td></tr><tr><td valign="top"><a href="#observed_maddr-1">observed_maddr/1</a></td><td></td></tr><tr><td valign="top"><a href="#protocol_version-1">protocol_version/1</a></td><td></td></tr><tr><td valign="top"><a href="#protocols-1">protocols/1</a></td><td></td></tr><tr><td valign="top"><a href="#spawn_identify-3">spawn_identify/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="address-1"></a>

### address/1 ###

<pre><code>
address(Libp2p_identify_pb::<a href="#type-identify">identify()</a>) -&gt; <a href="libp2p_crypto.md#type-address">libp2p_crypto:address()</a>
</code></pre>
<br />

<a name="agent_version-1"></a>

### agent_version/1 ###

<pre><code>
agent_version(Libp2p_identify_pb::<a href="#type-identify">identify()</a>) -&gt; string()
</code></pre>
<br />

<a name="decode-1"></a>

### decode/1 ###

<pre><code>
decode(Bin::binary()) -&gt; <a href="#type-identify">identify()</a>
</code></pre>
<br />

<a name="encode-1"></a>

### encode/1 ###

<pre><code>
encode(Msg::<a href="#type-identify">identify()</a>) -&gt; binary()
</code></pre>
<br />

<a name="listen_addrs-1"></a>

### listen_addrs/1 ###

<pre><code>
listen_addrs(Libp2p_identify_pb::<a href="#type-identify">identify()</a>) -&gt; [<a href="multiaddr.md#type-multiaddr">multiaddr:multiaddr()</a>]
</code></pre>
<br />

<a name="new-4"></a>

### new/4 ###

<pre><code>
new(Address::<a href="libp2p_crypto.md#type-address">libp2p_crypto:address()</a>, ListenAddrs::[string()], ObservedAddr::string(), Protocols::[string()]) -&gt; <a href="libp2p_identify_pb.md#type-libp2p_identify_pb">libp2p_identify_pb:libp2p_identify_pb()</a>
</code></pre>
<br />

<a name="new-5"></a>

### new/5 ###

<pre><code>
new(Address::<a href="libp2p_crypto.md#type-address">libp2p_crypto:address()</a>, ListenAddrs::[<a href="multiaddr.md#type-multiaddr">multiaddr:multiaddr()</a>], ObservedAddr::<a href="multiaddr.md#type-multiaddr">multiaddr:multiaddr()</a>, Protocols::[string()], AgentVersion::string()) -&gt; <a href="#type-identify">identify()</a>
</code></pre>
<br />

<a name="observed_addr-1"></a>

### observed_addr/1 ###

<pre><code>
observed_addr(Identify::<a href="#type-identify">identify()</a>) -&gt; string()
</code></pre>
<br />

<a name="observed_maddr-1"></a>

### observed_maddr/1 ###

`observed_maddr(Libp2p_identify_pb) -> any()`

<a name="protocol_version-1"></a>

### protocol_version/1 ###

<pre><code>
protocol_version(Libp2p_identify_pb::<a href="#type-identify">identify()</a>) -&gt; string()
</code></pre>
<br />

<a name="protocols-1"></a>

### protocols/1 ###

<pre><code>
protocols(Libp2p_identify_pb::<a href="#type-identify">identify()</a>) -&gt; [string()]
</code></pre>
<br />

<a name="spawn_identify-3"></a>

### spawn_identify/3 ###

<pre><code>
spawn_identify(Session::pid(), Handler::pid(), UserData::any()) -&gt; pid()
</code></pre>
<br />

