# Vivado 2023.1 -- simulation of an existing .xpr project.
# Arguments: <project.xpr> <testbench_top>
if {[llength $argv] != 2} {
    error "Usage: run_sim.tcl <project.xpr> <testbench_top>"
}
set project_file [file normalize [lindex $argv 0]]
set tb_top [lindex $argv 1]
if {![file isfile $project_file]} {
    error "Project file not found: $project_file"
}
puts "RUN_SIM: project=$project_file, testbench=$tb_top"
open_project $project_file
set_property target_simulator XSim [current_project]
set simset [get_filesets sim_1]
set_property top $tb_top $simset
set_property xsim.simulate.runtime all $simset
update_compile_order -fileset sim_1
launch_simulation -simset sim_1 -mode behavioral
close_sim
close_project
puts "RUN_SIM: simulator finished. See simulate.log for PASS/FAIL."
