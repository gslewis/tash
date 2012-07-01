#!/usr/bin/perl -w

package tash;

use 5.010;
use strict;
use warnings;

our ($STATUS_IN_PROGRESS, $STATUS_COMPLETE) = ('in_progress', 'complete');

# Set the first day of the week for weekly reports.  If timesheets are
# submitted on Thursday, the week starts on the following Friday.
our $START_OF_WEEK = 'friday';

my $db = new tash::DB();
$db->init();

my $cmd = new tash::Command(@ARGV);
$cmd->execute();

package tash::Command;

sub new {
    my $class = shift;
    my $self = {
        'task_num' => -1,
        'command' => 'list',
        'param' => '',
    };

    # Args: [task_num] [command] [params ...]

    # Set the task_num and command.
    unless (@_ == 0) {
        local $_ = shift;
        if (/^\d+$/) {
            $self->{'task_num'} = $_;
            $self->{'command'} = shift || 'info';
        } else {
            $self->{'command'} = $_;
        }
    }

    # Any remaining args become the parameter list.
    if (@_ > 0) {
        $self->{'param'} = join ' ', @_;
        $self->{'param'} =~ s/^\s+//;  # strip leading whitespace
        $self->{'param'} =~ s/\s+$//;  # strip trailing whitespace
        $self->{'param'} =~ s/'//;     # strip single quotes (saves escaping)
    }

    # Translate command aliases to their canonical name.
    local $_ = $self->{'command'};
    if (/-[?h]/) {
        $self->{'command'} = 'help';
    } elsif (/^(rm|delete)$/) {
        $self->{'command'} = 'remove';
    } elsif (/^sw$/) {
        $self->{'command'} = 'switch';
    } elsif (/^cleanup$/) {
        $self->{'command'} = 'clean';
    }

    return bless($self, $class);
}

sub execute {
    my $self = shift;

    my $sub = "cmd_" . $self->{'command'};
    eval { $self->$sub(); };
    if ($@) {
        print $@;
        $self->cmd_help();
        exit;
    }

    return;
}

sub cmd_add {
    my $self = shift;

    my $project = '';
    my $desc = '';

    if ($self->{'param'} =~ /^@(\w+)\s*(.*)$/) {
        $project = $1;
        $desc = $2;
    } else {
        $desc = $self->{'param'};
    }

    die "Description cannot be empty\n" unless scalar($desc);

    my $pid_sql = "SELECT id FROM projects WHERE name='${project}';";
    my $pid = $db->query($pid_sql);
    unless (scalar($pid)) {
        $db->query("INSERT INTO projects (name) VALUES ('${project}');");
        $pid = $db->query($pid_sql);
    }

    my $count = $db->query(
        "SELECT count(*) FROM tasks WHERE desc='${desc}' AND project=$pid;"
    );
    die "Task already exists '${desc}'\n" if $count > 0;

    my $max_task_num = $db->query("SELECT MAX(task_num) FROM tasks;") || 0;
    my $task_num = $max_task_num + 1;

    $db->query(
        "INSERT INTO tasks (task_num,desc,status,project) VALUES
        ($task_num,'$desc','${STATUS_IN_PROGRESS}',$pid);"
    );

    $self->_task_list('in_progress');

    return;
}

sub cmd_remove {
    my $self = shift;

    my @tasks = ();

    # Add the task_num, if set.
    push @tasks, $self->{'task_num'} unless $self->{'task_num'} == -1;

    # Add the remaining parameters.
    push @tasks, split / /, $self->{'param'} if scalar($self->{'param'});

    # Discard non-positive integers, convert to ints, sort numerically.
    @tasks = sort { $a <=> $b } map(int, grep { /^[1-9]\d*$/ } @tasks);

    return unless @tasks;

    my $deleted = 0;
    foreach my $task_num (@tasks) {
        my $response = _prompt("Delete task ${task_num} ? [Y/n] ");
        next if length($response) and lc($response) ne 'y';

        eval {
            my $tid = $db->get_task_id($task_num);

            $db->query("DELETE FROM sessions WHERE task=$tid;");
            $db->query("DELETE FROM tasks WHERE id=$tid;");

            ++$deleted;
        };
        if ($@) {
            print $@;
        }
    }

    if ($deleted) {
        $self->_task_list('in_progress');
    }

    return;
}

