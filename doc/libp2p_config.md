

# Module libp2p_config #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-handler">handler()</a> ###


<pre><code>
handler() = {atom(), atom()}
</code></pre>




### <a name="type-opts">opts()</a> ###


<pre><code>
opts() = [{atom(), any()}]
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#base_dir-1">base_dir/1</a></td><td></td></tr><tr><td valign="top"><a href="#get_opt-2">get_opt/2</a></td><td></td></tr><tr><td valign="top"><a href="#get_opt-3">get_opt/3</a></td><td></td></tr><tr><td valign="top"><a href="#insert_connection_handler-2">insert_connection_handler/2</a></td><td></td></tr><tr><td valign="top"><a href="#insert_group-3">insert_group/3</a></td><td></td></tr><tr><td valign="top"><a href="#insert_listener-3">insert_listener/3</a></td><td></td></tr><tr><td valign="top"><a href="#insert_pid-4">insert_pid/4</a></td><td></td></tr><tr><td valign="top"><a href="#insert_session-3">insert_session/3</a></td><td></td></tr><tr><td valign="top"><a href="#insert_stream_handler-2">insert_stream_handler/2</a></td><td></td></tr><tr><td valign="top"><a href="#insert_transport-3">insert_transport/3</a></td><td></td></tr><tr><td valign="top"><a href="#listen_addrs-1">listen_addrs/1</a></td><td></td></tr><tr><td valign="top"><a href="#listener-0">listener/0</a></td><td></td></tr><tr><td valign="top"><a href="#lookup_connection_handlers-1">lookup_connection_handlers/1</a></td><td></td></tr><tr><td valign="top"><a href="#lookup_group-2">lookup_group/2</a></td><td></td></tr><tr><td valign="top"><a href="#lookup_listener-2">lookup_listener/2</a></td><td></td></tr><tr><td valign="top"><a href="#lookup_pid-3">lookup_pid/3</a></td><td></td></tr><tr><td valign="top"><a href="#lookup_pids-2">lookup_pids/2</a></td><td></td></tr><tr><td valign="top"><a href="#lookup_session-2">lookup_session/2</a></td><td></td></tr><tr><td valign="top"><a href="#lookup_session-3">lookup_session/3</a></td><td></td></tr><tr><td valign="top"><a href="#lookup_sessions-1">lookup_sessions/1</a></td><td></td></tr><tr><td valign="top"><a href="#lookup_stream_handlers-1">lookup_stream_handlers/1</a></td><td></td></tr><tr><td valign="top"><a href="#lookup_transport-2">lookup_transport/2</a></td><td></td></tr><tr><td valign="top"><a href="#lookup_transports-1">lookup_transports/1</a></td><td></td></tr><tr><td valign="top"><a href="#remove_group-2">remove_group/2</a></td><td></td></tr><tr><td valign="top"><a href="#remove_listener-2">remove_listener/2</a></td><td></td></tr><tr><td valign="top"><a href="#remove_pid-3">remove_pid/3</a></td><td></td></tr><tr><td valign="top"><a href="#remove_session-2">remove_session/2</a></td><td></td></tr><tr><td valign="top"><a href="#session-0">session/0</a></td><td></td></tr><tr><td valign="top"><a href="#swarm_dir-2">swarm_dir/2</a></td><td></td></tr><tr><td valign="top"><a href="#transport-0">transport/0</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="base_dir-1"></a>

### base_dir/1 ###

`base_dir(TID) -> any()`

<a name="get_opt-2"></a>

### get_opt/2 ###

<pre><code>
get_opt(Opts::<a href="#type-opts">opts()</a>, L::atom() | list()) -&gt; undefined | {ok, any()}
</code></pre>
<br />

<a name="get_opt-3"></a>

### get_opt/3 ###

<pre><code>
get_opt(Opts::<a href="#type-opts">opts()</a>, K::atom() | list(), Default::any()) -&gt; any()
</code></pre>
<br />

<a name="insert_connection_handler-2"></a>

### insert_connection_handler/2 ###

<pre><code>
insert_connection_handler(TID::<a href="ets.md#type-tab">ets:tab()</a>, X2::{string(), <a href="#type-handler">handler()</a>, <a href="#type-handler">handler()</a>}) -&gt; true
</code></pre>
<br />

<a name="insert_group-3"></a>

### insert_group/3 ###

<pre><code>
insert_group(TID::<a href="ets.md#type-tab">ets:tab()</a>, GroupID::string(), Pid::pid()) -&gt; true
</code></pre>
<br />

<a name="insert_listener-3"></a>

### insert_listener/3 ###

<pre><code>
insert_listener(TID::<a href="ets.md#type-tab">ets:tab()</a>, Addrs::[string()], Pid::pid()) -&gt; true
</code></pre>
<br />

<a name="insert_pid-4"></a>

### insert_pid/4 ###

<pre><code>
insert_pid(TID::<a href="ets.md#type-tab">ets:tab()</a>, Kind::atom(), Ref::term(), Pid::pid()) -&gt; true
</code></pre>
<br />

<a name="insert_session-3"></a>

### insert_session/3 ###

<pre><code>
insert_session(TID::<a href="ets.md#type-tab">ets:tab()</a>, Addr::string(), Pid::pid()) -&gt; true
</code></pre>
<br />

