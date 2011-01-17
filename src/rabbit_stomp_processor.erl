%%   The contents of this file are subject to the Mozilla Public License
%%   Version 1.1 (the "License"); you may not use this file except in
%%   compliance with the License. You may obtain a copy of the License at
%%   http://www.mozilla.org/MPL/
%%
%%   Software distributed under the License is distributed on an "AS IS"
%%   basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%   License for the specific language governing rights and limitations
%%   under the License.
%%
%%   The Original Code is RabbitMQ.
%%
%%   The Initial Developers of the Original Code are LShift Ltd,
%%   Cohesive Financial Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created before 22-Nov-2008 00:00:00 GMT by LShift Ltd,
%%   Cohesive Financial Technologies LLC, or Rabbit Technologies Ltd
%%   are Copyright (C) 2007-2008 LShift Ltd, Cohesive Financial
%%   Technologies LLC, and Rabbit Technologies Ltd.
%%
%%   Portions created by LShift Ltd are Copyright (C) 2007-2009 LShift
%%   Ltd. Portions created by Cohesive Financial Technologies LLC are
%%   Copyright (C) 2007-2009 Cohesive Financial Technologies
%%   LLC. Portions created by Rabbit Technologies Ltd are Copyright
%%   (C) 2007-2009 Rabbit Technologies Ltd.
%%
%%   All Rights Reserved.
%%
%%   Contributor(s): ______________________________________.
%%
-module(rabbit_stomp_processor).
-behaviour(gen_server).

-export([start_link/1, process_frame/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         code_change/3, terminate/2]).

-include_lib("amqp_client/include/amqp_client.hrl").
-include("rabbit_stomp_frame.hrl").

-record(state, {socket, session_id, channel, connection, subscriptions}).

%%----------------------------------------------------------------------------
%% Public API
%%----------------------------------------------------------------------------
start_link(Sock) ->
    gen_server:start_link(?MODULE, [Sock], []).

process_frame(Pid, Frame = #stomp_frame{command = Command}) ->
    gen_server:cast(Pid, {Command, Frame}).

%%----------------------------------------------------------------------------
%% Basic gen_server callbacks
%%----------------------------------------------------------------------------

init([Sock]) ->
    process_flag(trap_exit, true),
    {ok,
     #state {
       socket        = Sock,
       session_id    = none,
       channel       = none,
       connection    = none,
       subscriptions = dict:new()}
    }.

terminate(_Reason, State) ->
    shutdown_channel_and_connection(State).

