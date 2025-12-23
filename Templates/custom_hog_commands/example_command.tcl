


set ::hog_command {
  NAME  {example_command}

  DESCRIPTION "A simple example command that is ran from TCLSH."

  CUSTOM_OPTIONS {
    {num.arg 1 "Number of times to print \"Hello World\""}
  }

  SCRIPT {

    set num [dict get $list_of_options num]
    for {set i 0} {$i < $num} {incr i} {
      puts "Hello World"
    }
    

  }

  NO_EXIT 0
  
}

