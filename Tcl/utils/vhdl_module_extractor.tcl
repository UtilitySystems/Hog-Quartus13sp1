

proc isAlphanumeric {char} {
  return [regexp {^[a-zA-Z0-9_]$} $char]
}

proc is_vhdl_keyword {token} {
  set protected_vhdl_keywords {
    abs access after alias all and architecture array assert attribute
    begin block body buffer bus
    case component configuration constant
    disconnect downto
    else elsif end entity exit
    file for function
    generate generic group guarded
    if impure in inertial inout is
    label library linkage literal loop
    map mod nand new next nor not null
    of on open or others out
    package port postponed procedure process pure
    range record register reject rem report return rol ror
    select severity signal shared sla sll sra srl subtype
    then to transport type
    unaffected units until use
    variable
    wait when while with
    xnor
  }

  return [expr {[lsearch -exact $protected_vhdl_keywords $token] != -1}]
}

# Create a VHDL module data structure
proc _create_vhdl_module {name library file_path sub_modules type} {
  return [ dict create name $name library $library file_path $file_path \
  sub_modules $sub_modules properties [dict create] type $type color "white"]
}


proc tokenize_vhdl {file_data} {
  set tokens {}
  set in_string 0

  set file_data [string tolower $file_data]
  set data [split $file_data ""]
  set length [llength $data]

  set i 0
  while {$i < $length} {

    set char [lindex $data $i]
    set token ""

    if {$char == "/"} {
      if {$i + 1 < $length} {
        set next_char [lindex $data [expr {$i + 1}]]
        if {$next_char == "*"} {
          # multi-line comment, skip until closing */
          # puts "Found multi-line comment at position $i"
          incr i 2
          while {$i < $length} {
          if {[lindex $data $i] == "*" && $i + 1 < $length && [lindex $data [expr {$i + 1}]] == "/"} {
            incr i 2
            break
          }
          incr i
          }
        } else {
          incr i
        }
      }
    } elseif {$char == "-"} {
        set next_char [lindex $data [expr {$i + 1}]]
        if {$next_char == "-"} {
          # single line comment, skip until end of line
          while {$i < $length && [lindex $data $i] != "\n"} {
            set token "$token[lindex $data $i]"
            incr i 1
          }
        }
        incr i

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
    } elseif {$char == "\""} {
      #ignore until matching "
      incr i
      set string_token ""
      while {$i < $length} {
        set char [lindex $data $i]
        if {$char == {\\}} {
          # skip escaped character
          incr i 2
          continue
        } elseif {$char == "\""} {
          incr i
          break
        }
        set string_token "${string_token}${char}"
        incr i
      }
      # puts "Found string literal: \"$string_token\""

    } elseif {$char == "\(" || $char == "\)" \
    || $char == "\{" || $char == "\}" \
    || $char == "\[" || $char == "\]" \
    || $char == ";" || $char == "," || $char == "." || $char == ":"} {
      lappend tokens $char
      incr i
    } else {
      incr i;
    }

  }
  return $tokens
}



