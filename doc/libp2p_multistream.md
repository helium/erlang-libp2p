

# Module libp2p_multistream #
* [Function Index](#index)
* [Function Details](#functions)

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#protocol_id-0">protocol_id/0</a></td><td></td></tr><tr><td valign="top"><a href="#read-1">read/1</a></td><td></td></tr><tr><td valign="top"><a href="#read_lines-1">read_lines/1</a></td><td></td></tr><tr><td valign="top"><a href="#write-2">write/2</a></td><td></td></tr><tr><td valign="top"><a href="#write_lines-2">write_lines/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="protocol_id-0"></a>

### protocol_id/0 ###

`protocol_id() -> any()`

<a name="read-1"></a>

### read/1 ###

<pre><code>
read(Connection::<a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>) -&gt; string() | {error, term()}
</code></pre>
<br />

<a name="read_lines-1"></a>

### read_lines/1 ###

<pre><code>
read_lines(Connection::<a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>) -&gt; [string()] | {error, term()}
</code></pre>
<br />

<a name="write-2"></a>

### write/2 ###

<pre><code>
write(Connection::<a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>, Msg::binary() | string()) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="write_lines-2"></a>

### write_lines/2 ###

`write_lines(Connection, Lines) -> any()`

