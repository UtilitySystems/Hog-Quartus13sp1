#
#  data structure:
#  hier_meta {
#    all_modules {
#      module_key {
#        name {}
#        library {}
#        type {}
#        file_path {}
#        sub_modules {}  # list of module_keys
#        properties {}
#      }
#    }
#
#    proj_files {
#      file_path {
#        file_path {}
#        ext {}
#        library {}
#        properties {}
#      }
#    }
#  }


source $tcl_path/utils/verilog_module_extractor.tcl
source $tcl_path/utils/vhdl_module_extractor.tcl

proc _create_hier_meta {} {
  set hier_meta [dict create]
  dict set hier_meta all_modules {}
  dict set hier_meta proj_files {}
  return $hier_meta
}

proc is_known_library {hier_meta_ref lib_name} {
  upvar 1 $hier_meta_ref hier_meta
  return [dict exists $hier_meta libraries known_libs $lib_name]
}

proc is_ignored_module {module_key ignore_patterns} {
  foreach pattern $ignore_patterns {
    if {[string match $pattern $module_key]} {
      return 1
    }
  }
  return 0
}

proc _create_proj_file_info {file_path library properties} {
  set file_info [dict create]
  dict set file_info file_path $file_path
  dict set file_info library $library
  dict set file_info properties $properties
  dict set file_info ext [file extension $file_path]
  return $file_info
}

proc file_info_path {file_info} {
  return [dict get $file_info file_path]
}

proc file_info_library {file_info} {
  return [dict get $file_info library]
}

proc file_info_properties {file_info} {
  return [dict get $file_info properties]
}

proc file_info_ext {file_info} {
  return [dict get $file_info ext]
}

proc _store_module {hier_meta_ref mod_name mod_library mod_type file_path sub_modules_list props} {
  upvar 1 $hier_meta_ref hier_meta

  set key "${mod_library}.${mod_type}.${mod_name}"
  set mod [dict create]
  dict set mod name $mod_name
  dict set mod library $mod_library
  dict set mod type $mod_type
  dict set mod file_path $file_path
  dict set mod sub_modules $sub_modules_list
  dict set mod properties $props
  dict set mod color "white"

  dict set hier_meta all_modules $key $mod
}

proc _hier_parse_vhdl {hier_meta_ref file_info} {
  upvar 1 $hier_meta_ref hier_meta

  set f [file_info_path $file_info]
  #puts "Parsing VHDL file: $f"

  if {![file exists $f]} { return }

  set library [file_info_library $file_info]
  set file_properties [file_info_properties $file_info]

  # Determine VHDL year from file properties
  set knownYears {87 93 2008 2019}
  set year 2008
  foreach y $knownYears {
    if {[lsearch -exact $file_properties $y] != -1} {
      set year $y
      break
    }
  }

  # Build module properties dict with filetype
  set mod_properties [dict create]
  dict set mod_properties filetype "VHDL$year"


  set extracted_vhdl_info [extract_vhdl_module_info $f $library]
  # Add all extracted VHDL modules to all_modules
  dict for {package_name package_data} [dict get $extracted_vhdl_info packages] {
    dict set package_data properties $mod_properties
    dict set hier_meta all_modules $package_name $package_data
  }

  dict for {package_body_name package_body_data} [dict get $extracted_vhdl_info packages_bodies] {
    dict set package_body_data properties $mod_properties
    dict set hier_meta all_modules $package_body_name $package_body_data
  }

  dict for {entity_name entity_data} [dict get $extracted_vhdl_info entities] {
    dict set entity_data properties $mod_properties
    dict set hier_meta all_modules $entity_name $entity_data
  }

  dict for {arch_name arch_data} [dict get $extracted_vhdl_info architectures] {
    dict set arch_data properties $mod_properties
    dict set hier_meta all_modules $arch_name $arch_data
  }

}

proc _hier_parse_verilog {hier_meta_ref file_info} {
  upvar 1 $hier_meta_ref hier_meta

  set f [file_info_path $file_info]
  #puts "Parsing Verilog file: $f"

  if {![file exists $f]} { return }

  set library [file_info_library $file_info]
  set file_properties [file_info_properties $file_info]

  set ext [string tolower [file extension $f]]
  set is_sv 0
  if {$ext eq ".sv" || [lsearch -exact $file_properties "SystemVerilog"] != -1} {
    set is_sv 1
  }

  # Build module properties dict with filetype
  set mod_properties [dict create]
  if {$is_sv} {
    dict set mod_properties filetype "SystemVerilog"
  } else {
    dict set mod_properties filetype "Verilog"
  }

  set submodules [extract_verilog_module_info $f]

  dict for {module sm_list} $submodules {
    set all_subs [list]
    foreach sm $sm_list {
      # not sure if we can extract library info from verilog instantiations?
      lappend all_subs "unknown.component.${sm}"
    }

    set all_subs [lsort -unique $all_subs]
    _store_module hier_meta $module $library component $f $all_subs $mod_properties
  }


}

