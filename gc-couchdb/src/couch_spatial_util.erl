% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_spatial_util).

-export([get_view/4]).
-export([ddoc_to_spatial_state/2, init_state/4, reset_index/3]).
-export([make_header/1]).
-export([index_file/2, compaction_file/2, open_file/1]).
-export([delete_files/2, delete_index_file/2, delete_compaction_file/2]).
% NOTE vmx 2012-10-19: get_row_count should really be removed as it's so
%     unefficient
-export([get_row_count/1]).
-export([validate_args/1]).
-export([expand_dups/2]).
-export([row_to_ejson/1, split_bbox_if_flipped/2]).

-include("couch_db.hrl").
-include("couch_spatial.hrl").
-include_lib("vtree/include/vtree.hrl").

-define(MOD, couch_spatial_index).

get_view(Db, DDoc, ViewName, Args) ->
    ArgCheck = fun(_InitState) ->
        {ok, validate_args(Args)}
    end,
    {ok, Pid, Args2} = couch_index_server:get_index(?MOD, Db, DDoc, ArgCheck),
    DbUpdateSeq = couch_util:with_db(Db, fun(WDb) ->
        couch_db:get_update_seq(WDb)
    end),
    MinSeq = case Args2#spatial_args.stale of
        ok -> 0; update_after -> 0; _ -> DbUpdateSeq
    end,
    {ok, State} = case couch_index:get_state(Pid, MinSeq) of
        {ok, _} = Resp -> Resp;
        Error -> throw(Error)
    end,
    couch_ref_counter:add(State#spatial_state.ref_counter),
    if Args2#spatial_args.stale == update_after ->
        spawn(fun() -> catch couch_index:get_state(Pid, DbUpdateSeq) end);
        true -> ok
    end,
    {ok, View} = extract_view(ViewName, State#spatial_state.views),
    Sig = view_sig(State, View, Args2),
    {ok, View, Sig, Args2}.


ddoc_to_spatial_state(DbName, DDoc) ->
    #doc{id=Id, body={Fields}} = DDoc,
    Language = couch_util:get_value(<<"language">>, Fields, <<"javascript">>),
    {DesignOpts} = couch_util:get_value(<<"options">>, Fields, {[]}),
    {RawIndexes} = couch_util:get_value(<<"spatial">>, Fields, {[]}),
    % RawViews is only needed to get the "lib" property
    {RawViews} = couch_util:get_value(<<"views">>, Fields, {[]}),
    Lib = couch_util:get_value(<<"lib">>, RawViews, {[]}),

    % add the views to a dictionary object, with the map source as the key
    DictBySrc =
    lists:foldl(fun({Name, IndexSrc}, DictBySrcAcc) ->
        Index =
        case dict:find({IndexSrc}, DictBySrcAcc) of
            {ok, Index0} -> Index0;
            error -> #spatial{def=IndexSrc} % create new spatial index object
        end,
        Index2 = Index#spatial{view_names=[Name|Index#spatial.view_names]},
        dict:store({IndexSrc}, Index2, DictBySrcAcc)
    end, dict:new(), RawIndexes),
    % number the views
    {Indexes, _N} = lists:mapfoldl(
        fun({_Src, Index}, N) ->
            {Index#spatial{id_num=N},N+1}
        end, 0, lists:sort(dict:to_list(DictBySrc))),

    IdxState = #spatial_state{
        db_name = DbName,
        idx_name = Id,
        lib = Lib,
        views = Indexes,
        language = Language,
        design_options = DesignOpts
    },
    SigInfo = {Indexes, Language, DesignOpts, couch_index_util:sort_lib(Lib)},
    {ok, IdxState#spatial_state{sig=couch_util:md5(term_to_binary(SigInfo))}}.


extract_view(_Name, []) ->
    {not_found, missing_named_view};
extract_view(Name, [#spatial{view_names=ViewNames}=View|Rest]) ->
    case lists:member(Name, ViewNames) of
        true -> {ok, View};
        false -> extract_view(Name, Rest)
    end.


view_sig(State, View, Args0) ->
    Sig = State#spatial_state.sig,
    #spatial{
        update_seq = UpdateSeq,
        purge_seq = PurgeSeq
    } = View,
    Args = Args0#spatial_args{
        preflight_fun=undefined,
        extra=[]
    },
    Bin = term_to_binary({Sig, UpdateSeq, PurgeSeq, Args}),
    couch_index_util:hexsig(couch_util:md5(Bin)).


init_state(Db, Fd, State, nil) ->
    Header = #spatial_header{
        seq = 0,
        purge_seq = couch_db:get_purge_seq(Db),
        id_btree_state = nil,
        view_states = [
            % vtree state, update_seq, purge_seq
            {#vtree_state{}, 0, 0} || _ <- State#spatial_state.views]
    },
    init_state(Db, Fd, State, Header);
init_state(Db, Fd, State, Header) ->
    #spatial_header{
        seq = Seq,
        purge_seq = PurgeSeq,
        id_btree_state = IdBtreeState,
        view_states = ViewStates
    } = Header,

    % There's currently only one less function supported, hence we can
    % hard-code it
    Less = fun(A, B) -> A < B end,

    Views = lists:zipwith(
       fun({VtreeState, UpdateSeq, PurgeSeq2}, View) ->
            Vtree = #vtree{
                root = VtreeState#vtree_state.root,
                kp_chunk_threshold = VtreeState#vtree_state.kp_chunk_threshold,
                kv_chunk_threshold = VtreeState#vtree_state.kv_chunk_threshold,
                min_fill_rate = VtreeState#vtree_state.min_fill_rate,
                less = Less,
                fd = Fd
            },
            View#spatial{
                vtree = Vtree,
                update_seq = UpdateSeq,
                purge_seq = PurgeSeq2,
                fd = Fd
            }
        end,
        ViewStates, State#spatial_state.views),

    {ok, IdBtree} = couch_btree:open(
        IdBtreeState, Fd, [{compression, couch_db:compression(Db)}]),

    State#spatial_state{
        fd = Fd,
        update_seq = Seq,
        purge_seq = PurgeSeq,
        id_btree = IdBtree,
        views = Views
    }.


get_row_count(View) ->
    Count = vtree_search:count_all(View#spatial.vtree),
    {ok, Count}.


validate_args(Args) ->
    % `stale` and `count` got already validated during parsing

    #spatial_args{
        bbox = Bbox,
        bounds = Bounds,
        range = Range
    } = Args,

    % In case a 'bbox` is given, the value of `bbox` will be stored in `range`
    % and `bbox` will be set to `nil` after validation.
    Range2 = case {Bbox, Range} of
    {nil, nil} ->
        nil;
    {Bbox, nil} ->
        Bbox;
    {nil, Range} ->
        Range;
    {Bbox, Range} ->
        Msg = <<"A bounding box *and* a range were specified."
                " Please use either of them.">>,
        throw({query_parse_error, Msg})
    end,

    case Bbox =:= nil orelse
        length(Bbox) == 2 of
    true ->
        case {Bbox, Bounds} of
        % Coordinates of the bounding box are flipped and no bounds for the
        % cartesian plane were set
        {[{W, E}, {S, N}], nil} when E < W; N < S ->
            Msg2 = <<"Coordinates of the bounding box are flipped, but no "
                    "bounds for the cartesian plane were specified "
                    "(use the `plane_bounds` parameter)">>,
            parse_error(Msg2);
        _ ->
            ok
        end;
    false ->
        parse_error(<<"`bbox` must have 2 dimensions.">>)
    end,

    case Bounds =:= nil orelse
            length(Bounds) == 2 of
        true -> ok;
        false -> parse_error(<<"`plane_bounds` must have 2 dimensions.">>)
    end,

    case Args#spatial_args.limit > 0 of
        true -> ok;
        false -> parse_error(<<"`limit` must be a positive integer.">>)
    end,

    case Args#spatial_args.skip >= 0 of
        true -> ok;
        false -> parse_error(<<"`skip` must be >= 0.">>)
    end,

    Args#spatial_args{
        bbox = nil,
        range = Range2
    }.


