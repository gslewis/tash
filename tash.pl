#!/usr/bin/perl -w

package tash;

use strict;
use feature ':5.12';

use Data::Dumper;

our ($STATUS_IN_PROGRESS, $STATUS_COMPLETE);
$STATUS_IN_PROGRESS = 'in_progress';
$STATUS_COMPLETE = 'complete';

my $db = new tash::DB();
$db->init();

my $cmd = new tash::Command(@ARGV);
#print Dumper($cmd);exit;
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

    local $_ = $self->{'command'};
    if (/-[?h]/) {
        $self->{'command'} = 'help';
    } elsif (/^(rm|delete)$/) {
        $self->{'command'} = 'remove';
    } elsif (/^sw$/) {
        $self->{'command'} = 'switch';
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

    $self->_task_list;
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
    #print tash::Dumper(\@tasks);

    my $deleted = 0;
    foreach my $task_num (@tasks) {
        print "Delete task ${task_num} ? [Y/n] ";
        my $response = readline(*STDIN);
        chomp $response;
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
        $self->_task_list;
    }
}

sub cmd_start {
    my $self = shift;

    my $tid = $db->get_task_id($self->{'task_num'});
    $self->_start_task($tid);
}

sub cmd_stop {
    my $self = shift;

    if ($self->{'task_num'} == -1) {
        $self->_stop_all_tasks();
    } else {
        $self->_stop_one_task();
    }
}

sub cmd_switch {
    my $self = shift;

    my $tid = $db->get_task_id($self->{'task_num'}, $STATUS_IN_PROGRESS);

    $self->_stop_all_tasks();
    $self->_start_task($tid);
}

sub cmd_session {
    my $self = shift;

    die "Missing session duration\n" unless $self->{'param'};

    my $tid = $db->get_task_id($self->{'task_num'});
    my $durn = $self->_parse_duration($self->{'param'});
    my $start = time;

    $db->query(
        "INSERT INTO sessions (task,start,duration) VALUES ($tid,$start,$durn);"
    );

    my $f_durn = $self->_format_duration($durn);
    say "Created session [$f_durn] for task $self->{'task_num'}";
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

            $self->_stop_session($self->{'task_num'}, $sid, $start,
                                 $self->{'param'});
        }
    }

    $db->query(
        "UPDATE tasks SET status='$STATUS_COMPLETE' WHERE id=$tid;"
    );
}

sub cmd_list {
    my $self = shift;

    $self->_task_list;
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
            push @$_, $self->_format_duration($_->[1]) . '*';
        } else {
            push @$_, $self->_format_duration($_->[1]);
        }
        $total += $_->[1];
    }
    $total = $self->_format_duration($total);

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
    printf $format, 'Started', 'Duration';
    say $rule2;

    for (@sessions) {
        printf $format, _date_format($_->[0]), $_->[2];
    }
    say $rule2;
    printf $format, '', $total;
    say $rule1;
}

sub cmd_help {
    my $self = shift;

    say "usage";
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
        when ('') {
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

    printf $format, ' ', 'Tk', 'Pro.', 'Elap.', 'Description';
    say $rule;

    for (@tasks) {
        my $marker = ' ';
        if ($_->[6]) {
            $marker = '*';
        } elsif ($_->[4] eq $STATUS_COMPLETE) {
            $marker = 'X';
        }

        my $elapsed = $self->_format_duration($_->[5]);
        my $desc = length($_->[2]) > $max_desc
                        ? substr($_->[2], 0, $max_desc) : $_->[2];

        printf $format, $marker, $_->[1], $_->[3], $elapsed, $desc;
    }
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

        $self->_stop_session($task_num, $sid, $start, $elapsed);
    }
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

    $self->_stop_session($task_num, $sid, $start, $elapsed);
}

sub _stop_session {
    my ($self, $task_num, $sid, $start, $elapsed) = @_;

    my $durn = $self->_close_session($sid, $start, $elapsed);
    my $f_durn = $self->_format_duration($durn);

    say "Stopped task $task_num [$f_durn]";
}

sub _close_session {
    my ($self, $sid, $start, $elapsed) = @_;

    my $durn = $elapsed ? $self->_parse_duration($elapsed) : (time - $start);

    $db->query("UPDATE sessions SET duration=$durn WHERE id=$sid;");

    return $durn;
}

sub _format_duration {
    my $self = shift;
    my $i_secs = shift;

    my $mins = $i_secs / 60;
    my $secs = $i_secs % 60;
    my $hours = 0;

    if ($mins > 60) {
        $hours = $mins / 60;
        $mins = $mins % 60;
    }

    return sprintf '%02d:%02d', $hours, $mins
}

sub _parse_duration {
    my $self = shift;
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
    int(qx/tput cols/);
}

sub _date_format {
    my @t = localtime(shift);

    my @wdays = qw(Sun Mon Tue Wed Thu Fri Sat);
    my @months = qw(Jan Feb Mar Apr May Jun Jul Sep Oct Nov Dec);

    my $format = "%s %02d-%s-%d %02d:%02d";

    sprintf $format,
        $wdays[$t[6]], $t[3], $months[$t[4]], (1900 + $t[5]), $t[2], $t[1];
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