

# Module libp2p_crypto #
* [Data Types](#types)
* [Function Index](#index)
* [Function Details](#functions)

<a name="types"></a>

## Data Types ##




### <a name="type-address">address()</a> ###


<pre><code>
address() = <a href="ecc_compact.md#type-compact_key">ecc_compact:compact_key()</a>
</code></pre>




### <a name="type-private_key">private_key()</a> ###


<pre><code>
private_key() = #ECPrivateKey{}
</code></pre>




### <a name="type-public_key">public_key()</a> ###


<pre><code>
public_key() = {#ECPoint{}, {namedCurve, ?secp256r1}}
</code></pre>




### <a name="type-sig_fun">sig_fun()</a> ###


<pre><code>
sig_fun() = fun((binary()) -&gt; binary())
</code></pre>

<a name="index"></a>

## Function Index ##


<table width="100%" border="1" cellspacing="0" cellpadding="2" summary="function index"><tr><td valign="top"><a href="#address_to_b58-1">address_to_b58/1</a></td><td></td></tr><tr><td valign="top"><a href="#address_to_pubkey-1">address_to_pubkey/1</a></td><td></td></tr><tr><td valign="top"><a href="#b58_to_address-1">b58_to_address/1</a></td><td></td></tr><tr><td valign="top"><a href="#b58_to_pubkey-1">b58_to_pubkey/1</a></td><td></td></tr><tr><td valign="top"><a href="#generate_keys-0">generate_keys/0</a></td><td>Generate keys suitable for a swarm.</td></tr><tr><td valign="top"><a href="#load_keys-1">load_keys/1</a></td><td>Load the private key from a pem encoded given filename.</td></tr><tr><td valign="top"><a href="#mk_sig_fun-1">mk_sig_fun/1</a></td><td></td></tr><tr><td valign="top"><a href="#pubkey_to_address-1">pubkey_to_address/1</a></td><td></td></tr><tr><td valign="top"><a href="#pubkey_to_b58-1">pubkey_to_b58/1</a></td><td></td></tr><tr><td valign="top"><a href="#save_keys-2">save_keys/2</a></td><td>Store the given keys in a file.</td></tr><tr><td valign="top"><a href="#verify-3">verify/3</a></td><td>Verifies a digital signature, using sha256.</td></tr></table>


<a name="functions"></a>

## Function Details ##

<a name="address_to_b58-1"></a>

### address_to_b58/1 ###

<pre><code>
address_to_b58(Addr::<a href="#type-address">address()</a>) -&gt; string()
</code></pre>
<br />

<a name="address_to_pubkey-1"></a>

### address_to_pubkey/1 ###

<pre><code>
address_to_pubkey(Addr::<a href="#type-address">address()</a>) -&gt; <a href="#type-public_key">public_key()</a>
</code></pre>
<br />

<a name="b58_to_address-1"></a>

### b58_to_address/1 ###

<pre><code>
b58_to_address(Str::string()) -&gt; <a href="#type-address">address()</a>
</code></pre>
<br />

<a name="b58_to_pubkey-1"></a>

### b58_to_pubkey/1 ###

<pre><code>
b58_to_pubkey(Str::string()) -&gt; <a href="#type-public_key">public_key()</a>
</code></pre>
<br />

<a name="generate_keys-0"></a>

### generate_keys/0 ###

<pre><code>
generate_keys() -&gt; {<a href="#type-private_key">private_key()</a>, <a href="#type-public_key">public_key()</a>}
</code></pre>
<br />

Generate keys suitable for a swarm.  The returned private and
public key has the attribute that the public key is a compressable
public key.

<a name="load_keys-1"></a>

### load_keys/1 ###

<pre><code>
load_keys(FileName::string()) -&gt; {ok, <a href="#type-private_key">private_key()</a>, <a href="#type-public_key">public_key()</a>} | {error, term()}
</code></pre>
<br />

Load the private key from a pem encoded given filename.
Returns the private and extracted public key stored in the file or
an error if any occorred.

<a name="mk_sig_fun-1"></a>

### mk_sig_fun/1 ###

<pre><code>
mk_sig_fun(PrivKey::<a href="#type-private_key">private_key()</a>) -&gt; <a href="#type-sig_fun">sig_fun()</a>
</code></pre>
<br />

<a name="pubkey_to_address-1"></a>

### pubkey_to_address/1 ###

<pre><code>
pubkey_to_address(PubKey::<a href="#type-public_key">public_key()</a> | <a href="ecc_compact.md#type-compact_key">ecc_compact:compact_key()</a>) -&gt; <a href="#type-address">address()</a>
</code></pre>
<br />

<a name="pubkey_to_b58-1"></a>

### pubkey_to_b58/1 ###

<pre><code>
pubkey_to_b58(PubKey::<a href="#type-public_key">public_key()</a> | <a href="ecc_compact.md#type-compact_key">ecc_compact:compact_key()</a>) -&gt; string()
</code></pre>
<br />

<a name="save_keys-2"></a>

### save_keys/2 ###

<pre><code>
save_keys(X1::{<a href="#type-private_key">private_key()</a>, <a href="#type-public_key">public_key()</a>}, FileName::string()) -&gt; ok | {error, term()}
</code></pre>
<br />

Store the given keys in a file.  See @see key_folder/1 for a
utility function that returns a name and location for the keys that
are relative to the swarm data folder.

<a name="verify-3"></a>

### verify/3 ###

<pre><code>
verify(Bin::binary(), Signature::binary(), PubKey::<a href="#type-public_key">public_key()</a>) -&gt; boolean()
</code></pre>
<br />

Verifies a digital signature, using sha256.

