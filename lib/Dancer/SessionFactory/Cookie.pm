use 5.010;
use strict;
use warnings;

package Dancer::SessionFactory::Cookie;
# ABSTRACT: Dancer 2 session storage in secure cookies
# VERSION

use Crypt::CBC              ();
use Crypt::Rijndael         ();
use Digest::SHA             (qw/hmac_sha256/);
use Math::Random::ISAAC::XS ();
use MIME::Base64            (qw/encode_base64url decode_base64url/);
use Sereal::Encoder         ();
use Sereal::Decoder         ();
use namespace::clean;

use Moo;
use Dancer::Core::Types;

with 'Dancer::Core::Role::SessionFactory';

#--------------------------------------------------------------------------#
# Attributes
#--------------------------------------------------------------------------#

=attr secret_key

This is used to secure the cookies.  Encryption keys and message authentication
keys are derived from this using one-way functions.  Changing it will
invalidate all sessions.

=cut

has secret_key => (
  is       => 'ro',
  isa      => Str,
  required => 1,
);

=attr max_duration

If C<cookie_duration> is not set, this puts a maximum duration on
the validity of the cookie, regardless of the length of the
browser session.

=cut

has max_duration => (
  is        => 'ro',
  isa       => Int,
  predicate => 1,
);

has _encoder => (
  is      => 'lazy',
  isa     => InstanceOf ['Sereal::Encoder'],
  handles => { '_freeze' => 'encode' },
);

sub _build__encoder {
  my ($self) = @_;
  return Sereal::Encoder->new(
    {
      snappy         => 1,
      croak_on_bless => 1,
    }
  );
}

has _decoder => (
  is      => 'lazy',
  isa     => InstanceOf ['Sereal::Decoder'],
  handles => { '_thaw' => 'decode' },
);

sub _build__decoder {
  my ($self) = @_;
  return Sereal::Decoder->new(
    {
      refuse_objects => 1,
      validate_utf8  => 1,
    }
  );
}

has _rng => (
  is      => 'lazy',
  isa     => InstanceOf ['Math::Random::ISAAC::XS'],
  handles => { '_irand' => 'irand' },
);

sub _build__rng {
  my ($self) = @_;
  my @seeds;
  if ( -f "/dev/random" ) {
    open my $fh, "<:raw", "/dev/random/";
    my $buf = "";
    while ( length $buf < 1024 ) {
      sysread( $fh, $buf, 1024 - length $buf, length $buf );
    }
    @seeds = unpack( 'l*', $buf );
  }
  else {
    @seeds = map { rand } 1 .. 256;
  }
  return Math::Random::ISAAC::XS->new(@seeds);
}

#--------------------------------------------------------------------------#
# Modified SessionFactory methods
#--------------------------------------------------------------------------#

# We don't need to generate an ID.  We'll set it during cookie generation
sub generate_id { '' }

# Cookie generation: serialize the session data into the session ID
# right before the cookie is generated
before 'cookie' => sub {
  my ( $self, %params ) = @_;
  my $session = $params{session};
  return unless ref $session && $session->isa("Dancer::Core::Session");

  # cookie is derived from session data and expiration time
  my $data    = $session->data;
  my $expires = $session->expires;

  # if expiration is set, we want to check it and possibly clear data;
  # if not set, we might add an expiration based on max_duration
  if ( defined $expires ) {
    $data = {} if $expires < time;
  }
  else {
    $expires = $self->has_max_duration ? time + $self->max_duration : "";
  }

  # random salt used to derive unique encryption/MAC key for each cookie
  my $salt       = $self->_irand;
  my $key        = hmac_sha256( $salt, $self->secret_key );
  my $cbc        = Crypt::CBC->new( -key => $key, -cipher => 'Rijndael' );
  my $ciphertext = encode_base64url( $cbc->encrypt( $self->_freeze($data) ) );
  my $msg        = join( "~", $salt, $expires, $ciphertext );

  $session->id( "$msg~" . encode_base64url( hmac_sha256( $msg, $key ) ) );
};

#--------------------------------------------------------------------------#
# SessionFactory implementation methods
#--------------------------------------------------------------------------#

# Cookie retrieval: extract, verify and decode data
sub _retrieve {
  my ( $self, $id ) = @_;
  return unless length $id;

  my ( $salt, $expires, $ciphertext, $mac ) = split qr/~/, $id;
  my $key = hmac_sha256( $salt, $self->secret_key );

  # Check MAC
  my $check_mac = hmac_sha256( join( "~", $salt, $expires, $ciphertext ), $key );
  return unless encode_base64url($check_mac) eq $mac;

  # Check expiration
  return if length($expires) && $expires < time;

  # Decode data
  my $cbc = Crypt::CBC->new( -key => $key, -cipher => 'Rijndael' );
  $self->_thaw( $cbc->decrypt( decode_base64url($ciphertext) ), my $data );
  return $data;
}

