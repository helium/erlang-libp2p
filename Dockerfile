FROM erlang:20.3

WORKDIR /opt/libp2p

ADD rebar.config rebar.config
ADD rebar.lock rebar.lock
RUN rebar3 get-deps
RUN rebar3 compile

ADD eqc/ eqc/
ADD src/ src/
ADD test/ test/
RUN cp test/libp2p_stream_relay_test.erl src/libp2p_stream_relay_test.erl
RUN rebar3 compile

CMD ["rebar3", "shell"]
