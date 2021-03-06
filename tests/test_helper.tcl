# Redis test suite. Copyright (C) 2009 Salvatore Sanfilippo antirez@gmail.com
# This software is released under the BSD License. See the COPYING file for
# more information.

package require Tcl 8.5

set tcl_precision 17
source tests/support/redis.tcl
source tests/support/server.tcl
source tests/support/tmpfile.tcl
source tests/support/test.tcl
source tests/support/util.tcl

## 在all_tests是一个全局变量
## 是一个list
set ::all_tests {
    unit/printver
    unit/dump
    unit/auth
    unit/protocol
    unit/keyspace
    unit/scan
    unit/type/string
    unit/type/incr
    unit/type/list
    unit/type/list-2
    unit/type/list-3
    unit/type/set
    unit/type/zset
    unit/type/hash
    unit/type/stream
    unit/type/stream-cgroups
    unit/sort
    unit/expire
    unit/other
    unit/multi
    unit/quit
    unit/aofrw
    integration/block-repl
    integration/replication
    integration/replication-2
    integration/replication-3
    integration/replication-4
    integration/replication-psync
    integration/aof
    integration/rdb
    integration/convert-zipmap-hash-on-load
    integration/logging
    integration/psync2
    integration/psync2-reg
    unit/pubsub
    unit/slowlog
    unit/scripting
    unit/maxmemory
    unit/introspection
    unit/introspection-2
    unit/limits
    unit/obuf-limits
    unit/bitops
    unit/bitfield
    unit/geo
    unit/memefficiency
    unit/hyperloglog
    unit/lazyfree
    unit/wait
    unit/pendingquerybuf
}
# Index to the next test to run in the ::all_tests list.
set ::next_test 0

# ::都是全局的名字空间
# 直接设置全局变量
set ::host 127.0.0.1
set ::port 21111
set ::traceleaks 0
set ::valgrind 0
set ::stack_logging 0
set ::verbose 0
set ::quiet 0
set ::denytags {}
set ::skiptests {}
set ::allowtags {}
set ::only_tests {}
set ::single_tests {}
set ::skip_till ""
set ::external 0; # If "1" this means, we are running against external instance
set ::file ""; # If set, runs only the tests in this comma separated list
set ::curfile ""; # Hold the filename of the current suite
set ::accurate 0; # If true runs fuzz tests with more iterations
set ::force_failure 0
set ::timeout 600; # 10 minutes without progresses will quit the test.
set ::last_progress [clock seconds]
set ::active_servers {} ; # Pids of active Redis instances.
set ::dont_clean 0
set ::wait_server 0
set ::stop_on_failure 0
set ::loop 0

# Set to 1 when we are running in client mode. The Redis test uses a
# server-client model to run tests simultaneously. The server instance
# runs the specified number of client instances that will actually run tests.
# The server is responsible of showing the result to the user, and exit with
# the appropriate exit code depending on the test outcome.
set ::client 0
set ::numclients 16

proc execute_tests name {
    set path "tests/$name.tcl"
    set ::curfile $path
    # 加载tcl文件
    source $path
    # 给测试server发包，表示某个测试用例已经完成
    send_data_packet $::test_server_fd done "$name"
}

# Setup a list to hold a stack of server configs. When calls to start_server
# are nested, use "srv 0 pid" to get the pid of the inner server. To access
# outer servers, use "srv -1 pid" etcetera.
set ::servers {}
proc srv {args} {
    set level 0
    if {[string is integer [lindex $args 0]]} {
        set level [lindex $args 0]
        set property [lindex $args 1]
    } else {
        set property [lindex $args 0]
    }
    set srv [lindex $::servers end+$level]
    dict get $srv $property
}

# Provide easy access to the client for the inner server. It's possible to
# prepend the argument list with a negative level to access clients for
# servers running in outer blocks.
proc r {args} {
    set level 0
    if {[string is integer [lindex $args 0]]} {
        set level [lindex $args 0]
        set args [lrange $args 1 end]
    }
    [srv $level "client"] {*}$args
}

proc reconnect {args} {
    set level [lindex $args 0]
    if {[string length $level] == 0 || ![string is integer $level]} {
        set level 0
    }

    set srv [lindex $::servers end+$level]
    # 获取主机
    set host [dict get $srv "host"]
    # 获取port
    set port [dict get $srv "port"]
    # config的配置
    set config [dict get $srv "config"]
    set client [redis $host $port]
    dict set srv "client" $client

    # select the right db when we don't have to authenticate
    if {![dict exists $config "requirepass"]} {
        $client select 9
    }

    # re-set $srv in the servers list
    lset ::servers end+$level $srv
}

