

# Module libp2p_peer #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-nat_type">nat_type()</a> ###


<pre><code>
nat_type() = <a href="libp2p_peer_pb.md#type-nat_type">libp2p_peer_pb:nat_type()</a>
</code></pre>




### <a name="type-peer">peer()</a> ###


__abstract datatype__: `peer()`

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#address-1">address/1</a></td><td>Gets the crypto address for the given peer.</td></tr><tr><td valign="top"><a href="#connected_peers-1">connected_peers/1</a></td><td>Gets the list of peer crypto addresses that the given peer was last
known to be connected to.</td></tr><tr><td valign="top"><a href="#decode-1">decode/1</a></td><td>Decodes a given binary into a peer.</td></tr><tr><td valign="top"><a href="#decode_list-1">decode_list/1</a></td><td>Decodes a given binary into a list of peers.</td></tr><tr><td valign="top"><a href="#encode-1">encode/1</a></td><td>Encodes the given peer into its binary form.</td></tr><tr><td valign="top"><a href="#encode_list-1">encode_list/1</a></td><td>Encodes a given list of peer into a binary form.</td></tr><tr><td valign="top"><a href="#is_stale-2">is_stale/2</a></td><td>Returns whether a given peer is stale relative to a given
stale delta time in milliseconds.</td></tr><tr><td valign="top"><a href="#listen_addrs-1">listen_addrs/1</a></td><td>Gets the list of peer multiaddrs that the given peer is
listening on.</td></tr><tr><td valign="top"><a href="#nat_type-1">nat_type/1</a></td><td>Gets the NAT type of the given peer.</td></tr><tr><td valign="top"><a href="#new-6">new/6</a></td><td></td></tr><tr><td valign="top"><a href="#supersedes-2">supersedes/2</a></td><td>Returns whether a given <code>Target</code> is more recent than <code>Other</code></td></tr><tr><td valign="top"><a href="#timestamp-1">timestamp/1</a></td><td>Gets the timestamp of the given peer.</td></tr><tr><td valign="top"><a href="#verify-1">verify/1</a></td><td>Cryptographically verifies a given peer.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="address-1"></a>

### address/1 ###

<pre><code>
address(Libp2p_signed_peer_pb::<a href="#type-peer">peer()</a>) -&gt; <a href="libp2p_crypto.md#type-address">libp2p_crypto:address()</a>
</code></pre>
<br />

Gets the crypto address for the given peer.

<a name="connected_peers-1"></a>

### connected_peers/1 ###

<pre><code>
connected_peers(Libp2p_signed_peer_pb::<a href="#type-peer">peer()</a>) -&gt; [binary()]
</code></pre>
<br />

Gets the list of peer crypto addresses that the given peer was last
known to be connected to.

<a name="decode-1"></a>

### decode/1 ###

<pre><code>
decode(Bin::binary()) -&gt; <a href="#type-peer">peer()</a>
</code></pre>
<br />

Decodes a given binary into a peer.

<a name="decode_list-1"></a>

### decode_list/1 ###

<pre><code>
decode_list(Bin::binary()) -&gt; [<a href="#type-peer">peer()</a>]
</code></pre>
<br />

Decodes a given binary into a list of peers.

<a name="encode-1"></a>

### encode/1 ###

<pre><code>
encode(Msg::<a href="#type-peer">peer()</a>) -&gt; binary()
</code></pre>
<br />

Encodes the given peer into its binary form.

<a name="encode_list-1"></a>

### encode_list/1 ###

<pre><code>
encode_list(List::[<a href="#type-peer">peer()</a>]) -&gt; binary()
</code></pre>
<br />

Encodes a given list of peer into a binary form.

<a name="is_stale-2"></a>

### is_stale/2 ###

<pre><code>
is_stale(Libp2p_signed_peer_pb::<a href="#type-peer">peer()</a>, StaleMS::integer()) -&gt; boolean()
</code></pre>
<br />

Returns whether a given peer is stale relative to a given
stale delta time in milliseconds. Note that the accuracy of a peer
entry is only up to the nearest second. .

<a name="listen_addrs-1"></a>

### listen_addrs/1 ###

<pre><code>
listen_addrs(Libp2p_signed_peer_pb::<a href="#type-peer">peer()</a>) -&gt; [string()]
</code></pre>
<br />

Gets the list of peer multiaddrs that the given peer is
listening on.

<a name="nat_type-1"></a>

### nat_type/1 ###

<pre><code>
nat_type(Libp2p_signed_peer_pb::<a href="#type-peer">peer()</a>) -&gt; <a href="#type-nat_type">nat_type()</a>
</code></pre>
<br />

Gets the NAT type of the given peer.

<a name="new-6"></a>

### new/6 ###

<pre><code>
new(Key::<a href="libp2p_crypto.md#type-address">libp2p_crypto:address()</a>, ListenAddrs::[string()], ConnectedAddrs::[binary()], NatType::<a href="#type-nat_type">nat_type()</a>, Timestamp::integer(), SigFun::fun((binary()) -&gt; binary())) -&gt; <a href="#type-peer">peer()</a>
</code></pre>
<br />

<a name="supersedes-2"></a>

### supersedes/2 ###

<pre><code>
supersedes(Target::<a href="#type-peer">peer()</a> | integer(), Other::<a href="#type-peer">peer()</a>) -&gt; boolean()
</code></pre>
<br />

Returns whether a given `Target` is more recent than `Other`

<a name="timestamp-1"></a>

### timestamp/1 ###

<pre><code>
timestamp(Libp2p_signed_peer_pb::<a href="#type-peer">peer()</a>) -&gt; integer()
</code></pre>
<br />

Gets the timestamp of the given peer.

<a name="verify-1"></a>

### verify/1 ###

<pre><code>
verify(Msg::<a href="#type-peer">peer()</a>) -&gt; <a href="#type-peer">peer()</a>
</code></pre>
<br />

Cryptographically verifies a given peer.

