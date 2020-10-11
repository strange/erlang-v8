%% Copyright (c) 2016-2020, Gustaf Sjoberg <gsjoberg@gmail.com>
%%
%% Permission to use, copy, modify, and/or distribute this software for any
%% purpose with or without fee is hereby granted, provided that the above
%% copyright notice and this permission notice appear in all copies.
%%
%% THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
%% WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
%% MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
%% ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
%% WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
%% ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
%% OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
-module(erlang_v8_vm).

-behaviour(gen_server).

-export([start/0]).
-export([start_link/1]).
-export([stop/1]).

-export([reset/1]).
-export([restart/1]).

-export([create_context/1]).
-export([destroy_context/2]).
-export([eval/3]).
-export([eval/4]).
-export([compile_module/4]).
-export([call/4]).
-export([call/5]).

-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).

-define(EXECUTABLE, "erlang_v8").
-define(SPAWN_OPTS, [{packet, 4}, binary]).
-define(DEFAULT_TIMEOUT, 2000).
-define(MAX_SOURCE_SIZE, 16#FFFFFFFF).

-define(OP_EVAL, 1).
-define(OP_CALL, 2).
-define(OP_CREATE_CONTEXT, 3).
-define(OP_DESTROY_CONTEXT, 4).
-define(OP_RESET_VM, 5).
-define(OP_COMPILE_MODULE, 6).

-define(OP_OK, 0).
-define(OP_ERROR, 1).
-define(OP_TIMEOUT, 2).
-define(OP_INVALID_CONTEXT, 3).

-record(state, {
        initial_source = [],
        max_source_size = 5 * 1024 * 1024,
        port,
        table,
        monitor_pid
    }).

%% External API

start_link(Opts) ->
    gen_server:start_link(?MODULE, [Opts], []).

start() ->
    gen_server:start(?MODULE, [], []).

create_context(Pid) ->
    call_with_timeout(Pid, {create_context, self(), 1000}, 5000).

eval(Pid, Context, Source) ->
    eval(Pid, Context, Source, ?DEFAULT_TIMEOUT).

eval(Pid, Context, Source, Timeout) ->
    call_with_timeout(Pid, {eval, Context, Source, Timeout}, 30000).

compile_module(Pid, Context, Name, Source) ->
    gen_server:call(Pid, {compile_module, Context, Name, Source}).

call(Pid, Context, FunctionName, Args) ->
    call(Pid, Context, FunctionName, Args, ?DEFAULT_TIMEOUT).

call(Pid, Context, FunctionName, Args, Timeout) ->
    call_with_timeout(Pid, {call, Context, FunctionName, Args, Timeout}, 30000).

destroy_context(Pid, Context) ->
    gen_server:call(Pid, {destroy_context, Context}, infinity).

reset(Pid) ->
    gen_server:call(Pid, reset).

restart(Pid) ->
    gen_server:call(Pid, restart).

stop(Pid) ->
    closed = gen_server:call(Pid, stop),
    ok.

%% Callbacks

init([Opts]) ->
    rand:seed(exs64),
    State = create_table(start_port(parse_opts(Opts))),
    {ok, State}.

handle_call({call, Context, FunctionName, Args, Timeout}, _From,
            #state{port = Port, max_source_size = MaxSourceSize} = State) ->
    Instructions = jsx:encode(#{ function => FunctionName,
                                 args => Args,
                                 timeout => Timeout }),
    handle_response(send_to_port(Port, ?OP_CALL, Context, Instructions,
                                 MaxSourceSize), State);

handle_call({eval, Context, Source, Timeout}, _From,
            #state{port = Port, max_source_size = MaxSourceSize} = State) ->
    Instructions = jsx:encode(#{ source => Source, timeout => Timeout }),
    handle_response(send_to_port(Port, ?OP_EVAL, Context, Instructions,
                                 MaxSourceSize), State);

handle_call({compile_module, Context, Name, Source}, _From,
            #state{port = Port, max_source_size = MaxSourceSize} = State) ->
    Instructions = jsx:encode(#{ name => Name, source => Source }),
    io:fwrite("About to compile module ~w, insns=~w~n", [Name, Instructions]),
    handle_response(send_to_port(Port, ?OP_COMPILE_MODULE, Context, Instructions,
                                 MaxSourceSize), State);

handle_call({create_context, Pid, _Timeout}, _From, #state{port = Port, table = Table} = State) ->
    Context = erlang:unique_integer([positive]),
    MRef = erlang:monitor(process, Pid),
    ets:insert(Table, {Context, MRef}),
    case send_to_port(Port, ?OP_CREATE_CONTEXT, Context) of
        {ok, _Response} ->
            {reply, {ok, Context}, State};
        _Other ->
            {reply, {error, invalid_context}, State}
    end;

handle_call({destroy_context, Context}, _From,
            #state{port = Port, table = Table} = State) ->
    case ets:lookup(Table, Context) of
        [{_Context, MRef}] ->
            true = ets:delete(Table, Context),
            true = erlang:demonitor(MRef, [flush]);
        [] ->
            ok
    end,
    case send_to_port(Port, ?OP_DESTROY_CONTEXT, Context) of
        {ok, _Response} ->
            {reply, ok, State};
        _Other ->
            {reply, {error, invalid_context}, State}
    end;

handle_call(reset, _From, #state{port = Port} = State) ->
    Port ! {self(), {command, <<?OP_RESET_VM:8>>}},
    {reply, ok, State};

handle_call(restart, _From, State) ->
    {reply, ok, start_port(close_port(State))};

handle_call(stop, _From, State) ->
    {stop, normal, closed, State};

handle_call(_Message, _From, State) ->
    {reply, ok, State}.

handle_cast(_Message, State) ->
    {noreply, State}.

handle_info({'DOWN', MRef, process, _Pid, _Reason},
            #state{table = Table, port = Port} = State) ->
    io:fwrite("Down, state=~w~n", [State]),
    [[Context]] = ets:match(Table, {'$1', MRef}),
    true = ets:delete(Table, Context),
    send_to_port(Port, ?OP_DESTROY_CONTEXT, Context),
    {noreply, State};

handle_info(_Msg, State) ->
    {noreply, State}.

terminate(_Reason, State) ->
    close_port(State),
    ok.

code_change(_OldVersion, State, _Extra) ->
    {ok, State}.

%% Internal API

handle_response({ok, Response}, State) ->
    {reply, {ok, Response}, State};
handle_response({error, invalid_source_size} = Error, State) ->
    {reply, Error, State};
handle_response({call_error, Reason}, State) ->
    {reply, {error, Reason}, State};
handle_response({error, _Reason} = Error, State) ->
    {reply, Error, start_port(kill_port(State))}.

%% @doc Close port gently.
close_port(#state{monitor_pid = Pid, port = Port} = State) ->
    catch port_close(Port),
    Pid ! demonitor,
    State#state{monitor_pid = undefined, port = undefined}.

%% @doc Close port and attempt to kill the OS process.
kill_port(#state{monitor_pid = Pid, port = Port} = State) ->
    catch port_close(Port),
    Pid ! kill,
    State#state{monitor_pid = undefined, port = undefined}.

create_table(State) ->
    TableRef = ets:new(?MODULE, [ordered_set]),
    State#state{table = TableRef}.

%% @doc Start port and port monitor.
start_port(#state{initial_source = Source} = State) ->
    Executable = filename:join(priv_dir(), ?EXECUTABLE),
    Opts = [{args, [Source]}|?SPAWN_OPTS],
    Port = open_port({spawn_executable, Executable}, Opts),
    monitor_port(State#state{port = Port}).

%% @doc Kill active port monitor before starting a new process.
monitor_port(#state{monitor_pid = Pid} = State) when is_pid(Pid) ->
    Pid ! demonitor,
    monitor_port(State#state{monitor_pid = undefined});

%% @doc Start a process that monitors the port (and parent process) and kills
%% the actual OS process when things go south.
monitor_port(#state{port = Port} = State) ->
    Parent = self(),
    Pid = spawn(fun() ->
        {os_pid, OSPid} = erlang:port_info(Port, os_pid),
        MRef = erlang:monitor(process, Parent),
        receive
            demonitor ->
                erlang:demonitor(MRef);
            kill ->
                os_kill(OSPid);
            {'DOWN', _Ref, process, Parent, _Reason} ->
                os_kill(OSPid)
        end
    end),
    State#state{monitor_pid = Pid}.

%% @doc Kill OS process.
os_kill(OSPid) ->
    os:cmd(io_lib:format("kill -9 ~p", [OSPid])).

send_to_port(Port, Op, Ref) ->
    send_to_port(Port, Op, Ref, <<>>).

send_to_port(Port, Op, Ref, Data) ->
    send_to_port(Port, Op, Ref, Data, infinity).

%% @doc Send source to port and wait for response
send_to_port(_Port, _Op, _Ref, Data, MaxSourceSize)
  when size(Data) > MaxSourceSize ->
    {error, invalid_source_size};
send_to_port(Port, Op, Ref, Data, _MaxSourceSize) ->
    Port ! {self(), {command, <<Op:8, Ref:32, Data/binary>>}},
    receive_port_data(Port).

receive_port_data(Port) ->
    receive
        {Port, {data, <<_:8, _Ref:32, "">>}} ->
            {ok, undefined};
        {Port, {data, <<?OP_OK:8, _Ref:32, "undefined">>}} ->
            {ok, undefined};
        {Port, {data, <<?OP_OK:8, _Ref:32, Response/binary>>}} ->
            case catch jsx:decode(Response, [return_maps]) of
                {'EXIT', _F} ->
                    {ok, Response};
                R ->
                    {ok, R}
            end;
        {Port, {data, <<?OP_ERROR:8, _Ref:32, Response/binary>>}} ->
            #{ <<"error">> := Reason } = jsx:decode(Response, [return_maps]),
            {call_error, Reason};
        {Port, {data, <<?OP_TIMEOUT:8, _Ref:32, _/binary>>}} ->
            {call_error, timeout};
        {Port, {data, <<?OP_INVALID_CONTEXT:8, _Ref:32, _/binary>>}} ->
            {call_error, invalid_context};
        {Port, Error} ->
            %% TODO: we should probably special case here.
            {error, Error}
    end.

%% @doc Return the path to the application's priv dir (assuming directory
%% structure is intact).
priv_dir() ->
    filename:join(filename:dirname(filename:dirname(code:which(?MODULE))),
                  "priv").

%% @doc Parse proplists/opts and populate a state record.
parse_opts(Opts) ->
    lists:foldl(fun parse_opt/2, #state{initial_source = <<>>}, Opts).

%% @doc Append source specified in source option.
parse_opt({source, S}, #state{initial_source = InitialSource} = State) ->
    State#state{initial_source = <<InitialSource/binary, S/binary>>};

%% @doc Read contents of file option and append to state.
parse_opt({file, F}, #state{initial_source = InitialSource} = State) ->
    %% Files should probably be read in the OS process instead to prevent
    %% keeping multiple copies of the JS source code in memory.
    {ok, S} = file:read_file(F),
    State#state{initial_source = <<InitialSource/binary, S/binary>>};

%% @doc Invalid max source size
parse_opt({max_source_size, N}, _State) when N > ?MAX_SOURCE_SIZE ->
    error(invalid_max_source_size_value);

%% @doc Set max source size for this vm
parse_opt({max_source_size, N}, State) ->
    State#state{max_source_size = N};

%% @doc Ignore unknown options.
parse_opt(_, State) -> State.

call_with_timeout(Pid, Message, Timeout) ->
    try
        gen_server:call(Pid, Message, Timeout)
    catch exit:{timeout, _Context} ->
        {error, vm_unresponsive}
    end.