# We don't actually flush data; instead we modify cookie generation
sub _flush { return }

# We have nothing to destroy, either; cookie expiration is all that matters
sub _destroy { return }

# There is no way to know about existing sessions when cookies
# are used as the store, so we lie and return an empty list.
sub _sessions { return [] }

1;

=for Pod::Coverage method_names_here

=head1 SYNOPSIS

  # In Dancer 2 config.yml file

  session: Cookie
  engines:
    session:
      Cookie:
        secret_key: your secret passphrase
        max_duration: 604800

=head1 DESCRIPTION

This module implements a session factory for Dancer 2 that stores session
state within a browser cookie.  It uses AES encryption to protect
session data, an expiration timestamp (within the cookie value itself) to
enforce session expiration, and a MAC to ensure integrity.

=head1 LIMITATIONS AND SECURITY

=head2 Session size

Cookies must fit within 4k, so don't store too much data in the session.
This module uses L<Sereal> for serialization and does enable the C<snappy>
compression option, which kicks in over 1K.

=head2 Secret key

You must protect the secret key, of course.  Rekeying periodically would
improve security.  Rekeying also invalidates all existing sessions.  In a
multi-node application, all nodes must share the same secret key.

=head2 Transport security

While session data is encrypted, an attacker could intercept cookies and replay
them to impersonate a valid user.  SSL encryption is strongly recommended.

=head2 Cookie replay

Because all session state is maintained in the session cookie, an attacker
or malicious user could replay an old cookie to return to a previous state.
Cookie-based sessions should not be used for recording incremental steps
in a transaction or to record "negative rights".

Because cookie expiration happens on the client-side, an attacker or malicious
user could replay a cookie after its scheduled expiration date.  It is strongly
recommended to set C<cookie_duration> or C<max_duration> to limit the window of
opportunity for such replay attacks.

=head2 Session authentication

A compromised secret key could be used to construct valid messages appearing to
be from any user.  Applications should take extra steps in their use of session
data to ensure that sessions are authenticated to the user.

One simple approach could be to store a hash of the user's hashed password
in the session on login and to verify it on each request.

  # on login
  my $hashed_pw = bcrypt( $password );
  if ( $hashed_pw eq $hashed_pw_from_db ) {
    session user => $user;
    session auth => bcrypt( $hashed_pw ) );
  }

  # on each request
  if ( bcrypt( $hashed_pw_from_db ) ne session("auth") ) {
    context->destroy_session;
  }

The downside of this is that if there is a read-only attack against the
database (SQL injection or leaked backup dump) and the secret key is compromised,
then an attacker can forge a cookie to impersonate any user.

A more secure approach suggested by Stephen Murdoch in "Hardened Stateless
Session Cookies", is to store an iterated hash of the hashed password in the
database and use the hashed password itself within the session.

  # on login
  my $hashed_pw = bcrypt( $password );
  if ( bcrypt( $hashed_pw ) eq $double_hashed_pw_from_db ) {
    session user => $user;
    session auth => $hashed_pw;
  }

  # on each request
  if ( $double_hashed_pw_from_db ne bcrypt( session("auth") ) ) {
    context->destroy_session;
  }

This latter approach means that even a compromise of the secret key and the
database contents can't be used to impersonate a user because doing so would
requiring reversing a one-way hash to determine the correct authenticator to
put into the forged cookie.

=head1 SEE ALSO

Papers on secure cookies and cookie session storage:

=for :list
* Liu, Alex X., et al., L<A Secure Cookie Protocol|http://www.cse.msu.edu/~alexliu/publications/Cookie/Cookie_COMNET.pdf>
* Murdoch, Stephen J., L<Hardened Stateless Session Cookies|http://www.cl.cam.ac.uk/~sjm217/papers/protocols08cookies.pdf>
* Fu, Kevin, et al., L<Dos and Don'ts of Client Authentication on the Web|http://pdos.csail.mit.edu/papers/webauth:sec10.pdf>

Other CPAN modules providing cookie session storage (possibly for other frameworks):

=for :list
* L<Dancer::Session::Cookie> -- Dancer 1 precursor to this module, encryption only, no MAC
* L<Plack::Middleware::Session::Cookie> -- MAC only
* L<Catalyst::Plugin::CookiedSession> -- encryption only

=cut

# vim: ts=2 sts=2 sw=2 et: