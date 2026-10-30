# Vivado 2023.1 -- synthesis of an existing .xpr project.
# Arguments: <project.xpr> <output_report_directory>
if {[llength $argv] != 2} {
    error "Usage: run_synth.tcl <project.xpr> <report_dir>"
}
set project_file [file normalize [lindex $argv 0]]
set report_dir [file normalize [lindex $argv 1]]
if {![file isfile $project_file]} {
    error "Project file not found: $project_file"
}
file mkdir $report_dir
puts "RUN_SYNTH: project=$project_file, reports=$report_dir"
open_project $project_file
set_property top camera_capture_top [get_filesets sources_1]
update_compile_order -fileset sources_1
reset_run synth_1
launch_runs synth_1 -jobs 8
wait_on_run synth_1
set run [get_runs synth_1]
puts "RUN_SYNTH: status=[get_property STATUS $run] progress=[get_property PROGRESS $run]"
if {[get_property PROGRESS $run] ne "100%"} {
    error "Synthesis did not complete: [get_property STATUS $run]"
}
open_run synth_1
report_utilization -file [file join $report_dir utilization.rpt]
report_timing_summary -file [file join $report_dir timing_summary.rpt]
report_timing -delay_type max -max_paths 20 -file [file join $report_dir worst_setup_paths.rpt]
close_project
puts "RUN_SYNTH: completed. Inspect timing_summary.rpt for WNS/TNS."