sub cmd_start {
    my $self = shift;

    my $tid = $db->get_task_id($self->{'task_num'});
    $self->_start_task($tid);

    return;
}

sub cmd_stop {
    my $self = shift;

    if ($self->{'task_num'} == -1) {
        $self->_stop_all_tasks();
    } else {
        $self->_stop_one_task();
    }

    return;
}

sub cmd_switch {
    my $self = shift;

    my $tid = $db->get_task_id($self->{'task_num'}, $STATUS_IN_PROGRESS);

    $self->_stop_all_tasks();
    $self->_start_task($tid);

    return;
}

sub cmd_session {
    my $self = shift;

    die "Missing session duration\n" unless $self->{'param'};

    my $tid = $db->get_task_id($self->{'task_num'});
    my $durn = _parse_duration($self->{'param'});
    my $start = time;

    $db->query(
        "INSERT INTO sessions (task,start,duration) VALUES ($tid,$start,$durn);"
    );

    my $f_durn = _format_duration($durn);
    say "Created session [$f_durn] for task $self->{'task_num'}";

    return;
}

sub cmd_done {
    my $self = shift;

    my $tid = $db->get_task_id($self->{'task_num'}, $STATUS_IN_PROGRESS);

    my $result = $db->query(
        "SELECT id,start FROM sessions WHERE task=$tid AND duration=0;"
    );

    if ($result) {
        foreach (split /\n/, $result) {
            my ($sid, $start) = map(int, split /\|/);

            _stop_session($self->{'task_num'}, $sid, $start, $self->{'param'});
        }
    }

    $db->query(
        "UPDATE tasks SET status='$STATUS_COMPLETE' WHERE id=$tid;"
    );

    return;
}

sub cmd_list {
    my $self = shift;

    $self->_task_list;

    return;
}

sub cmd_info {
    my $self = shift;

    my $result = $db->query(
        "SELECT t.id,t.desc,t.status,p.name
            FROM tasks AS t
            LEFT JOIN projects AS p ON p.id=t.project
            WHERE t.task_num=$self->{'task_num'};"
    );

    die "No such task: $self->{'task_num'}\n" unless $result;
    my ($tid, $desc, $status, $project) = split /\|/, $result;

    $result = $db->query(
        "SELECT start,duration FROM sessions WHERE task=$tid ORDER BY start ASC"
    );
    die "No sessions for task $self->{'task_num'}\n" unless $result;

    my @sessions = ();
    for (split /\n/, $result) {
        push @sessions, [map(int, split /\|/)];
    }

    my $now = time;
    my $total = 0;
    foreach (@sessions) {
        if ($_->[1] == 0) {
            $_->[1] = $now - $_->[0];
            push @$_, _format_duration($_->[1]) . '*';
        } else {
            push @$_, _format_duration($_->[1]);
        }
        $total += $_->[1];
    }
    $total = _format_duration($total);

    #print tash::Dumper(\@sessions);exit;

    my $cols = _get_cols();
    my $rule1 = '-' x $cols;
    my $rule2 = '=' x $cols;
    my $format = " %-21s | %s\n";

format STDOUT =
   Task: ^*
         $self->{'task_num'}
Project: ^*
         $project
 Status: ^*
         $status

^*
$desc
.
write;

    say $rule1;
    printf($format, 'Started', 'Duration');
    say $rule2;

    for (@sessions) {
        printf($format,
            _make_date('@' . $_->[0], '%a %d-%b-%Y %H:%M'),
            $_->[2]
        );
    }
    say $rule2;
    printf($format, '', $total);
    say $rule1;

    return;
}

