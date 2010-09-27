package SQL::Abstract::Tree;

use strict;
use warnings;
use Carp;

use Hash::Merge qw//;

use base 'Class::Accessor::Grouped';

__PACKAGE__->mk_group_accessors( simple => $_ ) for qw(
   newline indent_string indent_amount colormap indentmap fill_in_placeholders
   placeholder_surround
);

my $merger = Hash::Merge->new;

$merger->specify_behavior({
   SCALAR => {
      SCALAR => sub { $_[1] },
      ARRAY  => sub { [ $_[0], @{$_[1]} ] },
      HASH   => sub { $_[1] },
   },
   ARRAY => {
      SCALAR => sub { $_[1] },
      ARRAY  => sub { $_[1] },
      HASH   => sub { $_[1] },
   },
   HASH => {
      SCALAR => sub { $_[1] },
      ARRAY  => sub { [ values %{$_[0]}, @{$_[1]} ] },
      HASH   => sub { Hash::Merge::_merge_hashes( $_[0], $_[1] ) },
   },
}, 'SQLA::Tree Behavior' );


# Parser states for _recurse_parse()
use constant PARSE_TOP_LEVEL => 0;
use constant PARSE_IN_EXPR => 1;
use constant PARSE_IN_PARENS => 2;
use constant PARSE_RHS => 3;
use constant PARSE_IN_FUNC => 4;

