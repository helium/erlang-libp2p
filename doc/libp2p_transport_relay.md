

# Module libp2p_transport_relay #
* [Function Index](#index)
* [Function Details](#functions)

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#connect-5">connect/5</a></td><td></td></tr><tr><td valign="top"><a href="#match_addr-1">match_addr/1</a></td><td></td></tr><tr><td valign="top"><a href="#reg-1">reg/1</a></td><td></td></tr><tr><td valign="top"><a href="#start_link-1">start_link/1</a></td><td></td></tr><tr><td valign="top"><a href="#start_listener-2">start_listener/2</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="connect-5"></a>

### connect/5 ###

<pre><code>
connect(Pid::pid(), MAddr::string(), Options::<a href="libp2p_swarm.md#type-connect_opts">libp2p_swarm:connect_opts()</a>, Timeout::pos_integer(), TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; {ok, pid()} | {error, term()}
</code></pre>
<br />

<a name="match_addr-1"></a>

### match_addr/1 ###

<pre><code>
match_addr(Addr::string()) -&gt; {ok, string()} | false
</code></pre>
<br />

<a name="reg-1"></a>

### reg/1 ###

<pre><code>
reg(Address::string()) -&gt; atom()
</code></pre>
<br />

<a name="start_link-1"></a>

### start_link/1 ###

<pre><code>
start_link(TID::<a href="ets.md#type-tab">ets:tab()</a>) -&gt; ignore
</code></pre>
<br />

<a name="start_listener-2"></a>

### start_listener/2 ###

<pre><code>
start_listener(Pid::pid(), Addr::string()) -&gt; {error, unsupported}
</code></pre>
<br />

