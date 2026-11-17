use 5.016;
use strict;
use warnings;

package App::AnteREPL;

use Data::Dumper ();
use Encode qw(decode encode FB_CROAK);
use File::Basename qw(dirname);
use File::Spec ();
use File::Temp ();
use Text::Balanced qw(extract_quotelike);
use Text::ParseWords qw(shellwords);

our $VERSION = '0.01';
our $PROGRAM_VERSION = '0.1';
my $next_workspace = 0;
my $max_line = 999_999_999;

sub new {
    my ($class) = @_;
    return bless {
        lines     => {},
        saved     => '',
        filename  => undef,
        undo      => [],
        workspace => 'App::AnteREPL::Workspace::S' . ++$next_workspace,
        format    => 'native',
        initial_env => { %ENV },
    }, $class;
}

sub numbers { return sort { $a <=> $b } keys %{ $_[0]->{lines} }; }

sub source {
    my ($self) = @_;
    return join '', map { $self->{lines}{$_} . "\n" } $self->numbers;
}

sub listing {
    my ($self, $range) = @_;
    my ($first, $last) = _range($range);
    return join '', map { $_ . ' ' . $self->{lines}{$_} . "\n" }
        grep { $_ >= $first && $_ <= $last } $self->numbers;
}

sub display_listing {
    my ($self, $range) = @_;
    my ($first, $last) = _range($range);
    my @numbers = grep { $_ >= $first && $_ <= $last } $self->numbers;
    return ('', 0) unless @numbers;
    my $width = length $numbers[-1];
    return (join('', map { sprintf("%-*d %s\n", $width, $_, $self->{lines}{$_}) } @numbers), $width);
}

sub list_program {
    my ($self, $argument) = @_;
    $argument = '' unless defined $argument;
    my $mode = 'normal';
    $mode = lc($1) if $argument =~ s/(?:\A|\s)(SLOW|PAUSE)\s*\z//i;
    $argument =~ s/\A\s+|\s+\z//g;
    $argument =~ s/\s*-\s*/-/g;
    my ($text, $width) = $self->display_listing($argument);
    if ($self->{screen}) {
        $self->{screen}->list_rows([split /\n/, $text], $width, $mode);
    }
    else { print $text; }
}

sub dirty { return $_[0]->listing ne $_[0]->{saved}; }

sub clear_screen {
    my ($self) = @_;
    if ($self->{screen}) { $self->{screen}->clear_display; }
    elsif (-t STDOUT && ($ENV{TERM} || '') ne 'dumb') { print "\e[2J\e[H"; }
}

sub _number {
    my ($number) = @_;
    die "Line numbers must be integers from 1 to $max_line.\n"
        unless defined $number && $number =~ /\A[0-9]+\z/
        && $number >= 1 && $number <= $max_line;
    return 0 + $number;
}

sub _range {
    my ($range) = @_;
    return (1, $max_line) unless defined $range && length $range;
    return (_number($range), _number($range)) if $range =~ /\A[0-9]+\z/;
    die "Use a line number or a range such as 10-50, 10-, or -50.\n"
        unless $range =~ /\A([0-9]*)-([0-9]*)\z/ && (length($1) || length($2));
    my ($lo, $hi) = ($1, $2);
    $lo = length($lo) ? _number($lo) : 1;
    $hi = length($hi) ? _number($hi) : $max_line;
    die "Range starts after it ends.\n" if $lo > $hi;
    return ($lo, $hi);
}

sub _replace {
    my ($self, $lines) = @_;
    my $new = join '', map { $_ . ' ' . $lines->{$_} . "\n" }
        sort { $a <=> $b } keys %$lines;
    return 0 if $new eq $self->listing;
    push @{ $self->{undo} }, { %{ $self->{lines} } };
    shift @{ $self->{undo} } if @{ $self->{undo} } > 50;
    $self->{lines} = { %$lines };
    return 1;
}

sub set_line {
    my ($self, $number, $code, $literal) = @_;
    $number = _number($number);
    my %lines = %{ $self->{lines} };
    if (!defined $code || ($code eq '' && !$literal)) {
        delete $lines{$number};
    }
    else {
        die "A numbered entry must occupy one physical line.\n" if $code =~ /[\r\n\0]/;
        $lines{$number} = $code;
    }
    return $self->_replace(\%lines);
}

