
# This is a starting point for a more robust verilog module extractor, expect lots of unhandled edge cases

proc isAlphanumeric {char} {
  return [regexp {^[a-zA-Z0-9_]$} $char]
}

proc is_verilog_keyword {token} {
  set protected_verilog_keywords {
  always and assign automatic begin buf bufif0 bufif1 case casex
  casez cell cmos config deassign default defparam design disable edge
  else end endcase endconfig endfunction endgenerate endmodule endprimitive endspecify endtable
  endtask event for force forever fork function generate genvar highz0
  highz1 if ifnone incdir include initial inout input instance integer
  join large liblist library localparam macromodule medium module nand negedge
  nmos nor noshowcancelled not notif0 notif1 or output parameter pmos
  posedge primitive pull0 pull1 pulldown pullup pulsestyle_onevent pulsestyle_ondetect rcmos real
  realtime reg release repeat rnmos rpmos rtran rtranif0 rtranif1 scalared
  showcancelled signed small specify specparam strong0 strong1 supply0 supply1 table
  task time tran tranif0 tranif1 tri tri0 tri1 triand trior
  trireg unsigned1 use uwire vectored wait wand weak0 weak1 while
  wire wor xnor xor
  }

  return [expr {[lsearch -exact $protected_verilog_keywords $token] != -1}]
}


proc tokenize_verilog {file_data} {
  set tokens {}
  set in_string 0

  set data [split $file_data ""]
  set length [llength $data]

  set i 0
  while {$i < $length} {

    set char [lindex $data $i]
    set token ""

    if {$char == "/"} {
      # COMMENTS
      if {$i + 1 < $length} {
        set next_char [lindex $data [expr {$i + 1}]]
        if {$next_char == "/"} {
          # SINGLE LINE COMMENT, skip until end of line
          while {$i < $length && [lindex $data $i] != "\n"} {
            set token "$token[lindex $data $i]"
            incr i 1
          }
        } elseif {$next_char == "*"} {
          # MULTI-LINE COMMENT, skip until closing */
          puts "Found multi-line comment at position $i"
          incr i 2
          while {$i < $length} {
          if {[lindex $data $i] == "*" && $i + 1 < $length && [lindex $data [expr {$i + 1}]] == "/"} {
            incr i 2
            break
          }
          incr i
          }
        } else {
          puts "Warning: Unrecognized comment start at position $i: /$next_char"
        }
        #puts "Finished skipping comment \[$token\], current position is $i"
      }
    } elseif {$char == "`"} {
      # preprocessor directive, read until end of line
      # probably want to handle inlcudes here in the future
      while {$i < $length && [lindex $data $i] != "\n"} {
        set token "$token[lindex $data $i]"
        incr i
      }
      #puts "Found preprocessor directive: $token"

    } elseif {[isAlphanumeric $char]} {
        set token $char
        while {$i + 1 < $length} {
          set char [lindex $data [expr {$i + 1}]]
          incr i

          if {![isAlphanumeric $char]} {
            break
          }

          set token "${token}${char}"
        }
        lappend tokens $token

    } elseif {$char == "\(" || $char == "\)" || $char == "\{" || $char == "\}" || $char == "\[" || $char == "\]" || $char == ";" || $char == ","} {
      lappend tokens $char
      incr i
    } else {
      incr i
    }

  }
  return $tokens
}



proc parse_verilog_module {tokens} {
  set module_info [dict create]
  set i 0
  set length [llength $tokens]
  set current_module ""
  set in_module 0

  while {$i < $length} {
    set token [lindex $tokens $i]
    #puts "Processing token: \{$token\}"

    if {$token == "module"} {
      # next token should be module name
      if {$i + 1 < $length} {
        set module_name [lindex $tokens [expr {$i + 1}]]
        #puts "Found module: $module_name"
        set current_module $module_name
        set in_module 1

        set submodules {}

        incr i 2
      }
    } elseif {$token == "endmodule"} {
      # end of current module
      #puts "End of module: $current_module"
      dict set module_info $current_module $submodules
      set in_module 0
      set current_module ""
      incr i

    } elseif {$in_module} {

      if {$token == "localparam" || $token == "parameter" || $token == "input" \
          || $token == "output" || $token == "inout" || $token == "wire" \
          || $token == "reg" || $token == "assign" } {
        set debug_temp_token $token
        while {$i < $length} {
          incr i
          set debug_temp_token "$debug_temp_token [lindex $tokens $i]"
          if {[lindex $tokens $i] == ";" || [lindex $tokens $i] == "," } {
            break
          }
        }
        #puts "Skipping declaration: $debug_temp_token"
        incr i
      } elseif {$token == "always"} {
        set depth 0
        while {$i < $length} {
          if {[lindex $tokens $i] == "begin"} {
            incr depth
          } elseif {[lindex $tokens $i] == "end"} {
            incr depth -1
            if {$depth <= 0} {
              break
            }
          }
          incr i
        }
        incr i
      } else {
        # check for module instantiation: <module_name> <instance_name> ( ... );
        if {$i + 2 < $length && ![is_verilog_keyword [lindex $tokens $i]] && ![is_verilog_keyword [lindex $tokens [expr {$i + 1}]]] && [lindex $tokens [expr {$i + 2}]] == "("} {
          set submodule_name [lindex $tokens $i]
          set instance_name [lindex $tokens [expr {$i + 1}]]
          #puts "Found submodule instantiation: module=$submodule_name instance=$instance_name"

          #append to current module's submodule list
          lappend submodules $submodule_name

          # skip until ;
          while {$i < $length && [lindex $tokens $i] != ";"} {
            incr i
          }
        }

        incr i
      }
    } else {
      # Not in a module, skip
      incr i
    }
  }

  return $module_info
}

proc extract_verilog_module_info {file_path} {
    set file_id [open $file_path r]
    set file_content [read $file_id]
    close $file_id

    # tokenize the file content
    set tokens [tokenize_verilog $file_content]


    # parse the tokens to extract module information
    set module_info [parse_verilog_module $tokens]
    #puts "Extracted module information: $module_info"
    return $module_info

}
