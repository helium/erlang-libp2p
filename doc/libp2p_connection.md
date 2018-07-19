

# Module libp2p_connection #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

__This module defines the `libp2p_connection` behaviour.__<br /> Required callback functions: `acknowledge/2`, `send/3`, `recv/3`, `close/1`, `close_state/1`, `fdset/1`, `fdclr/1`, `addr_info/1`, `controlling_process/2`.

<a name="types"></a>

## Data Types ##




### <a name="type-close_state">close_state()</a> ###


<pre><code>
close_state() = open | closed | pending
</code></pre>




### <a name="type-connection">connection()</a> ###


<pre><code>
connection() = #connection{module = module(), state = any()}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#acknowledge-2">acknowledge/2</a></td><td></td></tr><tr><td valign="top"><a href="#addr_info-1">addr_info/1</a></td><td></td></tr><tr><td valign="top"><a href="#close-1">close/1</a></td><td></td></tr><tr><td valign="top"><a href="#close_state-1">close_state/1</a></td><td></td></tr><tr><td valign="top"><a href="#controlling_process-2">controlling_process/2</a></td><td></td></tr><tr><td valign="top"><a href="#fdclr-1">fdclr/1</a></td><td></td></tr><tr><td valign="top"><a href="#fdset-1">fdset/1</a></td><td></td></tr><tr><td valign="top"><a href="#mk_async_sender-2">mk_async_sender/2</a></td><td></td></tr><tr><td valign="top"><a href="#new-2">new/2</a></td><td></td></tr><tr><td valign="top"><a href="#recv-1">recv/1</a></td><td></td></tr><tr><td valign="top"><a href="#recv-2">recv/2</a></td><td></td></tr><tr><td valign="top"><a href="#recv-3">recv/3</a></td><td></td></tr><tr><td valign="top"><a href="#send-2">send/2</a></td><td></td></tr><tr><td valign="top"><a href="#send-3">send/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="acknowledge-2"></a>

### acknowledge/2 ###

<pre><code>
acknowledge(Connection::<a href="#type-connection">connection()</a>, Ref::any()) -&gt; ok
</code></pre>
<br />

<a name="addr_info-1"></a>

### addr_info/1 ###

<pre><code>
addr_info(Connection::<a href="#type-connection">connection()</a>) -&gt; {string(), string()}
</code></pre>
<br />

<a name="close-1"></a>

### close/1 ###

<pre><code>
close(Connection::<a href="#type-connection">connection()</a>) -&gt; ok
</code></pre>
<br />

<a name="close_state-1"></a>

### close_state/1 ###

<pre><code>
close_state(Connection::<a href="#type-connection">connection()</a>) -&gt; <a href="#type-close_state">close_state()</a>
</code></pre>
<br />

<a name="controlling_process-2"></a>

### controlling_process/2 ###

<pre><code>
controlling_process(Connection::<a href="#type-connection">connection()</a>, Pid::pid()) -&gt; ok | {error, closed | not_owner | atom()}
</code></pre>
<br />

<a name="fdclr-1"></a>

### fdclr/1 ###

<pre><code>
fdclr(Connection::<a href="#type-connection">connection()</a>) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="fdset-1"></a>

### fdset/1 ###

<pre><code>
fdset(Connection::<a href="#type-connection">connection()</a>) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="mk_async_sender-2"></a>

### mk_async_sender/2 ###

<pre><code>
mk_async_sender(Handler::pid(), Connection::<a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>) -&gt; function()
</code></pre>
<br />

<a name="new-2"></a>

### new/2 ###

<pre><code>
new(Module::atom(), State::any()) -&gt; <a href="#type-connection">connection()</a>
</code></pre>
<br />

<a name="recv-1"></a>

### recv/1 ###

<pre><code>
recv(Conn::<a href="#type-connection">connection()</a>) -&gt; {ok, binary()} | {error, term()}
</code></pre>
<br />

<a name="recv-2"></a>

### recv/2 ###

<pre><code>
recv(Conn::<a href="#type-connection">connection()</a>, Length::non_neg_integer()) -&gt; {ok, binary()} | {error, term()}
</code></pre>
<br />

<a name="recv-3"></a>

### recv/3 ###

<pre><code>
recv(Connection::<a href="#type-connection">connection()</a>, Length::non_neg_integer(), Timeout::non_neg_integer()) -&gt; {ok, binary()} | {error, term()}
</code></pre>
<br />

<a name="send-2"></a>

### send/2 ###

<pre><code>
send(Connection::<a href="#type-connection">connection()</a>, Data::iodata()) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="send-3"></a>

### send/3 ###

<pre><code>
send(Connection::<a href="#type-connection">connection()</a>, Data::iodata(), Timeout::non_neg_integer() | infinity) -&gt; ok | {error, term()}
</code></pre>
<br />

