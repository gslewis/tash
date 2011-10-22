tash - Task Manager using Bash
==============================

Version 0.2 - Sat 22 Oct 2011

Geoff Lewis <http://github.com/gslewis/tash>

This script provides a basic task manager using bash with sqlite3 for storage.
It was written for my particular timesheet reporting needs: a week's worth of
daily reports, starting from a given day of the week (Friday!), with tasks
associated with projects.  It was also written as an exercise in learning
bash and sqlite.  It is inspired by taskwarrior which I was unable to get to
do _exactly_ what I needed.

Installation
------------

Name the script whatever you like (I call it 'tash') and place it wherever you
like.  There are a couple of configuration settings in the script that you may
want to modify.  The first time tash is run, it will create ~/.tash.db
(replace 'tash' with whatever you call the script, minus any .sh suffix).

Usage
-----

The basic invocation is:

> tash [task_num] [command] [...]


To get a list of commands:

> tash help


Adding a new task:

> tash add @search Set up search engine

This will add a new task to the project 'search' with the description 'Set up
search engine'.  If the first word after the 'add' command starts with '@', it
represents the project name.  Otherwise the task is added to the 'nameless'
project.


Getting a list of all tasks:

The listing shows the task number, project, elapsed time and description of
each task.

> \# List 'in progress' tasks  
> tash  
> \# or  
> tash list  
> \# List 'complete' tasks  
> tash list complete  
> \# List all tasks (in progress and complete)  
> tash list all  
> \# List tasks in the 'search' project  
> tash list search  

(This means you can't have a project called 'all' or 'complete'.)

If you create a task by mistake, use the 'delete' command to delete it.


Getting information about a task:

> \# For task number 5 ...  
> tash 5  
> \# or  
> tash 5 info  

This will show all the sessions for the task.


Starting a task:

> \# For task number 5 ...  
> tash 5 start  

Starts a new session.  Does nothing if there is already a session running.


Stopping a task:

> \# For task number 5 ...  
> tash 5 stop  
> \# Stop the session with a given duration of 30 minutes  
> tash 5 stop 30m  
> \# Stop the session with a duration of 90 minutes  
> tash 5 stop 1.5h  
> \# Stop all running sessions
> tash stop
> \# Stop all running sessions with the given duration
> tash stop 15m

If no duration is given, the session duration is the actual duration -- the
time elapsed between starting and stopping the task.  A stopped task can be
restarted, which creates a new session.


Switching tasks:

If you want to stop the current session(s) and start a session for a different
task, use the "switch" command:

> \# Switch to task number 5
> tash 5 switch
> \# Switch to task number 5, stopping the current session at 45 minutes
> tash 5 switch 45m

Synonyms for "switch": sw

This is the same as doing a "stop all" followed by a "start".


Recording a session:

You can create a complete session with start time and duration using the
"session" command.  This saves you from having to "start" and "stop" the task
to generate the session.  In this case the duration is mandatory and the start
time is the current time.

> \# Create a 15 minute session for task number 5
> tash 5 session 15m


Completing a task:

> \# For task number 5  
> tash 5 done  
> \# Complete the running task with given duration of 15 minutes  
> tash 5 done 15m  

If a task is running when completed, the running session is closed, as per the
'stop' command.  Once a task is completed, it cannot be restarted but can be
viewed with the 'list', 'info' and 'report' commands.


Deleting a task:

> \# To delete task number 5  
> tash 5 delete  
> \# or to delete tasks 5 6 and 9  
> tash delete 5 6 9  

Synonyms for "delete": rm & remove

Deleting a task removes it and all its sessions from the database.  If you
have finished a task but still need to include it in reports, use the 'done'
command.  If you want to discard all completed tasks after having compiled
your report, use the 'clean' command.


Generating the weekly report:

> \# For the current week  
> tash report  
> \# For one week ago  
> tash report 1  

The report starts from the day designated as the start of the week (see the
configuration setting START_OF_WEEK) and shows a daily report for each day
showing the time spent on each task during the day.


Discarding completed tasks:

> tash clean

This will delete all completed tasks and their sessions and reallocate task
numbers.  Use this when you have compiled a report and don't need the
completed tasks any more.  If you want to archive your task history, make a
backup of the .tash.db file (or put it under version control).


Licence
-------
This script is public domain (2011).  If you find any of it remotely useful,
feel free to do with it what you will.

Geoff Lewis <gsl@gslsrc.net>