proc redis_deferring_client {args} {
    set level 0
    if {[llength $args] > 0 && [string is integer [lindex $args 0]]} {
        set level [lindex $args 0]
        set args [lrange $args 1 end]
    }

    # create client that defers reading reply
    set client [redis [srv $level "host"] [srv $level "port"] 1]

    # select the right db and read the response (OK)
    $client select 9
    $client read
    return $client
}

# Provide easy access to INFO properties. Same semantic as "proc r".
proc s {args} {
    set level 0
    if {[string is integer [lindex $args 0]]} {
        set level [lindex $args 0]
        set args [lrange $args 1 end]
    }
    status [srv $level "client"] [lindex $args 0]
}

proc cleanup {} {
    if {$::dont_clean} {
        return
    }
    if {!$::quiet} {puts -nonewline "Cleanup: may take some time... "}
    flush stdout
    # {*}[glob xxx] 表示就是一个使用glob的结果，返回一个字符串
    # Essentially, {*}$res will split the string into its whitespace-separated words
    # https://stackoverflow.com/questions/5124185/what-does-do-in-tcl
    catch {exec rm -rf {*}[glob tests/tmp/redis.conf.*]}
    catch {exec rm -rf {*}[glob tests/tmp/server.*]}
    if {!$::quiet} {puts "OK"}
}

proc test_server_main {} {
    # 清除临时配置
    cleanup
    set tclsh [info nameofexecutable]
    # 输出tclsh /usr/bin/tclsh8.5
    puts ", tclsh $tclsh"

    # Open a listening socket, trying different ports in order to find a
    # non busy one.
    set port [find_available_port 11111]
    if {!$::quiet} {
        puts "Starting test server at port $port"
    }
    # 启动服务器，监听127.0.0.1
    socket -server accept_test_clients -myaddr 127.0.0.1 $port

    # Start the client instances
    set ::clients_pids {}
    set start_port [expr {$::port+100}]
    # 没有特别指定，默认是16个客户端
    for {set j 0} {$j < $::numclients} {incr j} {
        # 给每个客户端分配启动端口号
        set start_port [find_available_port $start_port]
        set res [info script] {*}$::argv
        # 输出 tests/test_helper.tcl
        puts " res $res "

        # exec 启动子进程
        # 这里会重新 if {$::client} 这个分支
        set p [exec $tclsh [info script] {*}$::argv \
            --client $port --port $start_port &]
        # 客户端的pid获记录
        lappend ::clients_pids $p
        incr start_port 10
    }

    # Setup global state for the test server
    set ::idle_clients {}
    set ::active_clients {}
    # 设置dict类型
    array set ::active_clients_task {}
    array set ::clients_start_time {}
    set ::clients_time_history {}
    set ::failed_tests {}

    # Enter the event loop to handle clients I/O
    # 100ms后，test_server_cron
    after 100 test_server_cron
    #vwait一直等待，直到某个变量被写
    vwait forever
}

# This function gets called 10 times per second.
proc test_server_cron {} {
    # 获取当前的消耗的时间
    set elapsed [expr {[clock seconds]-$::last_progress}]

    # 消耗的时间大于10分钟
    if {$elapsed > $::timeout} {
        # 这个地方记录
        set err "\[[colorstr red TIMEOUT]\]: clients state report follows."
        # 打印错误日志
        puts $err
        # 添加错误
        lappend ::failed_tests $err
        show_clients_state
        # 杀死客户端
        kill_clients
        # 杀死服务器
        force_kill_all_servers
        the_end
    }

    # 继续100ms开始
    after 100 test_server_cron
}

proc accept_test_clients {fd addr port} {
    fconfigure $fd -encoding binary
    # 创建事件event handler
    fileevent $fd readable [list read_from_test_client $fd]
}

