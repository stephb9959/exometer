%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 Basho Technologies, Inc.  All Rights Reserved.
%%
%%   This Source Code Form is subject to the terms of the Mozilla Public
%%   License, v. 2.0. If a copy of the MPL was not distributed with this
%%   file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%
%% -------------------------------------------------------------------


%% @doc
%%
%% == Introduction ==
%% This module defines a sliding time-window histogram with execution
%% cost control.
%%
%% The problem with traditional histograms is that every sample is
%% stored and processed, no matter what the desired resolution is.
%%
%% If a histogram has a sliding window of 100 seconds, and we have a
%% sample rate of 100Hz will give us 10000 elements to process every time
%% we want to calculate that average, which is expensive.
%% The same goes for min/max finds, percentile calculations, etc.
%%
%% The solution is to introduce cost-control, where we can balance
%% execution time against sample resolution.
%%
%% The obvious implementation is to lower the sample rate by throwing
%% away samples and just store evey N samples. However, this will
%% mean potentially missed min/max values, and other extreme data
%% that is seen by the edge code but is thrown away.
%%
%% A slotted slide histogram will defined a number of time slots, each
%% spanning a fixed number of milliseconds. The slider then stores
%% slots that cover a given timespan into the past (a rolling
%% historgram). All slots older than the timespan are discarded.
%%
%% The "current" slot is defined as the time period between the time
%% stamp of the last stored slot and the time when it is time to store
%% the next slot. If the slot period (size) is 100ms, and the last
%% slot was stored in the histogram at msec 1200, the current slot
%% period ends at msec 1300.
%%
%% All samples received during the current slot are processed by a
%% low-cost fun that updates the current slot state. When the current
%% slot ends, another fun is used to transform the current slot state
%% to a value that is stored in the histogram.
%%
%% If a simple average is to be calculated for all samples received,
%% the sample-processing fun will add to the sum of the received
%% samples, and increment sample counter. When the current slot
%% expires, the result of SampleSum / SampleCount is stored in the
%% slot.
%%
%% If min/max are to be stored by the slotted histograms, the current
%% slot state would have a { Min, Max } tuple that is upadted with the
%% smallest and largest values received during the period. At slot
%% expiration the min/max tuple is simply stored, by the
%% transformation fun, in the histogram slots.
%%
%% By adjusting the slot period and the total histogram duration, the
%% cost of analysing the entire histogram can be balanced against
%% the resolution of that analysis.
%%
%%
%% == SLOT HISTOGRAM MANAGEMENT ==
%%
%% The slide state has maintains a list of { TimeStamp, SlotElem }
%% slot tuples. TimeStamp is the time period (in monotonic ms),
%% rounded down to the resolution of the slot period, and SlotElem is
%% the tuple generated by the current slot transformation MFA. The
%% list is sorted on descending time stamps (newest slot first).
%%
%% Normally each element in the list has a timestamp that is
%% SlotPeriod milliseconds newer than the next slot in the
%% list. However, if no samples are received during the current slot,
%% no slot for that time stamp will be stored, leaving a hole in the
%% list.  Normally, the the slot list would look like this (with a 100
%% msec slot period and a simple average value):
%%
%% <pre lang="erlang">
%%     [ { 1400, 23.2 }, { 1300, 23.1 }, { 1200, 22.8 }, { 1100, 23.0 } ]
%% </pre>
%%
%% If no samples were received during the period between 1200 and 1300
%% (ms), no slot would be stored at that time stamp, yielding the
%% following list:
%%
%% <pre lang="erlang">
%%     [ { 1400, 23.2 }, { 1300, 23.1 }, { 1100, 23.0 } ]
%% </pre>
%%
%% This means that the total length of the slot list may vary, even
%% if it always covers the same time span into the past.
%%
%% == SLOT LISTS ==
%%
%% The slotted slider stores its slots in two lists, list1, and list2.
%% list1 contains the newest slots. Once the oldest element in list1
%% is older than the time span covered by the histogram, the entire
%% content of list1 is shifted into list2, and list1 is set to [].
%% The old content of list2, if any, is discarded during the shift.
%%
%% When the content of the histogram is to be retrieved (through
%% fold{l,r}(), or to_list()), the entire content of list1 is prepended to
%% the part of list2 that is within than the time span covered by the
%% histogram.
%%
%% If the time span of the histogram is 5 seconds, with a 1 second
%% slot period, list1 looks can like this :
%%
%% <pre lang="erlang">
%%     list1 = [ {5000, 1.2}, {4000, 2.1}, {3000, 2.0}, {2000, 2.3}, {1000, 2.8} ]
%% </pre>
%%
%% When the next slot is stored in the list, add_slot() will detect
%% that the list is full since the oldest element ({1000, 20.8}) will
%% fall outside the time span covered by the histogram.  List1 will
%% shifted to List2, and List1 will be set to the single new slot that
%% is to be stored:
%%
%% <pre lang="erlang">
%%     list1 = [ {6000, 1.8} ]
%%     list2 = [ {5000, 1.2}, {4000, 2.1}, {3000, 2.0}, {2000, 2.3}, {1000, 2.8} ]
%% </pre>
%%
%% To_list() and fold{l,r}() will return list1, and the first four elements
%% of list2 in order to get a complete histogram covering the entire
%% time span:
%%
%% <pre lang="erlang">
%%     [ {6000, 1.8}, {5000, 1.2}, {4000, 2.1}, {3000, 2.0}, {2000, 2.3} ]
%% </pre>
%%
%%
%% == SAMPLE PROCESSING AND TRANSFORMATION FUN ==
%%
%% Two funs are provided to the new() function of the slotted slide
%% histogram. The processing function is called by add_element() and
%% will take the same sample value provided to that function together
%% with the current timestamp and slot state as arguments. The
%% function will return the new current slot state.
%%
%% <pre lang="erlang">
%%     M:F(TimeStamp, Value, State) -> NewState
%% </pre>
%%
%% The first call to the sample processing fun when the current slot
%% is newly reset (just after a slot has been added to the histogram),
%% state will be set to 'undefined'
%%
%% <pre lang="erlang">
%%     M:F(TimeStamp, Value, undefined) -> NewState
%% </pre>
%%
%% The transformation fun is called when the current slot has expired
%% and is to be stored in the histogram. It will receive the current
%% timestamp and slot state as arguments and returns the element to
%% be stored (together with a slot timestamp) in the slot histogram.
%%
%% <pre lang="erlang">
%%     M:F(TimeStamp, State) -> Element
%% </pre>
%%
%% Element will present in the lists returned by to_list() and fold{l,r}().
%% If the transformation MFA cannot do its job, for example because
%% no samples have been processed by the sample processing fun,
%% the transformation fun should return 'undefined'
%%
%% See new/2 and its avg_sample() and avg_transform() functions for an
%% example of a simple average value implementation.
%%
%% @end
-module(exometer_slot_slide).

