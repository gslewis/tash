#!/usr/bin/ruby

SQLITE="/usr/bin/sqlite3"

class Tash

    STATUS_IN_PROGRESS = 'in_progress'
    STATUS_COMPLETE = 'complete'

    attr_reader :task_num, :command, :param, :db_file

    # Long date format
    DF = '%a %d-%b-%Y %H:%M'

    def initialize()
        @db_file = "#{ENV['HOME']}/.#{File.basename($0, ".rb")}.db"

        @task_num = -1
        @command = 'list'
        @param = ''

        unless $*.empty? then
            if $*[0] =~ /\d+/
                @task_num = $*.shift
                @command = $*.empty? ? 'info' : $*.shift
            else
                @command = $*.shift
            end
        end

        @param = $*.join(' ')

        @command = 'help' if @command =~ /-[?h]/
    end

    def init_db
        return if File.exists? @db_file

        _query <<SQL
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
        print "Created database #{@db_file}\n"
    end

    def execute()
        self.send("cmd_#{@command}")
    end

    def method_missing(msg_id)
        print "Unknown command: #{msg_id.to_s.sub(/^cmd_/, '')}\n"
        cmd_help
        exit
    end

    def cmd_add
        @param.strip!

        project = ''
        desc = ''

        data = /^@(\w+)\s*(.*)$/.match(@param)
        if data
            project = data[1]
            desc = data[2]
        else
            desc = @param
        end

        # Can't be bothered escaping stuff, so just remove any quotes
        desc.delete! "'"

        raise "Description cannot be empty" if desc.empty?

        # Get the project id, if exists
        pid_sql = "SELECT id FROM projects WHERE name='#{project}';"
        pid = _query pid_sql
        if pid.empty?
            _query "INSERT INTO projects (name) VALUES ('#{project}');"
            pid = _query pid_sql
        end

        count = _query "SELECT count(*) FROM tasks
                         WHERE desc='#{desc}' AND project=#{pid};"
        raise "Task already exists '#{desc}'" if count.to_i > 0

        max_task_num = _query "SELECT MAX(task_num) FROM tasks;"
        task_num = max_task_num.to_i + 1

        _query "INSERT INTO tasks (task_num,desc,status,project) VALUES
                (#{task_num},'#{desc}','#{Tash::STATUS_IN_PROGRESS}',#{pid});"

        _task_list
    end

    def cmd_remove
        tasks = []

        # include the task_num arg, if set
        tasks << @task_num if @task_num != -1
        # include all param values
        tasks |= @param.split(' ') unless @param.empty?
        # discard anything not a positive integer
        tasks.delete_if { |x| x !~ /^[1-9]\d*$/ }

        return if tasks.empty?
        tasks.sort!

        deleted = 0
        tasks.each do |task_num|
            print "Delete task #{task_num} ? [Y/n] "
            response = STDIN.gets.chomp
            next unless response.empty? or response[0].downcase == 'y'

            begin
                tid = _get_task_id(task_num)

                _query "DELETE FROM sessions WHERE task=#{tid};"
                _query "DELETE FROM tasks WHERE id=#{tid};"

                deleted += 1
            rescue
                print $!, "\n"
            end
        end

        if deleted > 0
            _task_list
        end
    end
    alias cmd_rm cmd_remove
    alias cmd_delete cmd_remove

    def cmd_start
        tid = _get_task_id(@task_num)

        _start_task(tid, @task_num)
    end

    def cmd_stop
        if @task_num == -1
            _stop_all_tasks(@param)
        else
            _stop_one_task(@task_num, @param)
        end
    end

    def cmd_switch
        tid = _get_task_id(@task_num, Tash::STATUS_IN_PROGRESS)

        _stop_all_tasks(@param)
        _start_task(tid, @task_num)
    end
    alias cmd_sw cmd_switch

    def _start_task(tid, task_num = @task_num)
        result = _query "SELECT id FROM sessions
                         WHERE task=#{tid} AND duration=0;"

        unless result.empty?
            raise "Task #{task_num} already in progress"
        end

        start = Time.now().to_i
        _query "INSERT INTO sessions (task,start,duration)
                VALUES (#{tid},#{start},0);"

        print "Started task #{task_num}\n"
    end

    def _stop_all_tasks(elapsed)
        result = _query "SELECT s.id,s.start,t.task_num FROM sessions AS s
                        LEFT JOIN tasks AS t ON s.task=t.id
                        WHERE s.duration=0;"
        return if result.empty?

        result.each_line do |record|
            sid, start, task_num = record.chomp.split('|').map{|e| e.to_i}

            _stop_session(task_num, sid, start, elapsed)
        end
    end

    def _stop_one_task(task_num, elapsed)
        tid = _get_task_id(task_num, Tash::STATUS_IN_PROGRESS)

        result = _query "SELECT id,start FROM sessions
                         WHERE task=#{tid} AND duration=0;"
        if result.empty?
            raise "Task #{task_num} not started"
        end

        sid, start = result.chomp.split('|').map{|e| e.to_i}

        _stop_session(task_num, sid, start, elapsed)
    end

    def _stop_session(task_num, sid, start, elapsed = false)
        durn = _close_session(sid, start, elapsed)

        f_durn = _format_duration(durn)
        print "Stopped task #{task_num} [#{f_durn}]\n";
    end

    def _close_session(sid, start, elapsed = false)
        unless elapsed.nil? or elapsed.empty?
            durn = _parse_duration(elapsed)
        else
            durn = Time.now().to_i - start
        end

        _query "UPDATE sessions SET duration=#{durn} WHERE id=#{sid};"

        return durn
    end

    def cmd_session
        raise "Missing session duration" if @param.empty?

        tid = _get_task_id(@task_num)
        durn = _parse_duration(@param)
        start = Time.now().to_i

        _query "INSERT INTO sessions (task,start,duration)
                VALUES (#{tid},#{start},#{durn});"

        f_durn = _format_duration(durn)
        print "Created session [#{f_durn}] for task #{@task_num}\n"
    end

    def cmd_done
        tid = _get_task_id(@task_num, Tash::STATUS_IN_PROGRESS)

        result = _query "SELECT id,start FROM sessions
                         WHERE task=#{tid} AND duration=0;"

        unless result.empty?
            # Should only be one record...
            result.each_line do |record|
                sid, start = record.chomp.split('|').map{|e| e.to_i}

                _stop_session(@task_num, sid, start, @param)
            end
        end

        _query "UPDATE tasks SET status='#{Tash::STATUS_COMPLETE}'
                WHERE id=#{tid};"
    end

    def cmd_list
        _task_list(@param)
    end

    def _task_list(list_type = '')
        sql = "SELECT t.id,t.task_num,t.desc,p.name,t.status
            FROM tasks AS t
            LEFT JOIN projects AS p ON t.project=p.id"

        case list_type
        when 'complete'
            sql << " WHERE t.status='#{Tash::STATUS_COMPLETE}'"
        when 'all'
            # Do nothing
        when ''
            sql << " WHERE t.status='#{Tash::STATUS_IN_PROGRESS}'"
        else
            sql << " WHERE p.name='#{list_type}'"
        end

        sql << " ORDER BY p.name ASC, t.task_num ASC;"

        result = _query sql

        max_tasknum = 2
        max_project = 2

        tasks = []
        result.each_line do |record|
            fields = record.chomp.split('|')

            max_tasknum = [max_tasknum, fields[1].length].max
            max_project = [max_project, fields[3].length].max

            fields << _get_elapsed(fields[0])
            fields << _in_session(fields[0])

            tasks << fields
        end

        cols = _get_cols
        rule = '=' * cols
        format = "%s %#{max_tasknum}s | %#{max_project}s | %5s | %s\n"

        # Max available cols for the description, based on the format.
        max_desc = cols - 4 - max_tasknum - 3 - max_project - 9

        printf(format, ' ', 'Tk', 'Pro.', 'Elap.', 'Description')
        print rule, "\n"

        tasks.each do |task|
            if task[6]
                marker = '*' # in session
            elsif task[4] == Tash::STATUS_COMPLETE
                marker = 'X'
            else
                marker = ' '
            end

            elapsed = _format_duration(task[5])
            desc = task[2].length > max_desc ? task[2][0,max_desc] : task[2]

            printf(format, marker, task[1], task[3], elapsed, desc)
        end
    end

    def cmd_info
        raise "Invalid task number: #{@task_num}" unless @task_num =~ /\d+/

        result = _query "SELECT " \
            << %w(t.id t.desc t.status p.name).join(',') \
            << " FROM tasks AS t LEFT JOIN projects AS p ON p.id=t.project
                 WHERE t.task_num='#{@task_num}'"

        raise "No such task: #{@task_num}" if result.empty?
        tid, desc, status, project = result.chomp.split('|')

        result = _query "SELECT start,duration FROM sessions
                         WHERE task=#{tid} ORDER BY start ASC"

        sessions = Array.new;
        result.each_line do |session| 
            sessions << session.chomp.split('|').map{|e| e.to_i}
        end

        # Put the formatted duration in session[2] and calc the total durn
        now = Time.now().to_i
        total = 0
        sessions.each do |session|
            if session[1] == 0
                session[1] = now - session[0]
                session << _format_duration(session[1]) + '*'
            else
                session << _format_duration(session[1])
            end
            total += session[1]
        end
        total = _format_duration(total)

        cols = _get_cols
        rule1 = '-' * cols
        rule2 = '=' * cols
        format = " %-21s | %s"

        require 'erb'
        template =
%{   Task: <%= @task_num %>
Project: <%= project %>
 Status: <%= status %>

<%= desc %>
<%= rule1 %>
% if sessions.empty?
NO SESSIONS
% else
<%= sprintf(format, 'Started', 'Duration') %>
<%= rule2 %>
% sessions.each do |session|
<%= sprintf(format, Time.at(session[0]).strftime(DF), session[2]) %>
% end
<%= rule2 %>
<%= sprintf(format, '', total) %>
% end
<%= rule1 %>
}
        puts ERB.new(template, 0, '%').result(binding)
    end

    def cmd_report
        offset = /^\d+$/.match(@param) ? @param : 0

        start_date = `date --date="last friday -#{offset} week"`.chomp
        end_secs = `date --date="#{start_date} +1 week" +%s`.chomp.to_i

        now = Time.now().to_i
        end_secs = now if now < end_secs

        f_start_date = `date --date="#{start_date}" "+%A, %d %B %Y"`.chomp
        print "Report for week starting #{f_start_date}\n\n"

        format = " %5s | %2s%s | %5s | %s\n"

        cols = _get_cols

        printf(format, "Time", "Tk.", "", "Proj", "Description")
        print ('=' * cols), "\n"

        max_desc = cols - 23
        rule1 = '-' * cols

        time_f = start_date
        time_s = _date_to_secs(time_f)
        while time_s < end_secs do
            _report_daily(time_f, time_s, format, rule1, max_desc)

            time_f, time_s = _next_day(time_f)
        end
    end

    def _report_daily(time_f, time_start, format, rule, max_desc)
        time_end = time_start + 86400

        result = _query "SELECT task,SUM(duration) FROM sessions
            WHERE start>=#{time_start} AND start<#{time_end}
            AND duration>0 GROUP BY task;"
        return if result.empty?

        print `date --date="#{time_f}" "+%a %d-%b-%Y"`
        print rule, "\n"

        result.each_line do |record|
            tid, durn = record.chomp.split('|').map{|e| e.to_i}

            tk_info = _query "SELECT t.task_num,p.name,t.desc,t.status
                FROM tasks AS t LEFT JOIN projects AS p ON t.project=p.id
                WHERE t.id=#{tid};"

            task_num, project, desc, status = tk_info.chomp.split('|')
            prefix = (status == Tash::STATUS_COMPLETE ? 'X' : ' ')

            f_durn = _format_duration(durn)

            printf(format, f_durn, task_num, prefix, project[0,5],
                   desc[0, max_desc])
        end
    end

    def _date_to_secs(time_f)
        `date --date="#{time_f}" +%s`.chomp.to_i
    end

    def _next_day(time_f)
        result = []
        result << `date --date="#{time_f} +1 day"`.chomp
        result << _date_to_secs(result[0])
    end

    def cmd_clean
        result = _query "SELECT task_num,desc FROM tasks
                         WHERE status='#{Tash::STATUS_COMPLETE}';"
        unless result
            print "No completed tasks\n"
            return
        end

        max_tasknum = 2

        tasks = []
        result.each_line do |record|
            fields = record.chomp.split('|')
            max_tasknum = [max_tasknum, fields[0].length].max

            tasks << fields
        end

        format = "%#{max_tasknum}s | %s"
        cols = _get_cols
        rule1 = '-' * cols
        rule2 = '=' * cols

        require 'erb'
        template =
%{Discarding completed tasks...
<%= sprintf(format, "Tk", "Description") %>
<%= rule2 %>
% tasks.each do |task|
<%= sprintf(format, task[0], task[1]) %>
% end
<%= rule1 %>
}
        puts ERB.new(template, 0, '%').result(binding)

        print "Are you sure you want to delete these tasks? [y/N] "
        response = STDIN.gets.chomp

        return if response.empty? or response[0].downcase != 'y'

        # Delete all sessions belonging to completed tasks.
        _query "DELETE FROM sessions WHERE task IN
            (SELECT id FROM tasks WHERE status='#{Tash::STATUS_COMPLETE}');"

        # Delete all completed tasks.
        _query "DELETE FROM tasks WHERE status='#{Tash::STATUS_COMPLETE}';"

        # Delete all projects for which there is not task.
        _query "DELETE FROM projects WHERE id NOT IN
            (SELECT DISTINCT project FROM tasks);"

        # Select remaining tasks in the order we want to allocate task nums.
        result = _query "SELECT t.id FROM tasks AS t
            LEFT JOIN projects AS p ON t.project=p.id
            ORDER BY p.name ASC, t.id ASC;"

        task_num = 1
        result.each_line do |tid|
            tid = tid.chomp.to_i

            _query "UPDATE tasks SET task_num=#{task_num} WHERE id=#{tid};"

            task_num += 1
        end

        print "\nDeleted #{tasks.length} tasks\n"
    end
    alias cmd_cleanup cmd_clean

    def cmd_help
        print <<USAGE
Usage: #{$0} [task_num] [command] ...

Commands
    list [all|complete]       - shows a list of tasks
    add [@project] desc       - adds a task to the given project
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
    end

    def _query(sql)
        `#{SQLITE} #{@db_file} "#{sql}"`
    end

    def _format_duration(i_secs)
        mins = i_secs / 60
        secs = i_secs % 60

        if mins > 60
            hours = mins / 60
            mins = mins % 60
        else
            hours = 0
        end

        sprintf '%02d:%02d', hours, mins
    end

    def _get_elapsed(tid)
        result = _query "SELECT duration FROM sessions
                         WHERE task=#{tid} AND duration>0;"

        sum = 0
        result.each_line do |d| sum += d.chomp.to_i end

        return sum
    end

    def _in_session(tid)
        result = _query "SELECT count(*) FROM sessions
                        WHERE task=#{tid} AND duration=0;"

        result.chomp.to_i > 0
    end

    def _get_cols
        `tput cols`.to_i
    end

    def _get_task_id(task_num, task_status = false)
        sql = "SELECT id FROM tasks WHERE task_num=#{task_num}"
        if task_status
            sql << " AND status='#{task_status}'"
        end
        sql << ';'

        result = _query sql
        result = result.chomp

        if result.empty?
            if task_status
                raise "No such '#{task_status}' task: #{task_num}"
            else
                raise "No such task: #{task_num}"
            end
        end

        return result.to_i
    end

    def _parse_duration(s_durn)
        data = /(\d+(?:\.\d+)?)([hm])?/i.match(s_durn)
        raise "Invalid duration: #{s_durn}" unless data

        if data[2] && data[2].downcase == 'h'
            durn = data[1].to_f * 60
        else
            durn = data[1].to_f
        end

        # Convert to seconds
        durn *= 60
        return durn.to_i
    end
end

t = Tash.new
t.init_db
t.execute