sub cmd_report {
    my $self = shift;

    my $offset = $self->{'param'} || 0;

    my $start_date = _make_date("last $START_OF_WEEK -${offset} week");

    my $end_secs = _date_to_secs("${start_date} +1 week");

    my $f_start_date = _make_date("${start_date}", '%A, %d %B %Y');

    my $format = " %5s | %2s%s | %5s | %s\n";
    my $cols = _get_cols();

    say "Report for week starting ${f_start_date}";
    printf($format, 'Time', 'Tk.', '', 'Proj', 'Description');
    say '=' x $cols;

    my $max_desc = $cols - 23;
    my $rule = '-' x $cols;

    my $f_time = $start_date;
    my $time_sec = _date_to_secs($start_date);
    while ($time_sec < $end_secs) {
        _report_daily($f_time, $time_sec, $format, $rule, $max_desc);

        ($f_time, $time_sec) = _next_day($f_time);
    }

    return;
}

sub _report_daily {
    my ($time_f, $time_start, $format, $rule, $max_desc) = @_;

    my $time_end = $time_start + 86400;

    my $result = $db->query("SELECT task,SUM(duration) FROM sessions
        WHERE start>=${time_start} AND start<${time_end}
        AND duration>0 GROUP BY task;");
    return unless $result;

    say _make_date($time_f, '%a %d-%b-%Y');
    say "$rule";

    my @lines = split /\n/, $result;
    foreach my $record (@lines) {
        my ($tid, $durn) = map { int } split /\|/, $record;

        my $task_info = $db->query("SELECT t.task_num,p.name,t.desc,t.status
            FROM tasks AS t LEFT JOIN projects AS p ON t.project=p.id
            WHERE t.id=${tid};"
        );

        my ($task_num, $project, $desc, $status) = split /\|/, $task_info;
        my $prefix = $status eq $STATUS_COMPLETE ? 'X' : ' ';
        my $f_durn = _format_duration($durn);

        printf($format, $f_durn, $task_num, $prefix,
            substr($project, 0, 5),
            substr($desc, 0, $max_desc)
        );
    }

    return;
}

sub cmd_clean {
    my $self = shift;

    my $completed_tasks = $db->query("SELECT task_num,desc FROM tasks
        WHERE status='$STATUS_COMPLETE';"
    );

    unless ($completed_tasks) {
        say "No completed tasks.";
        return;
    }

    my $max_tasknum = 2;
    my @tasks = ();
    my @lines = split /\n/, $completed_tasks;
    foreach my $record (@lines) {
        my @fields = split /\|/, $record;
        push @tasks, \@fields;

        $max_tasknum = _max(length($fields[0]), $max_tasknum);
    }

    my $format = "%${max_tasknum}s | %s\n";
    my $cols = _get_cols();
    my $rule1 = '-' x $cols;
    my $rule2 = '=' x $cols;

    say "Discarding completed tasks...";
    printf($format, 'Tk', 'Description');
    say $rule2;
    foreach my $task_ref (@tasks) {
        printf($format, @$task_ref);
    }
    say $rule1;

    my $response = _prompt(
        "Are you sure you want to delete these tasks? [y/N] "
    );
    return unless length($response) && lc($response) eq 'y';

    # Delete all sessions belonging to completed tasks.
    $db->query("DELETE FROM sessions WHERE task IN
        (SELECT id FROM tasks WHERE status='$STATUS_COMPLETE');"
    );

    # Delete all completed tasks.
    $db->query("DELETE FROM tasks WHERE status='$STATUS_COMPLETE';");

    # Delete all projects for which there is no tasks.
    $db->query("DELETE FROM projects WHERE id NOT IN
        (SELECT DISTINCT project FROM tasks);"
    );

    # Select remaining tasks in the order we want to allocate task nums.
    my $remaining_tasks = $db->query("SELECT t.id FROM tasks AS t
        LEFT JOIN projects AS p ON t.project=p.id
        ORDER BY p.name ASC, t.id ASC;"
    );

    my $task_num = 1;
    my @tids = map { int } split /\n/, $remaining_tasks;
    foreach my $tid (@tids) {
        $db->query("UPDATE tasks SET task_num=${task_num} WHERE id=${tid};");

        ++$task_num;
    }

    return;
}

sub cmd_help {
    my $self = shift;

    print <<USAGE;
Usage: perl ${0} [task_num] [command] ...

Commands
    list [all|complete]       - shows a list of tasks
    add [\@project] desc       - adds a task to the given project
    <task_num> delete         - deletes a task and all its sessions
    <task_num> start          - starts a session for the given task
    [task_num] stop [durn]    - stops session(s) with optional duration
    <task_num> session <durn> - creates a session
    <task_num> switch [durn]  - switches session to a new task
    <task_num> done [durn]    - marks a task as complete
    <task_num> [info]         - shows information for the given task
    report [week]             - generate a weekly report
    cleanup                   - discard all completed tasks

USAGE

    return;
}

sub _task_list {
    my $self = shift;
    my $list_type = lc(shift || $self->{'param'});

    # Strip single quotes.
    $list_type =~ s/'//;

    my $sql = "SELECT t.id,t.task_num,t.desc,p.name,t.status
        FROM tasks AS t
        LEFT JOIN projects AS p ON t.project=p.id";

    given($list_type) {
        when ('complete') {
            $sql .= " WHERE t.status='$STATUS_COMPLETE'";
        }
        when ('all') {}
        when ($_ eq '' || $_ eq 'in_progress') {
            $sql .= " WHERE t.status='$STATUS_IN_PROGRESS'";
        }
        default {
            $sql .= " WHERE p.name='$list_type'";
        }
    }

    $sql .= " ORDER BY p.name ASC, t.task_num ASC;";

    my $result = $db->query($sql);

    my $max_task_num = 2;
    my $max_project = 2;

    my @tasks = ();
    foreach (split /\n/, $result) {
        my @fields = split /\|/;

        $max_task_num = _max(length($fields[1]), $max_task_num);
        $max_project = _max(length($fields[3]), $max_project);

        push @fields, $self->_get_elapsed($fields[0]);
        push @fields, $self->_in_session($fields[0]);

        push @tasks, \@fields;
    }

    my $cols = _get_cols();
    my $rule = '=' x $cols;
    my $format = "%s %${max_task_num}s | %${max_project}s | %4s | %s\n";
    my $max_desc = $cols - 4 - $max_task_num -3 - $max_project - 9;

    printf($format, ' ', 'Tk', 'Pro.', 'Elap.', 'Description');
    say $rule;

    for (@tasks) {
        my $marker = ' ';
        if ($_->[6]) {
            $marker = '*';
        } elsif ($_->[4] eq $STATUS_COMPLETE) {
            $marker = 'X';
        }

        my $elapsed = _format_duration($_->[5]);
        my $desc = length($_->[2]) > $max_desc
                        ? substr($_->[2], 0, $max_desc) : $_->[2];

        printf($format, $marker, $_->[1], $_->[3], $elapsed, $desc);
    }

    return;
}

sub _get_elapsed {
    my $self = shift;
    my $tid = shift;

    my $result = $db->query(
        "SELECT duration FROM sessions WHERE task=$tid AND duration>0;"
    );

    my $sum = 0;
    foreach (split /\n/, $result) {
        $sum += int($_);
    }

    return $sum;
}

sub _in_session {
    my $self = shift;
    my $tid = shift;

    my $result = $db->query(
        "SELECT count(*) FROM sessions WHERE task=$tid AND duration=0;"
    );

    return int($result) > 0 ? 1 : 0;
}

sub _start_task {
    my $self = shift;
    my $tid = shift;
    my $task_num = shift || $self->{'task_num'};

    my $result = $db->query(
        "SELECT id FROM sessions WHERE task=$tid AND duration=0;"
    );
    die "Task $task_num already in progress\n" if length($result);

    my $start = time;
    $db->query(
        "INSERT INTO sessions (task,start,duration) VALUES ($tid,$start,0);"
    );

    say "Started task $task_num";

    return;
}

sub _stop_all_tasks {
    my $self = shift;
    my $elapsed = shift || $self->{'param'};

    my $result = $db->query(
        "SELECT s.id,s.start,t.task_num FROM sessions AS s
            LEFT JOIN tasks AS t ON s.task=t.id
            WHERE s.duration=0;"
    );

    return unless $result;
    foreach (split /\n/, $result) {
        my ($sid, $start, $task_num) = split /\|/;

        _stop_session($task_num, $sid, $start, $elapsed);
    }

    return;
}

sub _stop_one_task {
    my $self = shift;
    my $task_num = shift || $self->{'task_num'};
    my $elapsed = shift || $self->{'param'};

    my $tid = $db->get_task_id($task_num, $STATUS_IN_PROGRESS);

    my $result = $db->query(
        "SELECT id,start FROM sessions WHERE task=$tid AND duration=0;"
    );
    die "Task $task_num not started\n" unless $result;

    my ($sid, $start) = map(int, split /\|/, $result);

    _stop_session($task_num, $sid, $start, $elapsed);

    return;
}

sub _stop_session {
    my ($task_num, $sid, $start, $elapsed) = @_;

    my $durn = _close_session($sid, $start, $elapsed);
    my $f_durn = _format_duration($durn);

    say "Stopped task $task_num [$f_durn]";

    return;
}

sub _close_session {
    my ($sid, $start, $elapsed) = @_;

    my $durn = $elapsed ? _parse_duration($elapsed) : (time - $start);

    $db->query("UPDATE sessions SET duration=$durn WHERE id=$sid;");

    return $durn;
}

sub _format_duration {
    my $i_secs = shift;

    my $mins = $i_secs / 60;
    my $secs = $i_secs % 60;
    my $hours = 0;

    if ($mins > 60) {
        $hours = $mins / 60;
        $mins = $mins % 60;
    }

    return sprintf('%02d:%02d', $hours, $mins);
}

sub _parse_duration {
    my $s_durn = shift;

    unless ($s_durn =~ /^(\d+(?:\.\d+)?)([hm])?$/i) {
        die "Invalid duration: $s_durn\n";
    }

    my $durn;
    if ($2 && lc($2) eq 'h') {
        $durn = $1 * 60.0;
    } else {
        $durn = $1;
    }

    # Convert to seconds
    return int($durn * 60);
}

sub _max {
    my ($l1, $l2) = @_;
    return $l1 > $l2 ? $l1 : $l2;
}

sub _get_cols {
    return int(qx/tput cols/);
}

sub _prompt {
    my $prompt = shift;

    print $prompt;
    my $response = readline(*STDIN);
    chomp $response;

    return $response;
}

sub _make_date {
    my $date_string = shift;
    my $date_format = shift;

    my $cmd = "date --date=\"${date_string}\"";
    if ($date_format) {
        $cmd .= " \"+${date_format}\"";
    }

    my $date = qx($cmd);
    chomp $date;

    return $date;
}

sub _date_to_secs {
    my $date_string = shift;

    return _make_date($date_string, '%s');
}

sub _next_day {
    my $start_time = shift;

    my $f_time = _make_date("${start_time} +1 day");
    my $time_secs = _date_to_secs($f_time);

    return ( $f_time, $time_secs );
}

package tash::DB;

use File::Basename;

sub new {
    my $class = shift;
    my $self = {
        'sqlite' => '/usr/bin/sqlite3',
        'db_file' => "$ENV{'HOME'}/." . basename($0, qw(.pl)) . '.db',
    };

    return bless($self, $class);
}

sub init {
    my $self = shift;

    return if -e $self->{'db_file'};

    my $sql = <<SQL;
CREATE TABLE projects (id INTEGER PRIMARY KEY, name);
CREATE TABLE tasks (id INTEGER PRIMARY KEY,
                    task_num INTEGER,
                    desc,
                    status,
                    project INTEGER REFERENCES projects (id));
CREATE TABLE sessions (id INTEGER PRIMARY KEY,
                       task INTEGER REFERENCES tasks(id),
                       start TIMESTAMP,
                       duration INTEGER);
SQL

    $self->query($sql);
}

sub query {
    my $self = shift;
    my $sql = shift;

    my $result = qx/$self->{'sqlite'} $self->{'db_file'} "$sql"/;
    chomp $result;
    return $result;
}

sub get_task_id {
    my $self = shift;
    my $task_num = shift;
    my $task_status = shift;

    my $sql = "SELECT id FROM tasks WHERE task_num=$task_num";
    if ($task_status) {
        $sql .= " AND status='$task_status'";
    }
    $sql .= ";";

    my $result = $self->query($sql);

    unless (length($result)) {
        if ($task_status) {
            die "No such '$task_status' task: $task_num\n";
        } else {
            die "No such task: $task_num\n";
        }
    }

    return int($result);
}

1;