-export([new/2, new/4, new/5,
         add_element/2,
         add_element/3,
         reset/1,
         to_list/1,
         foldl/3,
         foldl/4,
         foldr/3,
         foldr/4]).


-compile(inline).

-type(timestamp() :: integer()).
-type(value() :: any()).
-type(cur_state() :: any()).

-type(sample_fun() :: fun((timestamp(), value(), cur_state()) -> cur_state())).
-type transform_fun() :: fun((timestamp(), cur_state()) -> cur_state()).

%% Fixed size event buffer
%% A slot is indexed by taking the current timestamp (in ms) divided by the slot_period
%%
-record(slide, {timespan = 0 :: integer(),  % How far back in time do we go, in slot period increments.
                sample_fun :: sample_fun(),
                transform_fun :: transform_fun(),
                slot_period :: integer(),   % Period, in ms, of each slot
                cur_slot = 0 :: integer(),  % Current slot as in
                cur_state = undefined :: any(), % Total for the current slot
                list1_start_slot = 0 ::integer(),     % Slot of the first list1 element
                list1 = []    :: list(),
                list2 = []    :: list()}).

-spec new(integer(), integer()) -> #slide{}.
new(HistogramTimeSpan, SlotPeriod) ->
    new(HistogramTimeSpan, SlotPeriod, fun avg_sample/3, fun avg_transform/2).

-spec new(integer(), integer(), sample_fun(), transform_fun()) -> #slide{}.
new(HistogramTimeSpan, SlotPeriod, SampleF, TransformF) ->
    new(HistogramTimeSpan, SlotPeriod, SampleF, TransformF, []).

-spec new(integer(), integer(), sample_fun(), transform_fun(), list()) -> #slide{}.
new(HistogramTimeSpan, SlotPeriod, SampleF, TransformF, _Options)
  when is_function(SampleF, 3), is_function(TransformF, 2) ->
    #slide{timespan = trunc(HistogramTimeSpan / SlotPeriod),
           sample_fun = SampleF,
           transform_fun = TransformF,
           slot_period = SlotPeriod,
           cur_slot = trunc(timestamp() / SlotPeriod),
           cur_state = undefined,
           list1_start_slot = 0,
           list1 = [],
           list2 = []}.

-spec add_element(any(), #slide{}) -> #slide{}.

add_element(Val, Slide) ->
    add_element(timestamp(), Val, Slide).

add_element(TS, Val, #slide{cur_slot = CurrentSlot,
                            sample_fun = SampleF} = Slide) ->

    TSSlot = get_slot(TS, Slide),

    %% We have two options here:
    %% 1. We have moved into a new slot since last call to add_element().
    %%    In this case, we invoke the transform MFA for the now completed slot
    %%    and add the returned element to the slider using the add_slot() function.
    %%    Once that is done, we start with fresh 'undefined' current slot state
    %%    that the next call to the sample MFA will receive.
    %%
    %% 2. We are in the same slot as during the last call to add_element().
    %%    In this case, we will simply call the sample MFA to update the
    %%    current slot state.
    %%
    %%
    Slide1 =
        if TSSlot =/= CurrentSlot ->
                add_slot(TS, Slide);
           true ->
                Slide
        end,

    %%
    %% Invoke the sample MFA to get a new state to work with
    %%
    Slide1#slide {cur_state = SampleF(TS, Val, Slide1#slide.cur_state)}.


