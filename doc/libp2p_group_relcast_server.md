

# Module libp2p_group_relcast_server #
* [Function Index](#index)
* [Function Details](#functions)

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#accept_stream-4">accept_stream/4</a></td><td></td></tr><tr><td valign="top"><a href="#handle_ack-2">handle_ack/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_call-3">handle_call/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_cast-2">handle_cast/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_data-3">handle_data/3</a></td><td></td></tr><tr><td valign="top"><a href="#handle_info-2">handle_info/2</a></td><td></td></tr><tr><td valign="top"><a href="#handle_input-2">handle_input/2</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-4">start_link/4</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-2">terminate/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="accept_stream-4"></a>

### accept_stream/4 ###

`accept_stream(Pid, MAddr, StreamPid, Path) -> any()`

<a name="handle_ack-2"></a>

### handle_ack/2 ###

`handle_ack(Pid, Index) -> any()`

<a name="handle_call-3"></a>

### handle_call/3 ###

`handle_call(Msg, From, State) -> any()`

<a name="handle_cast-2"></a>

### handle_cast/2 ###

`handle_cast(Msg, State) -> any()`

<a name="handle_data-3"></a>

### handle_data/3 ###

`handle_data(Pid, Ref, Bin) -> any()`

<a name="handle_info-2"></a>

### handle_info/2 ###

`handle_info(Msg, State) -> any()`

<a name="handle_input-2"></a>

### handle_input/2 ###

`handle_input(Pid, Msg) -> any()`

<a name="init-1"></a>

### init/1 ###

`init(X1) -> any()`

<a name="start_link-4"></a>

### start_link/4 ###

`start_link(TID, GroupID, Args, Sup) -> any()`

<a name="terminate-2"></a>

### terminate/2 ###

`terminate(Reason, State) -> any()`

