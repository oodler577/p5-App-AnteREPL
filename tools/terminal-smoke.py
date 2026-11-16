#!/usr/bin/env python3
"""Optional Unix PTY integration checks; Python standard library, Perl, and vi."""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import signal
import struct
import termios
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


class View:
    """Minimal ANSI screen observer for the control sequences this app emits."""
    def __init__(self, height=16, width=80):
        self.height, self.width = height, width
        self.cells = [[' '] * width for _ in range(height)]
        self.row = self.col = 0
        self.pending = ''

    def feed(self, data):
        self.pending += data.decode('utf-8', 'replace')
        while self.pending:
            if self.pending.startswith('\x1b['):
                match = re.match(r'\x1b\[([0-?]*)([ -/]*)([@-~])', self.pending)
                if not match:
                    return
                params, _, command = match.groups()
                numbers = [int(n) if n else 0 for n in params.split(';')] if re.fullmatch(r'[0-9;]*', params) else []
                if command == 'H':
                    self.row = (numbers[0] if numbers and numbers[0] else 1) - 1
                    self.col = (numbers[1] if len(numbers) > 1 and numbers[1] else 1) - 1
                elif command == 'K' and 0 <= self.row < self.height:
                    self.cells[self.row] = [' '] * self.width
                elif command == 'J' and params == '2':
                    self.cells = [[' '] * self.width for _ in range(self.height)]
                self.pending = self.pending[match.end():]
                continue
            if self.pending[0] == '\x1b':
                if len(self.pending) < 2:
                    return
                self.pending = self.pending[2:]
                continue
            char, self.pending = self.pending[0], self.pending[1:]
            if char == '\r':
                self.col = 0
            elif char == '\n':
                self.row += 1
            elif ord(char) >= 32:
                if 0 <= self.row < self.height and 0 <= self.col < self.width:
                    self.cells[self.row][self.col] = char
                self.col += 1

    @property
    def lines(self):
        return [''.join(row).rstrip() for row in self.cells]


pid, fd = pty.fork()
if pid == 0:
    os.chdir(ROOT)
    os.environ['TERM'] = 'xterm'
    os.environ['EDITOR'] = 'vi'
    os.execvp('perl', ['perl', '-Ilib', 'script/anterepl'])

fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 16, 80, 0, 0))
view = View()
transcript = bytearray()


def wait_for(predicate, label, timeout=6):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        if select.select([fd], [], [], min(.05, max(0, deadline - time.monotonic())))[0]:
            data = os.read(fd, 65536)
            transcript.extend(data)
            view.feed(data)
    raise AssertionError(label + '\n' + '\n'.join(view.lines))


def send(text):
    os.write(fd, text.encode('utf-8'))


def command(text, expected_line):
    send(text + '\r')
    wait_for(lambda: expected_line in view.lines, text)