proc parse_vhdl_module {library file_path tokens} {
  set i 0
  set length [llength $tokens]

  set packages [dict create]
  set packages_bodies [dict create]
  set entities [dict create]
  set architectures [dict create]

  set inc_packages {}
  set last_entity ""
  set prev_inc_packages {}


  while {$i < $length} {
    set token [lindex $tokens $i]
    # puts "Processing token: \{$token\}"

    if {$token == "use"} {
      set package_full_name {}

      # eat the use
      incr i

      while {$i + 1 < $length && [lindex $tokens $i] != ";"} {
        # puts "Processing token in package name: \{[lindex $tokens $i]\}"
        set package_full_name "${package_full_name}[lindex $tokens $i]"
        incr i
      }

      # puts "Full package name: $package_full_name"

      set package_full_ame [split $package_full_name "."]
      set package_name "[lindex $package_full_ame 0].package.[lindex $package_full_ame 1]"

      # puts "Found package usage: $package_name"
      lappend inc_packages $package_name


    } elseif {$token == "package"} {
      # puts "Found package declaration at token: \{$token\}"
      if {$i + 2 < $length} {
        # puts "Processing potential package declaration, tokens: \{[lindex $tokens [expr {$i + 1}]]\} \{[lindex $tokens [expr {$i + 2}]]\}"
        if {[lindex $tokens [expr {$i + 2}]] == "is"} {
          set package_name [lindex $tokens [expr {$i + 1}]]
          set package_key "$library.package.$package_name"
          # puts "Found package: $package_key"

          # Store package with inc_packages as sub_modules
          set pkg_data [_create_vhdl_module $package_name $library $file_path $inc_packages "package"]
          dict set packages $package_key $pkg_data

          set last_entity $package_name
          set prev_inc_packages $inc_packages
          set inc_packages {}

          # drop everything until we end;
          while {$i < $length && [lindex $tokens $i] != "end"} {
            incr i
          }
        } elseif {$i + 3 < $length} {
          if {[lindex $tokens [expr {$i + 1}]] == "body" && [lindex $tokens [expr {$i + 3}]] == "is"} {
            set package_body_name [lindex $tokens [expr {$i + 2}]]
            set package_body_key "$library.package_body.$package_body_name"
            # puts "Found package body: $package_body_key"

            set body_sub_modules {}
            if {$package_body_name == $last_entity} {
              # puts "Sharing packages from $last_entity to $package_body_key"
              set body_sub_modules $prev_inc_packages
            } else {
              set body_sub_modules $inc_packages
            }


            set body_data [_create_vhdl_module $package_body_name $library $file_path $body_sub_modules "package_body"]

            dict set packages_bodies $package_body_key $body_data

            while {$i < $length} {
              if {$i + 1 < $length} {
                if {[lindex $tokens $i] == "end" && [lindex $tokens [expr {$i + 1}]] == ";"} {
                  break;
                }
              }
              if {$i + 2 < $length} {
                if {[lindex $tokens $i] == "end" \
                && ![is_vhdl_keyword [lindex $tokens [expr {$i + 1}]]] \
                && [lindex $tokens [expr {$i + 2}]] == ";"} {
                  break;
                }
              }
              incr i
            }
          }
        }
      }
    } elseif {$token == "entity"} {
      # next token should be module name
      if {$i + 2 < $length} {
        if {[lindex $tokens [expr {$i + 2}]] == "is"} {
          set entity_name [lindex $tokens [expr {$i + 1}]]
          set entity_key "$library.component.$entity_name"
          # puts "Found entity: $entity_key"

          # Store entity with inc_packages as sub_modules
          set entity_data [_create_vhdl_module $entity_name $library $file_path $inc_packages "entity"]
          dict set entities $entity_key $entity_data

          set last_entity $entity_name
          set prev_inc_packages $inc_packages
          set inc_packages {}

          # drop everything until we end;
          while {$i < $length && [lindex $tokens $i] != "end"} {
            incr i
          }
        }
      }
    } elseif {$token == "architecture"} {
      # next token should be architecture name, then "of", then module name then "is"
      if {$i + 4 < $length} {
        if {[lindex $tokens [expr {$i + 2}]] == "of" && [lindex $tokens [expr {$i + 4}]] == "is"} {
          set entity_name [lindex $tokens [expr {$i + 3}]]
          set arch_name [lindex $tokens [expr {$i + 1}]]
          set arch_key "${library}.arch.${entity_name}.${arch_name}"

          # puts "Found architecture: $arch_name for entity: $entity_name (key: $arch_key)"

          set arch_sub_modules {}

          if {$entity_name == $last_entity} {
            # packages are shared to architecture if they are declared with the entity
            # puts "Sharing packages from entity $last_entity to architecture $arch_key"
            set arch_sub_modules $prev_inc_packages
          } else {
            set arch_sub_modules $inc_packages
          }

          set known_lib_modules {}
          set unknown_lib_modules {}

          # check for component declarations in the architecture heading
          while {$i < $length && [lindex $tokens $i] != "begin"} {
            incr i
            # puts "Processing token in architecture heading: \{[lindex $tokens $i]\}"
            if {[lindex $tokens $i] == "component"} {
              # puts "Found component declaration at token: \{[lindex $tokens $i]\}"
              # puts "Following tokens for component declaration: \{[lindex $tokens [expr {$i + 1}]]\} \{[lindex $tokens [expr {$i + 2}]]\}"
              if {$i + 2 < $length \
              && ([lindex $tokens [expr {$i + 2}]] == "is" && [lindex $tokens [expr {$i + 3}]] == "port")
              || (![is_vhdl_keyword [lindex $tokens [expr {$i + 1}]]]  && [lindex $tokens [expr {$i + 2}]] == "port")} {
                set component_name [lindex $tokens [expr {$i + 1}]]
                # puts "Found component: $component_name in architecture $arch_key"

                lappend unknown_lib_modules "unknown.component.$component_name"
                incr i 2
              }
            }
          }

          # now we have to find matching end
          # eat the begin
          incr i
          while {$i < $length} {

            # puts "Processing token in architecture body: \{[lindex $tokens $i]\}"
            if {[lindex $tokens $i] == "end"} {
              if {$i + 1 < $length && [lindex $tokens [expr {$i + 1}]] == ";"} {
                break;
              }
            } elseif {[lindex $tokens $i] == ":"} {

              # puts "Found potential entity instantiation at token: \{[lindex $tokens $i]\}"

              if {$i + 1 < $length && [lindex $tokens [expr {$i + 1}]] == "entity"} {
                # puts "Found entity instantiation, parsing entity name starting at token: \{[lindex $tokens [expr {$i + 1}]]\}"
                incr i 2
                set entity_inst ""
                while {$i < $length} {
                  # puts "Processing token in entity instantiation: \{[lindex $tokens $i]\}"

                  if { ([lindex $tokens $i] == "port" || [lindex $tokens $i] == "generic") && [lindex $tokens [expr {$i + 1}]] == "map"} {
                    # puts  "Found port or generic map, stopping entity name parsing at token: \{[lindex $tokens $i]\}"
                    break
                  }

                  set entity_inst "${entity_inst}[lindex $tokens $i]"
                  incr i
                }

                set entity_inst [split $entity_inst "."]
                set entity_inst "[lindex $entity_inst 0].component.[lindex $entity_inst 1]"
                # puts "Found entity: $entity_inst in architecture $arch_key"
                lappend known_lib_modules "$entity_inst"
              }
            }
            incr i
          }

          # Combine packages and sub_modules
          set all_modules [concat $arch_sub_modules $known_lib_modules $unknown_lib_modules]
          set arch_data [_create_vhdl_module [lindex [split $arch_key "."] 2] $library $file_path $all_modules "architecture"]
          dict set architectures $arch_key $arch_data
        }
      }
    }
    incr i
  }

  # puts "Pre filter entities: $entities"
  # puts "Pre filter architectures: $architectures"
  # puts "Pre filter packages: $packages"
  # puts "Pre filter package bodies: $packages_bodies"


  set filtered_packages_bodies [dict create]
  dict for {package_body body_info} $packages_bodies {
    set entity_key [split $package_body "."]
    set entity_key "[lindex $entity_key 0].package.[lindex $entity_key 2]"
    # puts "Filtering package body: $package_body with entity key: $entity_key"

    # if we don't have the package def let's track the body
    if {![dict exists $packages $entity_key]} {
      dict set filtered_packages_bodies $package_body $body_info
    }
  }


  set filtered_architectures [dict create]
  dict for {architecture arch_info} $architectures {
    set entity_key [split $architecture "."]
    set entity_key "[lindex $entity_key 0].component.[lindex $entity_key 2]"

    if {![dict exists $entities $entity_key]} {
      dict set filtered_architectures $architecture $arch_info
    } else {
      set entity_submods [dict get $entities $entity_key sub_modules]
      set arch_modules [dict get $arch_info sub_modules]
      set all_modules [concat $entity_submods $arch_modules]
      set all_modules [lsort -unique $all_modules]
      # puts "Merging architecture $architecture with entity $entity_key, combined modules: $all_modules"
      dict set entities $entity_key sub_modules $all_modules
    }
  }

  return [dict create packages $packages packages_bodies $filtered_packages_bodies entities $entities architectures $filtered_architectures]
}

proc extract_vhdl_module_info {file_path {library "work"}} {
    set file_id [open $file_path r]
    set file_content [read $file_id]
    close $file_id

    set tokens [tokenize_vhdl $file_content]
    set result [parse_vhdl_module $library $file_path $tokens]

    return $result
}
