# Implementation of a pure-perl on_scope_end for perl 5.8.X
# (relies on lack of compile/runtime duality of %^H before 5.10
# which makes guard object operation possible)

package # hide from the pauses
  B::Hooks::EndOfScope::PP::HintHash;

use strict;
use warnings;

our $VERSION = '0.22';

use Scalar::Util ();

# This is the original implementation, which sadly is broken
# on perl 5.10+ within string evals
sub on_scope_end (&) {
  $^H |= 0x020000;

  # Workaround for memory corruption on older perls, see extended
  # comment below
  bless \%^H, 'B::Hooks::EndOfScope::PP::HintHash::__GraveyardTransport' if (
    B::Hooks::EndOfScope::PP::_PERL_VERSION >= 5.008
      and
    B::Hooks::EndOfScope::PP::_PERL_VERSION < 5.008004
      and
    ref \%^H eq 'HASH'  # only bless if it is a "pure hash" to start with
  );

  # localised %^H behaves funny on 5.8 - a
  # 'local %^H;'
  # is in effect the same as
  # 'local %^H = %^H;'
  # therefore make sure we use different keys so that things do not
  # fire too early due to hashkey overwrite
  push @{
    $^H{sprintf '__B_H_EOS__guardstack_0X%x', Scalar::Util::refaddr(\%^H) }
      ||= bless ([], 'B::Hooks::EndOfScope::PP::_SG_STACK')
  }, $_[0];
}

sub B::Hooks::EndOfScope::PP::_SG_STACK::DESTROY {
  B::Hooks::EndOfScope::PP::__invoke_callback($_) for @{$_[0]};
}

# This scope implements a clunky yet effective workaround for a core perl bug
# https://rt.perl.org/Public/Bug/Display.html?id=27040#txn-82797
#
# While we can not prevent the hinthash being marked for destruction twice,
# we *can* intercept the first DESTROY pass, and squirrel away the entire
# structure, until a time it can ( hopefully ) no longer do any visible harm
#
# There still *will* be corruption by the time we get to free it for real,
# since we can not prevent Perl's erroneous SAVEFREESV mark. What we hope is
# that by then the corruption will no longer matter
#
# Yes, this code does leak by design. Yes it is better than the alternative.
{
  my @Hint_Hash_Graveyard;

  # "Leak" this entire structure: ensures it and its contents will not be
  # garbage collected until the very very very end
  push @Hint_Hash_Graveyard, \@Hint_Hash_Graveyard;

  sub B::Hooks::EndOfScope::PP::HintHash::__GraveyardTransport::DESTROY {

    # Resurrect the hinthash being destroyed, persist it into the graveyard
    push @Hint_Hash_Graveyard, $_[0];

    # ensure we won't try to re-resurrect during GlobalDestroy
    bless $_[0], 'B::Hooks::EndOfScope::PP::HintHash::__DeactivateGraveyardTransport';

    # Perform explicit free of elements ( if any ) triggering all callbacks
    # This is what would have happened without this code being active
    %{$_[0]} = ();
  }
}

1;