parse_error(Msg) ->
    throw({query_parse_error, Msg}).


make_header(State) ->
    #spatial_state{
        update_seq = Seq,
        purge_seq = PurgeSeq,
        id_btree = IdBtree,
        views = Views
    } = State,
    ViewStates = [
        {
            #vtree_state{
                root = V#spatial.vtree#vtree.root,
                kp_chunk_threshold = V#spatial.vtree#vtree.kp_chunk_threshold,
                kv_chunk_threshold = V#spatial.vtree#vtree.kv_chunk_threshold,
                min_fill_rate = V#spatial.vtree#vtree.min_fill_rate
            },
            V#spatial.update_seq,
            V#spatial.purge_seq
        } || V <- Views
    ],
    #spatial_header{
        seq = Seq,
        purge_seq = PurgeSeq,
        id_btree_state = couch_btree:get_state(IdBtree),
        view_states = ViewStates
    }.


index_file(DbName, Sig) ->
    FileName = couch_index_util:hexsig(Sig) ++ ".spatial",
    couch_index_util:index_file(spatial, DbName, FileName).


compaction_file(DbName, Sig) ->
    FileName = couch_index_util:hexsig(Sig) ++ ".compact.spatial",
    couch_index_util:index_file(spatial, DbName, FileName).


% This is a verbatim copy from couch_mrview_utils
open_file(FName) ->
    case couch_file:open(FName) of
        {ok, Fd} -> {ok, Fd};
        {error, enoent} -> couch_file:open(FName, [create]);
        Error -> Error
    end.


