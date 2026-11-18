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
sub check { my ($ok, $message) = @_; die "$message (cursor $view->{row},$view->{col})\n" . screen_text() . "\n" unless $ok; }

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

wait_for(sub { has_line('*** PERL ANTE REPL V0.1 ***') }, 'startup');
command('cls', 'REPL commands must be uppercase; use CLS.');
check(has_line('*** PERL ANTE REPL V0.1 ***'), 'wrong-case cls cleared the screen');
check(index($transcript, 'Bareword "cls"') < 0, 'command hint leaked an interpreter diagnostic');
send_text("\x03");
wait_for(sub { has_line('To leave: QUIT, or QUIT! to discard unsaved source.')
    && has_line('Ctrl-D exits when AUTO is off and the source is saved.') }, 'idle Ctrl-C explains exit');
print "PASS: command bareword hints hide interpreter errors; idle Ctrl-C explains how to exit\n";
command('10 say "old"', '10 say "old"');
command('LIST', '10 say "old";');
send_text("\e[A\e[H\x15" . '10 say "new"' . "\r");
command('RUN', 'new');
print "PASS: move up into LIST output, edit, resubmit, and RUN\n";

my $program = File::Spec->catfile($temporary, 'long.bperl');
open my $file, '>:encoding(UTF-8)', $program or die "$program: $!\n";
print {$file} "# PERL ANTE REPL V0.1\n5 say \"low\";\n10 say \"second\";\n",
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
send_text("\e[1;5F");
command('LIST5', '5 say "lo!w";');
send_text("LIST SLOW\r");
wait_for(sub { has_prefix('LIST slow') }, 'LIST slow start');
send_text("\x03");
wait_for(sub { !has_prefix('LIST slow') }, 'LIST Ctrl-C stop');
command('say "after-list-stop"', 'after-list-stop');
print "PASS: LIST alignment, ranges, scrolling, pause/resume, slow, step, stop, and padded-row editing\n";

send_text(join "\r", '$FOO = {', 'bar => 1,', 'names => [qw(Alice Bob)],', '};', '');
command('DUMP $FOO', "          'bar' => 1,");
command('PEEK $FOO->{bar}', '  IV = 1');
print "PASS: multiline structures, dump, and native Devel::Peek output\n";

send_text('print "Name: "; $answer = <STDIN>; chomp $answer; say "Got:$answer";' . "\r");
wait_for(sub { has_line('Name:') }, 'program input prompt');
send_text("Ada\r");
wait_for(sub { has_line('Got:Ada') }, 'program stdin');
print "PASS: program prompts and reads a line through the screen\n";

command('say $_ for 1..40', '40');
check(!has_line('1'), 'display did not scroll upward');
send_text("\e[5~\e[5~");
wait_for(sub { $view->{row} == 0 }, 'PageUp stops at the visible top');
check(!has_line('20') && has_line('40'), 'PageUp recovered discarded screen rows');
send_text("\e[1;5F");
command('! printf "shell-output\\n"', 'shell-output');
print "PASS: display scrolls upward; PageUp stays within visible rows; shell output returns to screen\n";

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
command('say twice 21', '42');
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
wait_for(sub { has_line('To leave: QUIT, or QUIT! to discard unsaved source.') }, 'running Ctrl-C explains exit');
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