proc _hier_parse_ip {hier_meta_ref file_info} {
  upvar 1 $hier_meta_ref hier_meta

  set f [file_info_path $file_info]
  #puts "Parsing IP file: $f"

  if {![file exists $f]} { return }

  set library [file_info_library $file_info]

  # Extract IP name from filename (remove .xci extension)
  set name [file rootname [file tail $f]]

  # Build module properties dict
  set mod_properties [dict create]
  dict set mod_properties filetype "XCI"

  set all_subs [list]

  _store_module hier_meta $name $library component $f $all_subs $mod_properties
}


proc _hier_parse_file {hier_meta_ref file_info} {
  upvar 1 $hier_meta_ref hier_meta

  if {[file_info_ext $file_info] eq ".vhd"} {
    _hier_parse_vhdl hier_meta $file_info
  } elseif {[file_info_ext $file_info] eq ".v"} {
    _hier_parse_verilog hier_meta $file_info
  } elseif {[file_info_ext $file_info] eq ".xci"} {
    _hier_parse_ip hier_meta $file_info
  } elseif {[file_info_ext $file_info] eq ".bd"} {
    _hier_parse_bd hier_meta $file_info
  } else {
    puts "Warning: unrecognized file type for [file_info_path $file_info]"
  }


}

proc _hier_submodule_append {hier_meta_ref parent_key sub_key} {
  upvar 1 $hier_meta_ref hier_meta

  if {[dict exists $hier_meta all_modules $parent_key]} {
    set mod [dict get $hier_meta all_modules $parent_key]
    dict lappend mod sub_modules $sub_key
    dict set hier_meta all_modules $parent_key $mod
  }
}


# Attempts to match unknown sub module references to known modules
proc _reference_resolver {hier_meta_ref} {
  upvar 1 $hier_meta_ref hier_meta


  dict for {package_body body_info} [dict filter [dict get $hier_meta all_modules] key "*.package_body.*"] {
    #puts "Resolving references in package body: $package_body"
    set entity_key [split $package_body "."]
    set entity_key "[lindex $entity_key 0].package.[lindex $entity_key 2]"
    if {[dict exists [dict get $hier_meta all_modules] $entity_key]} {
      _hier_submodule_append hier_meta $entity_key $package_body
      continue
    }
  }

  dict for {architecture arch_info} [dict filter [dict get $hier_meta all_modules] key "*.architecture.*"] {
    #puts "Resolving references in package arch: $architecture"
    set entity_key [split $architecture "."]
    set entity_key "[lindex $entity_key 0].package.[lindex $entity_key 2]"
    if {[dict exists [dict get $hier_meta all_modules] $entity_key]} {
      _hier_submodule_append hier_meta $entity_key $architecture
      continue
    }
  }


  #puts "hier_meta before resolution: $hier_meta"

  set cache_map [dict create]
  set total_resolved 0
  set resolution_list [list]

  dict for {mod_key mod} [dict get $hier_meta all_modules] {
    set sub_modules [dict get $mod sub_modules]
    set new_sub_modules [list]

    #puts "Resolving submodules for $mod_key: $sub_modules"
    foreach sub_key $sub_modules {
      set parts [split $sub_key "."]
      set type [lindex $parts 1]
      set name [lindex $parts 2]
      set type_name "$type.$name"

      set found 0
      set resolved_mod_name ""

      # If mapping exists in cache, use it
      if {[dict exists $cache_map $sub_key]} {
        set resolved_mod_name [dict get $cache_map $sub_key]
        #puts "Resovled $sub_key -> $resolved_mod_name (cached)"
        lappend new_sub_modules $resolved_mod_name
        continue
      }

      foreach mod_name [dict keys [dict get $hier_meta all_modules]] {
        set mod_name_parts [split $mod_name "."]
        if {[string match $type_name "[lindex $mod_name_parts 1].[lindex $mod_name_parts 2]"]} {
          set resolved_mod_name $mod_name
          incr found 1
        }
      }

      if {$found == 0} {
        # Keep as unknown
        #puts "$mod_key: Unresolved mod: $sub_key"
        lappend new_sub_modules $sub_key
      } elseif {$found > 1} {
        puts "Warning: multiple matches found for $sub_key (type.name: $type_name). Keeping as unknown."
        # maybe we should see if one is in the same library as parent and use that one?

        lappend new_sub_modules $sub_key
      } else {
        # Resolved successfully
        #puts "Resolved $sub_key -> $resolved_mod_name"
        lappend new_sub_modules $resolved_mod_name
        dict set cache_map $sub_key $resolved_mod_name
        lappend resolution_list [dict create from $sub_key to $resolved_mod_name in_module $mod_key]
        incr total_resolved
      }
    }

    # Update module with resolved submodules
    dict set hier_meta all_modules $mod_key sub_modules $new_sub_modules
  }

  return [dict create total $total_resolved resolutions $resolution_list]
}

