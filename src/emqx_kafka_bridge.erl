%%--------------------------------------------------------------------
%% Copyright (c) 2015-2017 Feng Lee <feng@emqtt.io>.
%%
%% Modified by Ramez Hanna <rhanna@iotblue.net>
%% 
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------

-module(emqx_kafka_bridge).

-include("emqx_kafka_bridge.hrl").

-include_lib("emqx/include/emqx.hrl").

-export([load/1, unload/0]).

%% Hooks functions

-export([on_client_connected/4, on_client_disconnected/3]).

% -export([on_client_subscribe/4, on_client_unsubscribe/4]).

% -export([on_session_created/3, on_session_subscribed/4, on_session_unsubscribed/4, on_session_terminated/4]).

-export([on_message_publish/2, on_message_delivered/3, on_message_acked/3]).


%% Called when the plugin application start
load(Env) ->
    ekaf_init([Env]),
    emqx:hook('client.connected', fun ?MODULE:on_client_connected/4, [Env]),
    emqx:hook('client.disconnected', fun ?MODULE:on_client_disconnected/3, [Env]),
    emqx:hook('message.publish', fun ?MODULE:on_message_publish/2, [Env]),
    emqx:hook('message.delivered', fun ?MODULE:on_message_delivered/3, [Env]),
    emqx:hook('message.acked', fun ?MODULE:on_message_acked/3, [Env]).

