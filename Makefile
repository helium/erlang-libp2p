.PHONY: compile rel cover test typecheck

REBAR=./rebar3
SHORTSHA=`git rev-parse --short HEAD`
PKG_NAME_VER=${SHORTSHA}

OS_NAME=$(shell uname -s)

ifeq (${OS_NAME},FreeBSD)
make="gmake"
else
MAKE="make"
endif

compile:
	$(REBAR) compile

clean:
	$(REBAR) clean
	$(REBAR) as prod clean

cover: test
	$(REBAR) cover

test: compile
	$(REBAR) eunit

typecheck:
	$(REBAR) dialyzer