handle_cast({"CONNECT", Frame}, State = #state{channel = none}) ->
    {ok, DefaultVHost} = application:get_env(rabbit, default_vhost),
    process_request(
      fun(StateN) ->
              do_login(rabbit_stomp_frame:header(Frame, "login"),
                       rabbit_stomp_frame:header(Frame, "passcode"),
                       rabbit_stomp_frame:header(Frame, "virtual-host",
                                                 binary_to_list(DefaultVHost)),
                       StateN)
      end,
      fun(StateM) -> StateM end,
      State);

handle_cast(_Request, State = #state{channel = none}) ->
    error("Illegal command", "You must log in using CONNECT first\n", State);

handle_cast({Command, Frame}, State) ->
    process_request(
      fun(StateN) ->
              handle_frame(Command, Frame, StateN)
      end,
      fun(StateM) ->
              ensure_receipt(Frame, StateM)
      end,
      State).

handle_info(#'basic.consume_ok'{}, State) ->
    {noreply, State};
handle_info({Delivery = #'basic.deliver'{},
             #amqp_msg{props = Props, payload = Payload}}, State) ->
    {noreply, send_delivery(Delivery, Props, Payload, State)}.

process_request(ProcessFun, SuccessFun, State) ->
    Res = case catch ProcessFun(State) of
              {'EXIT',
               {{server_initiated_close, ReplyCode, Explanation}, _}} ->
                  amqp_death(ReplyCode, Explanation, State);
              {'EXIT', Reason} ->
                  priv_error("Processing error", "Processing error\n",
                              Reason, State);
              Result ->
                  Result
          end,
    case Res of
        {ok, Frame, NewState} ->
            case Frame of
                none -> ok;
                _    -> send_frame(Frame, NewState)
            end,
            {noreply, SuccessFun(NewState)};
        {error, Message, Detail, NewState} ->
            {noreply, send_error(Message, Detail, NewState)};
        {stop, R, State} ->
            {stop, R, State}
    end.

%%----------------------------------------------------------------------------
%% Frame handlers
%%----------------------------------------------------------------------------

handle_frame("DISCONNECT", _Frame, State) ->
    %% We'll get to shutdown the channels in terminate
    {stop, normal, State};

handle_frame("SUBSCRIBE", Frame, State) ->
    with_destination("SUBSCRIBE", Frame, State, fun do_subscribe/4);

handle_frame("UNSUBSCRIBE", Frame, State = #state{subscriptions = Subs}) ->
    ConsumerTag = case rabbit_stomp_frame:header(Frame, "id") of
                      {ok, IdStr} ->
                          list_to_binary("T_" ++ IdStr);
                      not_found ->
                          case rabbit_stomp_frame:header(Frame,
                                                         "destination") of
                              {ok, QueueStr} ->
                                  list_to_binary("Q_" ++ QueueStr);
                              not_found ->
                                  missing
                          end
                  end,
    if
        ConsumerTag == missing ->
            error("Missing destination or id",
                  "UNSUBSCRIBE must include a 'destination' or 'id' header\n",
                  State);
        true ->
            ok(send_method(#'basic.cancel'{consumer_tag = ConsumerTag,
                                           nowait       = true},
                           State#state{subscriptions =
                                           dict:erase(ConsumerTag, Subs)}))
    end;

handle_frame("SEND", Frame, State) ->
    with_destination("SEND", Frame, State, fun do_send/4);

handle_frame("ACK", Frame, State = #state{session_id    = SessionId,
                                          subscriptions = Subs}) ->
    case rabbit_stomp_frame:header(Frame, "message-id") of
        {ok, IdStr} ->
            case rabbit_stomp_util:parse_message_id(IdStr) of
                {ok, {ConsumerTag, SessionId, DeliveryTag}} ->
                    {_DestHdr, SubChannel} = dict:fetch(ConsumerTag, Subs),

                    Method = #'basic.ack'{delivery_tag = DeliveryTag,
                                          multiple = false},

                    case transactional(Frame) of
                        {yes, Transaction} ->
                            extend_transaction(Transaction,
                                               {SubChannel, Method},
                                               State);
                        no ->
                            amqp_channel:call(SubChannel, Method),
                            ok(State)
                    end;
                _ ->
                   error("Invalid message-id",
                         "ACK must include a valid 'message-id' header\n",
                         State)
            end;
        not_found ->
            error("Missing message-id",
                  "ACK must include a 'message-id' header\n",
                  State)
    end;

handle_frame("BEGIN", Frame, State) ->
    transactional_action(Frame, "BEGIN", fun begin_transaction/2, State);

handle_frame("COMMIT", Frame, State) ->
    transactional_action(Frame, "COMMIT", fun commit_transaction/2, State);

handle_frame("ABORT", Frame, State) ->
    transactional_action(Frame, "ABORT", fun abort_transaction/2, State);

handle_frame(Command, _Frame, State) ->
    error("Bad command",
          "Could not interpret command " ++ Command ++ "\n",
          State).

%%----------------------------------------------------------------------------
%% Internal helpers for processing frames callbacks
%%----------------------------------------------------------------------------

with_destination(Command, Frame, State, Fun) ->
    case rabbit_stomp_frame:header(Frame, "destination") of
        {ok, DestHdr} ->
            case rabbit_stomp_util:parse_destination(DestHdr) of
                {ok, Destination} ->
                    Fun(Destination, DestHdr, Frame, State);
                {error, {invalid_destination, Type, Content}} ->
                    error("Invalid destination",
                          "'~s' is not a valid ~p destination\n",
                          [Content, Type],
                          State);
                {error, {unknown_destination, Content}} ->
                    error("Unknown destination",
                          "'~s' is not a valid destination.\n" ++
                              "Valid destination types are: " ++
                              "/exchange, /topic or /queue.\n",
                          [Content],
                          State)
            end;
        not_found ->
            error("Missing destination",
                  "~p must include a 'destination' header\n",
                  [Command],
                  State)
    end.

do_login({ok, Login}, {ok, Passcode}, VirtualHost, State) ->
    {ok, Connection} = amqp_connection:start(
                         direct, #amqp_params{
                           username     = list_to_binary(Login),
                           password     = list_to_binary(Passcode),
                           virtual_host = list_to_binary(VirtualHost)}),
    {ok, Channel} = amqp_connection:open_channel(Connection),
    SessionId = rabbit_guid:string_guid("session"),
    ok("CONNECTED",[{"session", SessionId}], "",
       State#state{session_id = SessionId,
                   channel    = Channel,
                   connection = Connection});