check(index($transcript, 'READY>') < 0, 'legacy prompt appeared');
command('NEW!', 'NEW!');
command('CLS', '');
send_text("EVAL sub triple {\r");
wait_for(sub { has_line('EVAL sub triple {') && $view->{row} == 1 && $view->{col} == 0 }, 'typed function first continuation');
send_text("    return 3 * shift;\r");
wait_for(sub { has_line('    return 3 * shift;') && $view->{row} == 2 && $view->{col} == 0 }, 'typed function second continuation');
send_text("}\r");
wait_for(sub { has_line('}') && $view->{row} == 3 && $view->{col} == 0 }, 'typed closing brace returns to blank row');
command('say triple 14', '42');
command('STATUS', '0 lines; unchanged; no save filename.');
my $functions_file = File::Spec->catfile($temporary, 'functions.pl');
command(qq{SAVE "$functions_file"}, "Saved $functions_file.");
open my $saved_function, '<:raw', $functions_file or die "$functions_file: $!\n";
my $function_source = do { local $/; <$saved_function> };
close $saved_function;
check($function_source eq '', 'session-only function leaked into SAVE');
print "PASS: typed EVAL function closes with Enter and stays callable without entering VRAM or SAVE\n";
command('FUNCTIONS', 'triple');
check(has_line('twice'), 'FUNCTIONS omitted an earlier RUN-defined function');
command('EVAL sub triple { return 4 * shift; }', 'Subroutine triple redefined at PERL_ANTE_REPL_prompt line 1.');
command('say triple 14', '56');
print "PASS: FUNCTIONS lists live names and redefinition warns without confirmation\n";
command('RESET', 'Perl workspace reset; program retained.');
command('EVAL sub triple { 3 * shift }', 'EVAL sub triple { 3 * shift }');
send_text("CLS\r");
wait_for(sub { !grep { length } $view->lines }, 'clear screen for resubmission checks');
command('say triple 14', '42');
send_text("\e[A\e[A\e[F\x7f\x7f3\r");
wait_for(sub { has_line('say triple 3') && has_line('9') && $view->{row} == 2 }, 'replace earlier result');
check(!has_line('42'), 'old result remained on screen');
for (1 .. 3) {
    send_text("\e[A\e[A\r");
    pump_for(0.1);
    check(join('|', $view->lines) eq join('|', 'say triple 3', '9', ('') x 14), 'repeated result accumulated rows');
}
command('say "later-result"', 'later-result');
send_text("\e[1;5H\e[F\e[D1\r");
wait_for(sub { has_line('say triple 13') && has_line('39') && $view->{row} == 2
    && ($view->lines)[2] eq 'say "later-result"' }, 'insert into earlier input without a spacer');
check(join('|', $view->lines) eq join('|', 'say triple 13', '39', 'say "later-result"', 'later-result', ('') x 12),
    'replacement inserted a spacer, lost later entries, or left stale output');
send_text("\e[1;5H\e[F\x7f4\r");
wait_for(sub { has_line('say triple 14') && has_line('42') && $view->{row} == 2
    && ($view->lines)[2] eq 'say "later-result"' }, 'prepare exact 14-to-13 edit');
send_text("\e[1;5H\e[F\x7f3\r");
wait_for(sub { has_line('say triple 13') && has_line('39') && $view->{row} == 2
    && ($view->lines)[2] eq 'say "later-result"' }, 'exact 14-to-13 edit without a spacer');
check(join('|', $view->lines) eq join('|', 'say triple 13', '39', 'say "later-result"', 'later-result', ('') x 12),
    '14-to-13 edit added a blank row before the following command');
send_text("\e[1;5F");
wait_for(sub { $view->{row} == 4 && $view->{col} == 0 }, 'Ctrl-End after resubmission');
print "PASS: earlier entries use insert editing and replace results in place while retaining later commands\n";
send_text("\e[D");
wait_for(sub { $view->{row} == 3 && $view->{col} == length('later-result') }, 'Left from blank row to previous end');
send_text("\e[H\e[D");
wait_for(sub { $view->{row} == 2 && $view->{col} == length('say "later-result"') }, 'Left from output to command end');
send_text("\e[1;5H\e[D");
wait_for(sub { $view->{row} == 0 && $view->{col} == 0 }, 'Left stops on first row');
check(has_line('say triple 13') && has_line('39') && has_line('say "later-result"') && has_line('later-result'),
    'Left crossing a row boundary changed screen text');
print "PASS: Left crosses to the previous row end and stops at the first row\n";
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
send_text("\x03");
wait_for(sub { index(substr($transcript, $marker), 'To leave: QUIT, or QUIT!') >= 0 }, 'plain Ctrl-C explains exit');
$marker = length $transcript;
send_text("AUTO\n\$unfinished_plain = {\n");
wait_for(sub { index(substr($transcript, $marker), 'AUTO 10, step 5.') >= 0 }, 'plain AUTO restarted');
send_text("\x04");
wait_for(sub { index(substr($transcript, $marker), 'AUTO off.') >= 0 }, 'plain Ctrl-D cancels unfinished AUTO');
send_text("say \"plain-resumed\"\nQUIT!\n");
wait_for(sub { index($transcript, "\r\nplain-resumed\r\n") >= 0 }, 'plain input continues after cancelled block');
finish_repl();
print "PASS: plain-terminal Ctrl-D ends AUTO and cancels unfinished input without exiting\n";

