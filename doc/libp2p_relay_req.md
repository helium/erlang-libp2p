

# Module libp2p_relay_req #
* [Description](#description)
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)



### <a name="Libp2p2_Relay_Request">Libp2p2 Relay Request</a> ###

Libp2p2 Relay Request API.

<a name="types"></a>

## Data Types ##




### <a name="type-relay_req">relay_req()</a> ###


<pre><code>
relay_req() = #libp2p_relay_req_pb{}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#address-1">address/1</a></td><td>
Getter.</td></tr><tr><td valign="top"><a href="#create-1">create/1</a></td><td>
Create an relay request.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="address-1"></a>

### address/1 ###

<pre><code>
address(Req::<a href="#type-relay_req">relay_req()</a>) -&gt; string()
</code></pre>
<br />

Getter

<a name="create-1"></a>

### create/1 ###

<pre><code>
create(Address::string()) -&gt; <a href="#type-relay_req">relay_req()</a>
</code></pre>
<br />

Create an relay request