do_login(_, _, _, State) ->
    error("Bad CONNECT", "Missing login or passcode header(s)\n", State).

do_subscribe(Destination, DestHdr, Frame,
             State = #state{subscriptions = Subs,
                            connection    = Connection,
                            channel       = MainChannel}) ->

    Channel = case Destination of
                  {queue, _} ->
                      {ok, Channel1} = amqp_connection:open_channel(Connection),
                      amqp_channel:call(Channel1,
                                        #'basic.qos'{prefetch_size  = 0,
                                                     prefetch_count = 1,
                                                     global         = false}),
                      Channel1;
                  _ ->
                      MainChannel
              end,

    AckMode = rabbit_stomp_util:ack_mode(Frame),

    {ok, Queue} = ensure_queue(subscribe, Destination, Channel),

    {ok, ConsumerTag} = rabbit_stomp_util:consumer_tag(Frame),

    amqp_channel:subscribe(Channel,
                           #'basic.consume'{
                             queue        = Queue,
                             consumer_tag = ConsumerTag,
                             no_local     = false,
                             no_ack       = (AckMode == auto),
                             exclusive    = false},
                           self()),

    ExchangeAndKey = rabbit_stomp_util:parse_routing_information(Destination),
    ok = ensure_queue_binding(Queue, ExchangeAndKey, Channel),

    ok(State#state{subscriptions =
                       dict:store(ConsumerTag, {DestHdr, Channel}, Subs)}).

do_send(Destination, _DestHdr,
        Frame = #stomp_frame{body_iolist = BodyFragments},
        State = #state{channel = Channel}) ->
    {ok, _Q} = ensure_queue(send, Destination, Channel),

    Props = rabbit_stomp_util:message_properties(Frame),

    {Exchange, RoutingKey} =
        rabbit_stomp_util:parse_routing_information(Destination),

    Method = #'basic.publish'{
      exchange = list_to_binary(Exchange),
      routing_key = list_to_binary(RoutingKey),
      mandatory = false,
      immediate = false},

    case transactional(Frame) of
        {yes, Transaction} ->
            extend_transaction(Transaction,
                               {Method, Props, BodyFragments},
                               State);
        no ->
            ok(send_method(Method, Props, BodyFragments, State))
    end.

ensure_receipt(Frame, State) ->
    case rabbit_stomp_frame:header(Frame, "receipt") of
        {ok, Id}  -> send_frame("RECEIPT", [{"receipt-id", Id}], "", State);
        not_found -> State
    end.

send_delivery(Delivery = #'basic.deliver'{consumer_tag = ConsumerTag},
              Properties, Body,
              State = #state{session_id    = SessionId,
                             subscriptions = Subs}) ->
    case dict:find(ConsumerTag, Subs) of
        {ok, {Destination, _SubChannel}} ->
            send_frame(
              "MESSAGE",
              rabbit_stomp_util:message_headers(Destination, SessionId,
                                                Delivery, Properties),
              Body,
              State);
        error ->
            send_error("Subscription not found",
                       "There is no current subscription '~s'.",
                       [ConsumerTag],
                       State)
    end.