($pty, $pid) = start_repl();
$selector = IO::Select->new($pty);
$view = TerminalView->new(16, 80);
($transcript, $eof, $reaped) = ('', 0, 0);
wait_for(sub { has_line('*** PERL ANTE REPL V0.1 ***') }, 'resize session startup');
check(index($transcript, 'Screen clipped') < 0, 'initial size detection warned about a resize');
send_text("HELP\r");
wait_for(sub { has_prefix('HELP paused') }, 'HELP pauses on a visible screenful');
send_text('q');
wait_for(sub { !has_prefix('HELP paused') }, 'HELP returns to editing after Q');
send_text("CLS\r");
wait_for(sub { !grep { length } $view->lines }, 'clear HELP before resize exercise');
command('10 say "kept"', '10 say "kept"');
command('$runs = 0; say ++$runs', '1');
my $wide = 'wide:' . ('x' x 60);
command('say "wide:" . ("x" x 60)', $wide);
command('say "row:$_" for 1..10', 'row:10');
# The last printed row may arrive before fresh() adds the blank input row and
# scrolls a full screen. Snapshot only after that final cursor position.
wait_for(sub { $view->{row} == 15 && $view->{col} == 0
    && ($view->lines)[15] eq '' && has_line('row:10') }, 'resize fixture ready for input');
my $original_screen = screen_text();
resize_terminal(10, 40);
wait_for(sub { has_prefix('# Screen clipped; RECOVER') }, 'idle terminal shrink warning');
check(!has_line($wide), 'shrinking retained off-screen columns');
send_text("RECOVER\r");
wait_for(sub { has_prefix('Enlarge the terminal') }, 'recovery refuses a small terminal');
resize_terminal(16, 80);
pump_for(0.3);
check(!has_line($wide), 'growing automatically restored the saved screen');
send_text("RECOVER\r");
wait_for(sub { screen_text() eq $original_screen }, 'explicit recovery restores the bank');
command('? $runs', '1');
command('RUN', 'kept');
send_text("CLS\r");
wait_for(sub { !grep { length } $view->lines }, 'clear before right-edge output');
send_text('say "x" x 95' . "\r");
wait_for(sub { has_line('x' x 80) && has_line('x' x 15) }, 'output wraps at physical width');
resize_terminal(10, 40);
wait_for(sub { has_prefix('# Screen clipped; RECOVER') }, 'second shrink creates a fresh bank');
send_text("CLS\r");
wait_for(sub { !grep { length } $view->lines }, 'CLS discards resize bank');
resize_terminal(16, 80);
pump_for(0.3);
send_text("RECOVER\r");
wait_for(sub { has_prefix('No saved screen.') }, 'CLS bank cannot return');
send_text("QUIT!\r");
finish_repl();
print "PASS: idle resize crops rows/columns, grow stays blank, RECOVER is explicit, and source/workspace survive\n";

for my $command ('QUIT', 'QUIT!', 'EXIT', 'EXIT!') {
    ($pty, $pid) = start_repl();
    $selector = IO::Select->new($pty);
    $view = TerminalView->new(16, 80);
    ($transcript, $eof, $reaped) = ('', 0, 0);
    wait_for(sub { has_line('*** PERL ANTE REPL V0.1 ***') }, "$command startup");
    if ($command =~ /!/) {
        command('10 say "unsaved"', '10 say "unsaved"');
        send_text("QUIT\r");
        wait_for(sub { has_prefix('Unsaved program.') }, 'QUIT keeps unsaved source');
    }
    send_text("$command\r");
    finish_repl();
    check($transcript =~ /\e\[\?1049l\r?\n\z/,
        "$command did not print a newline after restoring the original display");
}
print "PASS: QUIT, QUIT!, EXIT, and EXIT! restore the terminal and finish on a fresh line\n";

sub resize_terminal {
    my ($height, $width) = @_;
    @{$view}{qw(height width)} = ($height, $width);
    $view->clear;
    $pty->set_winsize($height, $width);
}

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
pump_for(0.05); # Drain final terminal restoration and newline before closing.
my $settings = POSIX::Termios->new;
$settings->getattr(fileno($pty)) or die "Cannot read terminal settings: $!\n";
check(($settings->getlflag & ICANON) && ($settings->getlflag & ECHO), 'terminal not restored');
close $pty;
}
