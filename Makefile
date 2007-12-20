SOURCE_DIR=src
EBIN_DIR=ebin
INCLUDE_DIR=include
INCLUDES=$(wildcard $(INCLUDE_DIR)/*.hrl)
SOURCES=$(wildcard $(SOURCE_DIR)/*.erl)
TARGETS=$(patsubst $(SOURCE_DIR)/%.erl, $(EBIN_DIR)/%.beam,$(SOURCES))
ERLC_OPTS=-I $(INCLUDE_DIR) -o $(EBIN_DIR) -Wall +debug_info # +native -v

all: $(TARGETS)

$(EBIN_DIR)/%.beam: $(SOURCE_DIR)/%.erl $(INCLUDES)
	erlc $(ERLC_OPTS) $<

clean:
	rm -f ebin/*.beam $(TARGETS)

run: all start_server

RABBIT_SOURCE_ROOT=../AMQ
start_server:
	make -C $(RABBIT_SOURCE_ROOT)/erlang/rabbit run \
		RABBIT_ARGS='-pa '"$$(pwd)/$(EBIN_DIR)"' -rabbit \
			stomp_listeners [{\"0.0.0.0\",61613}] \
			extra_startup_steps [{\"STOMP-listeners\",rabbit_stomp,kickstart,[]}]'