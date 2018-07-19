

# Module libp2p_relay_envelope #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)



### <a name="Libp2p2_Relay_Envelope">Libp2p2 Relay Envelope</a> ###

Libp2p2 Relay Envelope API.

<a name="types"></a>

## Data Types ##




### <a name="type-relay_envelope">relay_envelope()</a> ###


<pre><code>
relay_envelope() = #libp2p_relay_envelope_pb{}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#create-1">create/1</a></td><td>
Create an envelope.</td></tr><tr><td valign="top"><a href="#data-1">data/1</a></td><td>
Getter.</td></tr><tr><td valign="top"><a href="#decode-1">decode/1</a></td><td>
Decode relay_envelope binary to record.</td></tr><tr><td valign="top"><a href="#encode-1">encode/1</a></td><td>
Encode relay_envelope record to binary.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="create-1"></a>

### create/1 ###

<pre><code>
create(Libp2p_relay_req_pb::<a href="libp2p_relay_req.md#type-relay_req">libp2p_relay_req:relay_req()</a> | <a href="libp2p_relay_resp.md#type-relay_resp">libp2p_relay_resp:relay_resp()</a> | <a href="libp2p_relay_bridge.md#type-relay_bridge_br">libp2p_relay_bridge:relay_bridge_br()</a> | <a href="libp2p_relay_bridge.md#type-relay_bridge_ra">libp2p_relay_bridge:relay_bridge_ra()</a> | <a href="libp2p_relay_bridge.md#type-relay_bridge_ab">libp2p_relay_bridge:relay_bridge_ab()</a>) -&gt; <a href="#type-relay_envelope">relay_envelope()</a>
</code></pre>
<br />

Create an envelope

<a name="data-1"></a>

### data/1 ###

<pre><code>
data(Env::<a href="#type-relay_envelope">relay_envelope()</a>) -&gt; {req, <a href="libp2p_relay_req.md#type-relay_req">libp2p_relay_req:relay_req()</a>} | {resp, <a href="libp2p_relay_resp.md#type-relay_resp">libp2p_relay_resp:relay_resp()</a>} | {bridge_br, <a href="libp2p_relay_bridge.md#type-relay_bridge_br">libp2p_relay_bridge:relay_bridge_br()</a>} | {bridge_ra, <a href="libp2p_relay_bridge.md#type-relay_bridge_ra">libp2p_relay_bridge:relay_bridge_ra()</a>} | {bridge_ab, <a href="libp2p_relay_bridge.md#type-relay_bridge_ab">libp2p_relay_bridge:relay_bridge_ab()</a>}
</code></pre>
<br />

Getter

<a name="decode-1"></a>

### decode/1 ###

<pre><code>
decode(Bin::binary()) -&gt; <a href="#type-relay_envelope">relay_envelope()</a>
</code></pre>
<br />

Decode relay_envelope binary to record

<a name="encode-1"></a>

### encode/1 ###

<pre><code>
encode(Libp2p_relay_envelope_pb::<a href="#type-relay_envelope">relay_envelope()</a>) -&gt; binary()
</code></pre>
<br />

Encode relay_envelope record to binary