sub _typed_source {
    my ($code) = @_;
    return $code unless defined $code && $code =~ /\S/;
    # A small input convenience, not a Perl parser. Number-colon entries bypass
    # this entirely; EDIT, IMPORT, LOAD, and the internal setter remain literal.
    return $code if $code =~ /\A\s*(?:=\w|__(?:DATA|END)__\b)/;
    local $@;
    my ($position, $visible, $body, $comment) = (0, '', $code, '');
    while ($position < length $code) {
        my $rest = substr($code, $position);
        # Consume sigils first, so $#array and special variables such as $#
        # and $" are not mistaken for comments or quoted strings.
        if ($rest =~ /\A([\$\@\%](?:\#?[\p{L}_][\p{L}\p{N}_]*(?:::[\p{L}_][\p{L}\p{N}_]*)*|[0-9]+|[^\w\s{]))/) {
            $position += length $1;
            $visible .= 'V';
            next;
        }
        if ($rest =~ /\A#/) {
            $body = substr($code, 0, $position);
            $comment = $rest;
            last;
        }
        # Protect hashes and punctuation inside ordinary strings and Perl's
        # quote-like operators. Never compile or execute input to classify it.
        my $quoted = $rest =~ /\A['"`]/
            || $rest =~ /\A(?:qq|qw|qx|qr|q|m|s|tr|y)\b\s*(?!=>)[^\w\s]/;
        if ($quoted || $rest =~ /\A\//) {
            my ($literal) = extract_quotelike("$rest", '');
            if (defined $literal && length $literal) {
                $position += length $literal;
                $visible .= 'Q';
                next;
            }
            return $code if $quoted; # An unfinished quote needs literal input.
        }
        if ($rest =~ /\A([\p{L}_][\p{L}\p{N}_]*)/) {
            $visible .= $1;
            $position += length $1;
            next;
        }
        $visible .= substr($code, $position++, 1);
    }
    return $code if $visible =~ /\A\s*\z/;
    return $code if $visible =~ /[;{(\[,]\s*\z/;
    return $code if $visible !~ /(?:\+\+|--)\s*\z/
        && $visible =~ /(?:[=+*\/%.?:&|!~-]|->|\b(?:and|or|xor|not))\s*\z/;
    return $code if $visible =~ /}\s*\z/ && $visible =~ /\A\s*(?:}|{|(?:(?:[\w]+:)\s*)?(?:if|unless|while|until|for|foreach|given|when|default|else|elsif|continue|sub|package|BEGIN|UNITCHECK|CHECK|INIT|END)\b)/;
    $body =~ s/(\s*)\z/;$1/;
    return $body . $comment;
}

sub delete_range {
    my ($self, $range) = @_;
    die "DEL needs a line number or range.\n" unless defined $range && length $range;
    my ($first, $last) = _range($range);
    my %lines = %{ $self->{lines} };
    delete @lines{ grep { $_ >= $first && $_ <= $last } keys %lines };
    return $self->_replace(\%lines);
}

sub renumber {
    my ($self, $start, $step) = @_;
    $start = _number(defined $start ? $start : 10);
    $step  = _number(defined $step ? $step : 10);
    my @old = $self->numbers;
    die "Renumbering would exceed $max_line.\n" if @old && $start + $#old * $step > $max_line;
    my %lines;
    $lines{ $start + $_ * $step } = $self->{lines}{ $old[$_] } for 0 .. $#old;
    return $self->_replace(\%lines);
}

sub undo {
    my ($self) = @_;
    die "Nothing to undo.\n" unless @{ $self->{undo} };
    $self->{lines} = pop @{ $self->{undo} };
    return 1;
}

sub _guard {
    my ($self, $command, $force) = @_;
    die "Unsaved program. Use SAVE, or $command! to discard it.\n" if $self->dirty && !$force;
}

sub clear {
    my ($self, $force) = @_;
    $self->_guard('NEW', $force);
    $self->_replace({});
    $self->{filename} = undef;
    $self->{saved} = '';
    $self->{format} = 'native';
}

sub _read_text {
    my ($path) = @_;
    open my $fh, '<:raw', $path or die "Cannot open '$path': $!\n";
    local $/;
    my $bytes = <$fh>;
    die "Cannot read '$path': $!\n" unless defined $bytes;
    close $fh or die "Cannot close '$path': $!\n";
    my $text = decode('UTF-8', $bytes, FB_CROAK);
    $text =~ s/\A\x{FEFF}//;
    $text =~ s/\r\n/\n/g;
    die "'$path' contains NUL bytes or unsupported bare carriage returns.\n" if $text =~ /[\0\r]/;
    return $text;
}

sub _write_text {
    my ($path, $text) = @_;
    my $fh = File::Temp->new(TEMPLATE => '.basic-perl-XXXXXX', DIR => dirname($path), UNLINK => 1);
    binmode $fh, ':raw' or die "Cannot set file mode: $!\n";
    print {$fh} encode('UTF-8', $text, FB_CROAK) or die "Cannot write '$path': $!\n";
    my $temporary = $fh->filename;
    close $fh or die "Cannot close temporary file for '$path': $!\n";
    if (-e $path) {
        my @stat = stat $path;
        die "Cannot stat '$path': $!\n" unless @stat;
        chmod($stat[2] & 0777, $temporary) or die "Cannot preserve permissions for '$path': $!\n";
    }
    rename $temporary, $path or die "Cannot replace '$path': $!\n";
    return 1;
}

sub save {
    my ($self, $path) = @_;
    $path = $self->{filename} unless defined $path;
    die "SAVE needs a filename, for example SAVE demo.bperl.\n" unless defined $path && length $path;
    my $format = $path =~ /\.pl\z/i ? 'perl' : $path =~ /\.bperl\z/i ? 'native' : $self->{format};
    _write_text($path, $format eq 'perl' ? $self->source : "# BASIC PERL V$PROGRAM_VERSION\n" . $self->listing);
    $self->{filename} = File::Spec->rel2abs($path);
    $self->{format} = $format;
    $self->{saved} = $self->listing;
    return $path;
}

sub load {
    my ($self, $path, $force) = @_;
    $self->_guard('LOAD', $force);
    my $text = _read_text($path);
    if ($text !~ /\A# BASIC PERL\b/ && $path !~ /\.bperl\z/i) {
        my $lines = _source_lines($text);
        $self->_replace($lines);
        $self->{filename} = File::Spec->rel2abs($path);
        $self->{format} = 'perl';
        $self->{saved} = $self->listing;
        return scalar keys %$lines;
    }
    my @records = split /\n/, $text, -1;
    pop @records if @records && $records[-1] eq '';
    die "Not a BASIC PERL V$PROGRAM_VERSION file. Use a .pl filename or IMPORT for ordinary Perl source.\n"
        unless @records && shift(@records) eq "# BASIC PERL V$PROGRAM_VERSION";
    my %lines;
    for my $record (@records) {
        die "Invalid numbered record in '$path'.\n" unless $record =~ /\A([0-9]+)[ \t](.*)\z/;
        my ($number, $code) = (_number($1), $2);
        die "Duplicate line $number in '$path'.\n" if exists $lines{$number};
        $lines{$number} = $code;
    }
    $self->_replace(\%lines);
    $self->{filename} = File::Spec->rel2abs($path);
    $self->{format} = 'native';
    $self->{saved} = $self->listing;
    return scalar keys %lines;
}

sub _source_lines {
    my ($text) = @_;
    my @code = split /\n/, $text, -1;
    pop @code if @code && $code[-1] eq '';
    die "Program has too many lines.\n" if @code * 10 > $max_line;
    my %lines;
    $lines{ ($_ + 1) * 10 } = $code[$_] for 0 .. $#code;
    return \%lines;
}

sub import_source {
    my ($self, $path, $force) = @_;
    $self->_guard('IMPORT', $force);
    my $lines = _source_lines(_read_text($path));
    $self->_replace($lines);
    $self->{filename} = undef;
    $self->{saved} = '';
    $self->{format} = 'native';
    return scalar keys %$lines;
}

sub export_source {
    my ($self, $path) = @_;
    my $prelude = "#!/usr/bin/env perl\nuse 5.016;\nuse strict;\nuse warnings;\nno strict 'vars';\nno warnings 'once';\nuse feature 'say';\n";
    _write_text($path, $prelude . $self->source);
    return $path;
}

sub _edit_text {
    my ($self, $before, $name) = @_;
    my $editor = (defined $ENV{EDITOR} && $ENV{EDITOR} =~ /\S/) ? $ENV{EDITOR}
        : (defined $ENV{VISUAL} && $ENV{VISUAL} =~ /\S/) ? $ENV{VISUAL}
        : $^O eq 'MSWin32' ? 'notepad' : 'vi';
    my @command = shellwords($editor);
    die "EDITOR is empty or has unmatched quotes.\n" unless @command && length $command[0];
    my $directory = File::Temp->newdir('basic-perl-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $path = File::Spec->catfile("$directory", $name);
    _write_text($path, $before);
    # List-form system: editor arguments are supported; no command shell is involved.
    my $status = $self->{screen}
        ? $self->{screen}->external(sub { system { $command[0] } @command, $path }, 0)
        : system { $command[0] } @command, $path;
    die "Cannot start editor '$command[0]': $!; memory unchanged.\n" if $status == -1;
    die "Editor terminated by signal " . ($status & 127) . "; memory unchanged.\n" if $status & 127;
    die "Editor exited with status " . ($status >> 8) . "; memory unchanged.\n" if $status;
    return _read_text($path);
}

sub edit {
    my ($self) = @_;
    my $before = $self->source;
    my $after = $self->_edit_text($before, 'program.pl');
    return 0 if $before eq $after;
    return $self->_replace(_source_lines($after));
}

sub _env_key {
    my ($key) = @_;
    die "Environment names cannot contain whitespace, =, #, quotes, or NUL.\n"
        unless defined $key && $key =~ /\A[^\s=\0#'\"]+\z/;
    return $key;
}

sub env_text {
    my ($values) = @_;
    $values = \%ENV unless defined $values;
    my $text = '';
    for my $key (sort keys %$values) {
        _env_key($key);
        my $value = $values->{$key};
        die "Environment values must be strings without NUL bytes.\n" if !defined $value || ref $value || $value =~ /\0/;
        my $byte_escapes = '';
        if (!utf8::is_utf8($value)) {
            local $@;
            my $decoded = eval { decode('UTF-8', "$value", FB_CROAK) };
            if (defined $decoded) { $value = $decoded; }
            else { $byte_escapes = 1; }
        }
        if ($value !~ /\A[A-Za-z0-9_.\/:\@%+,=-]*\z/) {
            $value =~ s/([\\"])/\\$1/g;
            $value =~ s/\n/\\n/g;
            $value =~ s/\r/\\r/g;
            $value =~ s/\t/\\t/g;
            $value =~ s/([\x01-\x08\x0b\x0c\x0e-\x1f\x7f])/sprintf('\\x%02X', ord $1)/ge;
            $value =~ s/([\x80-\xff])/sprintf('\\x%02X', ord $1)/ge if $byte_escapes;
            $value = '"' . $value . '"';
        }
        $text .= "$key=$value\n";
    }
    return $text;
}

sub _parse_env {
    my ($text) = @_;
    my (%values, $line);
    for my $record (split /\n/, $text) {
        ++$line;
        next if $record =~ /\A\s*(?:#.*)?\z/;
        die "Invalid environment assignment on line $line; use VAR=value.\n"
            unless $record =~ /\A\s*(?:export\s+)?([^\s=]+)\s*=(.*)\z/;
        my ($key, $value) = (_env_key($1), $2);
        die "Duplicate environment name '$key' on line $line.\n" if exists $values{$key};
        $value =~ s/\A\s+|\s+\z//g;
        if ($value =~ /\A"/) {
            die "Invalid quoted value on environment line $line.\n"
                unless $value =~ /\A"((?:[^"\\]|\\.)*)"\s*(?:#.*)?\z/;
            $value = $1;
            $value = encode('UTF-8', $value) if utf8::is_utf8($value);
            my %escape = ('n'=>"\n", 'r'=>"\r", 't'=>"\t", '\\'=>'\\', '"'=>'"');
            $value =~ s/\\(x[0-9A-Fa-f]{2}|[nrt\\"])/exists $escape{$1} ? $escape{$1} : chr(hex(substr($1, 1)))/ge;
        }
        elsif ($value =~ /\A'/) {
            die "Invalid quoted value on environment line $line.\n" unless $value =~ /\A'([^']*)'\s*(?:#.*)?\z/;
            $value = $1;
            $value = encode('UTF-8', $value) if utf8::is_utf8($value);
        }
        else {
            $value =~ s/(?:\A|\s+)#.*\z//;
            $value =~ s/\s+\z//;
            $value = encode('UTF-8', $value) if utf8::is_utf8($value);
        }
        die "NUL is not allowed in environment values (line $line).\n" if $value =~ /\0/;
        $values{$key} = $value;
    }
    return \%values;
}

sub environment {
    my ($self, $tail) = @_;
    my @args = _args($tail, 0, 3, 'ENV [name | SET name value | UNSET name | EDIT | SAVE file | LOAD file | RELOAD | RESET]');
    if (!@args) { print env_text(); return; }
    my $command = uc shift @args;
    if ($command eq 'SET') {
        die "Usage: ENV SET name value\n" unless @args == 2;
        my ($key, $value) = @args;
        _env_key($key);
        die "NUL is not allowed in environment values.\n" if $value =~ /\0/;
        $value = encode('UTF-8', $value) if utf8::is_utf8($value);
        $ENV{$key} = $value;
    }
    elsif ($command eq 'UNSET') {
        die "Usage: ENV UNSET name\n" unless @args == 1;
        delete $ENV{_env_key($args[0])};
    }
    elsif ($command eq 'SAVE') {
        die "Usage: ENV SAVE file\n" unless @args == 1;
        _write_text($args[0], env_text());
        $self->{env_filename} = File::Spec->rel2abs($args[0]);
        print "Environment saved.\n";
    }
    elsif ($command eq 'LOAD' || $command eq 'RELOAD') {
        die "Usage: ENV $command" . ($command eq 'LOAD' ? ' file' : ' [file]') . "\n"
            if @args > 1 || ($command eq 'LOAD' && !@args);
        my $path = @args ? $args[0] : $self->{env_filename};
        die "No environment file yet. Use ENV LOAD file or ENV SAVE file first.\n" unless defined $path;
        my $values = _parse_env(_read_text($path));
        %ENV = %$values;
        $self->{env_filename} = File::Spec->rel2abs($path);
        print "Environment loaded.\n";
    }
    elsif ($command eq 'EDIT') {
        die "Usage: ENV EDIT\n" if @args;
        my $before = env_text();
        my $after = $self->_edit_text($before, 'environment.env');
        my $values = _parse_env($after);
        %ENV = %$values;
        print $before eq $after ? "Environment unchanged.\n" : "Environment updated.\n";
    }
    elsif ($command eq 'RESET') {
        die "Usage: ENV RESET\n" if @args;
        %ENV = %{ $self->{initial_env} };
        print "Startup environment restored.\n";
    }
    else {
        my ($key) = _args($tail, 1, 1, 'ENV name');
        die "Environment name '$key' is not set.\n" unless exists $ENV{$key};
        print env_text({$key => $ENV{$key}});
    }
}

sub auto_mode {
    my ($self, $tail) = @_;
    my @args = _args($tail, 0, 2, 'AUTO [start [step]], AUTO OFF, or AUTO ECHO ON|OFF');
    if (@args && uc($args[0]) eq 'ECHO') {
        die "Usage: AUTO ECHO ON|OFF\n" unless @args == 2 && $args[1] =~ /\A(?:ON|OFF)\z/i;
        $self->{auto_echo} = uc($args[1]) eq 'ON' ? 1 : 0;
        print 'AUTO echo ', ($self->{auto_echo} ? 'on' : 'off'), ".\n";
        return;
    }
    if (@args == 1 && uc($args[0]) eq 'OFF') {
        delete $self->{auto};
        print "AUTO off.\n";
        return;
    }
    my @numbers = $self->numbers;
    my $step = @args > 1 ? _number($args[1]) : 5;
    my $start = @args ? _number($args[0]) : (@numbers ? $numbers[-1] + $step : $step);
    _number($start);
    $start += $step while $start <= $max_line && exists $self->{lines}{$start};
    die "No room for AUTO lines.\n" if $start > $max_line;
    $self->{auto} = { next => $start, step => $step };
    print "AUTO $start, step $step. AUTO OFF, Ctrl-C, or Ctrl-D ends entry.\n";
}

sub auto_store {
    my ($self, $source) = @_;
    die "AUTO source cannot contain NUL bytes or bare carriage returns.\n" if $source =~ /[\r\0]/;
    my $literal = $source =~ s/\A:(?:[ \t])?//;
    my @source = split /\n/, $source, -1;
    # A complete pasted/continued block is already Perl source. Preserve its
    # internal syntax. Single-line input gets the usual semicolon convenience.
    $source[0] = _typed_source($source[0]) if @source == 1 && !$literal;
    my %lines = %{ $self->{lines} };
    my ($next, $step) = @{ $self->{auto} }{qw(next step)};
    my @stored;
    for my $code (@source) {
        $next += $step while $next <= $max_line && exists $lines{$next};
        die "AUTO would exceed $max_line; nothing stored. Use AUTO OFF or choose a new start.\n" if $next > $max_line;
        push @stored, "$next $code\n";
        $lines{$next} = $code;
        $next += $step;
    }
    $self->_replace(\%lines);
    $next += $step while $next <= $max_line && exists $lines{$next};
    if ($next > $max_line) { delete $self->{auto}; }
    else { $self->{auto}{next} = $next; }
    print @stored if $self->{auto_echo};
    print "AUTO off: reached maximum line number.\n" unless $self->{auto};
}

sub input_needs_more {
    my ($self, $source) = @_;
    return 0 if $self->{auto} && $source =~ /\A:/;
    return needs_more($source);
}

sub reset_workspace {
    $_[0]->{workspace} = 'App::AnteREPL::Workspace::S' . ++$next_workspace;
}

sub function_names {
    my ($self) = @_;
    my $package = $self->{workspace} . '::';
    no strict 'refs';
    return sort grep { defined &{ $package . $_ } } keys %{$package};
}

sub evaluate {
    my ($self, $code, $stored) = @_;
    my $label = $stored ? 'BASIC_PERL_program' : 'BASIC_PERL_prompt';
    my $source = "package $self->{workspace};\n#line 1 \"$label\"\n" . $code . "\n";
    my ($value, $error);
    {
        local $SIG{INT} = sub { die "Interrupted.\n" };
        ($value, $error) = App::AnteREPL::Evaluator::evaluate($source);
    }
    if (length $error) {
        if ($stored) {
            my @numbers = $self->numbers;
            $error =~ s{at BASIC_PERL_program line ([0-9]+)}{
                $1 >= 1 && $1 <= @numbers
                    ? 'at stored line ' . $numbers[$1 - 1] . " (source line $1)"
                    : "at program source line $1"
            }ge;
        }
        die $error;
    }
    return $value;
}

sub run {
    my ($self) = @_;
    return $self->evaluate($self->source, 1);
}

sub inspect_value {
    my ($self, $command, $expression) = @_;
    die "$command needs a Perl expression.\n" unless $expression =~ /\S/;
    if ($command eq 'DUMP') {
        local $Data::Dumper::Sortkeys = 1;
        print $self->evaluate("Data::Dumper::Dumper(do { $expression\n })", 0);
        return;
    }
    require Devel::Peek;
    require POSIX;
    # Devel::Peek writes to the native stderr descriptor, bypassing tied Perl
    # handles. Redirect that descriptor temporarily so its output joins VRAM.
    my $temporary = File::Temp->new(UNLINK => 1);
    my $saved = POSIX::dup(2);
    die "Cannot preserve stderr: $!\n" unless defined $saved && $saved >= 0;
    unless (defined POSIX::dup2(fileno($temporary), 2)) {
        POSIX::close($saved);
        die "Cannot capture Devel::Peek output: $!\n";
    }
    $expression =~ s/;\s*\z//;
    my $ok = eval { $self->evaluate("Devel::Peek::Dump($expression\n)", 0); 1 };
    my $error = $@;
    my $restored = POSIX::dup2($saved, 2);
    POSIX::close($saved);
    die "Cannot restore stderr: $!\n" unless defined $restored;
    seek($temporary, 0, 0) or die "Cannot rewind peek output: $!\n";
    local $/;
    my $bytes = <$temporary>;
    print decode('UTF-8', $bytes || '');
    die $error unless $ok;
}

sub needs_more {
    my ($source) = @_;
    # Numbered lines and REPL/file/shell commands keep their own input grammar.
    return 0 if $source =~ /\A\s*(?:[0-9]+(?:[\s:]|\z)|!)/;
    return 0 if $source =~ /\A\s*(?:AUTO|ENV|LIST|RUN|EDIT|DEL|DELETE|RENUM|REORDER|UNDO|SAVE|LOAD|IMPORT|EXPORT|NEW|CLEAR|CLS|RESET|FUNCTIONS|STATUS|HELP|QUIT|EXIT)\b/i;
    my @stack;
    my %close = (')' => '(', ']' => '[', '}' => '{');
    local $@;
    my $position = 0;
    while ($position < length $source) {
        my $rest = substr($source, $position);
        if ($rest =~ /\A\#[^\n]*(?:\n|\z)/ || $rest =~ /\A\s+/) {
            $position += length $&;
            next;
        }
        if ($rest =~ /\A([\$\@\%](?:\#?[\p{L}_][\p{L}\p{N}_]*(?:::[\p{L}_][\p{L}\p{N}_]*)*|[0-9]+|[^\w\s{]))/) {
            $position += length $1;
            next;
        }
        my $quoted = $rest =~ /\A['"`]/
            || $rest =~ /\A(?:qq|qw|qx|qr|q|m|s|tr|y)\b\s*(?!=>)[^\w\s]/;
        if ($quoted || $rest =~ /\A\//) {
            my ($literal) = extract_quotelike("$rest", '');
            if (defined $literal && length $literal) { $position += length $literal; next; }
            return 1 if $quoted;
        }
        if ($rest =~ /\A[\p{L}_][\p{L}\p{N}_]*/) { $position += length $&; next; }
        my $char = substr($source, $position++, 1);
        if ($char =~ /[({\[]/) { push @stack, $char; }
        elsif (exists $close{$char}) {
            return 0 unless @stack && pop(@stack) eq $close{$char}; # Let Perl report a mismatch.
        }
    }
    return @stack ? 1 : 0;
}

sub _args {
    my ($tail, $min, $max, $usage) = @_;
    my @args = shellwords($tail);
    die "Usage: $usage\n" if @args < $min || @args > $max || (length($tail) && !@args);
    return @args;
}

sub help {
    return <<'HELP';
BASIC PERL V0.1 / App::AnteREPL
Commands are case-insensitive except EVAL, which must be uppercase.
Quote filenames and values containing spaces.

ENTERING AND RUNNING PERL
  Perl code             Execute immediately, unless AUTO is active.
  10 Perl code          Insert/replace line 10; supply a missing final ;.
  10: exact source      Store one literal line without adding a semicolon.
  10                    Delete line 10. Numbers range from 1 to 999999999.
  AUTO [start [step]]   Store unnumbered source; default increment is 5.
                        Default start: 5, or highest existing number plus 5.
                        Existing numbers are skipped. Use LIST to see numbers.
  AUTO ECHO ON|OFF      Echo numbered copies of stored entries; default OFF.
                        This preference persists for the session; it does not
                        start/end AUTO. Your typed text remains visible.
  AUTO OFF              End AUTO. Ctrl-C/Ctrl-D during entry also end AUTO,
                        keeping stored lines and cancelling unfinished input.
  : exact source        In AUTO, store a literal line without continuation.
  RUN                   Execute the whole stored program in numerical order.
  EVAL code             Uppercase only: execute Perl, including during AUTO.
                        EVAL leaves AUTO on. AUTO OFF resumes ordinary input.
                        EVAL do { ... } groups multiline code without storing.
                        Lowercase eval keeps Perl's normal eval semantics.
  EVAL sub name { ... } Define a session function without storing source.
                        Immediate code and RUN can call it. SAVE excludes it.
                        Redefining warns by default and replaces the function.
  FUNCTIONS             List defined names in this workspace, alphabetically.
                        Includes imports; excludes other packages and stubs.
                        Works during AUTO; does not execute or store source.
  ? expression          Evaluate in scalar context and display the result.
  DUMP expression       Data::Dumper output: dump $FOO or dump \%ENV.
  PEEK expression       Devel::Peek internals: peek $FOO or peek $FOO, 10.

  Use $x = 1 or our $x for persistent values; my is local to one evaluation.
  say/print display output. RUN shares package variables with immediate input.
  Stored subroutines become callable after RUN; LOAD/LIST do not define them.
  Open quotes, braces, brackets, or parentheses continue on the next row.
  A complete multiline AUTO entry preserves literal source: supply its final ;.
  Numbered and AUTO colon entries stay literal, one physical line at a time.
  Blank input does nothing. Commands remain available during AUTO.
  For heredocs/POD/unusual Perl, use EDIT or literal numbered/colon entries.
  DUMP and PEEK are prompt commands; stored Perl uses the module functions.

LISTING, EDITING, AND RECOVERY
  LIST                  List all source; numbers left-aligned, padded on right.
  LIST 10               List only line 10.
  LIST 10-50            Inclusive range. Also LIST 10-, LIST -50, LIST10-50.
  LIST [range] SLOW     Start slow. PAUSE instead pauses after each screenful.
                        Space: pause/resume; S: speed; Enter: step one row;
                        Q/Esc/Ctrl-C: stop. Other typing/movement ends LIST.
                        Plain/batch mode prints the whole range without pauses.
  EDIT                  Open the program in $EDITOR, then $VISUAL, then vi
                        (notepad on Windows). Editor receives no line numbers.
                        Save and close: changed source becomes 10,20,... .
                        An unchanged file keeps its numbering. EDIT never runs
                        the source; use SAVE afterward to write the real file.
  DEL range             Delete a line/range; DELETE is an alias.
  RENUM [start [step]]  Renumber; defaults are 10 and 10. REORDER is an alias.
  UNDO                  Undo a source edit (last 50), including EDIT or LOAD.
                        No rollback of executed Perl, %ENV, or file writes.
  CLS                   Clear display and retained screen rows; keep the
                        stored program ("VRAM"), variables, %ENV, and AUTO.
                        No output in a pipe or on a dumb terminal.
  NEW / CLEAR           Clear source and its filename; retain Perl variables.
  RESET                 Fresh Perl workspace; retain source and live %ENV.
  STATUS                Line count, save status, filename, and AUTO next/step.

FILES
  LOAD file             Read ordinary Perl or numbered BASIC PERL source.
                        Plain source gets numbers 10,20,... . No execution.
                        .bperl files require a valid native BASIC PERL header.
  IMPORT file           Read plain Perl as an unsaved copy; no save filename.
  SAVE [file]           Save; reuse last SAVE/LOAD filename and format.
                        .pl writes plain source; .bperl writes numbered source.
                        Other extensions retain the current format.
  EXPORT file           Plain Perl plus default pragmas, for standalone use.
                        Initialize any needed variables in the source itself.
  LOAD!, IMPORT!, NEW!, CLEAR!, QUIT!, EXIT!
                        Explicitly discard unsaved source. No other command
                        accepts this ! suffix. SAVE/EXPORT replace their file.

ENVIRONMENT
  ENV [name]            Display %ENV or one variable as sorted VAR=value lines.
  ENV SET name value    Set a literal value; quote spaces, e.g. 'hello world'.
  ENV UNSET name        Remove a variable. ENV SET name "" sets an empty value.
  EDIT ENV / ENV EDIT   Edit %ENV with the same editor, using VAR=value lines.
                        Save and close to replace live %ENV; removing a line
                        unsets it. Invalid input leaves the environment intact.
  ENV SAVE file         Save an environment snapshot.
  ENV LOAD file         Replace the whole environment from a snapshot file.
  ENV RELOAD [file]     Re-read the last ENV SAVE/LOAD file, or the named file.
  ENV RESET             Restore the environment inherited at startup.

  Direct Perl $ENV{NAME} assignments/deletes also work. Changes reach future
  child commands; they cannot change the parent shell or re-read its changes.
  Files allow blank lines, # comments, optional export, and quotes. Single
  quotes are literal; double quotes allow \n, \r, \t, \\, \", and \xHH.
  No $variable, backtick, or command expansion. Duplicate names/NUL are errors.
  Names exclude whitespace, =, #, quotes, and NUL. ENV subcommand names are
  reserved; inspect SET with dump $ENV{SET}. EDIT ENV changes memory;
  ENV SAVE persists it. ENV LOAD/RELOAD replace, rather than merge, %ENV.

SHELL AND EXIT
  ! command             Run a shell command; screen mode captures output with
                        closed stdin. Examples: ! pwd, ! env, ! cat filename.
  !! command            Give an interactive command the real terminal; press
                        Enter afterward to return. Plain mode uses normal I/O.
  chdir '/path'         Perl changes this session's directory; ! cd cannot.
  HELP                  Display this complete reference.
  QUIT / EXIT           Exit; refuse to discard unsaved source without !.
                        Outside AUTO, Ctrl-D also exits if source is saved.

SCREEN KEYS
  Arrows                Move through screen text, including LIST output.
  Enter                 Submit selected row or its complete multiline entry.
                        Rerunning replaces its output directly below the entry;
                        later entries remain. Cursor follows the new result.
                        No blank spacer is added. Esc goes to fresh input.
  Shift-Enter / Ctrl-N   Insert newline at cursor without submitting the entry.
                        Shift-Enter needs a distinct terminal key sequence;
                        use Ctrl-N if it behaves like ordinary Enter.
  Insert                Toggle insert/overwrite; default is insert.
  Backspace / Delete    Remove characters. Tab inserts to a 4-column tab stop.
  Home / End            Start/end of row. PageUp/PageDown traverse screen rows.
  Esc / Ctrl-End        Fresh blank row at bottom. Ctrl-Home: oldest row.
  Ctrl-U / Ctrl-L       Clear current row / redraw screen.
  Ctrl-C                Cancel input/end AUTO, or interrupt running Perl.
  Ctrl-D                End AUTO/cancel input; otherwise exit if source saved.

  No READY prompt or shell history. New output scrolls upward; 5000 rows kept
  this session. Long rows scroll sideways. Wide/combining glyphs may misalign.
  Editing screen text alone changes nothing until Enter. Bracketed paste waits
  for Enter. GUI editors need a wait option, e.g. $ENV{EDITOR} = 'code --wait'.

STARTUP
  anterepl [--quiet] [--plain] [program.pl|program.bperl]
  --quiet               Hide the banner. A startup file is loaded, never run.
  --plain               Plain input; --no-readline is an alias.
  --help / -h           This reference. --version prints application version.
  -- filename           Accept a startup filename beginning with a hyphen.
  Native Windows screen mode needs Term::ReadKey and an ANSI-capable terminal.
  Piped input uses plain mode; errors/incomplete or unsaved input exit nonzero.

More examples: https://github.com/oodler577/p5-App-AnteREPL/wiki
Offline manual: perldoc App::AnteREPL
HELP
}

sub dispatch {
    my ($self, $line) = @_;
    $line =~ s/\r?\n\z//;
    return 1 if $line =~ /\A\s*\z/;
    if ($line =~ /\A\s*LIST(?=[0-9-])(.*?)\s*\z/i) {
        $self->list_program($1);
        return 1;
    }
    if ($line =~ /\A\s*([0-9]+):(?:[ \t]?(.*))?\z/) {
        $self->set_line($1, defined $2 ? $2 : '', 1);
        return 1;
    }
    if ($line =~ /\A\s*([0-9]+)(?:[ \t](.*))?\z/) {
        my ($number, $code) = ($1, $2);
        $self->set_line($number, _typed_source($code));
        return 1;
    }
    if ($line =~ /\A\s*(DUMP|PEEK)\b\s*(.*)\z/is) {
        $self->inspect_value(uc($1), $2);
        return 1;
    }
    if ($line =~ /\A\s*\?\s*(.*)\z/s) {
        my $value = $self->evaluate($1, 0);
        print Data::Dumper->new([$value])->Terse(1)->Indent(1)->Sortkeys(1)->Dump;
        return 1;
    }
    if ($line =~ /\A\s*(!{1,2})\s*(\S.*)\z/) {
        my ($escape, $command) = ($1, $2);
        my @command = $^O eq 'MSWin32' ? ($ENV{COMSPEC} || 'cmd.exe', '/c', $command) : ('/bin/sh', '-c', $command);
        my $status = $self->{screen}
            ? ($escape eq '!!' ? $self->{screen}->external(sub { system @command }, 1) : $self->{screen}->shell(\@command))
            : system @command;
        die "Cannot start shell: $!\n" if $status == -1;
        die "Shell command failed (status $status).\n" if $status;
        return 1;
    }
    if ($line =~ /\A\s*((?i:AUTO|ENV|LIST|RUN|EDIT|DEL|DELETE|RENUM|REORDER|UNDO|SAVE|LOAD|IMPORT|EXPORT|NEW|CLEAR|CLS|RESET|FUNCTIONS|STATUS|HELP|QUIT|EXIT)|EVAL)(!?)(?:\s+(.*?))?\s*\z/s) {
        my ($command, $force, $tail) = (uc($1), $2, defined $3 ? $3 : '');
        die "The ! suffix is only supported by LOAD, IMPORT, NEW, CLEAR, QUIT, and EXIT.\n"
            if $force && $command !~ /\A(?:LOAD|IMPORT|NEW|CLEAR|QUIT|EXIT)\z/;
        if ($command eq 'EVAL') {
            die "EVAL needs Perl code.\n" unless length $tail;
            $self->evaluate($tail, 0);
        }
        elsif ($command eq 'AUTO') { $self->auto_mode($tail); }
        elsif ($command eq 'ENV') { $self->environment($tail); }
        elsif ($command eq 'EDIT' && uc($tail) eq 'ENV') { $self->environment('EDIT'); }
        elsif ($command eq 'LIST') {
            $self->list_program($tail);
        }
        elsif ($command eq 'DEL' || $command eq 'DELETE') {
            my ($range) = _args($tail, 1, 1, 'DEL line-or-range');
            $self->delete_range($range);
        }
        elsif ($command eq 'RENUM' || $command eq 'REORDER') {
            my @args = _args($tail, 0, 2, 'RENUM [start [step]]');
            $self->renumber(@args);
        }
        elsif ($command eq 'SAVE') {
            my ($path) = _args($tail, 0, 1, 'SAVE [file]');
            print 'Saved ', $self->save($path), ".\n";
        }
        elsif ($command eq 'LOAD' || $command eq 'IMPORT') {
            my ($path) = _args($tail, 1, 1, "$command file");
            my $count = $command eq 'LOAD' ? $self->load($path, $force) : $self->import_source($path, $force);
            print "Loaded $count lines.\n";
        }
        elsif ($command eq 'EXPORT') {
            my ($path) = _args($tail, 1, 1, 'EXPORT file');
            print 'Exported ', $self->export_source($path), ".\n";
        }
        else {
            _args($tail, 0, 0, $command);
            if ($command eq 'RUN') { $self->run; }
            elsif ($command eq 'EDIT') {
                print $self->edit ? "Program updated; lines numbered 10,20,...\n" : "Program unchanged.\n";
            }
            elsif ($command eq 'UNDO') { $self->undo; print "Program edit undone.\n"; }
            elsif ($command eq 'CLS') { $self->clear_screen; }
            elsif ($command eq 'NEW' || $command eq 'CLEAR') { $self->clear($force); }
            elsif ($command eq 'RESET') { $self->reset_workspace; print "Perl workspace reset; program retained.\n"; }
            elsif ($command eq 'FUNCTIONS') {
                my @names = $self->function_names;
                print @names ? join('', map { "$_\n" } @names)
                    : "No functions defined in this workspace.\n";
            }
            elsif ($command eq 'STATUS') {
                my @numbers = $self->numbers;
                print scalar(@numbers), ' lines; ', ($self->dirty ? 'unsaved changes' : 'unchanged'),
                    '; ', (defined $self->{filename} ? $self->{filename} : 'no save filename'), ".\n";
                print "AUTO next $self->{auto}{next}, step $self->{auto}{step}.\n" if $self->{auto};
            }
            elsif ($command eq 'HELP') { print help(); }
            elsif ($command eq 'QUIT' || $command eq 'EXIT') {
                $self->_guard('QUIT', $force);
                return 0;
            }
        }
        return 1;
    }
    if ($self->{auto}) { $self->auto_store($line); }
    else { $self->evaluate($line, 0); }
    return 1;
}

sub main {
    my @args = @_;
    my ($quiet, $plain, $filename);
    while (@args) {
        my $arg = shift @args;
        if ($arg eq '--help' || $arg eq '-h') {
            print "Usage: anterepl [--quiet] [--plain] [program.pl|program.bperl]\n\n", help();
            return 0;
        }
        elsif ($arg eq '--version') { print "App::AnteREPL $VERSION (BASIC PERL V$PROGRAM_VERSION)\n"; return 0; }
        elsif ($arg eq '--quiet') { $quiet = 1; }
        elsif ($arg eq '--plain' || $arg eq '--no-readline') { $plain = 1; }
        elsif ($arg eq '--') {
            die "Only one startup file is supported.\n" if defined $filename || @args != 1;
            $filename = shift @args;
        }
        elsif ($arg =~ /^-/ || defined $filename) { die "Usage: anterepl [--quiet] [--plain] [program.bperl]\n"; }
        else { $filename = $arg; }
    }
    binmode STDIN, ':encoding(UTF-8)';
    binmode STDOUT, ':encoding(UTF-8)';
    binmode STDERR, ':encoding(UTF-8)';
    $| = 1;
    my $self = __PACKAGE__->new;
    $self->load($filename, 1) if defined $filename;
    my $interactive = -t STDIN && -t STDOUT;
    if ($interactive && !$plain && ($ENV{TERM} || '') ne 'dumb') {
        my $screen = eval { App::AnteREPL::Screen->terminal };
        if ($screen) { return $screen->session($self, $quiet); }
        print STDERR "Screen editing unavailable: $@";
        print STDERR "Using plain input without a prompt.\n";
    }
    print "*** BASIC PERL V$PROGRAM_VERSION ***\nType HELP for commands.\n" unless $quiet;
    my $had_error = 0;
    while (1) {
        my ($line, $read_ok);
        {
            local $SIG{INT} = sub { die "Interrupted.\n" };
            $read_ok = eval {
                $line = <STDIN>;
                while (defined $line && $self->input_needs_more($line)) {
                    my $next = <STDIN>;
                    if (!defined $next && $interactive && $self->{auto}) {
                        $line = undef;
                        last;
                    }
                    die "Incomplete Perl entry at end of input.\n" unless defined $next;
                    $line .= $next;
                }
                1;
            };
        }
        if (!$read_ok) {
            my $error = $@;
            print STDERR "AUTO off.\n" if delete $self->{auto};
            print STDERR $error;
            $had_error = 1;
            next;
        }
        if (!defined $line) {
            STDIN->clearerr if $interactive;
            if ($interactive && $self->{auto}) {
                $self->auto_mode('OFF');
                next;
            }
            if ($self->dirty) {
                print STDERR "Unsaved program. Use SAVE or QUIT! to discard it.\n";
                if ($interactive) { next; }
                return 1;
            }
            last;
        }
        my $continue;
        my $ok = eval { $continue = $self->dispatch($line); 1 };
        if (!$ok) { print STDERR $@; $had_error = 1; next; }
        last unless $continue;
    }
    return $interactive ? 0 : $had_error;
}

package App::AnteREPL::Screen;
use Encode qw(decode FB_DEFAULT);
use Time::HiRes qw(time);
our $active;

sub new {
    return bless { rows => [{ text => '' }], row => 0, col => 0, top => 0,
        left => 0, width => 80, height => 24, serial => 0, insert => 1 }, $_[0];
}

sub terminal {
    my ($class) = @_;
    my $self = $class->new;
    open $self->{in}, '<&', \*STDIN or die "Cannot duplicate terminal input: $!\n";
    open $self->{out}, '>&', \*STDOUT or die "Cannot duplicate terminal output: $!\n";
    open $self->{err}, '>&', \*STDERR or die "Cannot duplicate terminal errors: $!\n";
    binmode $self->{in}, ':raw';
    binmode $self->{out}, ':encoding(UTF-8)';
    $self->{out}->autoflush(1);
    if (eval { require Term::ReadKey; 1 }) { $self->{backend} = 'readkey'; }
    else {
        die "Install Term::ReadKey for native Windows screen editing (cpanm Term::ReadKey).\n" if $^O eq 'MSWin32';
        require POSIX;
        $self->{backend} = 'posix';
        my $saved = POSIX::Termios->new;
        $saved->getattr(fileno($self->{in})) or die "Cannot read terminal settings: $!\n";
        $self->{saved_term} = $saved;
        my $raw = POSIX::Termios->new;
        $raw->getattr(fileno($self->{in}));
        $raw->setlflag($raw->getlflag & ~(POSIX::ICANON() | POSIX::ECHO() | POSIX::ECHONL()));
        $raw->setiflag($raw->getiflag & ~POSIX::IXON());
        $raw->setcc(POSIX::VMIN(), 1);
        $raw->setcc(POSIX::VTIME(), 0);
        $self->{raw_term} = $raw;
        eval { require 'sys/ioctl.ph'; $self->{winsize} = &TIOCGWINSZ if defined &TIOCGWINSZ; };
    }
    return $self;
}

sub dimensions {
    my ($self) = @_;
    return unless $self->{in};
    my ($width, $height);
    if ($self->{backend} eq 'readkey') {
        ($width, $height) = eval { Term::ReadKey::GetTerminalSize($self->{out}) };
    }
    elsif ($self->{winsize}) {
        my $size = pack('S4', 0, 0, 0, 0);
        ($height, $width) = unpack('S4', $size) if ioctl($self->{in}, $self->{winsize}, $size);
    }
    $self->{width} = $width if $width && $width >= 10;
    $self->{height} = $height if $height && $height >= 3;
}

sub enter {
    my ($self) = @_;
    if ($self->{backend} eq 'readkey') { Term::ReadKey::ReadMode('cbreak', $self->{in}); }
    else { $self->{raw_term}->setattr(fileno($self->{in}), POSIX::TCSANOW()); }
    $self->{entered} = 1;
    $active = $self;
    print {$self->{out}} "\e[?1049h\e[?2004h\e[2J";
    $self->render;
}

sub leave {
    my ($self) = @_;
    return unless delete $self->{entered};
    print {$self->{out}} "\e[?2004l\e[0 q\e[?25h\e[?1049l";
    if ($self->{backend} eq 'readkey') { Term::ReadKey::ReadMode('restore', $self->{in}); }
    else { $self->{saved_term}->setattr(fileno($self->{in}), POSIX::TCSANOW()); }
}

END { eval { $active->leave if $active; }; }

sub fresh {
    my ($self, $bottom) = @_;
    my $in_place = !$bottom && defined $self->{output_row};
    my $row = $in_place ? $self->{output_row} : $#{ $self->{rows} };
    if ($in_place) {
        if (length $self->{rows}[$row]{text}) {
            ++$row;
            push @{ $self->{rows} }, { text => '' } if $row == @{ $self->{rows} };
        }
        elsif ($row < $#{ $self->{rows} }
            && ($self->{rows}[$row]{output_for} || 0) == $self->{output_owner}) {
            # append's final blank row is a cursor position, not a separator.
            # Preserve actual blank output rows and the following entry itself.
            splice @{ $self->{rows} }, $row, 1;
        }
        if ($self->{rows}[$row]{text} eq ''
            && ($self->{rows}[$row]{output_for} || 0) == $self->{output_owner}) {
            $self->{rows}[$row] = { text => '' };
        }
    }
    else {
        push @{ $self->{rows} }, { text => '' } if length $self->{rows}[$row]{text};
        $row = $#{ $self->{rows} };
        $self->{rows}[$row] = { text => '' };
    }
    $self->{row} = $row;
    $self->{col} = 0;
    $self->{left} = 0;
    delete @{$self}{qw(output_row output_owner)};
}

sub start_output {
    my ($self, $first, $last) = @_;
    my $owner = $self->{rows}[$first]{entry_id} || ++$self->{serial};
    for my $index ($first .. $last) {
        $self->{rows}[$index]{entry_id} = $owner;
        delete $self->{rows}[$index]{output_for};
    }
    my $row = $last + 1;
    my $end = $row;
    ++$end while $end < @{ $self->{rows} }
        && ($self->{rows}[$end]{output_for} || 0) == $owner;
    splice @{ $self->{rows} }, $row, $end - $row;
    my $next = $self->{rows}[$row];
    # Reuse a blank input row; preserve subsequent commands and their output.
    unless ($next && $next->{text} eq '' && !$next->{group}
        && !$next->{entry_id} && !$next->{output_for}) {
        splice @{ $self->{rows} }, $row, 0, { text => '' };
    }
    $self->{rows}[$row]{output_for} = $owner;
    @{$self}{qw(row col left output_row output_owner)} = ($row, 0, 0, $row, $owner);
}

sub clear_display {
    my ($self) = @_;
    $self->{rows} = [{ text => '' }];
    @{$self}{qw(row col top left)} = (0, 0, 0, 0);
    delete @{$self}{qw(list_status output_row output_owner)};
    $self->render;
}

sub append {
    my ($self, $text) = @_;
    my $row = defined $self->{output_row} ? $self->{output_row} : $#{ $self->{rows} };
    $text =~ s/\r\n/\n/g;
    $text =~ s/\e\][^\a]*(?:\a|\e\\)//g;
    $text =~ s/\e\[[0-?]*[ -\/]*[\@-~]//g;
    $text =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/?/g;
    for my $part (split /(\n|\r|\t)/, $text) {
        if ($part eq "\n") {
            my $next = { text => '' };
            $next->{output_for} = $self->{output_owner} if $self->{output_owner};
            splice @{ $self->{rows} }, ++$row, 0, $next;
        }
        elsif ($part eq "\r") { $self->{rows}[$row]{text} = ''; }
        elsif ($part eq "\t") { $self->{rows}[$row]{text} .= ' ' x (8 - length($self->{rows}[$row]{text}) % 8); }
        else { $self->{rows}[$row]{text} .= $part; }
    }
    if (@{ $self->{rows} } > 5000) {
        my $excess = @{ $self->{rows} } - 5000;
        # Keep the most recent output row as well as the cursor when rerunning
        # near the oldest retained rows; LIST attaches padding to that row.
        my $keep = $row > 0 ? $row - 1 : 0;
        my $head = $excess < $keep ? $excess : $keep;
        splice @{ $self->{rows} }, 0, $head;
        $row -= $head;
        $self->{top} = $self->{top} > $head ? $self->{top} - $head : 0;
        splice @{ $self->{rows} }, 5000 if @{ $self->{rows} } > 5000;
    }
    $self->{output_row} = $row if defined $self->{output_row};
    $self->{row} = $row;
    $self->{col} = length $self->{rows}[$row]{text};
    $self->{left} = 0;
    $self->render if $self->{entered};
}

sub render {
    my ($self) = @_;
    return unless $self->{entered};
    $self->dimensions;
    my ($h, $w) = ($self->{height}, $self->{width} - 1);
    $self->{top} = $self->{row} if $self->{row} < $self->{top};
    $self->{top} = $self->{row} - $h + 1 if $self->{row} >= $self->{top} + $h;
    $self->{left} = $self->{col} if $self->{col} < $self->{left};
    $self->{left} = $self->{col} - $w + 1 if $self->{col} >= $self->{left} + $w;
    my $frame = "\e[?25l\e[H";
    for my $offset (0 .. $h - 1) {
        my $row = $self->{rows}[ $self->{top} + $offset ];
        my $text = $row ? $row->{text} : '';
        $text = $self->{list_status} if $self->{list_status}
            && $self->{top} + $offset == $self->{row} && $text eq '';
        $text = length($text) > $self->{left} ? substr($text, $self->{left}, $w) : '';
        $frame .= "\e[" . ($offset + 1) . ";1H\e[2K" . $text;
    }
    $frame .= "\e[" . ($self->{row} - $self->{top} + 1) . ';' . ($self->{col} - $self->{left} + 1) . 'H';
    $frame .= $self->{insert} ? "\e[6 q" : "\e[2 q";
    print {$self->{out}} $frame, ($self->{list_status} ? '' : "\e[?25h");
}

sub list_rows {
    my ($self, $rows, $width, $mode) = @_;
    return unless @$rows;
    $self->dimensions;
    my $controlled = @$rows > $self->{height} - 1 || $mode ne 'normal';
    my ($slow, $paused, $stop, $page_count) = ($mode eq 'slow', 0, 0, 0);
    local $SIG{INT} = sub { $stop = 1 };
    my $ok = eval {
        LINE: for my $index (0 .. $#$rows) {
            last if $stop;
            $self->{list_status} = 'LIST ' . ($slow ? 'slow' : 'normal') . ' | Space pause | S speed | Q stop' if $controlled;
            $self->append($rows->[$index] . "\n");
            # Remember which spaces belong to LIST's number column so editing
            # and resubmitting a listed row never accumulates source indentation.
            $self->{rows}[$self->{row} - 1]{list_width} = $width;
            ++$page_count;
            next if !$controlled || $index == $#$rows;
            $paused = 1 if $mode eq 'pause' && $page_count >= $self->{height} - 1;
            my $until = time + ($slow ? 0.25 : 0.03);
            while (!$stop) {
                $self->{list_status} = $paused
                    ? 'LIST paused | Space resume | Enter step | S speed | Q stop'
                    : 'LIST ' . ($slow ? 'slow' : 'normal') . ' | Space pause | S speed | Q stop';
                $self->render;
                my $remaining = $until - time;
                last if !$paused && $remaining <= 0;
                my $key = $self->key($paused ? 0.1 : $remaining);
                next if !ref($key) && $key eq 'NONE';
                if ((!ref($key) && $key =~ /\A(?:CANCEL|EOF|ESC)\z/) || (ref($key) && $key->[0] eq 'TEXT' && $key->[1] =~ /\A[qQ]\z/)) {
                    $stop = 1;
                    last;
                }
                if (ref($key) && $key->[0] eq 'TEXT' && $key->[1] eq ' ') {
                    $paused = !$paused;
                    $page_count = 0 unless $paused;
                }
                elsif (ref($key) && $key->[0] eq 'TEXT' && $key->[1] =~ /\A[sS]\z/) { $slow = !$slow; }
                elsif (!ref($key) && $key eq 'ENTER') { $paused = 1; $page_count = 0; next LINE; }
                else {
                    # A new command or a cursor movement ends LIST and is
                    # handed back to the editor, rather than eating typed input.
                    push @{ $self->{pending_keys} }, $key;
                    last LINE;
                }
                $until = time + ($slow ? 0.25 : 0.03);
            }
        }
        1;
    };
    my $error = $@;
    delete $self->{list_status};
    $self->{out}->clearerr if $self->{out};
    $self->render;
    die $error unless $ok;
}

sub byte {
    my ($self, $timeout) = @_;
    # ReadKey's Unix timed read can fall through to blocking getc when a
    # signal interrupts select. Use interruptible byte reads on Unix even
    # when ReadKey handles terminal modes; Windows needs its keyboard API.
    if ($self->{backend} eq 'readkey' && $^O eq 'MSWin32') {
        return Term::ReadKey::ReadKey(defined $timeout ? $timeout : 0, $self->{in});
    }
    if (defined $timeout) {
        my $set = '';
        vec($set, fileno($self->{in}), 1) = 1;
        return undef unless select($set, undef, undef, $timeout) > 0;
    }
    my $count = sysread($self->{in}, my $char, 1);
    return undef unless $count;
    return $char;
}

sub key {
    my ($self, $timeout) = @_;
    return shift @{ $self->{pending_keys} } if $self->{pending_keys} && @{ $self->{pending_keys} };
    my $char = $self->byte($timeout);
    return defined $timeout ? 'NONE' : 'EOF' unless defined $char;
    if ($char eq "\e") {
        my $next = $self->byte(0.08);
        return 'ESC' unless defined $next;
        return 'ESC' unless $next eq '[' || $next eq 'O';
        my $sequence = $next;
        while (length $sequence < 20) {
            my $part = $self->byte(0.08);
            last unless defined $part;
            $sequence .= $part;
            last if $part =~ /[A-Za-z~]/;
        }
        my %keys = ('[A'=>'UP', '[B'=>'DOWN', '[C'=>'RIGHT', '[D'=>'LEFT',
            'OA'=>'UP', 'OB'=>'DOWN', 'OC'=>'RIGHT', 'OD'=>'LEFT',
            '[H'=>'HOME', '[F'=>'END', 'OH'=>'HOME', 'OF'=>'END',
            '[1~'=>'HOME', '[4~'=>'END', '[7~'=>'HOME', '[8~'=>'END',
            '[2~'=>'INSERT', '[3~'=>'DELETE', '[5~'=>'PAGEUP', '[6~'=>'PAGEDOWN',
            '[1;5H'=>'TOP', '[1;5F'=>'BOTTOM', '[27;2;13~'=>'NEWLINE');
        # CSI-u Shift+Enter, including key press/repeat event forms. Ignore
        # release events. No terminal-wide keyboard protocol is enabled here.
        return 'NEWLINE' if $sequence =~ /\A\[13;2(?::[12])?u\z/;
        if ($sequence eq '[200~') {
            my $paste = '';
            while ($paste !~ /\e\[201~\z/) {
                my $byte = $self->byte;
                last unless defined $byte;
                $paste .= $byte;
            }
            $paste =~ s/\e\[201~\z//;
            $paste = decode('UTF-8', $paste, FB_DEFAULT) unless utf8::is_utf8($paste);
            $paste =~ s/\r\n?/\n/g;
            $paste =~ s/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]//g;
            return ['PASTE', $paste];
        }
        return $keys{$sequence} || 'IGNORE';
    }
    my %control = ("\r"=>'ENTER', "\n"=>'ENTER', "\x7f"=>'BACKSPACE', "\x08"=>'BACKSPACE',
        "\x03"=>'CANCEL', "\x04"=>'ENDINPUT', "\x0e"=>'NEWLINE',
        "\x15"=>'CLEAR', "\x0c"=>'REDRAW', "\t"=>'TAB');
    return $control{$char} if exists $control{$char};
    return 'IGNORE' if ord($char) < 32;
    if (!utf8::is_utf8($char) && ord($char) >= 128) {
        my $count = ord($char) < 224 ? 2 : ord($char) < 240 ? 3 : 4;
        for (2 .. $count) { my $byte = $self->byte(0.2); last unless defined $byte; $char .= $byte; }
        $char = decode('UTF-8', $char, FB_DEFAULT);
    }
    return ['TEXT', $char];
}

sub edit_key {
    my ($self, $key) = @_;
    my $row = $self->{rows}[ $self->{row} ];
    if (ref $key) {
        my $text = $key->[1];
        if ($key->[0] eq 'PASTE' && $text =~ /\n/) {
            my $group = $row->{group} || ++$self->{serial};
            my $before = substr($row->{text}, 0, $self->{col});
            my $after = substr($row->{text}, $self->{col});
            my @parts = split /\n/, $before . $text . $after, -1;
            my %owner = map { exists $row->{$_} ? ($_ => $row->{$_}) : () } qw(entry_id output_for);
            splice @{ $self->{rows} }, $self->{row}, 1, map { {text=>$_, group=>$group, %owner} } @parts;
            $self->{row} += $#parts;
            $self->{col} = length($parts[-1]) - length($after);
        }
        else {
            my $replace = $self->{insert} || $key->[0] eq 'PASTE' ? 0 : length $text;
            substr($row->{text}, $self->{col}, $replace, $text);
            $self->{col} += length $text;
        }
    }
    elsif ($key eq 'UP' || $key eq 'DOWN' || $key eq 'PAGEUP' || $key eq 'PAGEDOWN') {
        my $delta = $key =~ /PAGE/ ? $self->{height} - 1 : 1;
        $delta = -$delta if $key eq 'UP' || $key eq 'PAGEUP';
        $self->{row} += $delta;
        $self->{row} = 0 if $self->{row} < 0;
        $self->{row} = $#{ $self->{rows} } if $self->{row} > $#{ $self->{rows} };
        my $length = length $self->{rows}[ $self->{row} ]{text};
        $self->{col} = $length if $self->{col} > $length;
    }
    elsif ($key eq 'LEFT') { --$self->{col} if $self->{col} > 0; }
    elsif ($key eq 'RIGHT') { ++$self->{col} if $self->{col} < length $row->{text}; }
    elsif ($key eq 'HOME') { $self->{col} = 0; }
    elsif ($key eq 'END') { $self->{col} = length $row->{text}; }
    elsif ($key eq 'TOP') { $self->{row} = $self->{col} = 0; }
    elsif ($key eq 'BOTTOM' || $key eq 'ESC') { $self->fresh(1); }
    elsif ($key eq 'INSERT') { $self->{insert} = !$self->{insert}; }
    elsif ($key eq 'BACKSPACE') { substr($row->{text}, --$self->{col}, 1, '') if $self->{col} > 0; }
    elsif ($key eq 'DELETE') { substr($row->{text}, $self->{col}, 1, '') if $self->{col} < length $row->{text}; }
    elsif ($key eq 'CLEAR') { $row->{text} = ''; delete $row->{list_width}; $self->{col} = 0; }
    elsif ($key eq 'NEWLINE') { $self->edit_key(['PASTE', "\n"]); }
    elsif ($key eq 'TAB') { $self->edit_key(['TEXT', ' ' x (4 - $self->{col} % 4)]); }
}

sub entry {
    my ($self) = @_;
    my ($first, $last) = ($self->{row}, $self->{row});
    my $group = $self->{rows}[$first]{group};
    if (defined $group) {
        --$first while $first > 0 && ($self->{rows}[$first - 1]{group} || 0) == $group;
        ++$last while $last < $#{ $self->{rows} } && ($self->{rows}[$last + 1]{group} || 0) == $group;
    }
    my $text = join("\n", map { $self->{rows}[$_]{text} } $first .. $last);
    if ($first == $last && $self->{rows}[$first]{list_width}) {
        my $width = $self->{rows}[$first]{list_width};
        if (length($text) > $width && substr($text, $width, 1) eq ' '
            && substr($text, 0, $width) =~ /\A([0-9]+) *\z/) {
            $text = $1 . ' ' . substr($text, $width + 1);
        }
    }
    return ($text, $first, $last);
}

sub read_entry {
    my ($self) = @_;
    while (1) {
        $self->render;
        my $key = $self->key;
        if (!ref($key) && $key eq 'ENTER') {
            my ($text, $first, $last) = $self->entry;
            if ($self->{repl} ? $self->{repl}->input_needs_more($text) : App::AnteREPL::needs_more($text)) {
                my $group = $self->{rows}[$first]{group} || ++$self->{serial};
                $self->{rows}[$_]{group} = $group for $first .. $last;
                # Editing an earlier row of a complete entry must not insert a
                # second copy; incomplete entries continue after their last row.
                splice @{ $self->{rows} }, $last + 1, 0, {text=>'', group=>$group};
                $self->{row} = $last + 1;
                $self->{col} = 0;
                next;
            }
            $self->start_output($first, $last);
            return $text;
        }
        if (!ref($key) && $key eq 'ENDINPUT') {
            if ($self->{repl} && $self->{repl}{auto}) {
                $self->fresh(1);
                return 'AUTO OFF';
            }
            return undef;
        }
        if (!ref($key) && $key eq 'EOF') { return undef; }
        if (!ref($key) && $key eq 'CANCEL') { die "Interrupted.\n"; }
        $self->edit_key($key);
    }
}

sub read_data {
    my ($self) = @_;
    my $row = defined $self->{output_row} ? $self->{output_row} : $#{ $self->{rows} };
    $self->{row} = $row;
    my $start = length $self->{rows}[$row]{text};
    $self->{col} = $start;
    while (1) {
        $self->render;
        my $key = $self->key;
        if (!ref($key) && $key eq 'ENTER') {
            my $value = substr($self->{rows}[$row]{text}, $start);
            $self->append("\n");
            return "$value\n";
        }
        return undef if !ref($key) && ($key eq 'EOF' || $key eq 'ENDINPUT');
        die "Interrupted.\n" if !ref($key) && $key eq 'CANCEL';
        if (ref $key) { $key->[1] =~ s/\n/ /g; $self->edit_key($key); }
        elsif ($key eq 'LEFT' || $key eq 'BACKSPACE') { $self->edit_key($key) if $self->{col} > $start; }
        elsif ($key eq 'HOME') { $self->{col} = $start; }
        elsif ($key =~ /\A(?:RIGHT|END|DELETE|INSERT|TAB)\z/) { $self->edit_key($key); }
    }
}

sub external {
    my ($self, $code, $pause) = @_;
    $self->leave;
    my $status;
    my $ok = eval {
        local *STDIN;
        local *STDOUT;
        local *STDERR;
        open STDIN, '<&', $self->{in} or die $!;
        open STDOUT, '>&', $self->{out} or die $!;
        open STDERR, '>&', $self->{err} or die $!;
        $status = $code->();
        if ($pause) { print STDOUT "\nPress Enter to return to BASIC PERL."; scalar <STDIN>; }
        1;
    };
    my $error = $@;
    $self->enter;
    die $error unless $ok;
    return $status;
}

sub shell {
    my ($self, $command) = @_;
    require POSIX;
    my $file = File::Temp->new(UNLINK => 1);
    open my $null, '<', File::Spec->devnull or die $!;
    my @saved = map { POSIX::dup($_) } 0 .. 2;
    die "Cannot preserve shell file descriptors: $!\n" if grep { !defined $_ || $_ < 0 } @saved;
    my ($status, $error);
    eval {
        for my $fd (0 .. 2) {
            my $target = $fd ? fileno($file) : fileno($null);
            die "Cannot redirect shell descriptor $fd: $!\n" unless defined POSIX::dup2($target, $fd);
        }
        $status = system @$command;
        1;
    } or $error = $@;
    for my $fd (0 .. 2) { POSIX::dup2($saved[$fd], $fd); POSIX::close($saved[$fd]); }
    seek($file, 0, 0) or die $!;
    local $/;
    my $bytes = <$file>;
    $self->append(decode('UTF-8', $bytes || '', FB_DEFAULT));
    die $error if defined $error;
    return $status;
}

sub session {
    my ($self, $repl, $quiet) = @_;
    $repl->{screen} = $self;
    local $self->{repl} = $repl;
    $self->enter;
    my $ok = eval {
        local $SIG{TERM} = sub { die "Terminated.\n" };
        local $SIG{HUP} = sub { die "Terminal disconnected.\n" } unless $^O eq 'MSWin32';
        local *STDOUT;
        local *STDERR;
        local *STDIN;
        tie *STDOUT, 'App::AnteREPL::ScreenOutput', $self;
        tie *STDERR, 'App::AnteREPL::ScreenOutput', $self;
        tie *STDIN, 'App::AnteREPL::ScreenInput', $self;
        print "*** BASIC PERL V$App::AnteREPL::PROGRAM_VERSION ***\nType HELP for commands.\n" unless $quiet;
        while (1) {
            my $line;
            my $read_ok;
            {
                local $SIG{INT} = sub { die "Interrupted.\n" };
                $read_ok = eval { $line = $self->read_entry; 1 };
            }
            if (!$read_ok) {
                my $error = $@;
                $self->{out}->clearerr;
                $self->fresh(1);
                print STDERR "AUTO off.\n" if delete $repl->{auto};
                print STDERR $error;
                next;
            }
            if (!defined $line) {
                if ($repl->dirty) { $self->fresh(1); print STDERR "Unsaved program. Use SAVE or QUIT!.\n"; next; }
                last;
            }
            my $continue;
            my $ran = eval { $continue = $repl->dispatch($line); 1 };
            if (!$ran) { print STDERR $@; }
            elsif (!$continue) { last; }
            $self->fresh;
        }
        1;
    };
    my $error = $@;
    $self->leave;
    delete $repl->{screen};
    die $error unless $ok;
    return 0;
}

package App::AnteREPL::ScreenOutput;
sub TIEHANDLE { bless { screen => $_[1] }, $_[0] }
sub PRINT { my $self = shift; $self->{screen}->append(join(defined $, ? $, : '', @_) . (defined $\ ? $\ : '')); return 1; }
sub PRINTF { my ($self, $format, @args) = @_; $self->{screen}->append(sprintf $format, @args); return 1; }
sub WRITE { my ($self, $buffer, $length, $offset) = @_; my $part = substr($buffer, $offset || 0, $length); $self->{screen}->append($part); return length $part; }
sub FILENO { fileno $_[0]->{screen}{out} }
sub BINMODE { 1 }
sub CLOSE { 1 }

package App::AnteREPL::ScreenInput;
sub TIEHANDLE { bless { screen => $_[1] }, $_[0] }
sub READLINE { $_[0]->{screen}->read_data }
sub FILENO { fileno $_[0]->{screen}{in} }
sub BINMODE { 1 }
sub CLOSE { 1 }

# Keep REPL internals and their lexical variables out of the user's evaluation.
package App::AnteREPL::Evaluator;
use strict;
use warnings;
no strict 'vars';
no warnings 'once';
use feature 'say';

sub evaluate {
    local $@;
    return (scalar(eval $_[0]), $@);
}

1;

__END__

=head1 NAME

App::AnteREPL - BASIC-style program editing with real Perl execution

=head1 SYNOPSIS

    anterepl

    $name = 'world';
    10 say "Hello, $name";
    LIST
    10 say "Hello, $name";
    RUN
    Hello, world
    EDIT
    SAVE hello.bperl
    QUIT

=head1 DESCRIPTION

App::AnteREPL installs the C<anterepl> executable, with the banner
C<*** BASIC PERL V0.1 ***>. It combines
immediate Perl execution with an in-memory program indexed by line numbers.
It requires Perl 5.16 or newer. Type HELP for the command reference.

Install from a release archive with C<cpanm ./App-AnteREPL-0.01.tar.gz>, or
run C<perl Makefile.PL>, C<make test>, and C<make install> in the distribution.
For development without installation, use C<perl -Ilib script/anterepl>.

Numbers are editing addresses, not BASIC labels. RUN concatenates the stored
lines in numeric order and evaluates them together, so blocks, subroutines,
multiline strings, and heredocs work. Stored syntax/runtime errors report the
corresponding numbered line when Perl supplies its source location.

=head1 AUTO ENTRY

AUTO lets you enter program source without typing editing numbers:

    AUTO
    say "hi"
    say "there!"
    AUTO OFF
    LIST
    5  say "hi";
    10 say "there!";

The default increment is 5. With an existing program, AUTO starts 5 past its
highest number. C<AUTO 100> chooses a start; C<AUTO 100 10> also chooses a step.
Occupied numbers are skipped, so AUTO never silently overwrites stored lines.
Explicitly numbered entries still edit or delete the indicated line.

AUTO OFF returns to immediate execution. Ctrl-C or Ctrl-D while entering text
also ends AUTO and discards only the unfinished entry, retaining stored source.
Ctrl-D leaves the REPL running when AUTO is active. In plain terminal mode,
use Ctrl-D on an empty physical input line; piped EOF still ends batch input.
Blank entries do nothing. LIST,
RUN, EDIT, SAVE, ENV, and other commands remain available; C<EVAL code> executes
immediately while AUTO is active. STATUS shows the next number and step.

Single-line entries get the usual implicit semicolon. Open delimiters continue
onto subsequent rows, just as in immediate mode; the complete multiline entry
is stored together, preserving its literal source and requiring its own final
semicolon. Each physical line receives a number. A multiline paste is also
stored together; UNDO reverses the entire entry. C<: exact source> stores one
literal line without continuation or an inserted terminator, useful for heredoc
contents and other unusual syntax. AUTO does not echo a second, numbered copy
by default; use LIST to see assigned numbers. C<AUTO ECHO ON> enables those
copies; C<AUTO ECHO OFF> disables them. This preference lasts for the session
and does not start or stop AUTO. Typed screen text and AUTO status/error
messages remain visible.

=head1 SESSION-ONLY FUNCTIONS

Use a named subroutine to install a function in the current REPL workspace's
symbol table without adding its definition to the numbered program:

    AUTO OFF
    EVAL sub triple {
        return 3 * shift;
    }
    say triple(14)

Press ordinary Enter after the closing brace. The definition prints nothing;
the next entry calls it and prints 42. EVAL also works while AUTO is active,
but leaves AUTO on. Use C<? triple(14)> for an immediate call during AUTO.

The function lives in the workspace package of this Perl process. It is
callable by immediate input and RUN, but does not appear in LIST or SAVE.
CLS and NEW/CLEAR retain it. RESET selects a fresh workspace where that name
is no longer defined. Here "session-only" does not mean Perl's C<local> keyword
or a lexical C<my sub>; it is a normal named package subroutine.

To persist a definition deliberately, enter its source as numbered lines,
through AUTO, or through EDIT, then SAVE the program. There is no automatic
copying of evaluated source into the program or session serialization.

=head2 Listing functions

C<FUNCTIONS> prints defined function names in the current workspace, one per
line in alphabetical order. It includes imported functions and aliases in that
package, but excludes other packages, forward declarations without a body,
and anonymous functions held only in variables. An empty workspace reports
C<No functions defined in this workspace.> The command is case-insensitive,
takes no arguments, and works during AUTO without storing or executing source.
Definitions in numbered source appear only after RUN installs them.

=head2 Redefining functions and running setup code

Statements outside a subroutine body run once each time the EVAL entry is
submitted. The named subroutine remains available afterward. For example:

    EVAL do {
        $setups++;
        sub triple { return 3 * shift; }
    }
    FUNCTIONS
    say triple(14)

Defining C<triple> again replaces the function used by subsequent calls and
normally prints Perl's C<Subroutine triple redefined> warning. There is no
confirmation prompt. Existing code references, such as C<$old = \&triple>,
still call the previous body. Perl warning controls such as
C<no warnings 'redefine'> apply within the entry as usual.

Evaluation is not transactional: named subroutines are installed at compile
time, so a later runtime exception does not undo their definitions or other
side effects already performed.

=head1 ENVIRONMENT

    ENV
    ENV PATH
    ENV SET GREETING 'hello world'
    ENV UNSET GREETING
    EDIT ENV
    ENV SAVE session.env
    ENV LOAD session.env
    ENV RELOAD
    ENV RESET

ENV displays the current process environment as sorted C<VAR=value> lines.
Direct Perl changes such as C<$ENV{FOO} = 'bar'> and C<delete $ENV{FOO}> are also
visible. Changes affect subsequent Perl evaluations and child shell commands.
They do not change the parent shell. RESET alone resets only Perl variables;
ENV RESET restores the environment captured when AnteREPL started.

EDIT ENV (also ENV EDIT) opens a private temporary C<environment.env> in the
same editor as EDIT. Save and close it to replace the live environment.
Deleting a variable's line unsets it; an empty file clears the environment.
Invalid input or an unsuccessful editor exit leaves the environment unchanged.
Program source and its UNDO stack are separate from environment edits.

ENV SAVE writes a snapshot. ENV LOAD replaces the whole environment from a
file; it does not merge. ENV RELOAD re-reads the last successfully loaded or
saved environment file, or an explicitly supplied filename. EDIT ENV changes
memory only; ENV SAVE writes those changes to disk. No command can re-read
later changes made in the parent shell; save a file there and ENV LOAD it.

The file format is ordinary C<VAR=value>, with optional C<export> prefixes,
blank lines, and C<#> comments. Unquoted values have outer whitespace removed;
a hash preceded by whitespace starts a comment. Single-quoted values are
literal. Double-quoted values support C<\\n>, C<\\r>, C<\\t>, C<\\\\>, C<\\">,
and C<\\xHH>. Quotes preserve leading/trailing spaces and hashes. UTF-8 text
is supported, with byte escapes for non-UTF-8 values. Duplicate names and NUL
values are rejected. Names cannot contain whitespace, equals signs, hashes,
quotes, or NUL. Values are never expanded: dollar signs, command substitutions,
and backticks remain data. ENV SET uses shell-style argument quoting, also
without expansion; single quotes are useful for Windows backslash paths.

    EDITOR=vim
    GREETING="hello world"
    LITERAL='$HOME stays literal'

ENV subcommand names are reserved after ENV. Inspect a variable called SET,
for example, with C<dump $ENV{SET}>.

=head1 LISTING PROGRAMS

LIST left-aligns the line numbers and pads on their right, so the Perl source
starts in one column. The column width follows the largest number in the
selected range. This display padding never changes saved source or adds extra
indentation when a listed screen row is edited and submitted again.

    LIST
    LIST 10
    LIST 10-50
    LIST 10-
    LIST -50
    LIST10-50
    LIST SLOW
    LIST 10-500 PAUSE

Ranges are inclusive; spaces around the hyphen are accepted. Long listings
scroll upward row by row in screen mode. Space pauses/resumes, S toggles
normal/slow speed (approximately 33/4 rows per second), Enter steps one row and
remains paused, and Q/Esc/Ctrl-C stops. Other typing or cursor movement stops
LIST and passes that key to the editor. The temporary control hint is not
stored in screen memory. SLOW starts slowly; PAUSE stops after each screenful.
Plain mode and piped output never wait for keys or insert listing delays.

=head1 IMPLICIT SEMICOLONS

Ordinary numbered entries supply a missing final semicolon when stored:

    10 say "hi"
    LIST
    10 say "hi";

Existing terminators are retained. Full-line comments and common block or
continuation lines are left alone. A supplied semicolon goes before a trailing
comment, and hashes inside quoted strings are not treated as comments.

This convenience is not a complete Perl parser. For deliberate multiline
expressions, multiline strings, heredoc contents/terminators, POD, or unusual
syntax, use a colon immediately after the editing number to store exact source:

    10: my $text = <<'TEXT';
    20: hello
    30: TEXT
    40 say $text

The colon is an input instruction and is not part of the stored source. EDIT,
IMPORT, and LOAD also preserve literal source; they do not insert semicolons.
An already stored line is normalized only when re-entered without the colon.

=head1 EDIT

EDIT writes the current program, without line numbers, into a private temporary
C<program.pl> and starts C<$EDITOR>, falling back to C<$VISUAL>, then C<vi>
(C<notepad> on Windows). Set an editor that waits until editing is finished:

    export EDITOR=vim
    export EDITOR='code --wait'

The editor command is parsed into an executable and arguments; it is not passed
through a shell. Quote an executable path containing spaces. Windows paths
should use forward slashes when setting EDITOR. Shell expansions, pipes, and
redirections are not supported in EDITOR; use a wrapper script if needed.

After a successful exit, the saved UTF-8 file replaces the in-memory program,
renumbered 10,20,30,... . An unchanged file preserves the existing numbering.
Failure to start, nonzero exit, a missing/unreadable file, invalid UTF-8, NUL
bytes, or bare CR characters leaves the existing program intact. LF and CRLF
files are accepted. Blank lines are retained. UNDO restores the previous
program after a successful edit, including its numbering.

EDIT never runs or syntax-checks your source. Incomplete Perl is allowed in the
buffer; RUN reports errors. This avoids executing BEGIN blocks merely by
editing. Temporary editor files are removed when EDIT finishes.

=head1 WORKSPACE

Immediate input and RUN share a Perl package. C<$x = 1> and C<our $x = 1> persist
between evaluations, along with package arrays, hashes, and subroutines.
C<my> variables are local to one immediate evaluation or one complete RUN.
Pragmas and lexical imports must be repeated in each evaluation that needs
them; C<say> is enabled by default. Evaluation uses scalar context. Use
C<? expression> for Data::Dumper output; ordinary input does not automatically
print its return value. C<EVAL code> bypasses command and line-number parsing.
EVAL must be uppercase; lowercase C<eval> retains Perl's string/block evaluation
and exception-catching behavior. Other commands remain case-insensitive.

RESET switches to a fresh workspace but keeps the source program. NEW/CLEAR
clear the source but retain the workspace. RUN does not reset variables first.
An exception does not roll back side effects. This runs ordinary Perl with
your account's privileges; C<exit> exits the tool. UNDO affects only stored
source, not executed Perl, shell commands, or saved files.

To execute several blocks together without storing source, leave AUTO off and
type or paste a C<do { ... }> entry, or use C<EVAL do { ... }> during AUTO:

    EVAL do {
        my $total = 0;
        for my $n (1 .. 3) { $total += $n; }
        if ($total > 0) { say $total; }
    };

This prints 6 and leaves the stored program unchanged. Delimiter continuation
holds the entry until its closing brace. Bracketed paste also groups multiline
text and waits for Enter; the enclosing block works when typing line by line.

Named subroutines defined by immediate input persist in the shared workspace.
A definition in stored source becomes callable after RUN evaluates the program:

    10 sub twice { return 2 * shift }
    RUN
    say twice(21)

This prints 42. RUN executes the whole program, including other top-level
statements. LOAD and LIST only deal with source; they do not define functions.
Editing or deleting source does not change an already defined function until
it is redefined or RESET selects a fresh workspace. Use LIST or EDIT to revisit
the stored definition, and C<EVAL say twice(21)> to call it during AUTO.

=head1 FILES AND RECOVERY

LOAD accepts ordinary Perl source as well as UTF-8 numbered files bearing a
BASIC PERL header. Plain source receives numbers 10,20,..., preserving comments,
blank lines, and indentation. It is never executed during loading. A C<.bperl>
filename must have a valid native header; files starting with a BASIC PERL
header are validated as native regardless of extension.

SAVE remembers the loaded filename and format. C<SAVE file.pl> writes plain
source without editing numbers; C<SAVE file.bperl> writes numbered source.
Other extensions retain the current format (native for a new program).
Plain source normalizes line endings to LF and ends every stored line with a
newline. C<IMPORT file> remains available to bring in plain source as an unsaved
copy without adopting its filename. Old V0.1 numbered files remain compatible.

EXPORT writes an ordinary Perl script with a small prelude enabling the same
default pragmas. Workspace values are never serialized. Exported programs must
initialize the values they need to run independently.

File writes use a temporary file in the destination directory and rename it
after a successful close. LOAD validates the whole file before changing the
buffer. LOAD, IMPORT, NEW/CLEAR, and QUIT refuse to discard unsaved changes;
append C<!> to those commands to override. UNDO remembers the last 50 program
changes. The save filename is not rolled back by UNDO. Editing does not save
your source file: use SAVE afterward. No automatic crash recovery is provided.

=head1 SCREEN EDITING AND MULTILINE INPUT

Interactive mode uses an ANSI screen with no input prompt or shell-style
command history. New output scrolls the view upward. Arrow keys move the cursor
through displayed input and output, including LIST output. Edit a numbered row
and press Enter to update the stored program. Editing screen text alone does
not change the program or execute it. When you resubmit an earlier entry, its
new output replaces its previous output immediately below the entry, and the
cursor stays just below the new result. If another entry follows, the cursor
moves to its start without inserting a blank spacer or erasing that entry.
Shorter or silent results remove stale output rows; blank lines deliberately
printed by Perl remain. Later entries and their output remain available;
Esc or Ctrl-End moves to fresh input at the bottom. Multiline entries put their
result below the whole group, even when you press Enter on a row in the middle.
This changes only the screen display: executing Perl still repeats its normal
side effects.

C<CLS> clears the display and all retained screen rows, returning the cursor
to the top left. The stored program ("VRAM"), live Perl variables, C<%ENV>,
AUTO settings, save filename, unsaved status, and source UNDO remain intact.
C<LIST> displays the program again; C<RUN> still executes it. C<CLEAR> instead
erases the stored program, while Ctrl-L only redraws existing screen text.
In plain mode, CLS emits clear/home escapes only to a terminal whose TERM is
not C<dumb>; it produces no output when redirected or piped.

Typing inserts characters by default, including when editing earlier rows;
Insert switches between insert and overwrite. Backspace/Delete remove characters,
Home/End move within a row, and PageUp/PageDown move through retained screen
text. Esc or Ctrl-End returns to a blank row at the bottom; Ctrl-Home visits the
oldest row. Ctrl-U clears a row, Ctrl-L redraws, and Ctrl-C cancels input or
interrupts running Perl. The screen retains up to 5,000 output/input rows during
this session, with no saved history. Long rows scroll horizontally with the
cursor. Wide/combining Unicode glyphs can misalign the cursor; the editor assumes
one terminal cell per character.

Shift-Enter or Ctrl-N inserts a newline at the cursor without submitting,
splitting the current row and keeping it in the same multiline group. This
works even when the entry is already complete. Enter submits the entire group
once its delimiters are closed, including from a row in the middle. Insert
mode still controls whether subsequent typing inserts or overwrites text.

Shift-Enter requires the terminal to report a distinct key sequence. CSI-u
C<ESC [ 13 ; 2 u> and xterm C<ESC [ 27 ; 2 ; 13 ~> are recognized. If the
terminal sends ordinary Enter for both keys, AnteREPL cannot distinguish them;
use Ctrl-N or configure Shift-Enter to send one of those sequences. These
editing keys apply to screen input, not C<--plain> or program STDIN reads.

For immediate Perl, Enter continues on the next screen row while a brace,
bracket, parenthesis, or quoted literal remains open. Once closed, Enter
submits the whole entry. Earlier multiline entries remain grouped when edited
and resubmitted. Bracketed multiline paste waits for Enter before evaluating.
No extra continuation prompt is printed, and input is never compiled merely
to decide whether it needs another row. This is delimiter continuation, not a
complete Perl parser; use EDIT or literal numbered lines for heredocs/POD and
complex source. Numbered program lines retain their existing single-line rules.

DUMP expression is a prompt command backed by Data::Dumper::Dumper:

    $FOO = {
        bar => 1,
        names => [qw(Alice Bob)],
    };
    dump $FOO
    dump \%ENV

PEEK expression calls the core Devel::Peek::Dump directly on the expression,
including an optional limit, e.g. C<peek $FOO> or C<peek $FOO, 10>. Its native
stderr output is captured into the editable display. These are prompt commands;
in stored Perl use the module functions explicitly. They do not redefine Perl's
CORE::dump keyword.

Perl print/say/warn output and simple C<E<lt>STDINE<gt>> line input use the screen.
C<! command> captures external stdout/stderr into screen rows when it finishes,
with closed input. Use C<!! command> for interactive external programs; it lends
them the real terminal and waits for Enter before returning to the screen.
EDIT likewise restores normal terminal settings while your editor runs.
Use these escapes for external programs: direct system/exec calls and arbitrary
XS terminal output bypass the screen model.

Screen mode needs an ANSI-capable terminal. On Unix, it uses core POSIX terminal
support, or Term::ReadKey if installed. Native Windows requires Term::ReadKey
(C<cpanm Term::ReadKey>); its Windows backend has not been validated here.
C<--plain> disables screen editing and uses plain input with no prompt or history.
The old C<--no-readline> flag is an alias for C<--plain>.

C<--quiet> suppresses the banner. A startup filename is loaded but never
executed automatically. Piped input uses plain mode and supports the same
immediate delimiter continuation. Batches return a nonzero status after command
errors, incomplete input at EOF, or unsaved stored source at EOF. Outside AUTO,
Ctrl-D refuses to exit an interactive session with unsaved source. Source files and
workspace values have the same lifetime rules in both terminal modes.

=head1 SEE ALSO

L<https://github.com/oodler577/p5-App-AnteREPL/wiki> contains installation,
first-session, editing, environment, and troubleshooting walkthroughs.
Type HELP for the complete command and keyboard reference, also available
from C<anterepl --help>.

=head1 AUTHOR

Brett Estrade

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2026 Brett Estrade.

This software is free software; you may redistribute it and/or modify it
under the same terms as Perl itself.

=cut