# This is the readable handler of our test server. Clients send us messages
# in the form of a status code such and additional data. Supported
# status types are:
#
# ready: the client is ready to execute the command. Only sent at client
#        startup. The server will queue the client FD in the list of idle
#        clients.
# testing: just used to signal that a given test started.
# ok: a test was executed with success.
# err: a test was executed with an error.
# skip: a test was skipped by skipfile or individual test options.
# ignore: a test was skipped by a group tag.
# exception: there was a runtime exception while executing the test.
# done: all the specified test file was processed, this test client is
#       ready to accept a new task.
proc read_from_test_client fd {
    # gets：从$fd中读取一行, 返回的应该是字节数
    set bytes [gets $fd]
    set payload [read $fd $bytes]
    foreach {status data} $payload break
    set ::last_progress [clock seconds]

    # 如果测试客户端法国来的命令是ready
    # 也就是连接上了测试服务器
    if {$status eq {ready}} {
        if {!$::quiet} {
            puts "\[$status\]: $data"
        }
        signal_idle_client $fd
    } elseif {$status eq {done}} {
        set elapsed [expr {[clock seconds]-$::clients_start_time($fd)}]
        set all_tests_count [llength $::all_tests]
        set running_tests_count [expr {[llength $::active_clients]-1}]
        set completed_tests_count [expr {$::next_test-$running_tests_count}]
        puts "\[$completed_tests_count/$all_tests_count [colorstr yellow $status]\]: $data ($elapsed seconds)"
        lappend ::clients_time_history $elapsed $data
        signal_idle_client $fd
        set ::active_clients_task($fd) DONE
    } elseif {$status eq {ok}} {
        if {!$::quiet} {
            puts "\[[colorstr green $status]\]: $data"
        }
        set ::active_clients_task($fd) "(OK) $data"
    } elseif {$status eq {skip}} {
        if {!$::quiet} {
            puts "\[[colorstr yellow $status]\]: $data"
        }
    } elseif {$status eq {ignore}} {
        if {!$::quiet} {
            puts "\[[colorstr cyan $status]\]: $data"
        }
    } elseif {$status eq {err}} {
        set err "\[[colorstr red $status]\]: $data"
        puts $err
        lappend ::failed_tests $err
        set ::active_clients_task($fd) "(ERR) $data"
            if {$::stop_on_failure} {
            puts -nonewline "(Test stopped, press enter to continue)"
            flush stdout
            gets stdin
        }
    } elseif {$status eq {exception}} {
        puts "\[[colorstr red $status]\]: $data"
        kill_clients
        force_kill_all_servers
        exit 1
    } elseif {$status eq {testing}} {
        set ::active_clients_task($fd) "(IN PROGRESS) $data"
    } elseif {$status eq {server-spawned}} {
        lappend ::active_servers $data
    } elseif {$status eq {server-killed}} {
        set ::active_servers [lsearch -all -inline -not -exact $::active_servers $data]
    } else {
        if {!$::quiet} {
            puts "\[$status\]: $data"
        }
    }
}

proc show_clients_state {} {
    # The following loop is only useful for debugging tests that may
    # enter an infinite loop. Commented out normally.
    foreach x $::active_clients {
        # info exist 表示当前的变量是否存在
        if {[info exist ::active_clients_task($x)]} {
            puts "$x => $::active_clients_task($x)"
        } else {
            puts "$x => ???"
        }
    }
}

proc kill_clients {} {
    foreach p $::clients_pids {
        # 直接杀死进程
        catch {exec kill $p}
    }
}

proc force_kill_all_servers {} {
    foreach p $::active_servers {
        puts "Killing still running Redis server $p"
        catch {exec kill -9 $p}
    }
}

# A new client is idle. Remove it from the list of active clients and
# if there are still test units to run, launch them.
proc signal_idle_client fd {
    # Remove this fd from the list of active clients.
    set ::active_clients \
        [lsearch -all -inline -not -exact $::active_clients $fd]

    if 0 {show_clients_state}

    # New unit to process?
    if {$::next_test != [llength $::all_tests]} {
        if {!$::quiet} {
            # 打印日志
            puts [colorstr bold-white "Testing [lindex $::all_tests $::next_test]"]
            set ::active_clients_task($fd) "ASSIGNED: $fd ([lindex $::all_tests $::next_test])"
        }
        # 设置每个客户端的启动时间
        set ::clients_start_time($fd) [clock seconds]
        # 运行第n个测试用例
        send_data_packet $fd run [lindex $::all_tests $::next_test]
        # 添加一个活动的连接
        lappend ::active_clients $fd
        # 运行下一个测试用例
        incr ::next_test
        if {$::loop && $::next_test == [llength $::all_tests]} {
            set ::next_test 0
        }
    } else {
        lappend ::idle_clients $fd
        if {[llength $::active_clients] == 0} {
            the_end
        }
    }
}

# The the_end function gets called when all the test units were already
# executed, so the test finished.
proc the_end {} {
    # TODO: print the status, exit with the rigth exit code.
    puts "\n                   The End\n"
    puts "Execution time of different units:"
    # 打印各个测试用例的消耗的时间
    foreach {time name} $::clients_time_history {
        puts "  $time seconds - $name"
    }

    # 打印失败的测试case
    if {[llength $::failed_tests]} {
        puts "\n[colorstr bold-red {!!! WARNING}] The following tests failed:\n"
        foreach failed $::failed_tests {
            puts "*** $failed"
        }
        cleanup
        exit 1
    } else {
        puts "\n[colorstr bold-white {\o/}] [colorstr bold-green {All tests passed without errors!}]\n"
        cleanup
        exit 0
    }
}

