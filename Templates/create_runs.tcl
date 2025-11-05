set ::hog_command {
  NAME  {create_runs}

  DESCRIPTION "Create synthesis and implementation runs for all strategies in the current project."
  
  IDE "vivado 2023.2"

  CUSTOM_OPTIONS {
    {proj.arg "" "if set, open project with this name before creating runs."}
    {run         "if set, run the created implementation runs after creation."}
  }
  script {
    set impl_run_list {}
    

    set project_name [dict get $list_of_options proj]
    set run_flag     [dict get $list_of_options run]
    set jobs         [dict get $list_of_options njobs]

    Msg Info "Creating runs for project: '$project_name' with run flag: '$run_flag' and jobs: $jobs"



    if { $project_name ne "" } {
      set project_path "../Projects/$project_name/$project_name.xpr"
      set project_path [file normalize $project_path]
      if { ![file exists $project_path] } {
        Msg Error "WARNING: Project '$project_name' does not exist at expected path '$project_path'. (Create/open it before run creation if required.)"
        return
      }
    }

    open_project $project_path


    set synth_strategies [lreplace [list_property_value strategy [get_runs synth_1]] 0 0]
    set impl_strategies  [lreplace [list_property_value strategy [get_runs impl_1]] 0 0]

    set current_runs [get_runs]

    foreach synth_strat $synth_strategies {
      set synth_name "SYNTH_${synth_strat}"
      if { [IsInList $synth_name $current_runs] == 0 } {
        Msg Info "Creating synthesis run: $synth_name with strategy: $synth_strat"
        create_run $synth_name -flow {Vivado Synthesis 2023} -strategy $synth_strat -quiet
      }

      foreach impl_strat $impl_strategies {
        set impl_name "${synth_strat}_${impl_strat}"
        if { [IsInList $impl_name $current_runs] == 0 } {
          create_run $impl_name -parent_run $synth_name -flow {Vivado Implementation 2023} -strategy $impl_strat -quiet
        }
        if { [lsearch -exact $impl_run_list $impl_name] < 0 } {
          lappend impl_run_list $impl_name
        }
      }
      # RQS run per synth strategy
      set rqs_name "${synth_strat}_RQS"
      if { [llength [get_runs $rqs_name]] == 0 } {
        create_run $rqs_name -parent_run $synth_name -flow {Vivado RQS Implementation 2023}
      }
      if { [lsearch -exact $impl_run_list $rqs_name] < 0 } {
        lappend impl_run_list $rqs_name
      }
    }

    if { $run_flag } {
      Msg Info "Launching implementation runs: $impl_run_list with $jobs parallel jobs."
      launch_runs $impl_run_list -jobs $jobs
    }
  }
}