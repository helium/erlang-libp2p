

# Module libp2p_group #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-stream_client_spec">stream_client_spec()</a> ###


<pre><code>
stream_client_spec() = {Path::string(), {Module::atom(), Args::[any()]}}
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#send-2">send/2</a></td><td>Send the given data to the member of the group.</td></tr><tr><td valign="top"><a href="#sessions-1">sessions/1</a></td><td>Get the active list of sessions and their associated
multiaddress.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="send-2"></a>

### send/2 ###

<pre><code>
send(Pid::pid(), Data::iodata()) -&gt; ok | {error, term()}
</code></pre>
<br />

Send the given data to the member of the group. The
implementation of the group determines the strategy used for
delivery. For gossip groups, for example, delivery is best effort.

<a name="sessions-1"></a>

### sessions/1 ###

<pre><code>
sessions(Pid::pid()) -&gt; [{string(), pid()}]
</code></pre>
<br />

Get the active list of sessions and their associated
multiaddress.

