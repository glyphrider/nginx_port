%%%-------------------------------------------------------------------
%%% @author  <brian@WIN-K3A45UQAS1P>
%%% @copyright (C) 2014, 
%%% @doc
%%%
%%% @end
%%% Created :  1 Oct 2014 by  <brian@WIN-K3A45UQAS1P>
%%%-------------------------------------------------------------------
-module(nginx_server).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([add_rule/2,rm_rules/1,reload_config/0,rewrite_config/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {port,rules=[]}).

-define(CONFIG_HEADER,"worker_processes  1;~n~nevents {~n    worker_connections  1024;~n}~n~nhttp {~n    include       mime.types;~n    default_type  application/octet-stream;~n~n    sendfile        on;~n    keepalive_timeout  65;~n~n    server {~n        listen       80;~n~n").
-define(CONFIG_FOOTER,"        location = /50x.html {~n            root   html;~n        }~n    }~n}~n").

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

add_rule(Pattern,Port) ->
    gen_server:call(?SERVER, {add,Pattern,Port}).

rm_rules(Port) ->
    gen_server:call(?SERVER, {rm,Port}).

reload_config() ->
    gen_server:call(?SERVER, reload).

rewrite_config() ->
    gen_server:call(?SERVER, rewrite).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([]) ->
    process_flag(trap_exit,true),
    proxy_server_rewrite_config([]),
    Port = proxy_server(),
    {ok, #state{port=Port}}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(reload,_From,State) ->
    erlang:port_close(proxy_server(reload)),
    {reply,ok,State};
handle_call({add,Pattern,Port},_From,#state{rules=Rules} = State) ->
    {reply,ok,State#state{rules=Rules++[{Pattern,Port}]}};
handle_call({rm,Port},_From,#state{rules=Rules} = State) ->
    {reply,ok,State#state{rules=lists:filter(fun({_Pattern,RulePort}) -> RulePort /= Port end,Rules)}}; 
handle_call(rewrite,_From,#state{rules=Rules} = State) ->
    proxy_server_rewrite_config(Rules),
    {reply,ok,State};
handle_call(Request, From, State) ->
    lager:warn("Unexpected handle_call(~p) from ~p",[Request,From]),
    {reply, ok, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_info({'EXIT', Port, Reason}, #state{port = Port} = State) ->
    lager:info("nginx server stopped"),
    {stop, {port_terminated, Reason}, State};
handle_info({'EXIT', _SomeOtherPort, _Reason}, State) ->
    lager:info("nginx control complete"),
    {noreply, State};
handle_info(Info, State) ->
    lager:info("~p",[Info]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
 
terminate({port_terminated, _Reason}, _State) ->
    lager:info("gen_server stopped."),
    ok;
terminate(_Reason, #state{port = Port} = _State) ->
    port_close(Port),
    port_close(proxy_server(stop)),
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

priv_dir() ->
    case code:priv_dir(nginx) of
	{error, bad_name} ->
            {ok, Cwd} = file:get_cwd(),
            Cwd ++ "/priv/";
	Priv ->
	    Priv ++ "/"
    end.

%% atomize(String) ->
%%     case list_to_existing_atom(String) of
%% 	badarg ->
%% 	    list_to_atom(String);
%% 	Atom ->
%% 	    Atom
%%     end.

proxy_server() ->
    proxy_server_with_args([]).

proxy_server(Command) when is_atom(Command) ->
    proxy_server(atom_to_list(Command));
proxy_server(Command) ->
    proxy_server_with_args(["-s",Command]).

proxy_server_with_args([]) ->
    proxy_server_with_opts([]);
proxy_server_with_args(Args) ->
    proxy_server_with_opts([{args,Args}]).

proxy_server_with_opts(RequestedOpts) ->
    % Config = priv_dir() ++ "conf/nginx.conf",
    Priv = priv_dir(),
    Proxy = Priv ++ "nginx.exe",
    Opts = RequestedOpts ++ [{cd,Priv}],
    lager:info("executing proxy executable with opts = ~p",[Opts]),
    erlang:open_port({spawn_executable,Proxy},Opts).

proxy_server_rewrite_config(Rules) ->
    Config = priv_dir() ++ "conf/nginx.conf",
    lager:info("Trying to open ~p for re-writing",[Config]),
    proxy_server_rewrite_config(file:open(Config,[write]),Rules).

proxy_server_rewrite_config({error,Reason},_Rules) ->
    lager:error("Could not rewrite config file (~p)",[Reason]);
proxy_server_rewrite_config({ok,IoDevice},Rules) ->
    io:fwrite(IoDevice,?CONFIG_HEADER,[]),
    lists:foreach(fun(Rule) -> proxy_server_write_rule(IoDevice,Rule) end,Rules),
    io:fwrite(IoDevice,?CONFIG_FOOTER,[]),
    file:close(IoDevice).

proxy_server_write_rule(IoDevice,{Pattern,Port}) ->
    io:fwrite(IoDevice,"        location ~s {~n            proxy_set_header Host $host;~n            proxy_set_header X-Real-IP $remote_addr;~n            proxy_pass http://127.0.0.1:~B;~n        }~n~n",[Pattern,Port]).
