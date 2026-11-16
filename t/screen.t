use 5.016;
use strict;
use warnings;
use Test::More;
use FindBin;
use Cwd qw(abs_path);
use lib "$FindBin::Bin/../lib";
use App::AnteREPL;
my $script = abs_path("$FindBin::Bin/../script/anterepl");

sub capture (&) {
    my ($code) = @_;
    my $output = '';
    open my $fh, '>', \$output or die $!;
    local *STDOUT = $fh;
    $code->();
    return $output;
}

{
    package TestScreen;
    our @ISA = ('App::AnteREPL::Screen');
    sub key { shift @{ $_[0]{keys} } || 'EOF' }
    sub feed { my ($self, @keys) = @_; $self->{keys} = \@keys; return $self->read_entry; }
}
sub typing { map { ['TEXT', $_] } split //, $_[0] }

my $repl = App::AnteREPL->new;
$repl->dispatch('$FOO={bar=>1};');
my $dump = capture { $repl->dispatch('dump $FOO') };
like $dump, qr/\$VAR1 = \{/, 'dump uses Data::Dumper output';
like $dump, qr/'bar' => 1/, 'dump sees current workspace';
{
    local %ENV = (BASIC_PERL_TEST => 'visible');
    like capture { $repl->dispatch('dump \%ENV') }, qr/'BASIC_PERL_TEST' => 'visible'/, 'dump accepts an environment reference';
}
like capture { $repl->dispatch('DUMP [1, 2];') }, qr/1,\s+2/s, 'dump accepts expressions, optional semicolon and command case';
my $peek = capture { $repl->dispatch('peek $FOO') };
like $peek, qr/SV = /, 'peek uses Devel::Peek';
like $peek, qr/FLAGS = \(ROK\)/, 'peek sees a reference scalar';
like $peek, qr/PVHV/, 'peek follows the hash reference';
like $peek, qr/Elt "bar"/, 'peek inspects actual contents';
like $peek, qr/REFCNT = 1/, 'peek does not add an artificial reference to the named scalar';
like capture { $repl->dispatch('peek $FOO, 10;') }, qr/IV = 1/, 'peek accepts the optional depth/element limit';
my $failed = eval { $repl->dispatch('peek my $x = ;'); 1 };
ok !$failed, 'peek syntax errors are reported';
like capture { $repl->dispatch('say "still works"') }, qr/still works/, 'stdout restored after failed peek';

for my $code ('$FOO = {', '$FOO = {bar => [1,', 'say "open', 'say q{open', '($x +') {
    ok App::AnteREPL::needs_more($code), "continue incomplete input: $code";
}
for my $code ('$FOO = {bar=>[1,2]}', 'say "{[()]"', 'say q{nested {braces}}',
    '$FOO = { # } ignored', '10 if (1) {', '10: my $x = [', 'EDIT', '! echo "{"',
    'say $#array', '$FOO = {bar => 1}; # [', 'say 12 / 4', '$x =~ /[{}]/') {
    if ($code eq '$FOO = { # } ignored') { ok App::AnteREPL::needs_more($code), 'comments do not close a data structure'; }
    else { ok !App::AnteREPL::needs_more($code), "complete/special input: $code"; }
}
ok !App::AnteREPL::needs_more('$x = {]'), 'mismatched delimiters are handed to Perl for an error';

my $screen = TestScreen->new;
my $line = $screen->feed(typing('10 say "first"'), 'ENTER');
is $line, '10 say "first"', 'screen submits typed row without a prompt';
$repl->dispatch($line);
$screen->append($repl->listing);
is $screen->{rows}[1]{text}, '10 say "first";', 'LIST output is part of editable screen memory';
$line = $screen->feed('UP', 'END', ('LEFT') x 3, ['TEXT','!'], 'ENTER');
is $line, '10 say "firs!";', 'moving up edits the actual displayed output row';
is capture { $repl->run }, "first\n", 'editing the screen alone does not update stored source';
$repl->dispatch($line);
is capture { $repl->run }, "firs!\n", 'Enter resubmission changes stored source';

my $multi = TestScreen->new;
my $definition = $multi->feed(typing('$FOO = {'), 'ENTER', typing('bar => 2,'), 'ENTER',
    typing('names => [qw(Alice Bob)],'), 'ENTER', typing('};'), 'ENTER');
is $definition, "\$FOO = {\nbar => 2,\nnames => [qw(Alice Bob)],\n};", 'open delimiters join consecutive screen rows';
$repl->dispatch($definition);
is $repl->evaluate('$FOO->{bar}', 0), 2, 'complete multiline definition evaluates';
is $repl->evaluate('$FOO->{names}[1]', 0), 'Bob', 'nested data structure preserved';
my $again = $multi->feed('UP', 'UP', 'UP', 'HOME', ('RIGHT') x 7, ['TEXT','3'], 'ENTER');
like $again, qr/bar => 3,/, 'an earlier multiline entry can be edited in place';
$repl->dispatch($again);
is $repl->evaluate('$FOO->{bar}', 0), 3, 'resubmission evaluates the whole earlier entry';

my $paste = TestScreen->new;
{
    my $typed = TestScreen->new;
    my $r = App::AnteREPL->new;
    $typed->{repl} = $r;
    my $entry = $typed->feed(typing('EVAL sub triple {'), 'ENTER',
        typing('    return 3 * shift;'), 'ENTER', typing('}'), 'ENTER');
    is $entry, "EVAL sub triple {\n    return 3 * shift;\n}",
        'ordinary Enter on a closing subroutine brace completes the typed EVAL';
    is capture { $r->dispatch($entry) }, '', 'successful subroutine definition is silent';
    my $call = $typed->feed(typing('say triple(14)'), 'ENTER');
    is $call, 'say triple(14)', 'next typed command is outside the EVAL group';
    is capture { $r->dispatch($call) }, "42\n", 'the typed subroutine is callable immediately';
    my $store = $typed->feed(typing('STORE'), 'ENTER');
    like capture { $r->dispatch($store) }, qr/Stored 3 lines at 5-15/,
        'STORE is dispatched separately after the typed definition';
    is $r->source, "sub triple {\n    return 3 * shift;\n}\n",
        'stored definition excludes subsequent immediate commands';

    capture { $r->dispatch('AUTO') };
    $entry = $typed->feed(typing('EVAL sub from_auto {'), 'ENTER',
        typing('    return 7 * shift;'), 'ENTER', typing('}'), 'ENTER');
    capture { $r->dispatch($entry) };
    ok $r->{auto}, 'closing EVAL does not leave AUTO';
    $call = $typed->feed(typing('say from_auto(6)'), 'ENTER');
    is capture { $r->dispatch($call) }, '', 'ordinary call after EVAL is stored quietly during AUTO';
    is $r->listing('20'), "20 say from_auto(6);\n", 'quiet input was stored outside the completed EVAL block';
    capture { $r->dispatch($typed->feed(typing('AUTO OFF'), 'ENTER')) };
    is capture { $r->dispatch($typed->feed(typing('say from_auto(6)'), 'ENTER')) }, "42\n",
        'AUTO OFF makes the same function call execute immediately';
}
my $pasted = $paste->feed(['PASTE', "\$FOO = {\nbar => 8,\n};"], 'ENTER');
is $pasted, "\$FOO = {\nbar => 8,\n};", 'multiline paste waits for Enter and remains a single entry';
my $editing = TestScreen->new;
$editing->feed(typing('abc'), 'HOME', 'INSERT', ['TEXT','x'], 'DELETE', 'END', 'BACKSPACE', 'ENTER');
is $editing->{rows}[0]{text}, 'xb', 'insert, delete and backspace edit displayed text';
$editing->append("one\r\ntwo\r\n");
is $editing->{rows}[-2]{text}, 'two', 'CRLF output remains visible';
$editing->append("line $_\n") for 1 .. 30;
is $editing->{rows}[-2]{text}, 'line 30', 'new output advances display rows';
$editing->{height} = 6;
$editing->edit_key('PAGEUP');
is $editing->{rows}[ $editing->{row} ]{text}, 'line 26', 'PageUp navigates screen rows rather than command history';
$editing->edit_key('BOTTOM');
is $editing->{rows}[ $editing->{row} ]{text}, '', 'bottom returns to a blank row';

my $cancel = TestScreen->new;
$cancel->feed(typing('$bad = {'), 'ENTER', 'EOF');
$cancel->fresh;
my $next = $cancel->feed(typing('say 7'), 'ENTER');
is $next, 'say 7', 'cancelled continuation cannot absorb the next entry';

{
    package ByteScreen;
    our @ISA = ('App::AnteREPL::Screen');
    sub byte { return shift @{ $_[0]{bytes} }; }
}
my $keyboard = ByteScreen->new;
for my $sequence ("\e[13;2u", "\e[13;2:1u", "\e[13;2:2u", "\e[27;2;13~", "\x0e") {
    $keyboard->{bytes} = [split //, $sequence];
    is $keyboard->key, 'NEWLINE', 'modified Enter / Ctrl-N decodes as newline';
}
$keyboard->{bytes} = [split //, "\e[13;2:3u"];
is $keyboard->key, 'IGNORE', 'Shift+Enter key release does not insert a second newline';
$keyboard->{bytes} = ["\r"];
is $keyboard->key, 'ENTER', 'ordinary Enter remains submit';
$keyboard->{bytes} = ["\x04"];
is $keyboard->key, 'ENDINPUT', 'Ctrl-D is distinct from terminal disconnect';
$keyboard->{bytes} = [];
is $keyboard->key, 'EOF', 'terminal disconnect remains EOF';

my $split = TestScreen->new;
my $block = $split->feed(typing('EVAL do { say 1; };'), 'HOME', ('RIGHT') x 10,
    'NEWLINE', 'INSERT', typing('say 2; '), 'ENTER');
is $block, "EVAL do { \nsay 2; say 1; };", 'insert newline splits a complete entry without submitting';
is capture { $repl->dispatch($block) }, "2\n1\n", 'split entry executes together';
my $mid = $split->feed('UP', 'HOME', 'NEWLINE', 'ENTER');
is $mid, "EVAL do { \n\nsay 2; say 1; };", 'inserting a blank row retains the entire earlier group';
is capture { $repl->dispatch($mid) }, "2\n1\n", 'submission from the middle evaluates the complete group';

my $auto_end = TestScreen->new;
my $auto_repl = App::AnteREPL->new;
$auto_end->{repl} = $auto_repl;
capture { $auto_repl->dispatch('AUTO') };
$auto_repl->dispatch('say "kept"');
my $stop = $auto_end->feed(typing('$unfinished = {'), 'ENTER', 'ENDINPUT');
is $stop, 'AUTO OFF', 'Ctrl-D cancels incomplete AUTO input by ending AUTO';
capture { $auto_repl->dispatch($stop) };
ok !$auto_repl->{auto}, 'Ctrl-D leaves AUTO';
is $auto_repl->source, "say \"kept\";\n", 'Ctrl-D preserves completed source and drops unfinished input';
is $auto_end->feed(typing('say "immediate"'), 'ENTER'), 'say "immediate"', 'fresh entry after Ctrl-D does not join cancelled group';
is $auto_end->feed('ENDINPUT'), undef, 'Ctrl-D outside AUTO retains normal exit behavior';

{
    local %ENV = (ANTEREPL_CLS => 'retained');
    my $r = App::AnteREPL->new;
    $r->dispatch('10 say "retained program"');
    $r->dispatch('$value = 42');
    $r->{filename} = 'retained.pl';
    capture { $r->dispatch('AUTO 15') };
    my $s = TestScreen->new;
    $r->{screen} = $s;
    $s->append("old output\n" x 40);
    $s->{left} = 10;
    $s->{top} = 30;
    is capture { $r->dispatch('cLs') }, '', 'CLS accepts mixed case without a message';
    is_deeply $s->{rows}, [{text=>''}], 'CLS removes retained display rows';
    is_deeply [@{$s}{qw(row col top left)}], [0, 0, 0, 0], 'CLS returns to top left';
    $s->edit_key('TOP');
    is $s->{rows}[$s->{row}]{text}, '', 'old display text cannot be revisited';
    is capture { $r->dispatch('RUN') }, "retained program\n", 'CLS retains runnable VRAM';
    is $r->evaluate('$value', 0), 42, 'CLS retains live Perl variables';
    is $ENV{ANTEREPL_CLS}, 'retained', 'CLS retains environment';
    is $r->{filename}, 'retained.pl', 'CLS retains save filename';
    ok $r->dirty, 'CLS retains unsaved status';
    is_deeply $r->{auto}, {next=>15, step=>5}, 'CLS retains AUTO position';
    $r->dispatch('say "next line"');
    is $r->{lines}{15}, 'say "next line";', 'AUTO continues after CLS';
    $r->undo;
    $r->undo;
    is $r->source, '', 'CLS preserves earlier source undo without adding an edit';
    for my $bad ('CLS extra', 'CLS!') {
        ok !eval { $r->dispatch($bad); 1 }, "$bad is rejected";
    }
    ok !App::AnteREPL::needs_more('CLS {'), 'CLS errors do not start Perl continuation';
    delete $r->{screen};
    is capture { $r->dispatch('CLS') }, '', 'CLS emits no escapes to redirected output';
}

done_testing;