send_method(Method, State = #state{channel = Channel}) ->
    amqp_channel:call(Channel, Method),
    State.

send_method(Method, Properties, BodyFragments,
            State = #state{channel = Channel}) ->
    amqp_channel:call(Channel, Method, #amqp_msg{
                                props = Properties,
                                payload = lists:reverse(BodyFragments)}),
    State.

shutdown_channel_and_connection(State = #state{channel       = Channel,
                                               connection    = Connection,
                                               subscriptions = Subs}) ->
    dict:fold(
      fun(_ConsumerTag, {_DestHdr, SubChannel}, Acc) ->
              case SubChannel of
                  Channel -> Acc;
                  _ ->
                      amqp_channel:close(SubChannel),
                      Acc
              end
      end, 0, Subs),

    amqp_channel:close(Channel),
    amqp_connection:close(Connection),
    State#state{channel = none, connection = none}.


%%----------------------------------------------------------------------------
%% Transaction Support
%%----------------------------------------------------------------------------

transactional(Frame) ->
    case rabbit_stomp_frame:header(Frame, "transaction") of
        {ok, Transaction} ->
            {yes, Transaction};
        not_found ->
            no
    end.

transactional_action(Frame, Name, Fun, State) ->
    case transactional(Frame) of
        {yes, Transaction} ->
            Fun(Transaction, State);
        no ->
            error("Missing transaction",
                  Name ++ " must include a 'transaction' header\n",
                  State)
    end.

with_transaction(Transaction, State, Fun) ->
    case get({transaction, Transaction}) of
        undefined ->
            error("Bad transaction",
                  "Invalid transaction identifier: ~p\n",
                  [Transaction],
                  State);
        Actions ->
            Fun(Actions, State)
    end.

begin_transaction(Transaction, State) ->
    put({transaction, Transaction}, []),
    ok(State).

extend_transaction(Transaction, Action, State0) ->
    with_transaction(
      Transaction, State0,
      fun (Actions, State) ->
              put({transaction, Transaction}, [Action | Actions]),
              ok(State)
      end).

commit_transaction(Transaction, State0) ->
    with_transaction(
      Transaction, State0,
      fun (Actions, State) ->
              FinalState = lists:foldr(fun perform_transaction_action/2,
                                       State,
                                       Actions),
              erase({transaction, Transaction}),
              ok(State)
      end).

abort_transaction(Transaction, State0) ->
    with_transaction(
      Transaction, State0,
      fun (_Actions, State) ->
              erase({transaction, Transaction}),
              ok(State)
      end).

perform_transaction_action({Method}, State) ->
    send_method(Method, State);
perform_transaction_action({Channel, Method}, State) ->
    amqp_channel:call(Channel, Method),
    State;
perform_transaction_action({Method, Props, BodyFragments}, State) ->
    send_method(Method, Props, BodyFragments, State).

%%----------------------------------------------------------------------------
%% Queue and Binding Setup
%%----------------------------------------------------------------------------

ensure_queue(subscribe, {exchange, _}, Channel) ->
    %% Create anonymous, exclusive queue for SUBSCRIBE on /exchange destinations
    #'queue.declare_ok'{queue = Queue} =
        amqp_channel:call(Channel, #'queue.declare'{auto_delete = true,
                                                    exclusive = true}),
    {ok, Queue};
ensure_queue(send, {exchange, _}, _Channel) ->
    %% Don't create queues on SEND for /exchange destinations
    {ok, undefined};
ensure_queue(_, {queue, Name}, Channel) ->
    %% Always create named queue for /queue destinations
    Queue = list_to_binary(Name),
    #'queue.declare_ok'{queue = Queue} =
        amqp_channel:call(Channel,
                          #'queue.declare'{durable = true,
                                           queue   = Queue}),
    {ok, Queue};