def pump_for(seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if select.select([fd], [], [], max(0, deadline - time.monotonic()))[0]:
            data = os.read(fd, 65536)
            transcript.extend(data)
            view.feed(data)


try:
    wait_for(lambda: '*** BASIC PERL V0.1 ***' in view.lines, 'startup')
    command('10 say "old"', '10 say "old"')
    command('LIST', '10 say "old";')
    send('\x1b[A\x1b[H\x15' + '10 say "new"' + '\r')
    command('RUN', 'new')
    print('PASS: move up into LIST output, edit, resubmit, and RUN')

    with tempfile.TemporaryDirectory(prefix='basic-perl-list-') as directory:
        program = Path(directory) / 'long.bperl'
        program.write_text('# BASIC PERL V0.1\n5 say "low";\n10 say "second";\n'
                           + ''.join(f'{n} say {n};\n' for n in range(20, 401, 10)))
        command(f'LOAD! "{program}"', 'Loaded 41 lines.')
        send('LIST PAUSE\r')
        wait_for(lambda: any(line.startswith('LIST paused') for line in view.lines), 'LIST screenful pause')
        assert '5   say "low";' in view.lines and '10  say "second";' in view.lines, view.lines
        paused = view.lines[:]
        pump_for(.15)
        assert view.lines == paused, 'paused listing kept scrolling'
        old_last = max(int(m.group(1)) for line in view.lines if (m := re.match(r'^(\d+) +say', line)))
        send('\r')
        wait_for(lambda: any(line.startswith(f'{old_last + 10} ') for line in view.lines)
                 and any(line.startswith('LIST paused') for line in view.lines), 'LIST one-line step')
        send('s ')
        wait_for(lambda: any(line.startswith('LIST slow') for line in view.lines), 'LIST slow resume')
        send(' ')
        wait_for(lambda: any(line.startswith('LIST paused') for line in view.lines), 'LIST manual pause')
        send('q')
        wait_for(lambda: not any(line.startswith('LIST paused') for line in view.lines), 'LIST stop')
        command('LIST5-10', '5  say "low";')
        send('\x1b[A\x1b[A\x1b[F\x1b[D\x1b[D\x1b[D!\r')
        command('LIST5', '5 say "lo!";')
        send('LIST SLOW\r')
        wait_for(lambda: any(line.startswith('LIST slow') for line in view.lines), 'LIST slow start')
        send('\x03')
        wait_for(lambda: not any(line.startswith('LIST slow') for line in view.lines), 'LIST Ctrl-C stop')
        command('say "after-list-stop"', 'after-list-stop')
    print('PASS: LIST alignment, ranges, scrolling, pause/resume, slow, step, stop, and padded-row editing')

    send('$FOO = {\rbar => 1,\rnames => [qw(Alice Bob)],\r};\r')
    command('dump $FOO', "          'bar' => 1,")
    command('peek $FOO->{bar}', '  IV = 1')
    print('PASS: multiline structures, dump, and native Devel::Peek output')

    send('print "Name: "; $answer = <STDIN>; chomp $answer; say "Got:$answer";\r')
    wait_for(lambda: 'Name:' in view.lines, 'program input prompt')
    send('Ada\r')
    wait_for(lambda: 'Got:Ada' in view.lines, 'program stdin')
    print('PASS: program prompts and reads a line through the screen')

    command('say $_ for 1..40', '40')
    assert '1' not in view.lines, view.lines
    send('\x1b[5~\x1b[5~')
    wait_for(lambda: '20' in view.lines, 'screen PageUp')
    send('\x1b[1;5F')
    command('! printf "shell-output\\n"', 'shell-output')
    print('PASS: display scrolls upward; PageUp traverses text; shell output returns to screen')

    marker = len(transcript)
    send('!! printf "external-output\\n"\r')
    wait_for(lambda: b'Press Enter to return' in transcript[marker:], 'external shell handoff')
    send('\r')
    wait_for(lambda: b'\x1b[?1049h' in transcript[marker:], 'screen resume after shell')

    marker = len(transcript)
    send('EDIT\r')
    wait_for(lambda: b'program.pl' in transcript[marker:], 'vi opened')
    send(':%d\risay "edited";\x1b:wq\r')
    wait_for(lambda: 'Program updated; lines numbered 10,20,...' in view.lines, 'vi returned')
    command('RUN', 'edited')
    print('PASS: interactive shell and actual vi restore the screen and terminal modes')

    command('AUTO', 'AUTO 15, step 5. AUTO OFF or Ctrl-C ends entry.')
    command('say "auto-line"', '15 say "auto-line";')
    command('AUTO OFF', 'AUTO off.')
    command('say "immediate-again"', 'immediate-again')
    command('AUTO 25', 'AUTO 25, step 5. AUTO OFF or Ctrl-C ends entry.')
    send('$unfinished_auto = {\r')
    wait_for(lambda: '$unfinished_auto = {' in view.lines and view.col == 0
             and not view.lines[view.row], 'AUTO continuation')
    marker = len(transcript)
    send('\x03')
    wait_for(lambda: b'AUTO off.' in transcript[marker:] and b'Interrupted.' in transcript[marker:], 'Ctrl-C ends AUTO')
    command('say "auto-cancelled"', 'auto-cancelled')
    command('LIST 15-', '15 say "auto-line";')
    assert not any(line.startswith('25 ') for line in view.lines), 'unfinished AUTO source stored'
    print('PASS: AUTO numbering, AUTO OFF, and Ctrl-C preserve stored lines')

    command('ENV SET ANTEREPL_SMOKE before', 'ENV SET ANTEREPL_SMOKE before')
    marker = len(transcript)
    send('EDIT ENV\r')
    wait_for(lambda: b'environment.env' in transcript[marker:], 'vi environment opened')
    send(':%s/ANTEREPL_SMOKE=before/ANTEREPL_SMOKE=after/\r:wq\r')
    wait_for(lambda: 'Environment updated.' in view.lines, 'environment vi returned')
    command('ENV ANTEREPL_SMOKE', 'ANTEREPL_SMOKE=after')
    command('! printf "child-env:%s\\n" "$ANTEREPL_SMOKE"', 'child-env:after')
    with tempfile.TemporaryDirectory(prefix='anterepl-env-') as directory:
        command(f'ENV SAVE "{directory}/vars.env"', 'Environment saved.')
        command('ENV SET ANTEREPL_SMOKE changed', 'ENV SET ANTEREPL_SMOKE changed')
        command('ENV RELOAD', 'Environment loaded.')
        command('say "reloaded:$ENV{ANTEREPL_SMOKE}"', 'reloaded:after')
    print('PASS: EDIT ENV uses VAR=value; Perl and child shells see changes; RELOAD restores file')

    send('$incomplete = {\r')
    wait_for(lambda: '$incomplete = {' in view.lines and view.col == 0 and not view.lines[view.row], 'open continuation')
    send('\x03')
    wait_for(lambda: 'Interrupted.' in view.lines, 'cancel incomplete entry')
    command('say "after-cancel"', 'after-cancel')
    marker = len(transcript)
    send('say "running-loop"; while (1) {}\r')
    wait_for(lambda: 'running-loop' in view.lines, 'running loop')
    send('\x03')
    wait_for(lambda: b'Interrupted.' in transcript[marker:], 'interrupt running Perl')
    print('PASS: Ctrl-C cancels continuation and interrupts execution')

    assert b'READY>' not in transcript, 'legacy prompt appeared'
    send('QUIT!\r')
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        finished, status = os.waitpid(pid, os.WNOHANG)
        if finished:
            assert os.waitstatus_to_exitcode(status) == 0, status
            break
        time.sleep(.02)
    else:
        raise AssertionError('REPL did not exit')
    settings = termios.tcgetattr(fd)
    assert settings[3] & termios.ICANON and settings[3] & termios.ECHO, 'terminal not restored'
    print('PASS: no prompt/history UI; clean exit restores canonical input and echo')
finally:
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    os.close(fd)
