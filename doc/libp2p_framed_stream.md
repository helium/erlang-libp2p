

# Module libp2p_framed_stream #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

__This module defines the `libp2p_framed_stream` behaviour.__<br /> Required callback functions: `server/4`, `client/2`, `init/3`, `handle_data/3`.

<a name="types"></a>

## Data Types ##




### <a name="type-handle_call_result">handle_call_result()</a> ###


<pre><code>
handle_call_result() = {reply, Reply::term(), ModState::any()} | {reply, Reply::term(), ModState::any(), Response::<a href="#type-response">response()</a>} | {noreply, ModState::any()} | {noreply, ModState::any(), Response::<a href="#type-response">response()</a>} | {stop, Reason::term(), Reply::term(), ModState::any()} | {stop, Reason::term(), ModState::any()} | {stop, Reason::term(), Reply::term(), ModState::any(), Response::<a href="#type-response">response()</a>} | {stop, Reason::term(), ModState::any(), Response::<a href="#type-response">response()</a>}
</code></pre>




### <a name="type-handle_cast_result">handle_cast_result()</a> ###


<pre><code>
handle_cast_result() = {noreply, ModState::any()} | {noreply, ModState::any(), Response::<a href="#type-response">response()</a>} | {stop, Reason::term(), ModState::any()} | {stop, Reason::term(), ModState::any(), Response::<a href="#type-response">response()</a>}
</code></pre>




### <a name="type-handle_data_result">handle_data_result()</a> ###


<pre><code>
handle_data_result() = {noreply, ModState::any()} | {noreply, ModState::any(), Response::<a href="#type-response">response()</a>} | {stop, Reason::term(), ModState::any()} | {stop, Reason::term(), ModState::any(), Response::<a href="#type-response">response()</a>}
</code></pre>




### <a name="type-handle_info_result">handle_info_result()</a> ###


<pre><code>
handle_info_result() = {noreply, ModState::any()} | {noreply, ModState::any(), Response::<a href="#type-response">response()</a>} | {stop, Reason::term(), ModState::any()} | {stop, Reason::term(), ModState::any(), Response::<a href="#type-response">response()</a>}
</code></pre>




### <a name="type-init_result">init_result()</a> ###


<pre><code>
init_result() = {ok, ModState::any()} | {ok, ModState::any(), Response::<a href="#type-response">response()</a>} | {stop, Reason::term()} | {stop, Reason::term(), Response::<a href="#type-response">response()</a>}
</code></pre>




### <a name="type-kind">kind()</a> ###


<pre><code>
kind() = server | client
</code></pre>




### <a name="type-response">response()</a> ###


<pre><code>
response() = binary()
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#addr_info-1">addr_info/1</a></td><td></td></tr><tr><td valign="top"><a href="#client-3">client/3</a></td><td></td></tr><tr><td valign="top"><a href="#close-1">close/1</a></td><td></td></tr><tr><td valign="top"><a href="#close_state-1">close_state/1</a></td><td></td></tr><tr><td valign="top"><a href="#handle_call-3">handle_call/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_cast-2">handle_cast/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_info-2">handle_info/2</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#send-2">send/2</a></td><td></td></tr><tr><td valign="top"><a href="#send-3">send/3</a></td><td></td></tr><tr><td valign="top"><a href="#server-3">server/3</a></td><td></td></tr><tr><td valign="top"><a href="#server-4">server/4</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="addr_info-1"></a>

### addr_info/1 ###

`addr_info(Pid) -> any()`

<a name="client-3"></a>

### client/3 ###

<pre><code>
client(Module::atom(), Connection::<a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>, Args::[any()]) -&gt; {ok, pid()} | {error, term()} | ignore
</code></pre>
<br />

<a name="close-1"></a>

### close/1 ###

`close(Pid) -> any()`

<a name="close_state-1"></a>

### close_state/1 ###

`close_state(Pid) -> any()`

<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(Msg, From, State) -> any()`

<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(Request, State) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Msg, State) -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="send-2"></a>

### send/2 ###

`send(Pid, Data) -> any()`

<a name="send-3"></a>

### send/3 ###

`send(Pid, Data, Timeout) -> any()`

<a name="server-3"></a>

### server/3 ###

<pre><code>
server(Module::atom(), Connection::<a href="libp2p_connection.md#type-connection">libp2p_connection:connection()</a>, Args::[any()]) -&gt; no_return() | {error, term()}
</code></pre>
<br />

<a name="server-4"></a>

### server/4 ###

`server(Connection, Path, TID, Args) -> any()`

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