# The client is not even driven (the test server is instead) as we just need
# to read the command, execute, reply... all this in a loop.
# test_client_main 测试客户端的功能。
proc test_client_main server_port {
    # 连接服务器
    set ::test_server_fd [socket localhost $server_port]
    # 设置这个fd为二进制协议
    fconfigure $::test_server_fd -encoding binary
    # pid获取测试客户端的进程
    send_data_packet $::test_server_fd ready [pid]
    while 1 {
        # 从文件描述符中读
        set bytes [gets $::test_server_fd]
        # 设置payload
        set payload [read $::test_server_fd $bytes]
        foreach {cmd data} $payload break
        # 客户端开始准备测试
        if {$cmd eq {run}} {
            # 测试客户端开始启动server来进行测试
            execute_tests $data
        } else {
            error "Unknown test client command: $cmd"
        }
    }
}

proc send_data_packet {fd status data} {
    # 直接设置list
    set payload [list $status $data]
    # 先写入character字符串
    puts $fd [string length $payload]
    puts -nonewline $fd $payload
    flush $fd
}

proc print_help_screen {} {
    puts [join {
        "--valgrind         Run the test over valgrind."
        "--stack-logging    Enable OSX leaks/malloc stack logging."
        "--accurate         Run slow randomized tests for more iterations."
        "--quiet            Don't show individual tests."
        "--single <unit>    Just execute the specified unit (see next option). this option can be repeated."
        "--list-tests       List all the available test units."
        "--only <test>      Just execute the specified test by test name. this option can be repeated."
        "--skip-till <unit> Skip all units until (and including) the specified one."
        "--clients <num>    Number of test clients (default 16)."
        "--timeout <sec>    Test timeout in seconds (default 10 min)."
        "--force-failure    Force the execution of a test that always fails."
        "--config <k> <v>   Extra config file argument."
        "--skipfile <file>  Name of a file containing test names that should be skipped (one per line)."
        "--dont-clean       Don't delete redis log files after the run."
        "--stop             Blocks once the first test fails."
        "--loop             Execute the specified set of tests forever."
        "--wait-server      Wait after server is started (so that you can attach a debugger)."
        "--help             Print this help screen."
    } "\n"]
}

# parse arguments
# 变量参数
for {set j 0} {$j < [llength $argv]} {incr j} {
    # 访问列表中的选项
    set opt [lindex $argv $j]
    # 获取形参
    set arg [lindex $argv [expr $j+1]]
    # 如果为--tags
    # 字符串比较比较
    if {$opt eq {--tags}} {
        foreach tag $arg {
            if {[string index $tag 0] eq "-"} {
                lappend ::denytags [string range $tag 1 end]
            } else {
                lappend ::allowtags $tag
            }
        }
        incr j
    } elseif {$opt eq {--config}} {
        set arg2 [lindex $argv [expr $j+2]]
        lappend ::global_overrides $arg
        lappend ::global_overrides $arg2
        incr j 2
    } elseif {$opt eq {--skipfile}} {
        incr j
        set fp [open $arg r]
        set file_data [read $fp]
        close $fp
        set ::skiptests [split $file_data "\n"]
    } elseif {$opt eq {--valgrind}} {
        set ::valgrind 1
    } elseif {$opt eq {--stack-logging}} {
        if {[string match {*Darwin*} [exec uname -a]]} {
            set ::stack_logging 1
        }
    } elseif {$opt eq {--quiet}} {
        # 设置no debug
        set ::quiet 1
    } elseif {$opt eq {--host}} {
        set ::external 1
        set ::host $arg
        incr j
    } elseif {$opt eq {--port}} {
        # 设置端口号
        set ::port $arg
        incr j
    } elseif {$opt eq {--accurate}} {
        set ::accurate 1
    } elseif {$opt eq {--force-failure}} {
        set ::force_failure 1
    } elseif {$opt eq {--single}} {
        # 添加到测试的链表
        lappend ::single_tests $arg
        incr j
    } elseif {$opt eq {--only}} {
        lappend ::only_tests $arg
        incr j
    } elseif {$opt eq {--skiptill}} {
        set ::skip_till $arg
        incr j
    } elseif {$opt eq {--list-tests}} {
        foreach t $::all_tests {
            puts $t
        }
        exit 0
    } elseif {$opt eq {--verbose}} {
        set ::verbose 1
    } elseif {$opt eq {--client}} {
        set ::client 1
        set ::test_server_port $arg
        incr j
    } elseif {$opt eq {--clients}} {
        set ::numclients $arg
        incr j
    } elseif {$opt eq {--dont-clean}} {
        set ::dont_clean 1
    } elseif {$opt eq {--wait-server}} {
        set ::wait_server 1
    } elseif {$opt eq {--stop}} {
        set ::stop_on_failure 1
    } elseif {$opt eq {--loop}} {
        set ::loop 1
    } elseif {$opt eq {--timeout}} {
        set ::timeout $arg
        incr j
    # 这种也是可以的
    } elseif {$opt == "--help"} {
        puts "test --help"
        print_help_screen
        exit 0
    } else {
        puts "Wrong argument: $opt"
        exit 1
    }
}

