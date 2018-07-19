

# Module libp2p_yamux_stream #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-opt">opt()</a> ###


<pre><code>
opt() = {max_window, pos_integer()}
</code></pre>




### <a name="type-stream">stream()</a> ###


<pre><code>
stream() = reference()
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#acknowledge-2">acknowledge/2</a></td><td></td></tr><tr><td valign="top"><a href="#addr_info-1">addr_info/1</a></td><td></td></tr><tr><td valign="top"><a href="#callback_mode-0">callback_mode/0</a></td><td></td></tr><tr><td valign="top"><a href="#close-1">close/1</a></td><td></td></tr><tr><td valign="top"><a href="#close_state-1">close_state/1</a></td><td></td></tr><tr><td valign="top"><a href="#controlling_process-2">controlling_process/2</a></td><td></td></tr><tr><td valign="top"><a href="#fdclr-1">fdclr/1</a></td><td></td></tr><tr><td valign="top"><a href="#fdset-1">fdset/1</a></td><td></td></tr><tr><td valign="top"><a href="#handle_event-4">handle_event/4</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#new_connection-1">new_connection/1</a></td><td></td></tr><tr><td valign="top"><a href="#open_stream-3">open_stream/3</a></td><td></td></tr><tr><td valign="top"><a href="#receive_data-2">receive_data/2</a></td><td></td></tr><tr><td valign="top"><a href="#receive_stream-3">receive_stream/3</a></td><td></td></tr><tr><td valign="top"><a href="#recv-3">recv/3</a></td><td></td></tr><tr><td valign="top"><a href="#send-3">send/3</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-3">terminate/3</a></td><td></td></tr><tr><td valign="top"><a href="#update_window-3">update_window/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="acknowledge-2"></a>

### acknowledge/2 ###

`acknowledge(X1, X2) -> any()`

<a name="addr_info-1"></a>

### addr_info/1 ###

`addr_info(Pid) -> any()`

<a name="callback_mode-0"></a>

### callback_mode/0 ###

`callback_mode() -> any()`

<a name="close-1"></a>

### close/1 ###

`close(Pid) -> any()`

<a name="close_state-1"></a>

### close_state/1 ###

`close_state(Pid) -> any()`

<a name="controlling_process-2"></a>

### controlling_process/2 ###

`controlling_process(Pid, Owner) -> any()`

<a name="fdclr-1"></a>

### fdclr/1 ###

`fdclr(Pid) -> any()`

<a name="fdset-1"></a>

### fdset/1 ###

`fdset(Pid) -> any()`

<a name="handle_event-4"></a>

### handle_event/4 ###

`handle_event(EventType, Event, State, Data) -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="new_connection-1"></a>

### new_connection/1 ###

`new_connection(Pid) -> any()`

<a name="open_stream-3"></a>

### open_stream/3 ###

`open_stream(Session, TID, StreamID) -> any()`

<a name="receive_data-2"></a>

### receive_data/2 ###

`receive_data(Ref, Data) -> any()`

<a name="receive_stream-3"></a>

### receive_stream/3 ###

`receive_stream(Session, TID, StreamID) -> any()`

<a name="recv-3"></a>

### recv/3 ###

`recv(Pid, Size, Timeout) -> any()`

<a name="send-3"></a>

### send/3 ###

`send(Pid, Data, Timeout) -> any()`

<a name="terminate-3"></a>

### terminate/3 ###

`terminate(Reason, State, Data) -> any()`

<a name="update_window-3"></a>

### update_window/3 ###

`update_window(Ref, Flags, Header) -> any()`