% This is a verbatim copy from couch_mrview_utils
delete_files(DbName, Sig) ->
    delete_index_file(DbName, Sig),
    delete_compaction_file(DbName, Sig).


% This is a verbatim copy from couch_mrview_utils
delete_index_file(DbName, Sig) ->
    delete_file(index_file(DbName, Sig)).


% This is a verbatim copy from couch_mrview_utils
delete_compaction_file(DbName, Sig) ->
    delete_file(compaction_file(DbName, Sig)).


% This is a verbatim copy from couch_mrview_utils
delete_file(FName) ->
    case filelib:is_file(FName) of
        true ->
            RootDir = couch_index_util:root_dir(),
            couch_file:delete(RootDir, FName);
        _ ->
            ok
    end.


reset_index(Db, Fd, State) ->
    ok = couch_file:truncate(Fd, 0),
    ok = couch_file:write_header(Fd, {State#spatial_state.sig, nil}),
    init_state(Db, Fd, reset_state(State), nil).


reset_state(State) ->
    Views = [View#spatial{vtree = #vtree{}} || View <- State#spatial_state.views],
    State#spatial_state{
        fd = nil,
        query_server = nil,
        update_seq = 0,
        id_btree = nil,
        views = Views
    }.


expand_dups([], Acc) ->
    lists:reverse(Acc);
expand_dups([#kv_node{body={dups, Vals}}=Node | Rest], Acc) ->
    Expanded = [Node#kv_node{body=Val} || Val <- Vals],
    expand_dups(Rest, Expanded ++ Acc);
expand_dups([KV | Rest], Acc) ->
    expand_dups(Rest, [KV | Acc]).


row_to_ejson({Mbb, DocId, Geom, Value}) ->
    % If there's no geometry in the output, there's no bbox to add
    GeomData = case Geom of
    nil ->
        [];
    _ ->
        % XXX NOTE vmx 2012-11-28: Currently the first two dimensions are
        %     expected to be the bounding box of the geometry
        % XXX vmx 2012-11-28: I'm not sure if a bounding box should be
        %     emitted at all. It's duplicated information you can get from
        %     the key yourself.
        {[{W, E}, {S, N}], _} = lists:split(2, Mbb),
        [
            {<<"bbox">>, [W, S, E, N]},
            {<<"geometry">>,
                couch_spatial_updater:geocouch_to_geojsongeom(Geom)}
        ]
    end,
    {[
        {<<"id">>, DocId},
        {<<"key">>, [[Min, Max] || {Min, Max} <- Mbb]}
    ] ++ GeomData ++ [{<<"value">>, Value}]}.


split_bbox_if_flipped([{W, E}, {S, N}]=Bbox, [{BW, BE}, {BS, BN}]=_Bounds) ->
    case bbox_is_flipped(Bbox) of
    {flipped, Direction} ->
        Bboxes = case Direction of
        both ->
            [[{W, BE}, {S, BN}], [{W, BE}, {BS, N}],
                [{BW, E}, {S, BN}], [{BW, E}, {BS, N}]];
        x ->
            [[{W, BE}, {S, N}], [{BW, E}, {S, N}]];
        y ->
            [[{W, E}, {S, BN}], [{W, E}, {BS, N}]]
        end,
        % if boxes are still flipped, they are out of the bounds
        lists:foldl(fun(B, Acc) ->
           case bbox_is_flipped(B) of
               {flipped, _} -> Acc;
               not_flipped -> [B|Acc]
           end
        end, [], Bboxes);
    not_flipped ->
        [Bbox]
    end.


bbox_is_flipped([{W, E}, {S, N}]) when E < W, N < S ->
    {flipped, both};
bbox_is_flipped([{W, E}, _]) when E < W ->
    {flipped, x};
bbox_is_flipped([_, {S, N}]) when N < S ->
    {flipped, y};
bbox_is_flipped(_Bbox) ->
    not_flipped.
