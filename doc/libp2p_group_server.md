

# Module libp2p_group_server #
* [Function Index](#index)
* [Function Details](#functions)

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#request_target-3">request_target/3</a></td><td></td></tr><tr><td valign="top"><a href="#send_ready-3">send_ready/3</a></td><td></td></tr><tr><td valign="top"><a href="#send_result-3">send_result/3</a></td><td></td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="request_target-3"></a>

### request_target/3 ###

<pre><code>
request_target(Server::pid(), Kind::term(), Worker::pid()) -&gt; ok
</code></pre>
<br />

<a name="send_ready-3"></a>

### send_ready/3 ###

<pre><code>
send_ready(Server::pid(), Ref::term(), Ready::boolean()) -&gt; ok
</code></pre>
<br />

<a name="send_result-3"></a>

### send_result/3 ###

<pre><code>
send_result(Server::pid(), Ref::term(), Result::any()) -&gt; ok
</code></pre>
<br />