proc dfs_sort {hier_meta_ref top_module} {
  upvar 1 $hier_meta_ref hier_meta

  proc _dfs_visit {hier_meta_ref node sorted_ref bad_nodes_ref} {
    upvar 1 $hier_meta_ref hier_meta
    upvar 1 $sorted_ref sorted
    upvar 1 $bad_nodes_ref bad_nodes

    if {![dict exists $hier_meta all_modules $node]} {
      return
    }

    set mod [dict get $hier_meta all_modules $node]
    set color [dict get $mod color]

    if {$color eq "gray"} {
      # cycle detected
      puts "ERROR: Circular dependency detected at $node"
      if {[lsearch -exact $bad_nodes $node] == -1} {
        lappend bad_nodes $node
      }
      return
    }

    if {$color eq "black"} {
      return
    }

    # update node
    dict set mod color "gray"
    dict set hier_meta all_modules $node $mod

    set sub_modules [dict get $mod sub_modules]
    foreach child $sub_modules {
      _dfs_visit hier_meta $child sorted bad_nodes
    }

    # done processing children, mark black and add to sorted list
    set mod [dict get $hier_meta all_modules $node]
    dict set mod color "black"
    dict set hier_meta all_modules $node $mod
    lappend sorted $node
  }


  set sorted [list]
  set bad_nodes [list]

  _dfs_visit hier_meta $top_module sorted bad_nodes

  if {[llength $bad_nodes] > 0} {
    return [dict create success 0 sorted {} cycles 1 bad_nodes $bad_nodes]
  }

  return [dict create success 1 sorted $sorted cycles 0 bad_nodes {}]
}


proc _debug_print_hier_meta {hier_meta_ref {indent 0}} {
  upvar 1 $hier_meta_ref hier_meta

  set ind [string repeat "  " $indent]

  puts "${ind}=== ALL MODULES ==="
  dict for {key mod} [dict get $hier_meta all_modules] {
    puts "${ind}$key:"
    dict for {field value} $mod {
      puts "${ind}  $field: $value"
    }
    puts ""
  }

  puts "${ind}=== PROJECT FILES ==="
  dict for {file finfo} [dict get $hier_meta proj_files] {
    puts "${ind}$file:"
    dict for {field value} $finfo {
      puts "${ind}  $field: $value"
    }
    puts ""
  }
}



