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

done_testing;
