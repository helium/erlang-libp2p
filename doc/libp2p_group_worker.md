

# Module libp2p_group_worker #
* [Function Index](#index)
* [Function Details](#functions)

__Behaviours:__ [`gen_statem`](gen_statem.md).

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#ack-1">ack/1</a></td><td></td></tr><tr><td valign="top"><a href="#assign_stream-3">assign_stream/3</a></td><td></td></tr><tr><td valign="top"><a href="#assign_target-2">assign_target/2</a></td><td></td></tr><tr><td valign="top"><a href="#callback_mode-0">callback_mode/0</a></td><td></td></tr><tr><td valign="top"><a href="#connect-3">connect/3</a></td><td></td></tr><tr><td valign="top"><a href="#init-1">init/1</a></td><td></td></tr><tr><td valign="top"><a href="#request_target-3">request_target/3</a></td><td></td></tr><tr><td valign="top"><a href="#send-3">send/3</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-4">start_link/4</a></td><td></td></tr><tr><td valign="top"><a href="#terminate-3">terminate/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="ack-1"></a>

### ack/1 ###

<pre><code>
ack(Pid::pid()) -&gt; ok
</code></pre>
<br />

<a name="assign_stream-3"></a>

### assign_stream/3 ###

`assign_stream(Pid, MAddr, Connection) -> any()`

<a name="assign_target-2"></a>

### assign_target/2 ###

<pre><code>
assign_target(Pid::pid(), MAddr::string() | undefined) -&gt; ok
</code></pre>
<br />

<a name="callback_mode-0"></a>

### callback_mode/0 ###

`callback_mode() -> any()`

<a name="connect-3"></a>

### connect/3 ###

<pre><code>
connect(EventType::enter, Msg::term(), Data::term()) -&gt; <a href="gen_statem.md#type-state_enter_result">gen_statem:state_enter_result</a>(connect)
</code></pre>
<br />

<a name="init-1"></a>

### init/1 ###

<pre><code>
init(Args::term()) -&gt; <a href="gen_statem.md#type-init_result">gen_statem:init_result</a>(atom())
</code></pre>
<br />

<a name="request_target-3"></a>

### request_target/3 ###

<pre><code>
request_target(EventType::enter, Msg::term(), Data::term()) -&gt; <a href="gen_statem.md#type-state_enter_result">gen_statem:state_enter_result</a>(request_target)
</code></pre>
<br />

<a name="send-3"></a>

### send/3 ###

<pre><code>
send(Pid::pid(), Ref::term(), Data::binary()) -&gt; ok
</code></pre>
<br />

<a name="start_link-4"></a>

### start_link/4 ###

<pre><code>
start_link(Kind::atom(), ClientSpec::<a href="libp2p_group.md#type-stream_client_spec">libp2p_group:stream_client_spec()</a>, Server::pid(), TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; {ok, Pid::pid()} | ignore | {error, Error::term()}
</code></pre>
<br />

<a name="terminate-3"></a>

### terminate/3 ###

<pre><code>
terminate(Reason::term(), State::term(), Data::term()) -&gt; any()
</code></pre>
<br />

