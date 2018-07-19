

# Module libp2p_ack_stream #
* [Function Index](#index)
* [Function Details](#functions)

__This module defines the `libp2p_ack_stream` behaviour.__<br /> Required callback functions: `handle_data/3`, `accept_stream/4`.

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#client-2">client/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_cast-3">handle_cast/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_data-3">handle_data/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_send-5">handle_send/5</a></td><td></td></tr><tr><td valign="top"><a href="#init-3">init/3</a></td><td></td></tr><tr><td valign="top"><a href="#server-4">server/4</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="client-2"></a>

### client/2 ###

`client(Connection, Args) -> any()`

<a name="handle_cast-3"></a>

### handle_cast/3 ###

`handle_cast(Kind, X2, State) -> any()`

<a name="handle_data-3"></a>

### handle_data/3 ###

`handle_data(Kind, Data, State) -> any()`

<a name="handle_send-5"></a>

### handle_send/5 ###

`handle_send(Kind, From, Data, Timeout, State) -> any()`

<a name="init-3"></a>

### init/3 ###

`init(X1, Connection, X3) -> any()`

<a name="server-4"></a>

### server/4 ###

`server(Connection, Path, TID, Args) -> any()`