<a name="insert_stream_handler-2"></a>

### insert_stream_handler/2 ###

<pre><code>
insert_stream_handler(TID::<a href="ets.md#type-tab">ets:tab()</a>, X2::{string(), <a href="libp2p_session.md#type-stream_handler">libp2p_session:stream_handler()</a>}) -&gt; true
</code></pre>
<br />

<a name="insert_transport-3"></a>

### insert_transport/3 ###

<pre><code>
insert_transport(TID::<a href="ets.md#type-tab">ets:tab()</a>, Module::atom(), Pid::pid()) -&gt; true
</code></pre>
<br />

<a name="listen_addrs-1"></a>

### listen_addrs/1 ###

<pre><code>
listen_addrs(TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; [string()]
</code></pre>
<br />

<a name="listener-0"></a>

### listener/0 ###

<pre><code>
listener() -&gt; ?LISTENER
</code></pre>
<br />

<a name="lookup_connection_handlers-1"></a>

### lookup_connection_handlers/1 ###

<pre><code>
lookup_connection_handlers(TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; [{string(), {<a href="#type-handler">handler()</a>, <a href="#type-handler">handler()</a>}}]
</code></pre>
<br />

<a name="lookup_group-2"></a>

### lookup_group/2 ###

<pre><code>
lookup_group(TID::<a href="ets.md#type-tab">ets:tab()</a>, GroupID::string()) -&gt; {ok, pid()} | false
</code></pre>
<br />

<a name="lookup_listener-2"></a>

### lookup_listener/2 ###

<pre><code>
lookup_listener(TID::<a href="ets.md#type-tab">ets:tab()</a>, Addr::string()) -&gt; {ok, pid()} | false
</code></pre>
<br />

<a name="lookup_pid-3"></a>

### lookup_pid/3 ###

<pre><code>
lookup_pid(TID::<a href="ets.md#type-tab">ets:tab()</a>, Kind::atom(), Ref::term()) -&gt; {ok, pid()} | false
</code></pre>
<br />

<a name="lookup_pids-2"></a>

### lookup_pids/2 ###

<pre><code>
lookup_pids(TID::<a href="ets.md#type-tab">ets:tab()</a>, Kind::atom()) -&gt; [{term(), pid()}]
</code></pre>
<br />

<a name="lookup_session-2"></a>

### lookup_session/2 ###

<pre><code>
lookup_session(TID::<a href="ets.md#type-tab">ets:tab()</a>, Addr::string()) -&gt; {ok, pid()} | false
</code></pre>
<br />

<a name="lookup_session-3"></a>

### lookup_session/3 ###

<pre><code>
lookup_session(TID::<a href="ets.md#type-tab">ets:tab()</a>, Addr::string(), Options::<a href="#type-opts">opts()</a>) -&gt; {ok, pid()} | false
</code></pre>
<br />

<a name="lookup_sessions-1"></a>

### lookup_sessions/1 ###

<pre><code>
lookup_sessions(TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; [{term(), pid()}]
</code></pre>
<br />

<a name="lookup_stream_handlers-1"></a>

### lookup_stream_handlers/1 ###

<pre><code>
lookup_stream_handlers(TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; [{string(), <a href="libp2p_session.md#type-stream_handler">libp2p_session:stream_handler()</a>}]
</code></pre>
<br />

<a name="lookup_transport-2"></a>

### lookup_transport/2 ###

<pre><code>
lookup_transport(TID::<a href="ets.md#type-tab">ets:tab()</a>, Module::atom()) -&gt; {ok, pid()} | false
</code></pre>
<br />

<a name="lookup_transports-1"></a>

### lookup_transports/1 ###

<pre><code>
lookup_transports(TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; [{term(), pid()}]
</code></pre>
<br />

<a name="remove_group-2"></a>

### remove_group/2 ###

<pre><code>
remove_group(TID::<a href="ets.md#type-tab">ets:tab()</a>, GroupID::string()) -&gt; true
</code></pre>
<br />

<a name="remove_listener-2"></a>

### remove_listener/2 ###

<pre><code>
remove_listener(TID::<a href="ets.md#type-tab">ets:tab()</a>, Addr::string()) -&gt; true
</code></pre>
<br />

<a name="remove_pid-3"></a>

### remove_pid/3 ###

<pre><code>
remove_pid(TID::<a href="ets.md#type-tab">ets:tab()</a>, Kind::atom(), Ref::term()) -&gt; true
</code></pre>
<br />

<a name="remove_session-2"></a>

### remove_session/2 ###

<pre><code>
remove_session(TID::<a href="ets.md#type-tab">ets:tab()</a>, Addr::string()) -&gt; true
</code></pre>
<br />

<a name="session-0"></a>

### session/0 ###

<pre><code>
session() -&gt; ?SESSION
</code></pre>
<br />

<a name="swarm_dir-2"></a>

### swarm_dir/2 ###

<pre><code>
swarm_dir(TID::<a href="ets.md#type-tab">ets:tab()</a>, Names::[<a href="file.md#type-name_all">file:name_all()</a>]) -&gt; <a href="file.md#type-filename_all">file:filename_all()</a>
</code></pre>
<br />

<a name="transport-0"></a>

### transport/0 ###

<pre><code>
transport() -&gt; ?TRANSPORT
</code></pre>
<br />