-spec to_list(#slide{}) -> list().
%%
to_list(#slide{timespan = TimeSpan}) when TimeSpan == 0 ->
    [];

%% Convert the whole histograms, in both buffers, to a list.
to_list(#slide{timespan = TimeSpan } = Slide) ->
    Oldest = get_slot(Slide) - TimeSpan,
    take_since(Oldest, Slide).

-spec reset(#slide{}) -> #slide{}.

reset(#slide{} = Slide) ->
    Slide#slide { cur_state = undefined,
                  cur_slot = 0,
                  list1 = [],
                  list2 = [],
                  list1_start_slot = 0}.


foldl(TS, Fun, Acc, #slide{timespan = TimeSpan} = Slide) ->
    Oldest = get_slot(TS, Slide) - TimeSpan,
    lists:foldl(Fun, Acc, take_since(Oldest, Slide)).

foldl(Fun, Acc,  Slide) ->
    foldl(timestamp(), Fun, Acc, Slide).


foldr(TS, Fun, Acc, #slide{timespan = TimeSpan} = Slide) ->
    Oldest = get_slot(TS, Slide) - TimeSpan,
    lists:foldr(Fun, Acc, take_since(Oldest, Slide)).

foldr(Fun, Acc, Slide) ->
    foldr(timestamp(), Fun, Acc, Slide).

%% Collect all elements in the histogram with a timestamp that falls
%% within the timespan ranging from Oldest up to the current timme.
%%
take_since(Oldest, #slide{cur_slot = CurrentSlot,
                          cur_state = CurrentState,
                          slot_period = SlotPeriod } =Slide) ->

    %% Check if we need to add a slot for the current time period
    %% before we start to grab data.
    %% We add the current slot if it has a sample (cur_state =/= undefined)
    %% and the slot period has expired.
    TS = timestamp(),
    TSSlot = get_slot(TS, Slide),
    #slide { list1 = List1,
             list2 = List2} =
        if TSSlot =/= CurrentSlot, CurrentState =/= undefined ->
                add_slot(TS, Slide);
           true ->
                Slide
        end,

    take_since(List2, Oldest, SlotPeriod, take_since(List1, Oldest, SlotPeriod, [])).

take_since([{TS,Element} |T], Oldest, SlotPeriod, Acc) when TS >= Oldest ->
    take_since(T, Oldest, SlotPeriod, [{TS * SlotPeriod, Element} |Acc]);

take_since(_, _, _, Acc) ->
    %% Don't reverse; already the wanted order.
    Acc.


%%
get_slot(Slide) ->
    get_slot(timestamp(), Slide).

get_slot(TS, #slide{slot_period = Period}) ->
    trunc(TS / Period).

%%
%% Calculate the average data sampled during the current slot period
%% and push that average to the new slot.
%%
add_slot(TS, #slide{timespan = TimeSpan,
                    slot_period = SlotPeriod,
                    cur_slot = CurrentSlot,
                    cur_state = CurrentState,
                    transform_fun = TransformF,
                    list1 = List1,
                    list1_start_slot = StartSlot} = Slide) ->

    %% Transform current slot state to an element to be deposited
    %% in the histogram list
    TSSlot = trunc(TS / SlotPeriod),
    case TransformF(TS, CurrentState) of
        undefined ->  %% Transformation function could not produce an element
            %% Reset the time slot to the current slot. Reset state./
            Slide#slide{ cur_slot = TSSlot,
                         cur_state = undefined};

        %% The transform function produced an element to store
        Element ->
            %%
            %% Check if it is time to do a buffer swap.
            %% If the oldset element of list1,
            %%
            if StartSlot < TSSlot - TimeSpan ->
                    %% Shift list1 into list2.
                    %% Add the new slot as the initial element of list1
                    Slide#slide{ list1 = [{ CurrentSlot, Element }],
                                 list2 = List1,
                                 list1_start_slot = CurrentSlot,
                                 cur_slot = TSSlot,
                                 cur_state = undefined};
               true ->
                    %% No shift necessary. Tack on the new slot to list1.
                    Slide#slide{ list1 = [{ CurrentSlot, Element } | List1 ],
                                 cur_slot = TSSlot,
                                 cur_state = undefined }
            end
    end.



%% Simple sample processor that maintains the average value
%% of all samples received during the current slot.
avg_sample(_TS, Value, undefined) ->
    { 1, Value };

avg_sample(_TS, Value, {Count, Total}) ->
    { Count + 1, Total + Value }.

%% If avg_sample() has not been called for the current time slot,
%% then the provided state will still be 'undefined'
avg_transform(_TS, undefined) ->
    undefined;

%% Calculate the average of all received samples during the current slot
%% and return it as the element to be stored in the histogram.
avg_transform(_TS, { Count, Total }) ->
    Total / Count. %% Return the average value.


timestamp() ->
    %% Invented epoc is {1258,0,0}, or 2009-11-12, 4:26:40
    %% Millisecond resolution
    {MS,S,US} = os:timestamp(),
    (MS-1258)*1000000000 + S*1000 + US div 1000.
