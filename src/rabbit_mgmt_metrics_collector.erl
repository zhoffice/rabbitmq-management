%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2016 Pivotal Software, Inc.  All rights reserved.
%%
-module(rabbit_mgmt_metrics_collector).

-record(state, {table, agent, policies, rates_mode}).

-include_lib("rabbit_common/include/rabbit.hrl").

-spec start_link(atom()) -> rabbit_types:ok_pid_or_error().

-export([name/1]).
-export([start_link/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
         code_change/3]).

-import(rabbit_misc, [pget/3]).
-import(rabbit_mgmt_db, [pget/2, lookup_element/3]).

name(Table) ->
    list_to_atom((atom_to_list(Table) ++ "_metrics_collector")).

start_link(Table) ->
    gen_server2:start_link({local, name(Table)}, ?MODULE, [Table], []).

init([Table]) ->    
    {ok, RatesMode} = application:get_env(rabbitmq_management, rates_mode),
    {ok, Policies} = application:get_env(
                       rabbitmq_management, sample_retention_policies),
    Policy = retention_policy(Table),
    TablePolicies = proplists:get_value(Policy, Policies),
    Interval = take_smaller(TablePolicies),
    {ok, Agent} = rabbit_mgmt_agent_collector_sup:start_child(self(), Table,
							      Interval * 1000),
    {ok, #state{table = Table, agent = Agent, policies = TablePolicies,
		rates_mode = RatesMode}}.

handle_call(_Request, _From, State) ->
    {noreply, State}.

handle_cast({metrics, Timestamp, Records}, State = #state{table = Table,
                                                          policies = TablePolicies,
							  rates_mode = RatesMode}) ->
    aggregate_metrics(Timestamp, Table, TablePolicies, Records, RatesMode),
    {noreply, State}.

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

retention_policy(connection_created) -> basic; %% really nothing
retention_policy(connection_metrics) -> basic;
retention_policy(connection_coarse_metrics) -> basic;
retention_policy(channel_created) -> basic;
retention_policy(channel_metrics) -> basic;
retention_policy(channel_queue_exchange_metrics) -> detailed;
retention_policy(channel_exchange_metrics) -> detailed;
retention_policy(channel_queue_metrics) -> detailed;
retention_policy(channel_process_metrics) -> basic;
retention_policy(consumer_created) -> basic;
retention_policy(queue_metrics) -> basic; 
retention_policy(queue_coarse_metrics) -> basic.

take_smaller(Policies) ->
    lists:min([I || {_, I} <- Policies]).

aggregate_metrics(Timestamp, Table, Policies, Records, RatesMode) ->
    [aggregate_entry(Timestamp, Table, Policies, R, RatesMode) || R <- Records].

aggregate_entry(_TS, connection_created, _, {Id, Metrics}, _) ->
    Ftd = rabbit_mgmt_format:format(
	    Metrics,
	    {fun rabbit_mgmt_format:format_connection_created/1, true}),
    ets:insert(connection_created_stats, {Id, pget(name, Ftd, unknown), Ftd});
aggregate_entry(_TS, connection_metrics, _, {Id, Metrics}, _) ->
    ets:insert(connection_stats, {Id, Metrics});
aggregate_entry(TS, connection_coarse_metrics, Policies,
                {Id, RecvOct, SendOct, Reductions}, _) ->
    %% VHOSTS are aggregated??
    [begin
         insert_entry(connection_stats_coarse_conn_stats, Id, TS,
                      {RecvOct, SendOct, Reductions}, Size, Interval, false),
         insert_entry(vhost_stats_coarse_conn_stats,
		      vhost({connection_created_stats, Id}), TS,
                      {RecvOct, SendOct, Reductions}, Size, Interval, false)
     end || {Size, Interval} <- Policies];
aggregate_entry(_TS, channel_created, _, {Id, Metrics}, _) ->
    Ftd = rabbit_mgmt_format:format(Metrics, {[], false}),
    ets:insert(channel_created_stats, {Id, pget(name, Ftd, unknown), Ftd});
aggregate_entry(_TS, channel_metrics, _, {Id, Metrics}, _) ->
    ets:insert(channel_stats, {Id, Metrics});
aggregate_entry(TS, channel_exchange_metrics, Policies, {{Ch, X} = Id, Metrics},
		RatesMode) ->
    %% TODO check queue and exchange exists
    Stats = {pget(publish, Metrics, 0), pget(confirm, Metrics, 0),
	     pget(return_unroutable, Metrics, 0)},
    {Publish, _, _} = Diff = get_difference(Id, Stats),
    ets:insert(old_aggr_stats, {Id, Stats}),
    [begin
         insert_entry(channel_stats_fine_stats, Ch, TS, Diff, Size, Interval,
		      true),
         insert_entry(vhost_stats_fine_stats, vhost(X), TS, Diff, Size,
		      Interval, true),
	 insert_entry(exchange_stats_publish_in, X, TS, {Publish}, Size, Interval,
		      true)
     end || {Size, Interval} <- Policies],
    case RatesMode of
	basic ->
	    ok;
	_ ->
	    [insert_entry(channel_exchange_stats_fine_stats, Id, TS, Stats,
			  Size, Interval, false) || {Size, Interval} <- Policies]
    end;