ensure_queue(subscribe, {topic, _}, Channel) ->
    %% Create anonymous, exclusive queue for SUBSCRIBE on /topic destinations
    #'queue.declare_ok'{queue = Queue} =
        amqp_channel:call(Channel, #'queue.declare'{auto_delete = true,
                                                    exclusive = true}),
    {ok, Queue};
ensure_queue(send, {topic, _}, _Channel) ->
    %% Don't create queues on SEND for /topic destinations
    {ok, undefined}.

ensure_queue_binding(QueueBin, {"", Queue}, _Channel) ->
    %% i.e., we should only be asked to bind to the default exchange a
    %% queue with its own name
    QueueBin = list_to_binary(Queue),
    ok;
ensure_queue_binding(Queue, {Exchange, RoutingKey}, Channel) ->
    #'queue.bind_ok'{} =
        amqp_channel:call(Channel,
                          #'queue.bind'{
                            queue       = Queue,
                            exchange    = list_to_binary(Exchange),
                            routing_key = list_to_binary(RoutingKey)}),
    ok.
%%----------------------------------------------------------------------------
%% Success/error handling
%%----------------------------------------------------------------------------

ok(State) ->
    {ok, none, State}.

ok(Command, Headers, BodyFragments, State) ->
    {ok, #stomp_frame{command     = Command,
                      headers     = Headers,
                      body_iolist = BodyFragments}, State}.

amqp_death(ReplyCode, Explanation, State) ->
    ErrorName = ?PROTOCOL:amqp_exception(ReplyCode),
    {stop, amqp_death,
     send_error(atom_to_list(ErrorName),
                format_message("~s~n", [Explanation]),
                State)}.

error(Message, Detail, State) ->
    priv_error(Message, Detail, none, State).

error(Message, Format, Args, State) ->
    priv_error(Message, Format, Args, none, State).

priv_error(Message, Detail, ServerPrivateDetail, State) ->
    error_logger:error_msg("STOMP error frame sent:~n" ++
                           "Message: ~p~n" ++
                           "Detail: ~p~n" ++
                           "Server private detail: ~p~n",
                           [Message, Detail, ServerPrivateDetail]),
    {error, Message, Detail, State}.

priv_error(Message, Format, Args, ServerPrivateDetail, State) ->
    priv_error(Message, format_detail(Format, Args),
                    ServerPrivateDetail, State).

format_detail(Format, Args) ->
    lists:flatten(io_lib:format(Format, Args)).
%%----------------------------------------------------------------------------
%% Frame sending utilities
%%----------------------------------------------------------------------------
send_frame(Command, Headers, BodyFragments, State) ->
    send_frame(#stomp_frame{command     = Command,
                            headers     = Headers,
                            body_iolist = BodyFragments},
               State).

send_frame(Frame, State = #state{socket = Sock}) ->
    %% We ignore certain errors here, as we will be receiving an
    %% asynchronous notification of the same (or a related) fault
    %% shortly anyway. See bug 21365.
    %% io:format("Sending ~p~n", [Frame]),
    case gen_tcp:send(Sock, rabbit_stomp_frame:serialize(Frame)) of
        ok -> State;
        {error, closed} -> State;
        {error, enotconn} -> State;
        {error, Code} ->
            error_logger:error_msg("Error sending STOMP frame ~p: ~p~n",
                                   [Frame#stomp_frame.command,
                                    Code]),
            State
    end.

send_error(Message, Detail, State) ->
    send_frame("ERROR", [{"message", Message},
                         {"content-type", "text/plain"}], Detail, State).

send_error(Message, Format, Args, State) ->
    send_error(Message, format_detail(Format, Args), State).

%%----------------------------------------------------------------------------
%% Skeleton gen_server callbacks
%%----------------------------------------------------------------------------
handle_call(_Cmd, _From, State) ->
    State.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.