my $op_look_ahead = '(?: (?= [\s\)\(\;] ) | \z)';
my $op_look_behind = '(?: (?<= [\s\)\(] ) | \A )';
my $quote_left = qr/[\`\'\"\[]/;
my $quote_right = qr/[\`\'\"\]]/;

# These SQL keywords always signal end of the current expression (except inside
# of a parenthesized subexpression).
# Format: A list of strings that will be compiled to extended syntax ie.
# /.../x) regexes, without capturing parentheses. They will be automatically
# anchored to op boundaries (excluding quotes) to match the whole token.
my @expression_start_keywords = (
  'SELECT',
  'UPDATE',
  'INSERT \s+ INTO',
  'DELETE \s+ FROM',
  'FROM',
  'SET',
  '(?:
    (?:
        (?: (?: LEFT | RIGHT | FULL ) \s+ )?
        (?: (?: CROSS | INNER | OUTER ) \s+ )?
    )?
    JOIN
  )',
  'ON',
  'WHERE',
  'VALUES',
  'EXISTS',
  'GROUP \s+ BY',
  'HAVING',
  'ORDER \s+ BY',
  'LIMIT',
  'OFFSET',
  'FOR',
  'UNION',
  'INTERSECT',
  'EXCEPT',
  'RETURNING',
  'ROW_NUMBER \s* \( \s* \) \s+ OVER',
);

my $exp_start_re = join ("\n\t|\n", @expression_start_keywords );
$exp_start_re = qr/ $op_look_behind (?i: $exp_start_re ) $op_look_ahead /x;

# These are binary operator keywords always a single LHS and RHS
# * AND/OR are handled separately as they are N-ary
# * so is NOT as being unary
# * BETWEEN without paranthesis around the ANDed arguments (which
#   makes it a non-binary op) is detected and accomodated in
#   _recurse_parse()

# this will be included in the $binary_op_re, the distinction is interesting during
# testing as one is tighter than the other, plus mathops have different look
# ahead/behind (e.g. "x"="y" )
my @math_op_keywords = (qw/ < > != <> = <= >= /);
my $math_re = join ("\n\t|\n", map
  { "(?: (?<= [\\w\\s] | $quote_right ) | \\A )"  . quotemeta ($_) . "(?: (?= [\\w\\s] | $quote_left ) | \\z )" }
  @math_op_keywords
);
$math_re = qr/$math_re/x;

sub _math_op_re { $math_re }


my $binary_op_re = '(?: NOT \s+)? (?:' . join ('|', qw/IN BETWEEN R?LIKE/) . ')';
$binary_op_re = "(?: $op_look_behind (?i: $binary_op_re ) $op_look_ahead ) \n\t|\n $math_re";
$binary_op_re = qr/$binary_op_re/x;

sub _binary_op_re { $binary_op_re }


my $tokenizer_re = join("\n\t|\n",
  $exp_start_re,
  $binary_op_re,
  "$op_look_behind (?i: AND|OR|NOT ) $op_look_ahead",
  (map { quotemeta $_ } qw/( ) ? */),
);

#this one *is* capturing
$tokenizer_re = qr/ \s* ( $tokenizer_re ) \s* /x;

my %indents = (
   select        => 0,
   update        => 0,
   'insert into' => 0,
   'delete from' => 0,
   from          => 1,
   where         => 0,
   join          => 1,
   'left join'   => 1,
   on            => 2,
   'group by'    => 0,
   'order by'    => 0,
   set           => 1,
   into          => 1,
   values        => 1,
);

my %profiles = (
   console => {
      fill_in_placeholders => 1,
      placeholder_surround => ['?/', ''],
      indent_string => ' ',
      indent_amount => 2,
      newline       => "\n",
      colormap      => {},
      indentmap     => { %indents },

      eval { require Term::ANSIColor }
        ? do {
          my $c = \&Term::ANSIColor::color;
          (
            placeholder_surround => [$c->('black on_cyan'), $c->('reset')],
            colormap => {
              select        => [$c->('red'), $c->('reset')],
              'insert into' => [$c->('red'), $c->('reset')],
              update        => [$c->('red'), $c->('reset')],
              'delete from' => [$c->('red'), $c->('reset')],

              set           => [$c->('cyan'), $c->('reset')],
              from          => [$c->('cyan'), $c->('reset')],

              where         => [$c->('green'), $c->('reset')],
              values        => [$c->('yellow'), $c->('reset')],

              join          => [$c->('magenta'), $c->('reset')],
              'left join'   => [$c->('magenta'), $c->('reset')],
              on            => [$c->('blue'), $c->('reset')],

              'group by'    => [$c->('yellow'), $c->('reset')],
              'order by'    => [$c->('yellow'), $c->('reset')],
            }
          );
        } : (),
   },
   console_monochrome => {
      fill_in_placeholders => 1,
      placeholder_surround => ['?/', ''],
      indent_string => ' ',
      indent_amount => 2,
      newline       => "\n",
      colormap      => {},
      indentmap     => { %indents },
   },
   html => {
      fill_in_placeholders => 1,
      placeholder_surround => ['<span class="placeholder">', '</span>'],
      indent_string => '&nbsp;',
      indent_amount => 2,
      newline       => "<br />\n",
      colormap      => {
         select        => ['<span class="select">'  , '</span>'],
         'insert into' => ['<span class="insert-into">'  , '</span>'],
         update        => ['<span class="select">'  , '</span>'],
         'delete from' => ['<span class="delete-from">'  , '</span>'],
         where         => ['<span class="where">'   , '</span>'],
         from          => ['<span class="from">'    , '</span>'],
         join          => ['<span class="join">'    , '</span>'],
         on            => ['<span class="on">'      , '</span>'],
         'group by'    => ['<span class="group-by">', '</span>'],
         'order by'    => ['<span class="order-by">', '</span>'],
         set           => ['<span class="set">', '</span>'],
         into          => ['<span class="into">', '</span>'],
         values        => ['<span class="values">', '</span>'],
      },
      indentmap     => { %indents },
   },
   none => {
      colormap      => {},
      indentmap     => {},
   },
);

sub new {
   my $class = shift;
   my $args  = shift || {};

   my $profile = delete $args->{profile} || 'none';
   my $data = $merger->merge( $profiles{$profile}, $args );

   bless $data, $class
}

sub parse {
  my ($self, $s) = @_;

  # tokenize string, and remove all optional whitespace
  my $tokens = [];
  foreach my $token (split $tokenizer_re, $s) {
    push @$tokens, $token if (length $token) && ($token =~ /\S/);
  }

  my $tree = $self->_recurse_parse($tokens, PARSE_TOP_LEVEL);
  return $tree;
}

sub _recurse_parse {
  my ($self, $tokens, $state) = @_;

  my $left;
  while (1) { # left-associative parsing

    my $lookahead = $tokens->[0];
    if ( not defined($lookahead)
          or
        ($state == PARSE_IN_PARENS && $lookahead eq ')')
          or
        ($state == PARSE_IN_EXPR && $lookahead =~ qr/ ^ (?: $exp_start_re | \) ) $ /x )
          or
        ($state == PARSE_RHS && $lookahead =~ qr/ ^ (?: $exp_start_re | $binary_op_re | (?i: AND | OR | NOT ) | \) ) $ /x )
          or
        ($state == PARSE_IN_FUNC && $lookahead ne '(')
    ) {
      return $left||();
    }

    my $token = shift @$tokens;

    # nested expression in ()
    if ($token eq '(' ) {
      my $right = $self->_recurse_parse($tokens, PARSE_IN_PARENS);
      $token = shift @$tokens   or croak "missing closing ')' around block " . $self->unparse($right);
      $token eq ')'             or croak "unexpected token '$token' terminating block " . $self->unparse($right);

      $left = $left ? [$left, [PAREN => [$right||()] ]]
                    : [PAREN  => [$right||()] ];
    }
    # AND/OR
    elsif ($token =~ /^ (?: OR | AND ) $/xi )  {
      my $op = uc $token;
      my $right = $self->_recurse_parse($tokens, PARSE_IN_EXPR);

      # Merge chunks if logic matches
      if (ref $right and $op eq $right->[0]) {
        $left = [ (shift @$right ), [$left, map { @$_ } @$right] ];
      }
      else {
       $left = [$op => [$left, $right]];
      }
    }
    # binary operator keywords
    elsif ( $token =~ /^ $binary_op_re $ /x ) {
      my $op = uc $token;
      my $right = $self->_recurse_parse($tokens, PARSE_RHS);

      # A between with a simple LITERAL for a 1st RHS argument needs a
      # rerun of the search to (hopefully) find the proper AND construct
      if ($op eq 'BETWEEN' and $right->[0] eq 'LITERAL') {
        unshift @$tokens, $right->[1][0];
        $right = $self->_recurse_parse($tokens, PARSE_IN_EXPR);
      }

      $left = [$op => [$left, $right] ];
    }
    # expression terminator keywords (as they start a new expression)
    elsif ( $token =~ / ^ $exp_start_re $ /x ) {
      my $op = uc $token;
      my $right = $self->_recurse_parse($tokens, PARSE_IN_EXPR);
      $left = $left ? [ $left,  [$op => [$right] ]]
                   : [ $op => [$right] ];
    }
    # NOT
    elsif ( $token =~ /^ NOT $/ix ) {
      my $op = uc $token;
      my $right = $self->_recurse_parse ($tokens, PARSE_RHS);
      $left = $left ? [ @$left, [$op => [$right] ]]
                    : [ $op => [$right] ];

    }
    # generic function
    elsif (@$tokens && $tokens->[0] eq '(') {
      my $right = $self->_recurse_parse($tokens, PARSE_IN_FUNC);

      $left = $left ? [ $left, [ $token => [$right||()] ]]
                    : [ $token => [$right||()] ];
    }
    # literal (eat everything on the right until RHS termination)
    else {
      my $right = $self->_recurse_parse ($tokens, PARSE_RHS);
      $left = $left ? [ $left, [LITERAL => [join ' ', $token, $self->unparse($right)||()] ] ]
                    : [ LITERAL => [join ' ', $token, $self->unparse($right)||()] ];
    }
  }
}

sub format_keyword {
  my ($self, $keyword) = @_;

  if (my $around = $self->colormap->{lc $keyword}) {
     $keyword = "$around->[0]$keyword$around->[1]";
  }

  return $keyword
}

my %starters = (
   select        => 1,
   update        => 1,
   'insert into' => 1,
   'delete from' => 1,
);

sub pad_keyword {
   my ($self, $keyword, $depth) = @_;

   my $before = '';
   if (defined $self->indentmap->{lc $keyword}) {
      $before = $self->newline . $self->indent($depth + $self->indentmap->{lc $keyword});
   }
   $before = '' if $depth == 0 and defined $starters{lc $keyword};
   return [$before, ' '];
}

sub indent { ($_[0]->indent_string||'') x ( ( $_[0]->indent_amount || 0 ) * $_[1] ) }

sub _is_key {
   my ($self, $tree) = @_;
   $tree = $tree->[0] while ref $tree;

   defined $tree && defined $self->indentmap->{lc $tree};
}

sub fill_in_placeholder {
   my ($self, $bindargs) = @_;

   if ($self->fill_in_placeholders) {
      my $val = pop @{$bindargs} || '';
      my ($left, $right) = @{$self->placeholder_surround};
      $val =~ s/\\/\\\\/g;
      $val =~ s/'/\\'/g;
      return qq('$left$val$right')
   }
   return '?'
}

sub unparse {
  my ($self, $tree, $bindargs, $depth) = @_;

  $depth ||= 0;

  if (not $tree or not @$tree) {
    return '';
  }

  my ($car, $cdr) = @{$tree}[0,1];

  if (! defined $car or (! ref $car and ! defined $cdr) ) {
    require Data::Dumper;
    Carp::confess( sprintf ( "Internal error - malformed branch at depth $depth:\n%s",
      Data::Dumper::Dumper($tree)
    ) );
  }

  if (ref $car) {
    return join ('', map $self->unparse($_, $bindargs, $depth), @$tree);
  }
  elsif ($car eq 'LITERAL') {
    if ($cdr->[0] eq '?') {
      return $self->fill_in_placeholder($bindargs)
    }
    return $cdr->[0];
  }
  elsif ($car eq 'PAREN') {
    return '(' .
      join(' ',
        map $self->unparse($_, $bindargs, $depth + 2), @{$cdr}) .
    ($self->_is_key($cdr)?( $self->newline||'' ).$self->indent($depth + 1):'') . ') ';
  }
  elsif ($car eq 'AND' or $car eq 'OR' or $car =~ / ^ $binary_op_re $ /x ) {
    return join (" $car ", map $self->unparse($_, $bindargs, $depth), @{$cdr});
  }
  else {
    my ($l, $r) = @{$self->pad_keyword($car, $depth)};
    return sprintf "$l%s %s$r", $self->format_keyword($car), $self->unparse($cdr, $bindargs, $depth);
  }
}

sub format { my $self = shift; $self->unparse($self->parse($_[0]), $_[1]) }

1;

=pod

=head1 SYNOPSIS

 my $sqla_tree = SQL::Abstract::Tree->new({ profile => 'console' });

 print $sqla_tree->format('SELECT * FROM foo WHERE foo.a > 2');

 # SELECT *
 #   FROM foo
 #   WHERE foo.a > 2

=head1 METHODS

=head2 new

 my $sqla_tree = SQL::Abstract::Tree->new({ profile => 'console' });

 $args = {
   profile => 'console',      # predefined profile to use (default: 'none')
   fill_in_placeholders => 1, # true for placeholder population
   placeholder_surround =>    # The strings that will be wrapped around
              [GREEN, RESET], # populated placeholders if the above is set
   indent_string => ' ',      # the string used when indenting
   indent_amount => 2,        # how many of above string to use for a single
                              # indent level
   newline       => "\n",     # string for newline
   colormap      => {
     select => [RED, RESET], # a pair of strings defining what to surround
                             # the keyword with for colorization
     # ...
   },
   indentmap     => {
     select        => 0,     # A zero means that the keyword will start on
                             # a new line
     from          => 1,     # Any other positive integer means that after
     on            => 2,     # said newline it will get that many indents
     # ...
   },
 }

Returns a new SQL::Abstract::Tree object.  All arguments are optional.

=head3 profiles

There are four predefined profiles, C<none>, C<console>, C<console_monochrome>,
and C<html>.  Typically a user will probably just use C<console> or
C<console_monochrome>, but if something about a profile bothers you, merely
use the profile and override the parts that you don't like.

=head2 format

 $sqlat->format('SELECT * FROM bar WHERE x = ?', [1])

Takes C<$sql> and C<\@bindargs>.

Returns a formatting string based on the string passed in

=head2 parse

 $sqlat->parse('SELECT * FROM bar WHERE x = ?')

Returns a "tree" representing passed in SQL.  Please do not depend on the
structure of the returned tree.  It may be stable at some point, but not yet.

=head2 unparse

 $sqlat->parse($tree_structure, \@bindargs)

Transform "tree" into SQL, applying various transforms on the way.

=head2 format_keyword

 $sqlat->format_keyword('SELECT')

Currently this just takes a keyword and puts the C<colormap> stuff around it.
Later on it may do more and allow for coderef based transforms.

=head2 pad_keyword

 my ($before, $after) = @{$sqlat->pad_keyword('SELECT')};

Returns whitespace to be inserted around a keyword.

=head2 fill_in_placeholder

 my $value = $sqlat->fill_in_placeholder(\@bindargs)

Removes last arg from passed arrayref and returns it, surrounded with
the values in placeholder_surround, and then surrounded with single quotes.

=head2 indent

Returns as many indent strings as indent amounts times the first argument.

=head1 ACCESSORS

=head2 colormap

See L</new>

=head2 fill_in_placeholders

See L</new>

=head2 indent_amount

See L</new>

=head2 indent_string

See L</new>

=head2 indentmap

See L</new>

=head2 newline

See L</new>

=head2 placeholder_surround

See L</new>