aggregate_entry(TS, channel_queue_metrics, Policies, {{Ch, Q} = Id, Metrics},
		RatesMode) ->
    %% TODO check queue and exchange exists
    Deliver = pget(deliver, Metrics, 0),
    DeliverNoAck = pget(deliver_no_ack, Metrics, 0),
    Get = pget(get, Metrics, 0),
    GetNoAck = pget(get_no_ack, Metrics, 0),
    Stats = {Get, GetNoAck, Deliver, DeliverNoAck, pget(redeliver, Metrics, 0),
	     pget(ack, Metrics, 0), Deliver + DeliverNoAck + Get + GetNoAck},
    Diff = get_difference(Id, Stats),
    ets:insert(old_aggr_stats, {Id, Stats}),
    [begin
	 insert_entry(queue_stats_deliver_stats, Q, TS, Diff, Size, Interval,
		      true),
	 insert_entry(vhost_stats_deliver_stats, vhost(Q), TS, Diff, Size,
		      Interval, true),
	 insert_entry(channel_stats_deliver_stats, Ch, TS, Diff, Size, Interval,
		      true)
     end || {Size, Interval} <- Policies],
    case RatesMode of
	basic ->
	    ok;
	_ ->
	    [insert_entry(channel_queue_stats_deliver_stats, Id, TS, Stats, Size,
			  Interval, false) || {Size, Interval} <- Policies]
    end;
aggregate_entry(TS, channel_queue_exchange_metrics, Policies,
		{{_Ch, {Q, X} = Id}, Publish}, RatesMode) ->
    %% TODO check queue and exchange exists
    Stats = {Publish},
    Diff = get_difference(Id, Stats),
    ets:insert(old_aggr_stats, {Id, Stats}),
    %% channel_exch, queue_exch, echange_stats
    [begin
	 insert_entry(queue_stats_publish, Q, TS, Diff, Size, Interval, true),
	 insert_entry(exchange_stats_publish_out, X, TS, Diff, Size, Interval, true)
     end || {Size, Interval} <- Policies],
    case RatesMode of
	basic ->
	    ok;
	_ ->
	    [insert_entry(queue_exchange_stats_publish, Id, TS, Diff, Size, Interval, true)
	     || {Size, Interval} <- Policies]
    end;
aggregate_entry(TS, channel_process_metrics, Policies, {Id, Reductions}, _) ->
    [begin
	 insert_entry(channel_process_stats, Id, TS, {Reductions}, Size, Interval,
		      false)
     end || {Size, Interval} <- Policies];
aggregate_entry(_TS, consumer_created, _, {Id, Exclusive, AckRequired,
					   PrefetchCount, Args}, _) ->
    Fmt = rabbit_mgmt_format:format([{exclusive, Exclusive},
				     {ack_required, AckRequired},
				     {prefetch_count, PrefetchCount},
				     {arguments, Args}], {[], false}),
    ets:insert(consumer_stats, {Id, Fmt}),
    ok;
aggregate_entry(_TS, queue_metrics, _, {Id, Metrics}, _) ->
    Fmt = rabbit_mgmt_format:format(
	    Metrics,
	    {fun rabbit_mgmt_format:format_queue_stats/1, false}),
    ets:insert(queue_stats, {Id, Fmt});
aggregate_entry(TS, queue_coarse_metrics, Policies, {Name, Ready, Unack, Msgs,
						     Red}, _) ->
    %% TODO vhost stats ready, unack, msg
    [begin
	 insert_entry(queue_process_stats, Name, TS, {Red},
		      Size, Interval, false),
	 insert_entry(queue_msg_stats, Name, TS, {Ready, Unack, Msgs},
		      Size, Interval, false)
     end || {Size, Interval} <- Policies];
aggregate_entry(_, _, _, _, _) ->
    ok.

insert_entry(Table, Id, TS, Entry, Size, Interval, Incremental) ->
    Key = {Id, Interval},
    Slide = case ets:lookup(Table, Key) of
                [{Key, S}] ->
                    S;
                [] ->
                    exometer_slide:new(Size * 1000, [{interval, Interval * 1000},
						     {incremental, Incremental}])
            end,
    ets:insert(Table, {Key, exometer_slide:add_element(TS, Entry, Slide)}).

get_difference(Id, Stats) ->
    case ets:lookup(old_aggr_stats, Id) of
	[] ->
	    Stats;
	[{Id, OldStats}] ->
	    difference(OldStats, Stats)
    end.

difference({A0}, {B0}) ->
    {B0 - A0};
difference({A0, A1, A2}, {B0, B1, B2}) ->
    {B0 - A0, B1 - A1, B2 - A2};
difference({A0, A1, A2, A3, A4, A5, A6}, {B0, B1, B2, B3, B4, B5, B6}) ->
    {B0 - A0, B1 - A1, B2 - A2, B3 - A3, B4 - A4, B5 - A5, B6 - A6}.

vhost(#resource{virtual_host = VHost}) ->
    VHost;
vhost({queue_stats, #resource{virtual_host = VHost}}) ->
    VHost;
vhost({TName, Pid}) ->
    pget(vhost, lookup_element(TName, Pid, 3)).