# If --skil-till option was given, we populate the list of single tests
# to run with everything *after* the specified unit.
if {$::skip_till != ""} {
    set skipping 1
    foreach t $::all_tests {
        if {$skipping == 0} {
            lappend ::single_tests $t
        }
        if {$t == $::skip_till} {
            set skipping 0
        }
    }
    if {$skipping} {
        puts "test $::skip_till not found"
        exit 0
    }
}

# Override the list of tests with the specific tests we want to run
# in case there was some filter, that is --single or --skip-till options.
if {[llength $::single_tests] > 0} {
    # 只测试用户指定测试的选项
    set ::all_tests $::single_tests
}

proc attach_to_replication_stream {} {
    set s [socket [srv 0 "host"] [srv 0 "port"]]
    fconfigure $s -translation binary
    puts -nonewline $s "SYNC\r\n"
    flush $s

    # Get the count
    while 1 {
        set count [gets $s]
        set prefix [string range $count 0 0]
        if {$prefix ne {}} break; # Newlines are allowed as PINGs.
    }
    if {$prefix ne {$}} {
        error "attach_to_replication_stream error. Received '$count' as count."
    }
    set count [string range $count 1 end]

    # Consume the bulk payload
    while {$count} {
        set buf [read $s $count]
        set count [expr {$count-[string length $buf]}]
    }
    return $s
}

proc read_from_replication_stream {s} {
    fconfigure $s -blocking 0
    set attempt 0
    while {[gets $s count] == -1} {
        if {[incr attempt] == 10} return ""
        after 100
    }
    fconfigure $s -blocking 1
    set count [string range $count 1 end]

    # Return a list of arguments for the command.
    set res {}
    for {set j 0} {$j < $count} {incr j} {
        read $s 1
        set arg [::redis::redis_bulk_read $s]
        if {$j == 0} {set arg [string tolower $arg]}
        lappend res $arg
    }
    return $res
}

proc assert_replication_stream {s patterns} {
    for {set j 0} {$j < [llength $patterns]} {incr j} {
        assert_match [lindex $patterns $j] [read_from_replication_stream $s]
    }
}

proc close_replication_stream {s} {
    close $s
}

# With the parallel test running multiple Redis instances at the same time
# we need a fast enough computer, otherwise a lot of tests may generate
# false positives.
# If the computer is too slow we revert the sequential test without any
# parallelism, that is, clients == 1.
proc is_a_slow_computer {} {
    # start 为当前的毫秒数
    set start [clock milliseconds]
    # 很典型的for 循环
    for {set j 0} {$j < 1000000} {incr j} {}
    # clock milliseconds 获取当前时间戳，精度为毫秒
    set elapsed [expr [clock milliseconds]-$start]
    ## 大于200毫米为慢电脑
    expr {$elapsed > 200}
}

# 如果直接通过./runtest启动，那么$::client是没有设置的
# 直接转到else分支
# 测试客户端的程序
if {$::client} {
    if {[catch { test_client_main $::test_server_port } err]} {
        set estr "Executing test client: $err.\n$::errorInfo"
        puts $estr
        if {[catch {send_data_packet $::test_server_fd exception $estr}]} {
            puts $estr
        }
        exit 1
    }
} else {
    if {[is_a_slow_computer]} {
        puts "** SLOW COMPUTER ** Using a single client to avoid false positives."
        set ::numclients 1
    }

    if {[catch { test_server_main } err]} {
        # 有错误信息
        if {[string length $err] > 0} {
            # only display error when not generated by the test suite
            if {$err ne "exception"} {
                puts $::errorInfo
            }
            exit 1
        }
    }
}
