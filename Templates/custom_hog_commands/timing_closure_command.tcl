set ::hog_command {
  NAME  {close_timing}

  DESCRIPTION "Creates runs for all possible combinations of synthesis and implementation strategies \
  in the current project, launches them (optionally), and monitors them for timing closure."

  IDE "vivado 2023.2"

  OPTIONS { njobs.arg }

  CUSTOM_OPTIONS {
    {proj.arg "" "if set, open project with this name before creating runs."}
    {run         "if set, run the created implementation runs after creation."}
    {monitor     "if set, monitor runs."}
    {timeout.arg 0 "monitor timeout in minutes."}
    {force       "if set, force reset of all synth/impl runs."}
    {keep_going  "if set, continue running after finding timing clean run."}
  }

  SCRIPT {

    proc secs_to_hms {seconds} {
      if {$seconds < 0} { set seconds 0 }
      set h [format %02d [expr {$seconds / 3600}]]
      set m [format %02d [expr {($seconds % 3600) / 60}]]
      set s [format %02d [expr {$seconds % 60}]]
      return "$h:$m:$s"
    }

    proc get_progress {run} {
      set raw ""
      set p 0
      if {[catch {set raw [get_property PROGRESS [get_runs $run]]}]} { return 0 }
      if {[regexp {([0-9]+)} $raw -> num]} { set p $num }
      return $p
    }

    proc get_run_status {run} {
      set status [get_property STATUS [get_runs $run]]
      if {[string match -nocase *RUNNING* $status]} {
        return "RUNNING"
      } elseif {[string match -nocase *COMPLETE* $status]} {
        return "COMPLETE"
      } elseif {[string match -nocase *ERROR* $status] } {
        return "ERROR"
      } elseif {[string match -nocase *QUEUED* $status] } {
        return "QUEUED"
      } else {
        return ""
      }
    }

    proc determine_njobs {runs} {
      set running_jobs 0
      foreach r $runs {
        if {[get_run_status $r] eq "RUNNING"} {
          incr running_jobs
        }
      }
      return $running_jobs
    }

    proc collect_metrics {runs} {
      set total [llength $runs]
      set done 0
      set err 0
      set sum_prog 0.0
      set best_wns ""
      foreach r $runs {
        if {![llength [get_runs $r]]} { continue }
        set status ""
        catch { set status [get_property STATUS [get_runs $r]] }
        set p [get_progress $r]
        set sum_prog [expr {$sum_prog + $p}]
        if {$p >= 100} {
          incr done
          if {![catch {get_property STATS.WNS [get_runs $r]} wns]} {
            if {$best_wns eq "" || $wns > $best_wns} { set best_wns $wns }
          }
        }
        if {[string match -nocase *ERROR* $status] || [string match -nocase *FAILED* $status]} { incr err }
      }
      set avg_prog [expr { $total > 0 ? $sum_prog / double($total) : 0 }]
      return [dict create total $total done $done err $err avg_prog $avg_prog best_wns $best_wns]
    }

    proc show_run_status {runs start_ms} {
      set elapsed_sec [expr {([clock milliseconds] - $start_ms) / 1000}]
      set metrics [collect_metrics $runs]

      set err [dict get $metrics err]
      set done [dict get $metrics done]
      set total [dict get $metrics total]
      set completed [expr {$err + $done}]

      set line "Elapsed [secs_to_hms $elapsed_sec] | Runs $completed/$total (ERR:$err DONE:$done) | Progress [format %.1f [dict get $metrics avg_prog]]%"

      set best_wns [dict get $metrics best_wns]
      if {$best_wns ne ""} {
        append line " | Best WNS $best_wns"
      }

      puts -nonewline "\r$line"
      flush stdout
    }


    proc launch_needed_runs {runs force_reset num_jobs project_dir project_file run_file timeout_min keep_going} {
      if {$force_reset} {
        Msg Info "Force reset: resetting all runs before launch."
        catch { reset_run $runs }
      }

      set runs_to_launch {}
      if {$force_reset} {
        set runs_to_launch $runs
      } else {
        foreach r $runs {
          if {![llength [get_runs $r]]} { continue }
          set status [get_run_status $r]
          if {$status ni {QUEUED RUNNING ERROR COMPLETE}} {
            lappend runs_to_launch $r
          }
        }
      }

      if {[llength $runs_to_launch] == 0} {
        Msg Info "All runs already queued, running, or finished."
        return
      }

      set synth_runs {}
      set impl_runs {}

      foreach r $runs_to_launch {
        if {[get_property IS_SYNTHESIS [get_runs $r]] == "1"} {
          lappend synth_runs $r
        } else {
          lappend impl_runs $r
        }
      }



      Msg Info "Launching [llength $runs_to_launch] runs with $num_jobs jobs in background..."

      # Create temporary launch script in project directory
      set script_path [file join $project_dir "launch_runs_bg.tcl"]

      # Clean up stale running flag if it exists
      if {[file exists $run_file]} {
        file delete $run_file
      }

      set fp [open $script_path w]
      puts $fp "# Temporary script to launch runs in background"
      puts $fp "set run_file \"$run_file\""
      puts $fp "set script_path \"$script_path\""
      puts $fp ""
      puts $fp "open_project \"$project_file\""
      puts $fp "launch_runs [list $runs_to_launch] -jobs $num_jobs"
      puts $fp ""
      puts $fp "# Create running flag"
      puts $fp "set fp \[open \$run_file w\]"
      puts $fp "puts \$fp \"set start_ms \[clock milliseconds\]\""
      puts $fp "puts \$fp \"set jobs $num_jobs\""
      puts $fp "close \$fp"
      puts $fp ""

      if {$keep_going} {
        set exit_cond "ALL"
      } else {
        set exit_cond "ANY_ONE_MET_TIMING"
      }

      puts $fp "# Wait for runs with appropriate exit condition"
      if {$timeout_min > 0} {
        set timeout_string "-timeout $timeout_min"
      } else {
        set timeout_string ""
      }

      puts $fp "wait_on_runs -quiet $timeout_string [list $synth_runs]"
      puts $fp "wait_on_runs -quiet $timeout_string -exit_condition $exit_cond [list $impl_runs]"
      puts $fp ""
      puts $fp "# Cleanup"
      puts $fp "file delete \$run_file"
      puts $fp "file delete \$script_path"
      puts $fp "exit"
      close $fp

      exec sh -c "setsid vivado -mode batch -source $script_path > /dev/null 2>&1 < /dev/null &" &
    }

    proc check_timing_closure {impl_run} {
      if {![llength [get_runs $impl_run]]} { return 0 }
      if {[get_run_status $impl_run] ne "COMPLETE"} { return 0 }

      foreach stat {STATS.WNS STATS.WHS STATS.TPWS} {
        if {[catch {get_property $stat [get_runs $impl_run]}]} { return 0 }
      }

      set wns  [get_property STATS.WNS  [get_runs $impl_run]]
      set whs  [get_property STATS.WHS  [get_runs $impl_run]]
      set tpws [get_property STATS.TPWS [get_runs $impl_run]]

      return [expr {$wns >= 0 && $whs >= 0 && $tpws >= 0}]
    }

    proc all_runs_complete {run_list} {
      foreach r $run_list {
        if {![llength [get_runs $r]]} { continue }
        set st [get_run_status $r]
        if {$st in {RUNNING QUEUED}} { return 0 }
      }
      return 1
    }




    set impl_run_list {}
    set synth_run_list {}


    set project_name [dict get $list_of_options proj]
    set run_flag     [dict get $list_of_options run]
    set jobs         [dict get $list_of_options njobs]
    set monitor_flag [dict get $list_of_options monitor]
    set timeout_min  [dict get $list_of_options timeout]
    set force_flag   [dict get $list_of_options force]
    set keep_going   [dict get $list_of_options keep_going]


    if { $project_name ne "" } {
      set project_file "../Projects/$project_name/$project_name.xpr"
      set project_file [file normalize $project_file]
      if { ![file exists $project_file] } {
        Msg Error "WARNING: Project '$project_name' does not exist at expected path '$project_file'. (Create/open it before run creation if required.)"
        return
      }
    }

    set project_dir [file dirname $project_file]
    set run_file [file join $project_dir ".launch_runs_bg.running"]

    open_project $project_file


    set synth_strategies [lreplace [list_property_value strategy [get_runs synth_1]] 0 0]
    set synth_flow [get_property flow [get_runs synth_1]]
    set impl_strategies  [lreplace [list_property_value strategy [get_runs impl_1]] 0 0]
    set impl_flow [get_property flow [get_runs impl_1]]

    set current_runs [get_runs]

    set synth_to_impl_dict [dict create]

    foreach synth_strat $synth_strategies {
      set synth_name "SYNTH_${synth_strat}"
      lappend synth_run_list $synth_name

      set synth_impl_list {}

      if { [IsInList $synth_name $current_runs] == 0 } {
        Msg Info "Creating synthesis run: $synth_name with strategy: $synth_strat"
        create_run $synth_name -flow $synth_flow -strategy $synth_strat -quiet
      }

      foreach impl_strat $impl_strategies {
        set impl_name "${synth_strat}_${impl_strat}"
        lappend impl_run_list $impl_name
        lappend synth_impl_list $impl_name
        if { [IsInList $impl_name $current_runs] == 0 } {
          create_run $impl_name -parent_run $synth_name -flow $impl_flow -strategy $impl_strat -quiet
        }
      }

      #RQS:
      #set rqs_name "${synth_strat}_RQS"
      #lappend impl_run_list $rqs_name
      #lappend synth_impl_list $rqs_name
      #if { [llength [get_runs $rqs_name]] == 0 } {
      #  create_run $rqs_name -parent_run $synth_name -flow {Vivado RQS Implementation 2023}
      #}

      dict set synth_to_impl_dict $synth_name $synth_impl_list
    }

    set all_runs $synth_run_list

    set max_impl_per_synth 0
    dict for {synth_name impl_list} $synth_to_impl_dict {
      set len [llength $impl_list]
      if {$len > $max_impl_per_synth} { set max_impl_per_synth $len }
    }

    for {set i 0} {$i < $max_impl_per_synth} {incr i} {
      foreach synth_name $synth_run_list {
        set impl_list [dict get $synth_to_impl_dict $synth_name]
        if {$i < [llength $impl_list]} {
          lappend all_runs [lindex $impl_list $i]
        }
      }
    }

    # ------------------------------------------------------------
    # Launch runs in background, wait until they start
    # ------------------------------------------------------------
    if { $run_flag } {
      launch_needed_runs $all_runs $force_flag $jobs $project_dir $project_file $run_file $timeout_min $keep_going
      close_project
      Msg Info "Waiting for background launch to start..."

      while {1} {
        if {[file exists $run_file]} {
          Msg Info "Background launch started successfully."
          break
        }

        after 1000
      }
      if {$monitor_flag} {
        open_project $project_file
      }
    }

    # ------------------------------------------------------------
    # Monitoring runs and display status
    # ------------------------------------------------------------
    if {$monitor_flag} {
      if {![file exists $run_file]} {
        Msg Error "Could not detect timing closure run... exiting...  "
        return
      }

      source $run_file



      if {!$run_flag} {
        set jobs [determine_njobs $all_runs]
        if {$jobs == 0} {
          Msg Warning "No running jobs detected. Ensure runs are launched and running..."
          return;
        }
      }

      set total_runs [llength $all_runs]
      Msg Info "Monitoring $total_runs runs ($jobs active) for timing closure (timeout=${timeout_min}min)."

      set timing_passed 0
      set passed_run ""

      while {1} {
        show_run_status $all_runs $start_ms

        if {$timeout_min > 0} {
          set elapsed_ms [expr {[clock milliseconds] - $start_ms}]
          set timeout_ms [expr {$timeout_min * 60 * 1000}]
          if {$elapsed_ms > $timeout_ms} {
            Msg Warning "Timeout reached (${timeout_min}min) without timing closure."
            break
          }
        }

        if {!$timing_passed} {
          foreach impl_run $impl_run_list {
            if {[check_timing_closure $impl_run]} {
              set timing_passed 1
              set passed_run $impl_run

              set wns  [get_property STATS.WNS  [get_runs $impl_run]]
              set whs  [get_property STATS.WHS  [get_runs $impl_run]]
              set tpws [get_property STATS.TPWS [get_runs $impl_run]]
              Msg Info "Timing closure achieved in $impl_run (WNS=$wns, WHS=$whs, TPWS=$tpws)."

              if {!$keep_going} { break }
            }
          }
        }

        if {![file exists $run_file]} {
          break;
        }

        if {$timing_passed && !$keep_going} {
          break
        }
        if {$keep_going && [all_runs_complete $all_runs]} {
          Msg Info "All runs complete."
          break
        }

        after 1000
      }

      puts ""

      if {$timing_passed && $passed_run ne "" && !$keep_going} {
        set to_reset {}
        foreach impl_run $impl_run_list {
          if {$impl_run eq $passed_run} { continue }
          if {[get_run_status $impl_run] eq "QUEUED"} {
            catch { reset_run $impl_run}
          }
        }
      }
    }
  }
}
