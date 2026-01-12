#
#  data structure:
#  hier_meta {
#    all_modules { 
#      lib.type.name { 
#        name {}  
#        library {}  
#        type {}  
#        file_path {}  
#        sub_modules {}  
#        properities {}  
#      }
#    }
#    libraries {
#      unknown_libs {
#        lib_name {
#          module {...}
#        }
#      }
#      known_libs {
#        lib_name {
#          module {...}
#        }
#      }
#    }
#
#    proj_files {
#      file_path {
#        file_path {}
#        ext {}
#        library {}
#        properties {)
#      }
#    }
#  }


proc _create_hier_meta {} {
  set hier_meta [dict create] 
  dict set hier_meta all_modules {}
  dict set hier_meta libraries [dict create unknown_libs {} known_libs {}] 
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

proc _store_module {hier_meta_ref mod_name mod_library mod_type file_path known_subs unknown_subs props} {
  upvar 1 $hier_meta_ref hier_meta
  
  set key "${mod_library}.${mod_type}.${mod_name}"
  set mod [dict create]
  dict set mod name $mod_name
  dict set mod library $mod_library
  dict set mod type $mod_type
  dict set mod file_path $file_path
  dict set mod known_lib_modules $known_subs
  dict set mod unknown_lib_modules $unknown_subs
  dict set mod properties $props
  
  dict set hier_meta all_modules $key $mod
  
  if {[dict exists $hier_meta libraries known_libs $mod_library]} {
    dict set hier_meta libraries known_libs $mod_library $key $mod
  } else {
    dict set hier_meta libraries unknown_libs $mod_library $key $mod
  }
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

  set fh [open $f r]
  set txt [read $fh]
  close $fh

  regsub -all {\-\-[^\n\r]*} $txt "" txt
  regsub -all {[\n\r]+} $txt " " txt
  set txt [string tolower $txt]

  set known_packages [list]
  set unknown_packages [list]

  # Parse library usage
  foreach {im ulib upkg} [regexp -all -inline -nocase {use\s+(\w+)\s*\.\s*(\w+)\s*\.\s*all} $txt] {
    if {[is_known_library hier_meta $ulib] || [string tolower $ulib] eq "ieee" || [string tolower $ulib] eq "std"} {
      lappend known_packages "${ulib}.package.${upkg}"
    } else {
      lappend unknown_packages "${ulib}.package.${upkg}"
    }
  }

  # Parse entities
  foreach {full name} [regexp -inline -all -nocase {entity\s+(\w+)\s+is} $txt] {
    set known_subs [list]
    set unknown_subs [list]

    # Find the architecture for this entity
    set arch_start_pattern "architecture\\s+(\\w+)\\s+of\\s+${name}\\s+is"
    if {[regexp -nocase -indices $arch_start_pattern $txt match arch_name_match]} {
      set arch_start_idx [lindex $match 1]
      set arch_name [string range $txt [lindex $arch_name_match 0] [lindex $arch_name_match 1]]
      
      # Find end of architecture
      set arch_end_pattern "end\\s+${arch_name}\\s*;"
      if {[regexp -nocase -indices -start $arch_start_idx $arch_end_pattern $txt end_match]} {
        set arch_end_idx [lindex $end_match 0]
        
        # Extract architecture body
        set arch_body [string range $txt $arch_start_idx $arch_end_idx]
        #puts "Found architecture $arch_name for entity $name"
        
        # Entity instantiations:
        foreach {full inst ilib iname} [regexp -all -inline {(\w+)\s*:\s*entity\s+(\w+)\s*\.\s*(\w+)\s+port\s+map} $arch_body] {
          if {[is_known_library hier_meta $ilib]} {
            lappend known_subs "${ilib}.component.${iname}"
          } else {
            lappend unknown_subs "${ilib}.component.${iname}"
          }
        }
        
        # Component declarations: 
        set components [list]
        foreach {full comp} [regexp -all -inline {component\s+(\w+)\s+(?:is|port)} $arch_body] {
          lappend components $comp
        }
        
        # Component instantiations:
        foreach comp $components {
          foreach {full inst} [regexp -all -inline [format {(\w+)\s*:\s*(?:component\s+)?%s\s+port\s+map} $comp] $arch_body] {
            lappend unknown_subs "unknown.component.${comp}"
          }
        }
      } else {
        puts "Warning: Found architecture start but no end for entity $name"
      }
    } else {
      puts "Warning: No architecture found for entity $name"
    }

    #puts "Entity $name: known_subs=$known_subs, unknown_subs=$unknown_subs"
    #puts "Entity $name: known_packages=$known_packages, unknown_packages=$unknown_packages"
    set known_subs [concat $known_subs $known_packages]
    set unknown_subs [concat $unknown_subs $unknown_packages]
    set known_subs [lsort -unique $known_subs]
    set unknown_subs [lsort -unique $unknown_subs]
    _store_module hier_meta $name $library component $f $known_subs $unknown_subs $mod_properties
  }

  # Parse packages
  foreach {full name} [regexp -inline -all -nocase {package\s+(\w+)\s+is} $txt] {
    set known_subs $known_packages
    set unknown_subs $unknown_packages
    _store_module hier_meta $name $library package $f $known_subs {} $mod_properties
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

  set fh [open $f r]
  set txt [read $fh]
  close $fh

  # Find module declarations
  foreach {full name} [regexp -all -inline -line {^(?!\s*//)\s*module\s+(\w+)} $txt] {
    set unknown_subs [list]

    # Find module instantiations
    set inst_pattern {^\s*(\w+)\s*(?:#\s*\([^;]*\))?\s+(\w+)\s*\(}
    foreach {full mod_type inst_name} [regexp -all -inline -line $inst_pattern $txt] {
      # Filter out Verilog/SystemVerilog keywords
      set keywords {if for while begin end module endmodule input output inout wire reg logic parameter localparam function task case casex casez generate initial always always_comb always_ff always_latch}
      if {[lsearch -exact $keywords [string tolower $mod_type]] == -1 && [lsearch -exact $keywords [string tolower $inst_name]] == -1} {
        lappend unknown_subs "unknown.component.${mod_type}"
      }
    }
    
    set unknown_subs [lsort -unique $unknown_subs]
    _store_module hier_meta $name $library component $f {} $unknown_subs $mod_properties
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
  
  set known_subs [list]
  set unknown_subs [list]
  
  _store_module hier_meta $name $library component $f $known_subs $unknown_subs $mod_properties
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


# Attempts to match unknown sub module references to known modules
proc _reference_resolver {hier_meta_ref} {
  upvar 1 $hier_meta_ref hier_meta

  set cache_map [dict create]
  set total_resolved 0
  set resolution_list [list]

  dict for {mod_key mod} [dict get $hier_meta all_modules] {
    set unknown_subs [dict get $mod unknown_lib_modules]
    set resolved_subs [list]
    set unresolved_subs [list]
    
    foreach unknown_sub $unknown_subs {
      set parts [split $unknown_sub "."]
      set type [lindex $parts 1]
      set name [lindex $parts 2]
      set type_name "$type.$name"

      set found 0
      set resolved_mod_name ""

      # If mapping exists in cache, use it
      if {[dict exists $cache_map $unknown_sub]} {
        #puts "found in cache: $unknown_sub -> [dict get $cache_map $unknown_sub]"
        set resolved_mod_name [dict get $cache_map $unknown_sub]
        lappend resolved_subs $resolved_mod_name
        continue
      } 

      foreach mod_name [dict keys [dict get $hier_meta all_modules]] {
        #puts "Checking $type_name against $mod_name"
        set mod_name_parts [split $mod_name "."]

        if {[string match $type_name "[lindex $mod_name_parts 1].[lindex $mod_name_parts 2]"]} {
          set resolved_mod_name $mod_name
          incr found 1
        }
      }


      if {$found == 0} {
        #puts "Warning: no matches found for $unknown_sub (type.name: $type_name). Keeping as unknown."
        lappend unresolved_subs $unknown_sub
      } elseif {$found > 1} {
        puts "Warning: multiple matches found for $unknown_sub (type.name: $type_name). Keeping as unknown."
        lappend unresolved_subs $unknown_sub
      } else {
        lappend resolved_subs $resolved_mod_name
        dict set cache_map $unknown_sub $resolved_mod_name
        lappend resolution_list [dict create from $unknown_sub to $resolved_mod_name in_module $mod_key]
        incr total_resolved
        #puts "Resolved $unknown_sub to $resolved_mod_name"
      }
    }
    
    # Update module with resolved submodules
    if {[llength $resolved_subs] > 0} {
      set known_subs [dict get $mod known_lib_modules]
      set all_subs [concat $known_subs $resolved_subs]
      set all_subs [lsort -unique $all_subs]
      dict set hier_meta all_modules $mod_key known_lib_modules $all_subs
      dict set hier_meta all_modules $mod_key unknown_lib_modules $unresolved_subs
    }
  }
  
  return [dict create total $total_resolved resolutions $resolution_list]
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
  
  puts "${ind}=== KNOWN LIBRARIES ==="
  dict for {lib modules} [dict get $hier_meta libraries known_libs] {
    puts "${ind}$lib: $modules"
  }
  puts ""
  
  puts "${ind}=== UNKNOWN LIBRARIES ==="
  dict for {lib modules} [dict get $hier_meta libraries unknown_libs] {
    puts "${ind}$lib: $modules"
  }
  puts ""
  
  puts "${ind}=== PROJECT FILES ==="
  dict for {file finfo} [dict get $hier_meta proj_files] {
    puts "${ind}$file:"
    dict for {field value} $finfo {
      puts "${ind}  $field: $value"
    }
    puts ""
  }
}



proc Hierarchy {listProperties listLibraries repo_path {output_path ""} {light ""} {top_module_override ""} {ignore_opt_list ""}} {
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
    dict set hier_meta libraries known_libs $lib {}

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
  #if {$total > 0} {
  #  foreach res $resolutions {
  #    set from [dict get $res from]
  #    set to [dict get $res to]
  #    set in_mod [dict get $res in_module]
  #    puts "  $from -> $to (first resolved in $in_mod)"
  #  }
  #}
  #puts "[_debug_print_hier_meta hier_meta]"

  if {$output_path != ""} {
    set output_file [open $repo_path/$output_path "w"]
  } else {
    set output_file ""
  }


  print_hierarchy hier_meta $top_module $output_file $ignore_list $light


#  print_hierarchy $topmodule $topdeps $toppath $deps $mods $repo_path $output_file

  if {$output_path != ""} {
    close $output_file
  }
}

proc print_hierarchy {hier_meta_ref module {output_file ""} {ignore_list ""} {light 0} {indent 0} {stack_ref ""} {last_properties_ref ""} {is_last 1}} {
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
    set is_circular 1
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
  set known_subs [dict get $mod known_lib_modules]
  set unknown_subs [dict get $mod unknown_lib_modules]
  set all_subs [concat $known_subs $unknown_subs]
  set all_subs [lsort -unique $all_subs]
  
  # Recursively print submodules
  set num_subs [llength $all_subs]
  set sub_idx 0
  foreach sub $all_subs {
    incr sub_idx
    set is_last_child [expr {$sub_idx == $num_subs}]
    
    # Update last_properties for this child
    lappend last_properties $is_last
    print_hierarchy hier_meta $sub $output_file $ignore_list $light [expr {$indent + 1}] stack last_properties $is_last_child
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
  _store_module hier_meta $name $library component $f "" $unknown_modules $mod_properties

}
