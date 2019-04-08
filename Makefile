.PHONY: compile rel cover test typecheck doc

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

shell:
	$(REBAR) shell

clean:
	$(REBAR) clean

cover:
	$(REBAR) cover

test:
	$(REBAR) as test do eunit,ct

ci:
	$(REBAR) dialyzer && $(REBAR) as test do eunit,ct 2>&1 | tee build.log | sed 's/^\(\x1b\[[0-9;]*m\)*>>>/---/'

typecheck:
	$(REBAR) dialyzer

doc:
	$(REBAR) edoc
