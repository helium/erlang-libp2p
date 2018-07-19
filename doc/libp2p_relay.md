

# Module libp2p_relay #
* [Description](#description)
* [Function Index](#index)
* [Function Details](#functions)



### <a name="Libp2p_Relay">Libp2p Relay</a> ###
.

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#add_stream_handler-1">add_stream_handler/1</a></td><td></td></tr><tr><td valign="top"><a href="#dial_framed_stream-3">dial_framed_stream/3</a></td><td>
Dial relay stream.</td></tr><tr><td valign="top"><a href="#p2p_circuit-1">p2p_circuit/1</a></td><td>
Split p2p circuit address.</td></tr><tr><td valign="top"><a href="#p2p_circuit-2">p2p_circuit/2</a></td><td>
Create p2p circuit address.</td></tr><tr><td valign="top"><a href="#version-0">version/0</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="add_stream_handler-1"></a>

### add_stream_handler/1 ###

<pre><code>
add_stream_handler(TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; ok
</code></pre>
<br />

<a name="dial_framed_stream-3"></a>

### dial_framed_stream/3 ###

<pre><code>
dial_framed_stream(Swarm::pid(), Address::string(), Args::list()) -&gt; {ok, pid()} | {error, any()} | ignore
</code></pre>
<br />

Dial relay stream

<a name="p2p_circuit-1"></a>

### p2p_circuit/1 ###

<pre><code>
p2p_circuit(P2PCircuit::string()) -&gt; {ok, {string(), string()}} | error
</code></pre>
<br />

Split p2p circuit address

<a name="p2p_circuit-2"></a>

### p2p_circuit/2 ###

<pre><code>
p2p_circuit(A::string(), B::string()) -&gt; string()
</code></pre>
<br />

Create p2p circuit address

<a name="version-0"></a>

### version/0 ###

<pre><code>
version() -&gt; string()
</code></pre>
<br />

