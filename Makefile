.PHONY: compile rel cover test typecheck doc ci

REBAR=./rebar3
SHORTSHA=`git rev-parse --short HEAD`
PKG_NAME_VER=${SHORTSHA}

OS_NAME=$(shell uname -s)

ifeq (${OS_NAME},FreeBSD)
make="gmake"
else
MAKE="make"
endif

ifeq ($(BUILDKITE), true)
  # get branch name and replace any forward slashes it may contain
  CIBRANCH=$(subst /,-,$(BUILDKITE_BRANCH))
else
  CIBRANCH=$(shell git rev-parse --abbrev-ref HEAD | sed 's/\//-/')
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
	$(REBAR) as test do cover && $(REBAR) do xref, dialyzer && ($(REBAR) do eunit,ct || (mkdir -p artifacts; tar --exclude='./_build/test/lib' --exclude='./_build/test/plugins' -czf artifacts/$(CIBRANCH).tar.gz _build/test; false))
	$(REBAR) covertool generate
	codecov --required -f _build/test/covertool/libp2p.covertool.xml

typecheck:
	$(REBAR) dialyzer

doc:
	$(REBAR) edoc
