

# Module libp2p_session #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-stream_handler">stream_handler()</a> ###


<pre><code>
stream_handler() = {atom(), atom(), [any()]}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#addr_info-1">addr_info/1</a></td><td></td></tr><tr><td valign="top"><a href="#close-1">close/1</a></td><td></td></tr><tr><td valign="top"><a href="#close-3">close/3</a></td><td></td></tr><tr><td valign="top"><a href="#close_state-1">close_state/1</a></td><td></td></tr><tr><td valign="top"><a href="#dial-2">dial/2</a></td><td></td></tr><tr><td valign="top"><a href="#dial_framed_stream-4">dial_framed_stream/4</a></td><td></td></tr><tr><td valign="top"><a href="#goaway-1">goaway/1</a></td><td></td></tr><tr><td valign="top"><a href="#open-1">open/1</a></td><td></td></tr><tr><td valign="top"><a href="#ping-1">ping/1</a></td><td></td></tr><tr><td valign="top"><a href="#streams-1">streams/1</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="addr_info-1"></a>

### addr_info/1 ###

<pre><code>
addr_info(Pid::pid()) -&gt; {string(), string()}
</code></pre>
<br />

<a name="close-1"></a>

### close/1 ###

<pre><code>
close(Pid::pid()) -&gt; ok
</code></pre>
<br />

<a name="close-3"></a>

### close/3 ###

<pre><code>
close(Pid::pid(), Reason::term(), Timeout::non_neg_integer() | infinity) -&gt; ok
</code></pre>
<br />

<a name="close_state-1"></a>

### close_state/1 ###

<pre><code>
close_state(Pid::pid()) -&gt; <a href="libp2p_connection.md#type-close_state">libp2p_connection:close_state()</a>
</code></pre>
<br />

<a name="dial-2"></a>

### dial/2 ###

<pre><code>
dial(Path::string(), SessionPid::pid()) -&gt; {ok, <a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>} | {error, term()}
</code></pre>
<br />

<a name="dial_framed_stream-4"></a>

### dial_framed_stream/4 ###

<pre><code>
dial_framed_stream(Path::string(), Session::pid(), Module::atom(), Args::[any()]) -&gt; {ok, Stream::pid()} | {error, term()} | ignore
</code></pre>
<br />

<a name="goaway-1"></a>

### goaway/1 ###

<pre><code>
goaway(Pid::pid()) -&gt; ok
</code></pre>
<br />

<a name="open-1"></a>

### open/1 ###

<pre><code>
open(Pid::pid()) -&gt; {ok, <a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>} | {error, term()}
</code></pre>
<br />

<a name="ping-1"></a>

### ping/1 ###

<pre><code>
ping(Pid::pid()) -&gt; {ok, pos_integer()} | {error, term()}
</code></pre>
<br />

<a name="streams-1"></a>

### streams/1 ###

<pre><code>
streams(Pid::pid()) -&gt; [pid()]
</code></pre>
<br />

