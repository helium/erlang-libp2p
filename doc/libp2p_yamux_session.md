

# Module libp2p_yamux_session #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`gen_server`](gen_server.md).

<a name="types"></a>

## Data Types ##




### <a name="type-flags">flags()</a> ###


<pre><code>
flags() = non_neg_integer()
</code></pre>

0 | (bit combo of ?SYN | ?ACK | ?FIN | ?RST)



### <a name="type-header">header()</a> ###


<pre><code>
header() = #header{type = non_neg_integer(), flags = <a href="#type-flags">flags()</a>, stream_id = <a href="#type-stream_id">stream_id()</a>, length = non_neg_integer()}
</code></pre>




### <a name="type-stream_id">stream_id()</a> ###


<pre><code>
stream_id() = non_neg_integer()
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#handle_call-3">handle_call/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_cast-2">handle_cast/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_info-2">handle_info/2</a></td><td></td></tr><tr><td valign="top"><a href="#header_data-3">header_data/3</a></td><td></td></tr><tr><td valign="top"><a href="#header_length-1">header_length/1</a></td><td></td></tr><tr><td valign="top"><a href="#header_update-3">header_update/3</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#send_data-3">send_data/3</a></td><td></td></tr><tr><td valign="top"><a href="#send_data-4">send_data/4</a></td><td></td></tr><tr><td valign="top"><a href="#send_header-2">send_header/2</a></td><td></td></tr><tr><td valign="top"><a href="#send_header-3">send_header/3</a></td><td></td></tr><tr><td valign="top"><a href="#start_client-3">start_client/3</a></td><td></td></tr><tr><td valign="top"><a href="#start_server-4">start_server/4</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(Msg, From, State) -> any()`

<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(Msg, State) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Msg, State) -> any()`

<a name="header_data-3"></a>

### header_data/3 ###

<pre><code>
header_data(StreamID::<a href="#type-stream_id">stream_id()</a>, Flags::<a href="#type-flags">flags()</a>, Length::non_neg_integer()) -&gt; <a href="#type-header">header()</a>
</code></pre>
<br />

<a name="header_length-1"></a>

### header_length/1 ###

<pre><code>
header_length(Header::<a href="#type-header">header()</a>) -&gt; non_neg_integer()
</code></pre>
<br />

<a name="header_update-3"></a>

### header_update/3 ###

<pre><code>
header_update(Flags::<a href="#type-flags">flags()</a>, StreamID::<a href="#type-stream_id">stream_id()</a>, Length::non_neg_integer()) -&gt; <a href="#type-header">header()</a>
</code></pre>
<br />

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="send_data-3"></a>

### send_data/3 ###

<pre><code>
send_data(Pid::pid(), Header::<a href="#type-header">header()</a>, Data::binary()) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="send_data-4"></a>

### send_data/4 ###

<pre><code>
send_data(Pid::pid(), Header::<a href="#type-header">header()</a>, Data::binary(), Timeout::non_neg_integer()) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="send_header-2"></a>

### send_header/2 ###

<pre><code>
send_header(Pid::pid(), Header::<a href="#type-header">header()</a>) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="send_header-3"></a>

### send_header/3 ###

<pre><code>
send_header(Pid::pid(), Header::<a href="#type-header">header()</a>, Timeout::non_neg_integer()) -&gt; ok | {error, term()}
</code></pre>
<br />

<a name="start_client-3"></a>

### start_client/3 ###

<pre><code>
start_client(Connection::<a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>, Path::string(), TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; {ok, pid()}
</code></pre>
<br />

<a name="start_server-4"></a>

### start_server/4 ###

<pre><code>
start_server(Connection::<a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>, Path::string(), TID::<a href="ets.md#type-tab">ets:tab()</a>, X4::[]) -&gt; no_return()
</code></pre>
<br />

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