proc Hierarchy {listProperties listLibraries repo_path {output_path ""} {compile_order 0} {light ""} {top_module_override ""} {ignore_opt_list ""}} {
  set hier_meta [_create_hier_meta]

  set top_module ""

  set ignore_list [list]
  foreach pat [split $ignore_opt_list ","] {
    set pat [string trim $pat]
    if {$pat ne ""} {
      if {![regexp {^[\w*]+\.[\w*]+\.[\w*]+$} $pat]} {
        puts "Warning: ignore pattern '$pat' does not match expected format <lib>.<type>.<name> (wildcards * allowed), ignoring"
      } else {
        lappend ignore_list $pat
      }
    }
  }

  # If user specified top module, use that
  if {$top_module_override ne ""} {
    set top_module $top_module_override
    puts "Using specified top module: $top_module"
  }

  # Populate hier_meta.proj_files with per-file metadata
  dict for {lib files} $listLibraries {
    set lib [file rootname $lib]

    foreach f $files {
      set props ""
      if {[dict exists $listProperties $f]} {

        set fprops [dict get $listProperties $f]
        # Only extract from properties if not already specified
        if {$top_module eq ""} {
          set top [lindex [regexp -inline {\ytop\s*=\s*(.+?)\y.*} $fprops] 1]
          if {$top != ""} {
            set top_module "${lib}.component.${top}"
          }
        }

        set props $fprops
      }
      dict set hier_meta proj_files $f [_create_proj_file_info $f $lib $props]
    }
  }

  if {$top_module_override eq ""} {
    puts "Top module from properties: $top_module"
  }
  dict for {file file_info} [dict get $hier_meta proj_files] {
    _hier_parse_file hier_meta $file_info
  }

  puts "Completed initial parsing "
  #puts "[_debug_print_hier_meta hier_meta]"

  set resolve_result [_reference_resolver hier_meta]
  set total [dict get $resolve_result total]
  set resolutions [dict get $resolve_result resolutions]
  puts "Completed reference resolution: $total references resolved"


  if {$output_path != ""} {
    set output_file [open $repo_path/$output_path "w"]
  } else {
    set output_file ""
  }


  set sorted_modules [dfs_sort hier_meta $top_module]
  set bad_nodes [dict get $sorted_modules bad_nodes]

  if {$compile_order} {
    print_compile_order hier_meta [dict get $sorted_modules sorted] $output_file
  } else {
    print_hierarchy hier_meta $top_module $output_file $ignore_list $bad_nodes $light
  }

  if {$output_path != ""} {
    close $output_file
  }
}

proc print_compile_order {hier_meta_ref sorted_list {output_file ""}} {
  upvar 1 $hier_meta_ref hier_meta

  set groups [list]
  set curr_file_type ""
  set curr_files [list]

  foreach mod_key $sorted_list {
    set mod [dict get $hier_meta all_modules $mod_key]
    set file_path [dict get $mod file_path]
    set props [dict get $mod properties]
    set file_type [dict get $props filetype]

    if {$file_type ne $curr_file_type} {
      if {$curr_file_type ne ""} {
        lappend groups [list $curr_file_type $curr_files]
      }
      set curr_file_type $file_type
      set curr_files [list $file_path]
    } else {
      lappend curr_files $file_path
    }
  }

  if {$curr_file_type ne ""} {
    lappend groups [list $curr_file_type $curr_files]
  }

  foreach group $groups {
    set type [lindex $group 0]
    set files [lindex $group 1]
    set output_line "$type \{$files\}"

    if {$output_file ne ""} {
      puts $output_file $output_line
    } else {
      puts $output_line
    }
  }
}

proc print_hierarchy {hier_meta_ref module {output_file ""} {ignore_list ""} \
{bad_nodes ""} {light 0} {indent 0} {stack_ref ""} {last_properties_ref ""} {is_last 1}} {
  upvar 1 $hier_meta_ref hier_meta

  # Check if this module should be ignored
  if {[is_ignored_module $module $ignore_list]} {
    return
  }

  # Initialize stack and last_properties on first call
  if {$stack_ref eq ""} {
    set stack [list]
    set last_properties [list]
  } else {
    upvar 1 $stack_ref stack
    upvar 1 $last_properties_ref last_properties
  }

  # Check if module exists
  if {![dict exists $hier_meta all_modules $module]} {
    set parts [split $module "."]
    set lib [lindex $parts 0]
    set type [lindex $parts 1]
    set name [lindex $parts 2]
    set file_path ""
    set module_exists 0
  } else {
    set mod [dict get $hier_meta all_modules $module]
    set name [dict get $mod name]
    set type [dict get $mod type]
    set lib [dict get $mod library]
    set file_path [dict get $mod file_path]
    set module_exists 1
  }

  # Check if we have a circular dependency
  set is_circular 0
  if {[lsearch -exact $stack $module] != -1} {
    # if it's in bad nodes then yeah it actually is a circular dependency,
    # otherwise it just means parent node probably also references it
    if {[lsearch -exact $bad_nodes $module] != -1} {
      set is_circular 1
    }
  }

  if {!$is_circular} {
    lappend stack $module
  }

  # Build indent string
  set indent_str ""
  for {set i 0} {$i < [llength $last_properties]} {incr i} {
      if {[lindex $last_properties $i]} {
          append indent_str "     "
      } else {
          append indent_str "│    "
      }
  }

  # Choose connector symbols
  if {$indent > 0} {
      if {$is_last} {
          set connector "└── "
      } else {
          set connector "├── "
      }
  } else {
      set connector ""
  }

  # Determine file path display based on light mode
  if {$light} {
    set path_str ""
  } else {
    set path_str " - ${file_path}"
  }

  # Build message based on whether module exists
  if {!$module_exists} {
    set msg "${indent_str}${connector}${name} (${lib}.${type})"
  } elseif {$is_circular} {
    set msg "${indent_str}${connector}${name} (${lib}.${type})${path_str} \[WARNING: circular reference detected\]"
  } else {
    set msg "${indent_str}${connector}${name} (${lib}.${type})${path_str}"
  }

  if {$output_file ne ""} {
    puts $output_file $msg
  } else {
    puts $msg
  }

  if {$is_circular || !$module_exists} {
    return
  }

  # Get submodules
  set sub_modules [dict get $mod sub_modules]
  set all_subs [lsort -unique $sub_modules]

  # Recursively print submodules
  set num_subs [llength $all_subs]
  set sub_idx 0
  foreach sub $all_subs {
    incr sub_idx
    set is_last_child [expr {$sub_idx == $num_subs}]

    # Update last_properties for this child
    lappend last_properties $is_last
    print_hierarchy hier_meta $sub $output_file $ignore_list $bad_nodes $light [expr {$indent + 1}] stack last_properties $is_last_child
    set last_properties [lrange $last_properties 0 end-1]
  }

  # Pop from stack after processing all children
  set stack [lrange $stack 0 end-1]
}



