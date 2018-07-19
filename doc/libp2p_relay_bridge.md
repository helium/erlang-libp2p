

# Module libp2p_relay_bridge #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)



### <a name="Libp2p2_Relay_Bridge">Libp2p2 Relay Bridge</a> ###

Libp2p2 Relay Bridge API.

<a name="types"></a>

## Data Types ##




### <a name="type-relay_bridge_ab">relay_bridge_ab()</a> ###


<pre><code>
relay_bridge_ab() = #libp2p_relay_bridge_ab_pb{}
</code></pre>




### <a name="type-relay_bridge_br">relay_bridge_br()</a> ###


<pre><code>
relay_bridge_br() = #libp2p_relay_bridge_br_pb{}
</code></pre>




### <a name="type-relay_bridge_ra">relay_bridge_ra()</a> ###


<pre><code>
relay_bridge_ra() = #libp2p_relay_bridge_ra_pb{}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#a-1">a/1</a></td><td>
Getter.</td></tr><tr><td valign="top"><a href="#b-1">b/1</a></td><td>
Getter.</td></tr><tr><td valign="top"><a href="#create_ab-2">create_ab/2</a></td><td>
Create an relay bridge R to A.</td></tr><tr><td valign="top"><a href="#create_br-2">create_br/2</a></td><td>
Create an relay bridge B to R.</td></tr><tr><td valign="top"><a href="#create_ra-2">create_ra/2</a></td><td>
Create an relay bridge R to A.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="a-1"></a>

### a/1 ###

<pre><code>
a(Libp2p_relay_bridge_br_pb::<a href="#type-relay_bridge_br">relay_bridge_br()</a> | <a href="#type-relay_bridge_ra">relay_bridge_ra()</a> | <a href="#type-relay_bridge_ab">relay_bridge_ab()</a>) -&gt; string()
</code></pre>
<br />

Getter

<a name="b-1"></a>

### b/1 ###

<pre><code>
b(Libp2p_relay_bridge_br_pb::<a href="#type-relay_bridge_br">relay_bridge_br()</a> | <a href="#type-relay_bridge_ra">relay_bridge_ra()</a> | <a href="#type-relay_bridge_ab">relay_bridge_ab()</a>) -&gt; string()
</code></pre>
<br />

Getter

<a name="create_ab-2"></a>

### create_ab/2 ###

<pre><code>
create_ab(A::string(), B::string()) -&gt; <a href="#type-relay_bridge_ab">relay_bridge_ab()</a>
</code></pre>
<br />

Create an relay bridge R to A

<a name="create_br-2"></a>

### create_br/2 ###

<pre><code>
create_br(A::string(), B::string()) -&gt; <a href="#type-relay_bridge_br">relay_bridge_br()</a>
</code></pre>
<br />

Create an relay bridge B to R

<a name="create_ra-2"></a>

### create_ra/2 ###

<pre><code>
create_ra(A::string(), B::string()) -&gt; <a href="#type-relay_bridge_ra">relay_bridge_ra()</a>
</code></pre>
<br />

Create an relay bridge R to A

