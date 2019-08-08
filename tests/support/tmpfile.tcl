set ::tmpcounter 0
set ::tmproot "./tests/tmp"
file mkdir $::tmproot

# returns a dirname unique to this process to write to
proc tmpdir {basename} {
    set dir [file join $::tmproot $basename.[pid].[incr ::tmpcounter]]
    file mkdir $dir
    set _ $dir
}

# return a filename unique to this process to write to
# 获取对每个进程独一无二的文件
proc tmpfile {basename} {
    file join $::tmproot $basename.[pid].[incr ::tmpcounter]
}
