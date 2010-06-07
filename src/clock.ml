(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2010 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

type clock_variable = Source.clock_variable
type source = Source.source
type active_source = Source.active_source

include Source.Clock_variables

let create_known s = create_known (s:>Source.clock)

let log = Dtools.Log.make ["clock"]

(** [started] indicates that the application has loaded and started
  * its initial configuration.
  * It is mostly intended to allow different behaviors on error:
  *  - for the initial conf, all errors are fatal
  *  - after that (dynamic code execution, interactive mode) some errors
  *    are not fatal anymore. *)

let started = ref false
let running () = !started
let set_running () = started := true

(** If initialization raises an exception, we want to report it and shutdown.
  * However, this has to be done carefully, by un-initializing first:
  * otherwise shutdown will hang (and temporary files may remain, etc). *)
let iter ~rollback f l =
  let rec aux ran = function
    | [] -> ()
    | c::tl ->
        (try f c with e -> List.iter rollback ran  ; raise e) ;
        aux (c::ran) tl
  in
    aux [] l

(** We need to keep track of all used clocks, to have them (un)register
  * new sources. We use a weak table to avoid keeping track forever of
  * clocks that are unused and unusable. *)

module H = struct
  type t = Source.clock
  let equal a b = a = b
  let hash a = Oo.id a
end
module Clocks = Weak.Make(H)
let clocks = Clocks.create 10

(** Base clock class *)

class clock id =
object (self)

  initializer Clocks.add clocks (self:>Source.clock)

  method id = id

  val log = Dtools.Log.make ["clock";id]

  val lock = Mutex.create ()
  val mutable outputs = []

  method attach s =
    Tutils.mutexify lock
      (fun () ->
         if not (List.exists (fun (_,s') -> s=s') outputs) then
           outputs <- (`New,s)::outputs)
      ()

  method detach test =
    Tutils.mutexify lock
      (fun () ->
         outputs <-
           List.fold_left
             (fun outputs (flag,s) ->
                if test s then
                  match flag with
                    | `New -> outputs
                    | `Active -> (`Old,s)::outputs
                    | `Starting -> (`Aborted,s)::outputs
                    | `Old | `Aborted -> (flag,s)::outputs
                else
                  (flag,s)::outputs)
             [] outputs) ()

  val mutable sub_clocks : Source.clock_variable list = []
  method sub_clocks = sub_clocks
  method attach_clock c =
    if not (List.mem c sub_clocks) then sub_clocks <- c::sub_clocks

  val mutable round = 0

  method get_tick = round

  method end_tick =
    let leaving,outputs =
      Tutils.mutexify lock
        (fun () ->
           let new_outputs,leaving,active =
             List.fold_left
               (fun (outputs,leaving,active) (flag,(s:active_source)) ->
                  match flag with
                    | `Old -> outputs, s::leaving, active
                    | `Active -> (flag,s)::outputs, leaving, s::active
                    | _ -> (flag,s)::outputs, leaving, active)
               ([],[],[])
               outputs
           in
             outputs <- new_outputs ;
             leaving,active) ()
    in
      List.iter (fun (s:active_source) -> s#leave (s:>source)) leaving ;
      List.iter (fun s -> s#output) outputs ;
      round <- round + 1 ;
      List.iter (fun s -> s#after_output) outputs

  method start_outputs =
    (* Extract the list of outputs to start, mark them as Starting
     * so they are not managed by a nested call of start_outputs
     * (triggered by collect, which can be triggered by the
     *  starting of outputs).
     *
     * It would be simpler to let the streaming loop (or #end_tick) take
     * care of initialization, just like it takes care of shutting sources
     * down. But this way we guarantee that sources created "simultaneously"
     * start streaming simultaneously. *)
    let to_start =
      Tutils.mutexify lock
        (fun () ->
           let rec aux (outputs,to_start) = function
             | (`New,s)::tl -> aux ((`Starting,s)::outputs,s::to_start) tl
             | (flag,s)::tl -> aux ((flag,s)::outputs,to_start) tl
             | [] -> outputs,to_start
           in
           let new_outputs,to_start = aux ([],[]) outputs in
             outputs <- new_outputs ;
             to_start)
        ()
    in
    fun () ->
    let to_start =
      if to_start <> [] then
        log#f 4 "Starting %d sources..." (List.length to_start) ;
      List.map
        (fun (s:active_source) ->
           try s#get_ready [(s:>source)] ; `Woken_up s with
             | e when !started ->
                 log#f 2 "Error when starting %s: %s!"
                   s#id (Printexc.to_string e) ;
                 `Error s)
        to_start
    in
    let to_start =
      List.map
        (function
           | `Error s -> `Error s
           | `Woken_up (s:active_source) ->
               try s#output_get_ready ; `Started s with
                 | e when !started ->
                     log#f 2 "Error when starting %s: %s!"
                       s#id (Printexc.to_string e) ;
                     s#leave (s:>source) ;
                     `Error s)
        to_start
    in
    (* Now mark the started sources as `Active,
     * unless they have been deactivating in the meantime (`Aborted)
     * in which case they have to be cleanly stopped. *)
    let leaving =
      Tutils.mutexify lock
        (fun () ->
           let new_outputs, leaving =
             List.fold_left
               (fun (outputs,leaving) (flag,s) ->
                  if List.mem (`Started s) to_start then
                    match flag with
                       | `Starting -> (`Active,s)::outputs, leaving
                       | `Aborted -> outputs, s::leaving
                       | `New | `Active | `Old -> assert false
                  else if List.mem (`Error s) to_start then
                    match flag with
                       | `Starting -> outputs, leaving
                       | `Aborted -> outputs, leaving
                       | `New | `Active | `Old -> assert false
                  else
                    (flag,s)::outputs, leaving)
               ([],[]) outputs
           in
             outputs <- new_outputs ;
             leaving) ()
    in
      if leaving <> [] then
        log#f 4 "Stopping %d sources..." (List.length leaving) ;
      List.iter (fun (s:active_source) -> s#leave (s:>source)) leaving

end

(** {1 Wallclock implementation}
  * This was formerly known as the Root.
  * One could think of several wallclocks for isolated parts of a script.
  * One can also think of alsa-clocks, etc. *)

open Dtools

let conf =
  Conf.void ~p:(Configure.conf#plug "root") "Streaming clock settings"
let conf_max_latency =
  Conf.float ~p:(conf#plug "max_latency") ~d:60. "Maximum latency in seconds"
    ~comments:[
      "If the latency gets higher than this value, the outputs will be reset,";
      "instead of trying to catch it up second by second." ;
      "The reset is typically only useful to reconnect icecast mounts."
    ]
let conf_sync =
  Conf.bool ~p:(conf#plug "sync") ~d:true "Synchronization flag"
    ~comments:[
      "Control whether or not liquidsoap should take care of the timing.";
      "Otherwise, the sources may handle it by themselves -- typically in the ";
      "case of un-bufferized alsa I/O, which turns root synchronization off";
      "automatically.";
      "Leaving the sources without synchronization can also be useful for ";
      "debugging or measuring performance, as it results in liquidsoap running";
      "as fast as possible."
    ]

(** Timing stuff, make sure the frame rate is correct. *)

let time = Unix.gettimeofday
let usleep d =
  (* In some implementations,
   * Thread.delay uses Unix.select which can raise EINTR.
   * A really good implementation would keep track of the elapsed time and then
   * trigger another Thread.delay for the remaining time.
   * This cheap thing does the job for now.. *)
  try Thread.delay d with Unix.Unix_error (Unix.EINTR,_,_) -> ()

class wallclock ?sync id =
object (self)

  inherit clock ("wallclock_"^id) as super

  (** Main loop. *)

  val mutable running = false
  val do_running =
    let lock = Mutex.create () in
      fun f -> Tutils.mutexify lock f ()

  val mutable sync =
    match sync with None -> conf_sync#get | Some b -> b

  method private run =
    let acc = ref 0 in
    let max_latency = -. conf_max_latency#get in
    let last_latency_log = ref (time ()) in
    let t0 = ref (time ()) in
    let ticks = ref 0L in
    let delay () =
      !t0
      +. (Lazy.force Frame.duration) *. Int64.to_float (Int64.add !ticks 1L)
      -. time ()
    in
      if sync then
        log#f 3 "Streaming loop starts, synchronized with wallclock."
      else
        log#f 3 "Streaming loop starts, no sync." ;
      let rec loop () =
        if outputs = [] then () else
        let rem = if not sync then 0. else delay () in
          (* Sleep a while or worry about the latency *)
          if (not sync) || rem > 0. then begin
            acc := 0 ;
            usleep rem
          end else begin
            incr acc ;
            if rem < max_latency then begin
              log#f 2 "Too much latency! Resetting active sources.." ;
              List.iter
                (function
                   | (`Active,s) when s#is_active -> s#output_reset
                   | _ -> ())
                outputs ;
              t0 := time () ;
              ticks := 0L ;
              acc := 0
            end else if
              (rem <= -1. || !acc >= 100) && !last_latency_log +. 1. < time ()
            then begin
              last_latency_log := time () ;
              log#f 2 "We must catchup %.2f seconds%s!"
                (-. rem)
                (if !acc <= 100 then "" else
                   " (we've been late for 100 rounds)") ;
              acc := 0
            end
          end ;
          ticks := Int64.add !ticks 1L ;
          (* This is where the streaming actually happens: *)
          super#end_tick ;
          loop ()
      in
        loop () ;
        do_running (fun () -> running <- false) ;
        log#f 3 "Streaming loop stopped."

  val thread_name = "wallclock_" ^ id

  method start_outputs =
    let f = super#start_outputs in
      fun () -> begin
        f () ;
        if List.exists (function (`Active,_) -> true | _ -> false) outputs then
          do_running
            (fun () ->
               (* TODO This might be too early: this could be a nested
                *   #start_outputs in which case we'd prefer the outer
                *   one to start the thread. *)
               if not running then begin
                 running <- true ;
                 ignore (Tutils.create (fun () -> self#run) () thread_name)
               end)
      end

end

(** {1 Self-sync wallclock}
  * Special kind of clock for self-synched devices,
  * that only does synchronization when all input/outputs are stopped
  * (a normal non-synched wallclock goes 100% CPU when blocking I/O
  * stops). *)

class self_sync id =
object
  inherit wallclock ~sync:true id as super

  val mutable blocking_sources = 0
  val bs_lock = Mutex.create ()

  method register_blocking_source =
    Tutils.mutexify bs_lock
      (fun () ->
         if blocking_sources = 0 then begin
           log#f 4 "Delegating clock to active sources." ;
           sync <- false
         end ;
         blocking_sources <- blocking_sources + 1)
      ()

  method unregister_blocking_source =
    Tutils.mutexify bs_lock
      (fun () ->
         blocking_sources <- blocking_sources - 1 ;
         if blocking_sources = 0 then begin
           sync <- true ;
           log#f 4 "All active sources stopped, synching with wallclock."
         end)
      ()
end

(** {1 Global clock management} *)

(** When created, sources have a clock variable, which gets unified
  * with other variables or concrete clocks. When the time comes to
  * initialize the source, if its clock isn't defined yet, it gets
  * assigned to a default clock and that clock will take care of
  * starting it.
  *
  * Taking all freshly created sources, assigning them to the default
  * clock if needed, and starting them, is performed by [collect].
  * This is typically called after each script execution.
  * Technically we could separate collection and clock assignment,
  * which might simplify some things if it becomes unmanageable in the
  * future.
  *
  * Sometimes we need to be sure that collect doesn't happen during
  * the execution of a function. Otherwise, sources might be assigned
  * the default clock too early. This is done using [collect_after].
  * This need is not cause by running collect in too many places, but
  * simply because there is no way to control collection on a per-thread
  * basis (collect only the sources created by a given thread of
  * script execution).
  *
  * Functions running using [collect_after] should be kept short.
  * However, in theory, with multiple threads, we could have plenty
  * of short functions always overlapping so that collection can
  * never be done. This shouldn't happen too much, but in any case
  * we can't get rid of this without a more fine-grained collect,
  * which would require (heavy) execution contexts to tell from
  * which thread/code a given source has been added. *)

(** We must keep track of the number of tasks currently executing
  * in a collect_after. When the last one exits it must collect.
  *
  * It is okay to start a new collect_after when a collect is
  * ongoing: all that we're doing is avoiding collection of sources
  * created by the task. That's why #start_outputs first harvests
  * sources then returns a function actually starting those sources:
  * only the first part is done within critical section.
  *
  * The last trick is that we start with a fake task (after_collect_tasks=1)
  * to avoid that the initial parsing of files triggers collect and thus
  * a too early initialization of outputs (before daemonization). Main is
  * in charge of finishing that virtual task and trigger the initial
  * collect. *)
let after_collect_tasks = ref 1
let lock = Mutex.create ()
let cond = Condition.create ()

(** We might not need a default clock, so we use a lazy clock value.
  * We don't use Lazy because we need a thread-safe mechanism. *)
let get_default =
  Tutils.lazy_cell (fun () -> (new wallclock "main" :> Source.clock))

(** A function displaying the varying number of allocating clocks.
  * It's not thread safe but the worst that can happen is a doubled log. *)
let gc_alarm =
  let last_displayed = ref (-1) in
    fun () ->
      let nb_clocks = Clocks.count clocks in
        if nb_clocks <> !last_displayed then begin
          log#f 4 "Currently %d clocks allocated." nb_clocks ;
          last_displayed := nb_clocks
        end

let () = ignore (Gc.create_alarm gc_alarm)

(** After some sources have been created or removed (by script execution),
  * finish assigning clocks to sources (assigning the default clock),
  * start clocks and sources that need starting,
  * and stop those that need stopping. *)
let collect ~must_lock =
  if must_lock then Mutex.lock lock ;
  (* If at least one task is engaged it will take care of collection later.
   * Otherwise, prepare a collection while in critical section
   * (to avoid harvesting sources created by a task) and run it
   * outside of critical section (to avoid all sorts of shit). *)
  if !after_collect_tasks > 0 then
    Mutex.unlock lock
  else begin
    Source.iterate_new_outputs
      (fun o ->
         if not (is_known o#clock) then
           ignore (unify o#clock (create_known (get_default ())))) ;
    gc_alarm () ;
    let collects =
      Clocks.fold (fun s l -> s#start_outputs::l) clocks []
    in
      Mutex.unlock lock ;
      List.iter (fun f -> f ()) collects
  end

let collect_after f =
  Mutex.lock lock ;
  after_collect_tasks := !after_collect_tasks + 1 ;
  Mutex.unlock lock ;
  Tutils.finalize f
    ~k:(fun () ->
          Mutex.lock lock ;
          after_collect_tasks := !after_collect_tasks - 1 ;
          collect ~must_lock:false)

let start () =
  Mutex.lock lock ;
  after_collect_tasks := !after_collect_tasks - 1 ;
  collect ~must_lock:false

(** To stop, simply detach everything and the clocks will stop running.
  * No need to collect, stopping is done by itself. *)
let stop () =
  Clocks.iter (fun s -> s#detach (fun _ -> true)) clocks

let fold f x = Clocks.fold f clocks x
