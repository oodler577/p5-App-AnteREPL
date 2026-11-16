#!/usr/bin/env perl

use 5.016;
use strict;
use warnings;
use Cwd qw(abs_path);
use Encode qw(decode encode FB_DEFAULT);
use Errno qw(EINTR EIO);
use File::Spec;
use File::Temp qw(tempdir);
use FindBin;
use IO::Select;
use POSIX qw(WNOHANG ICANON ECHO);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

BEGIN {
    die "This optional terminal test requires a Unix PTY.\n" if $^O eq 'MSWin32';
    eval { require IO::Pty; 1 }
        or die "This optional test needs IO::Pty: cpanm IO::Tty\n";
}

{
    package TerminalView;

    # Only observe the ANSI sequences used by AnteREPL; this is not a terminal.
    sub new {
        my ($class, $height, $width) = @_;
        my $self = bless { height=>$height, width=>$width, row=>0, col=>0, pending=>'' }, $class;
        $self->clear;
        return $self;
    }

    sub clear {
        my ($self) = @_;
        $self->{cells} = [map { ' ' x $self->{width} } 1 .. $self->{height}];
    }

    sub feed {
        my ($self, $data) = @_;
        $self->{pending} .= Encode::decode('UTF-8', $data, Encode::FB_DEFAULT());
        while (length $self->{pending}) {
            if ($self->{pending} =~ /\A\e\[/) {
                return unless $self->{pending} =~ s/\A\e\[([0-?]*)([ -\/]*)([\@-~])//;
                my ($params, $command) = ($1, $3);
                my @numbers = $params =~ /\A[0-9;]*\z/ ? map { length($_) ? 0 + $_ : 0 } split(/;/, $params, -1) : ();
                if ($command eq 'H') {
                    $self->{row} = ($numbers[0] || 1) - 1;
                    $self->{col} = ($numbers[1] || 1) - 1;
                }
                elsif ($command eq 'K' && $self->{row} >= 0 && $self->{row} < $self->{height}) {
                    $self->{cells}[ $self->{row} ] = ' ' x $self->{width};
                }
                elsif ($command eq 'J' && $params eq '2') { $self->clear; }
                next;
            }
            if (substr($self->{pending}, 0, 1) eq "\e") {
                return if length($self->{pending}) < 2;
                substr($self->{pending}, 0, 2, '');
                next;
            }
            my $char = substr($self->{pending}, 0, 1, '');
            if ($char eq "\r") { $self->{col} = 0; }
            elsif ($char eq "\n") { ++$self->{row}; }
            elsif (ord($char) >= 32) {
                if ($self->{row} >= 0 && $self->{row} < $self->{height}
                    && $self->{col} >= 0 && $self->{col} < $self->{width}) {
                    substr($self->{cells}[ $self->{row} ], $self->{col}, 1, $char);
                }
                ++$self->{col};
            }
        }
    }

    sub lines {
        my ($self) = @_;
        return map { my $line = $_; $line =~ s/\s+\z//; $line } @{ $self->{cells} };
    }
}

my $root = abs_path(File::Spec->catdir($FindBin::Bin, '..'));
my $temporary = tempdir('anterepl-terminal-XXXXXX', TMPDIR=>1, CLEANUP=>1);
sub start_repl {
    my @args = @_;
    my $terminal = IO::Pty->new or die "Cannot create PTY: $!\n";
    $terminal->slave->set_winsize(16, 80);
    my $child = fork;
    die "Cannot fork: $!\n" unless defined $child;
    if ($child) { $terminal->close_slave; return ($terminal, $child); }
    $terminal->make_slave_controlling_terminal;
    my $slave = $terminal->slave;
    open STDIN, '<&', $slave or die "stdin: $!\n";
    open STDOUT, '>&', $slave or die "stdout: $!\n";
    open STDERR, '>&', $slave or die "stderr: $!\n";
    $terminal->close_slave;
    close $terminal;
    chdir $root or die "chdir: $!\n";
    # Test the environment editor with predictable, non-personal settings.
    %ENV = (PATH=>$ENV{PATH} || '/usr/bin:/bin', TERM=>'xterm', EDITOR=>'vi', LC_ALL=>'C');
    exec $^X, '-Ilib', 'script/anterepl', @args;
    die "Cannot start anterepl: $!\n";
}
my ($pty, $pid) = start_repl();
my $selector = IO::Select->new($pty);
my $view = TerminalView->new(16, 80);
my ($transcript, $eof, $reaped) = ('', 0, 0);
$SIG{PIPE} = 'IGNORE';

END {
    if (defined $pid && $pid > 0 && !$reaped) {
        local $?;
        kill 'KILL', -$pid;
        kill 'KILL', $pid;
        waitpid($pid, 0);
    }
}

sub now { clock_gettime(CLOCK_MONOTONIC) }
sub has_line { my ($line) = @_; return scalar grep { $_ eq $line } $view->lines; }
sub has_prefix { my ($prefix) = @_; return scalar grep { index($_, $prefix) == 0 } $view->lines; }
sub screen_text { join "\n", $view->lines }
sub check { my ($ok, $message) = @_; die "$message\n" . screen_text() . "\n" unless $ok; }

sub read_available {
    my ($timeout) = @_;
    return if $eof || !$selector->can_read($timeout);
    my $count = sysread($pty, my $data, 65536);
    return if !defined $count && $! == EINTR;
    if ((defined $count && !$count) || (!defined $count && $! == EIO)) { $eof = 1; return; }
    die "PTY read failed: $!\n" unless defined $count;
    $transcript .= $data;
    $view->feed($data);
}

sub wait_for {
    my ($predicate, $label, $timeout) = @_;
    my $deadline = now() + (defined $timeout ? $timeout : 6);
    while (now() < $deadline) {
        return if $predicate->();
        last if $eof;
        read_available(0.05);
    }
    check($predicate->(), $label);
}

sub send_text {
    my ($text) = @_;
    my $bytes = encode('UTF-8', $text);
    my $offset = 0;
    while ($offset < length $bytes) {
        my $count = syswrite($pty, $bytes, length($bytes) - $offset, $offset);
        next if !defined $count && $! == EINTR;
        die "PTY write failed: $!\n" unless $count;
        $offset += $count;
    }
}

sub command {
    my ($input, $expected) = @_;
    send_text("$input\r");
    wait_for(sub { has_line($expected) }, $input);
}

sub pump_for {
    my ($seconds) = @_;
    my $deadline = now() + $seconds;
    while (!$eof && now() < $deadline) { read_available(0.02); }
}

wait_for(sub { has_line('*** BASIC PERL V0.1 ***') }, 'startup');
command('10 say "old"', '10 say "old"');
command('LIST', '10 say "old";');
send_text("\e[A\e[H\x15" . '10 say "new"' . "\r");
command('RUN', 'new');
print "PASS: move up into LIST output, edit, resubmit, and RUN\n";

my $program = File::Spec->catfile($temporary, 'long.bperl');
open my $file, '>:encoding(UTF-8)', $program or die "$program: $!\n";
print {$file} "# BASIC PERL V0.1\n5 say \"low\";\n10 say \"second\";\n",
    map { "$_ say $_;\n" } grep { $_ % 10 == 0 } 20 .. 400;
close $file or die $!;
command(qq{LOAD! "$program"}, 'Loaded 41 lines.');
send_text("LIST PAUSE\r");
wait_for(sub { has_prefix('LIST paused') }, 'LIST screenful pause');
check(has_line('5   say "low";') && has_line('10  say "second";'), 'LIST alignment');
my $paused = screen_text();
pump_for(0.15);
check(screen_text() eq $paused, 'paused listing kept scrolling');
my @listed = sort { $a <=> $b } map { /\A(\d+) +say/ ? $1 : () } $view->lines;
my $next = $listed[-1] + 10;
send_text("\r");
wait_for(sub { has_prefix("$next ") && has_prefix('LIST paused') }, 'LIST one-line step');
send_text('s ');
wait_for(sub { has_prefix('LIST slow') }, 'LIST slow resume');
send_text(' ');
wait_for(sub { has_prefix('LIST paused') }, 'LIST manual pause');
send_text('q');
wait_for(sub { !has_prefix('LIST paused') }, 'LIST stop');
command('LIST5-10', '5  say "low";');
send_text("\e[A\e[A\e[F\e[D\e[D\e[D!\r");
command('LIST5', '5 say "lo!";');
send_text("LIST SLOW\r");
wait_for(sub { has_prefix('LIST slow') }, 'LIST slow start');
send_text("\x03");
wait_for(sub { !has_prefix('LIST slow') }, 'LIST Ctrl-C stop');
command('say "after-list-stop"', 'after-list-stop');
print "PASS: LIST alignment, ranges, scrolling, pause/resume, slow, step, stop, and padded-row editing\n";

send_text(join "\r", '$FOO = {', 'bar => 1,', 'names => [qw(Alice Bob)],', '};', '');
command('dump $FOO', "          'bar' => 1,");
command('peek $FOO->{bar}', '  IV = 1');
print "PASS: multiline structures, dump, and native Devel::Peek output\n";

send_text('print "Name: "; $answer = <STDIN>; chomp $answer; say "Got:$answer";' . "\r");
wait_for(sub { has_line('Name:') }, 'program input prompt');
send_text("Ada\r");
wait_for(sub { has_line('Got:Ada') }, 'program stdin');
print "PASS: program prompts and reads a line through the screen\n";

command('say $_ for 1..40', '40');
check(!has_line('1'), 'display did not scroll upward');
send_text("\e[5~\e[5~");
wait_for(sub { has_line('20') }, 'screen PageUp');
send_text("\e[1;5F");
command('! printf "shell-output\\n"', 'shell-output');
print "PASS: display scrolls upward; PageUp traverses text; shell output returns to screen\n";

my $marker = length $transcript;
send_text('!! printf "external-output\\n"' . "\r");
wait_for(sub { index(substr($transcript, $marker), 'Press Enter to return') >= 0 }, 'external shell handoff');
send_text("\r");
wait_for(sub { index(substr($transcript, $marker), "\e[?1049h") >= 0 }, 'screen resume after shell');

$marker = length $transcript;
send_text("EDIT\r");
wait_for(sub { index(substr($transcript, $marker), 'program.pl') >= 0 }, 'vi opened');
send_text(":%d\ri" . 'say "edited";' . "\e:wq\r");
wait_for(sub { has_line('Program updated; lines numbered 10,20,...') }, 'vi returned');
command('RUN', 'edited');
print "PASS: interactive shell and actual vi restore the screen and terminal modes\n";

command('AUTO', 'AUTO 15, step 5. AUTO OFF, Ctrl-C, or Ctrl-D ends entry.');
command('say "auto-line"', 'say "auto-line"');
command('STATUS', 'AUTO next 20, step 5.');
check(!has_prefix('15 say'), 'AUTO echoed a numbered copy by default');
command('AUTO OFF', 'AUTO off.');
command('say "immediate-again"', 'immediate-again');
command('AUTO 25', 'AUTO 25, step 5. AUTO OFF, Ctrl-C, or Ctrl-D ends entry.');
send_text('$unfinished_auto = {' . "\r");
wait_for(sub { has_line('$unfinished_auto = {') && $view->{col} == 0
    && ($view->lines)[$view->{row}] eq '' }, 'AUTO continuation');
$marker = length $transcript;
send_text("\x03");
wait_for(sub { my $new = substr($transcript, $marker); index($new, 'AUTO off.') >= 0
    && index($new, 'Interrupted.') >= 0 }, 'Ctrl-C ends AUTO');
command('say "auto-cancelled"', 'auto-cancelled');
command('LIST 15-', '15 say "auto-line";');
check(!has_prefix('25 '), 'unfinished AUTO source stored');
print "PASS: AUTO numbering, AUTO OFF, and Ctrl-C preserve stored lines\n";

command('ENV SET ANTEREPL_SMOKE before', 'ENV SET ANTEREPL_SMOKE before');
$marker = length $transcript;
send_text("EDIT ENV\r");
wait_for(sub { index(substr($transcript, $marker), 'environment.env') >= 0 }, 'vi environment opened');
send_text(":%s/ANTEREPL_SMOKE=before/ANTEREPL_SMOKE=after/\r:wq\r");
wait_for(sub { has_line('Environment updated.') }, 'environment vi returned');
command('ENV ANTEREPL_SMOKE', 'ANTEREPL_SMOKE=after');
command('! printf "child-env:%s\\n" "$ANTEREPL_SMOKE"', 'child-env:after');
my $environment = File::Spec->catfile($temporary, 'vars.env');
command(qq{ENV SAVE "$environment"}, 'Environment saved.');
command('ENV SET ANTEREPL_SMOKE changed', 'ENV SET ANTEREPL_SMOKE changed');
command('ENV RELOAD', 'Environment loaded.');
command('say "reloaded:$ENV{ANTEREPL_SMOKE}"', 'reloaded:after');
print "PASS: EDIT ENV uses VAR=value; Perl and child shells see changes; RELOAD restores file\n";

command('AUTO 25', 'AUTO 25, step 5. AUTO OFF, Ctrl-C, or Ctrl-D ends entry.');
send_text("CLS\r");
wait_for(sub { !grep { length } $view->lines }, 'CLS clears the display');
check($view->{row} == 0 && $view->{col} == 0, 'CLS cursor is not at top left');
send_text("\e[1;5H");
pump_for(0.1);
check(!grep({ length } $view->lines), 'CLS retained old screen rows');
command('LIST', '15 say "auto-line";');
command('RUN', 'auto-line');
command('EVAL say "retained:$FOO->{bar}:$ENV{ANTEREPL_SMOKE}"', 'retained:1:after');
command('STATUS', 'AUTO next 25, step 5.');
command('AUTO OFF', 'AUTO off.');
print "PASS: CLS clears screen rows and retains VRAM, workspace, environment, and AUTO\n";

send_text("\e[200~" . "do {\nmy \$total = 0;\nfor my \$n (1..3) { \$total += \$n; }\nif (\$total) { say \"pasted:\$total\"; }\n};" . "\e[201~");
pump_for(0.1);
check(!has_line('pasted:6'), 'bracketed paste executed before Enter');
send_text("\r");
wait_for(sub { has_line('pasted:6') }, 'immediate multiblock paste');
command('STATUS', '2 lines; unsaved changes; ' . $program . '.');
command('20 sub twice { return 2 * shift }', '20 sub twice { return 2 * shift }');
command('RUN', 'auto-line');
command('say twice(21)', '42');
print "PASS: immediate multiline paste waits for Enter, stays out of VRAM, and calls RUN-defined functions\n";

send_text('$incomplete = {' . "\r");
wait_for(sub { has_line('$incomplete = {') && $view->{col} == 0
    && ($view->lines)[$view->{row}] eq '' }, 'open continuation');
$marker = length $transcript;
send_text("\x03");
wait_for(sub { index(substr($transcript, $marker), 'Interrupted.') >= 0 }, 'cancel incomplete entry');
command('say "after-cancel"', 'after-cancel');
$marker = length $transcript;
send_text('say "running-loop"; while (1) {}' . "\r");
wait_for(sub { has_line('running-loop') }, 'running loop');
send_text("\x03");
wait_for(sub { index(substr($transcript, $marker), 'Interrupted.') >= 0 }, 'interrupt running Perl');
print "PASS: Ctrl-C cancels continuation and interrupts execution\n";

command('AUTO 25', 'AUTO 25, step 5. AUTO OFF, Ctrl-C, or Ctrl-D ends entry.');
$marker = length $transcript;
send_text('$unfinished_d = {' . "\r\x04");
wait_for(sub { index(substr($transcript, $marker), 'AUTO off.') >= 0 }, 'Ctrl-D ends AUTO');
command('say "after-control-d"', 'after-control-d');
command('STATUS', '3 lines; unsaved changes; ' . $program . '.');

send_text('EVAL do { say "split-enter"; };' . "\e[H" . ("\e[C" x 10) . "\e[13;2u");
wait_for(sub { has_line('EVAL do {') && has_line('say "split-enter"; };') }, 'Shift-Enter splits row');
check(!has_line('split-enter'), 'Shift-Enter submitted instead of inserting');
send_text("\e[27;2;13~\x0e\r");
wait_for(sub { has_line('split-enter') }, 'inserted blank rows remain executable');
command(q{eval { die "caught" }; say $@ =~ /caught/ ? "perl-eval-ok" : "bad"}, 'perl-eval-ok');
print "PASS: Ctrl-D leaves AUTO; Shift-Enter/Ctrl-N insert rows; lowercase eval catches exceptions\n";

command('EVAL $stored_runs++; sub from_eval { return 42 }', 'EVAL $stored_runs++; sub from_eval { return 42 }');
command('say from_eval()', '42');
command('STORE', 'Stored 1 line at 25. Use SAVE to write them.');
command('say "stored-runs:$stored_runs"', 'stored-runs:1');
print "PASS: STORE keeps EVAL source without executing it again\n";

check(index($transcript, 'READY>') < 0, 'legacy prompt appeared');
command('NEW!', 'NEW!');
send_text("\x04");
finish_repl();
print "PASS: Ctrl-D outside AUTO exits cleanly and restores canonical input and echo\n";

($pty, $pid) = start_repl('--plain', '--quiet');
$selector = IO::Select->new($pty);
$view = TerminalView->new(16, 80);
($transcript, $eof, $reaped) = ('', 0, 0);
send_text("AUTO\nsay \"plain-stored\"\nSTATUS\n");
wait_for(sub { index($transcript, 'AUTO next 10, step 5.') >= 0 }, 'plain AUTO stored input');
send_text("\x04");
wait_for(sub { index($transcript, 'AUTO off.') >= 0 }, 'plain Ctrl-D ends AUTO');
send_text("RUN\n");
wait_for(sub { index($transcript, "\r\nplain-stored\r\n") >= 0 }, 'plain session remains usable');
$marker = length $transcript;
send_text("AUTO\n\$unfinished_plain = {\n");
wait_for(sub { index(substr($transcript, $marker), 'AUTO 10, step 5.') >= 0 }, 'plain AUTO restarted');
send_text("\x04");
wait_for(sub { index(substr($transcript, $marker), 'AUTO off.') >= 0 }, 'plain Ctrl-D cancels unfinished AUTO');
send_text("say \"plain-resumed\"\nQUIT!\n");
wait_for(sub { index($transcript, "\r\nplain-resumed\r\n") >= 0 }, 'plain input continues after cancelled block');
finish_repl();
print "PASS: plain-terminal Ctrl-D ends AUTO and cancels unfinished input without exiting\n";

sub finish_repl {
my $deadline = now() + 5;
while (now() < $deadline) {
    my $finished = waitpid($pid, WNOHANG);
    if ($finished == $pid) {
        my $status = $?;
        $reaped = 1;
        check($status == 0, "REPL exited with status $status");
        last;
    }
    die "Cannot wait for REPL: $!\n" if $finished < 0;
    pump_for(0.02);
    sleep(0.02) if $eof;
}
check($reaped, 'REPL did not exit');
my $settings = POSIX::Termios->new;
$settings->getattr(fileno($pty)) or die "Cannot read terminal settings: $!\n";
check(($settings->getlflag & ICANON) && ($settings->getlflag & ECHO), 'terminal not restored');
close $pty;
}
