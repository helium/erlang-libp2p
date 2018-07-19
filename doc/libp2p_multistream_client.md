

# Module libp2p_multistream_client #
* [Function Index](#index)
* [Function Details](#functions)

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#handshake-1">handshake/1</a></td><td></td></tr><tr><td valign="top"><a href="#ls-1">ls/1</a></td><td></td></tr><tr><td valign="top"><a href="#negotiate_handler-3">negotiate_handler/3</a></td><td></td></tr><tr><td valign="top"><a href="#select-2">select/2</a></td><td></td></tr><tr><td valign="top"><a href="#select_one-3">select_one/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="handshake-1"></a>

### handshake/1 ###

<pre><code>
handshake(Connection::<a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="ls-1"></a>

### ls/1 ###

<pre><code>
ls(Connection::<a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>) -&gt; [string()] | {error, term()}
</code></pre>
<br />

<a name="negotiate_handler-3"></a>

### negotiate_handler/3 ###

<pre><code>
negotiate_handler(Handlers::[{string(), term()}], Path::string(), Connection::<a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>) -&gt; {ok, term()} | {error, term()}
</code></pre>
<br />

<a name="select-2"></a>

### select/2 ###

<pre><code>
select(Protocol::string(), Connection::<a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="select_one-3"></a>

### select_one/3 ###

<pre><code>
select_one(Rest::[tuple()], Index::pos_integer(), Connection::<a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>) -&gt; tuple() | {error, term()}
</code></pre>
<br />