on_client_connected(#{client_id := ClientId, username := Username}, _ConnAck, _ConnAttrs, _Env) ->
    % io:format("client ~s connected, connack: ~w~n", [ClientId, ConnAck]),
    % produce_kafka_payload(<<"event">>, Client),

    Action = <<"connected">>,
    Payload = [{action, Action}, {clientid, ClientId}, {username, Username}, {ts, emqx_time:now_ms()}],
    %{ok, Event} = format_event(Payload),
    produce_kafka_event(Payload),
    ok.

on_client_disconnected(#{client_id := ClientId, username := Username}, _Reason, _Env) ->
    % io:format("client ~s disconnected, reason: ~w~n", [ClientId, Reason]),
    % produce_kafka_payload(<<"event">>, _Client),

    Action = <<"disconnected">>,
    Payload = [{action, Action}, {clientid, ClientId}, {username, Username}, {ts, emqx_time:now_ms()}],
    %{ok, Event} = format_event(Payload),
    produce_kafka_event(Payload),
    ok.

%% transform message and return
on_message_publish(Message = #message{topic = <<"$SYS/", _/binary>>}, _Env) ->
    {ok, Message};

on_message_publish(Message, _Env) ->
    % io:format("Publish message ~s~n", [emqx_message:format(Message)]),
    {ok, Payload} = format_payload(Message),
    produce_kafka_payload(Payload),
    {ok, Message}.

on_message_delivered(#{}, Message, _Env) ->
    % io:format("delivered to client(~s/~s): ~s~n", [Username, ClientId, emqttd_message:format(Message)]),
    {ok, Message}.

on_message_acked(#{}, Message, _Env) ->
    % io:format("client(~s/~s) acked: ~s~n", [Username, ClientId, emqttd_message:format(Message)]),
    {ok, Message}.

ekaf_init(_Env) ->
    {ok, BrokerValues} = application:get_env(emqx_kafka_bridge, broker),
    KafkaHost = proplists:get_value(host, BrokerValues),
    KafkaPort = proplists:get_value(port, BrokerValues),
    KafkaPartitionStrategy = proplists:get_value(partitionstrategy, BrokerValues),
    KafkaPartitionWorkers = proplists:get_value(partitionworkers, BrokerValues),
    KafkaPayloadTopic = proplists:get_value(payloadtopic, BrokerValues),
    KafkaEventTopic = proplists:get_value(eventtopic, BrokerValues),
    application:set_env(ekaf, ekaf_bootstrap_broker, {KafkaHost, list_to_integer(KafkaPort)}),
    application:set_env(ekaf, ekaf_partition_strategy, list_to_atom(KafkaPartitionStrategy)),
    application:set_env(ekaf, ekaf_per_partition_workers, KafkaPartitionWorkers),
    application:set_env(ekaf, ekaf_bootstrap_payload_topics, list_to_binary(KafkaPayloadTopic)),
    application:set_env(ekaf, ekaf_bootstrap_event_topics, list_to_binary(KafkaEventTopic)),
    application:set_env(ekaf, ekaf_buffer_ttl, 10),
    application:set_env(ekaf, ekaf_max_downtime_buffer_size, 5),
    % {ok, _} = application:ensure_all_started(kafkamocker),
    {ok, _} = application:ensure_all_started(gproc),
    % {ok, _} = application:ensure_all_started(ranch),
    {ok, _} = application:ensure_all_started(ekaf).

ekaf_get_payload_topic() ->
    {ok, Topic} = application:get_env(ekaf, ekaf_bootstrap_payload_topics),
    Topic.

ekaf_get_event_topic() ->
    {ok, Topic} = application:get_env(ekaf, ekaf_bootstrap_event_topics),
    Topic.

format_payload(Message) ->
    Username = emqx_message:get_header(username, Message),

    Topic = Message#message.topic,
    Tail = string:right(binary_to_list(Topic), 4),
    RawType = string:equal(Tail, <<"_raw">>),
    % io:format("Tail= ~s , RawType= ~s~n",[Tail,RawType]),

    MsgPayload = Message#message.payload,
    % io:format("MsgPayload : ~s~n", [MsgPayload]),

    if
        RawType == true ->
            MsgPayload64 = list_to_binary(base64:encode_to_string(MsgPayload));
    % io:format("MsgPayload64 : ~s~n", [MsgPayload64]);
        RawType == false ->
            MsgPayload64 = MsgPayload
    end,

    IsJson = jsx:is_json(MsgPayload64),
    % io:format("IsJson= ~s , MsgPayload64= ~s~n",[IsJson,MsgPayload64]),
    if
        IsJson == true ->
            {ok, MsgPayloadJson} = emqx_json:safe_decode(MsgPayload64);
        IsJson == false ->
            MsgPayloadJson = MsgPayload64
    end,

    Payload = [{action, message_publish},
        {clientid, Message#message.from},
        {username, Username},
        {topic, Topic},
        {payload, MsgPayloadJson},
        {ts, emqx_time:now_ms()}],
    %io:format("~s~n", [Payload]),
    {ok, Payload}.


%% Called when the plugin application stop
unload() ->
    emqx:unhook('client.connected', fun ?MODULE:on_client_connected/4),
    emqx:unhook('client.disconnected', fun ?MODULE:on_client_disconnected/3),
    % emqx:unhook('client.subscribe', fun ?MODULE:on_client_subscribe/4),
    % emqx:unhook('client.unsubscribe', fun ?MODULE:on_client_unsubscribe/4),
    % emqx:unhook('session.subscribed', fun ?MODULE:on_session_subscribed/4),
    % emqx:unhook('session.unsubscribed', fun ?MODULE:on_session_unsubscribed/4),
    emqx:unhook('message.publish', fun ?MODULE:on_message_publish/2),
    emqx:unhook('message.delivered', fun ?MODULE:on_message_delivered/3),
    emqx:unhook('message.acked', fun ?MODULE:on_message_acked/3).

produce_kafka_payload(Message) ->
    Topic = ekaf_get_payload_topic(),
    {ok, MessageBody} = emqx_json:safe_encode(Message),

    % MessageBody64 = base64:encode_to_string(MessageBody),
    Payload = iolist_to_binary(MessageBody),
    ekaf:produce_async_batched(Topic, Payload).
    
produce_kafka_event(Message) ->
    Topic = ekaf_get_event_topic(),
    {ok, MessageBody} = emqx_json:safe_encode(Message),

    % MessageBody64 = base64:encode_to_string(MessageBody),
    Payload = iolist_to_binary(MessageBody),
    ekaf:produce_async_batched(Topic, Payload).