proc get_rtl_refs {node {name ""}} {
  set out [dict create]

  # If current node represents a named component and has HDL reference_info, record it
  if {$name ne "" && ![catch {dict get $node reference_info} refinfo]} {
    set rt ""; set rn ""
    catch {set rt [dict get $refinfo ref_type]}
    catch {set rn [dict get $refinfo ref_name]}
    if {[string equal $rt "hdl"] && $rn ne ""} {
      dict set out $name $rn
    }
  }

  # check 'components' dict
  if {![catch {dict get $node components} comps]} {
    dict for {cname cnode} $comps {
      set childMap [get_rtl_refs $cnode $cname]
      set out [dict merge $out $childMap]
    }
  }

  # Also scan other dict-valued children for embedded components
  dict for {k v} $node {
    if {$k eq "components" || $k eq "reference_info"} {continue}
    if {[catch {dict size $v}]} {continue}
    set childMap [get_rtl_refs $v $k]
    set out [dict merge $out $childMap]
  }

  return $out
}

proc _hier_parse_bd {hier_meta_ref file_info} {
  upvar 1 $hier_meta_ref hier_meta

  set f [file_info_path $file_info]
  #puts "Parsing block design file: $f"

  if {![file exists $f]} { return }

  set library [file_info_library $file_info]
  set file_properties [file_info_properties $file_info]

  # Module name is the filename without extension
  set name [file rootname [file tail $f]]
  set mod_properties [dict create]
  dict set mod_properties filetype "BD"

  set bd_file [open $f r]
  set bd_json [read $bd_file]
  close $bd_file
  set bd_design $bd_json

  # Realllly hacky way to convert the bd json into a tcl dict
  set lines [split $bd_design "\n"]
  set filtered_lines {}
  foreach line $lines {
    if {[string first "\\" $line] == -1} {
      lappend filtered_lines $line
    }
  }
  set bd_design [join $filtered_lines "\n"]

  regsub -all {":\s*\{} $bd_design " \{" bd_design
  regsub -all {:\s*("(?:[^"\\]|\\.)*")} $bd_design { {\1}} bd_design
  regsub -all {"} $bd_design {} bd_design
  regsub -all {,} $bd_design {} bd_design
  regsub -all {:\s* \{} $bd_design {\{} bd_design
  regsub -all {\[} $bd_design "\{" bd_design
  regsub -all {\]} $bd_design "\}" bd_design

  set bd_design [string range $bd_design 1 end-1]





  # Validate dict
  if {[catch {dict size $bd_design} err]} {
    puts "Warning: malformed bd_design in $f, skipping"
    puts $err
    return {}
  }

  set bd_design [lindex $bd_design 1]

  #puts "Modules found in $f:"
  #dict for {m v} [get_rtl_refs $bd_design] {
  #  puts "$m -> $v"
  #}

  #let's extract only unique values from get_rtl_refs
  set unknown_modules {}
  dict for {m v} [get_rtl_refs $bd_design] {
    if {[lsearch -exact $unknown_modules $v] == -1} {
      lappend unknown_modules "unknown.component.$v"
    }
  }
  _store_module hier_meta $name $library component $f $unknown_modules $mod_properties

}
