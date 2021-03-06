package Plack::Middleware::CSRFBlock;
use parent qw(Plack::Middleware);
use strict;
use warnings;

# ABSTRACT: Block CSRF Attacks with minimal changes to your app

use Data::Dumper;
use Digest::SHA1;
use HTML::Parser;
use Plack::Request;
use Plack::TempBuffer;
use Plack::Util;
use Plack::Util::Accessor qw(
    parameter_name header_name add_meta meta_name token_length
    session_key blocked onetime whitelisted
    _token_generator _req
);

# No Data::Dumper pretty printing
$Data::Dumper::Indent = 0;

sub prepare_app {
    my ($self) = @_;

    $self->parameter_name('SEC') unless defined $self->parameter_name;
    $self->token_length(16) unless defined $self->token_length;
    $self->session_key('csrfblock.token') unless defined $self->session_key;
    $self->meta_name('csrftoken') unless defined $self->meta_name;
    $self->add_meta(0) unless defined $self->meta_name;
    $self->whitelisted( sub { 0 } ) unless defined $self->whitelisted;

    # Upper-case header name and replace - with _
    my $header_name = uc($self->header_name || 'X-CSRF-Token') =~ s/-/_/gr;
    $self->header_name( $header_name );

    $self->_token_generator(sub {
        my $token = Digest::SHA1::sha1_hex(rand() . $$ . {} . time);
        substr($token, 0 , $self->token_length);
    });
}

sub log {
    my ($self, $level, $msg, %args) = @_;
    # Do we want to include env in the log?
    my $include_env = $args{env} // 0;

    my $req = $self->_req;
    return unless $req;

    $msg = "CSRFBLOCK: $msg";
    $msg .= ' ENV: ' . Dumper( $req->env ) if $include_env;

    if ( $req->logger ) {
        $req->logger->({ level => $level, message => $msg });
    } else {
        print STDERR $msg . "\n";
    }
}

sub call {
    my($self, $env) = @_;

    # Generate a Plack Request for this request
    my $request = Plack::Request->new( $env );

    # Set the request on self
    $self->_req( $request );

    # We need a session
    my $session = $request->session;
    unless ($session) {
        $self->log( error => 'No session found!' );
        die "CSRFBlock needs Session." unless $session;
    }

    my $token = $session->{$self->session_key};
    my $whitelisted = $self->whitelisted->( $request );
    if( $request->method =~ m{^post$}i && !$whitelisted ) {
        # Log the request with env info
        $self->log( info => 'Got POST Request', env => 1 );

        # If we don't have a token, can't do anything
        return $self->token_not_found( $env ) unless $token;

        my $found;

        # First, check if the header is set correctly.
        $found = ( $request->header( $self->header_name ) || '') eq $token;

        $self->log( info => 'Found in Header? : ' . ($found ? 1 : 0) );

        # If the token wasn't set, let's check the params
        unless ($found) {
            my $val = $request->parameters->{ $self->parameter_name } || '';
            $found = $val eq $token;
            $self->log( info => 'Found in parameters : ' . ($found ? 1 : 0) );
        }

        return $self->token_not_found($env) unless $found;

        # If we are using onetime token, remove it from the session
        delete $session->{$self->session_key} if $self->onetime;
    }

    return $self->response_cb($self->app->($env), sub {
        my $res = shift;
        my $ct = Plack::Util::header_get($res->[1], 'Content-Type') || '';
        if($ct !~ m{^text/html}i and $ct !~ m{^application/xhtml[+]xml}i){
            return $res;
        }

        my @out;
        my $http_host = $request->uri->host;
        my $token = $session->{$self->session_key} ||= $self->_token_generator->();
        my $parameter_name = $self->parameter_name;

        my $p = HTML::Parser->new(
            api_version => 3,
            start_h => [sub {
                my($tag, $attr, $text) = @_;
                push @out, $text;

                no warnings 'uninitialized';

                $tag = lc($tag);
                # If we found the head tag and we want to add a <meta> tag
                if( $tag eq 'head' && $self->add_meta ) {
                    # Put the csrftoken in a <meta> element in <head>
                    # So that you can get the token in javascript in your
                    # App to set in X-CSRF-Token header for all your AJAX
                    # Requests
                    my $name = $self->meta_name;
                    push @out, "<meta name=\"$name\" content=\"$token\"/>";
                }

                # If tag isn't 'form' and method isn't 'post' we dont care
                return unless $tag eq 'form' && $attr->{'method'} =~ /post/i;

                if(
                    !($attr->{'action'} =~ m{^https?://([^/:]+)[/:]}
                            and $1 ne $http_host)
                ) {
                    push @out, '<input type="hidden" ' .
                               "name=\"$parameter_name\" value=\"$token\" />";
                }

                # TODO: determine xhtml or html?
                return;
            }, "tagname, attr, text"],
            default_h => [\@out , '@{text}'],
        );
        my $done;

        return sub {
            return if $done;

            if(defined(my $chunk = shift)) {
                $p->parse($chunk);
            }
            else {
                $p->eof;
                $done++;
            }
            join '', splice @out;
        }
    });
}

sub token_not_found {
    my ($self, $env) = (shift, shift);

    $self->log( error => 'Token not found, returning 403!', env => 1 );

    if(my $app_for_blocked = $self->blocked) {
        return $app_for_blocked->($env, @_);
    }
    else {
        my $body = 'CSRF detected';
        return [
            403,
            [ 'Content-Type' => 'text/plain', 'Content-Length' => length($body) ],
            [ $body ]
        ];
    }
}

1;
__END__

=head1 SYNOPSIS

[![Build Status](https://secure.travis-ci.org/throughnothing/Plack-Middleware-CSRFBlock.png?branch=master)](http://travis-ci.org/throughnothing/Plack-Middleware-CSRFBlock)

  use Plack::Builder;

  my $app = sub { ... }

  builder {
    enable 'Session';
    enable 'CSRFBlock';
    $app;
  }

=head1 DESCRIPTION

This middleware blocks CSRF. You can use this middleware without any modifications
to your application, in most cases. Here is the strategy:

=over 4

=item output filter

When the application response content-type is "text/html" or
"application/xhtml+xml", this inserts hidden input tag that contains token
string into C<form>s in the response body.  It can also adds an optional meta
tag (by setting C<add_meta> to true) with the default name "csrftoken".
For example, the application response body is:

  <html>
    <head>
        <title>input form</title>
    </head>
    <body>
      <form action="/receive" method="post">
        <input type="text" name="email" /><input type="submit" />
      </form>
  </html>

this becomes:

  <html>
    <head><meta name="csrftoken" content="0f15ba869f1c0d77"/>
        <title>input form</title>
    </head>
    <body>
      <form action="/api" method="post"><input type="hidden" name="SEC" value="0f15ba869f1c0d77" />
        <input type="text" name="email" /><input type="submit" />
      </form>
  </html>

This affects C<form> tags with C<method="post">, case insensitive.

=item input check

For every POST requests, this module checks the C<X-CSRF-Token> header first,
then C<POST> input parameters. If the correct token is not ofund in either,
then a 403 Forbidden is returned by default.

Supports C<application/x-www-form-urlencoded> and C<multipart/form-data> for
input parameters, but any C<POST> will be validated with the C<X-CSRF-Token>
header.  Thus, every C<POST> will have to have either the header, or the
appropriate form parameters in the body.

=item javascript

This module can be used easily with javascript by having your javascript
provide the C<X-CSRF-Token> with any ajax C<POST> requests it makes.  You can
get the C<token> in javascript by getting the value of the C<csrftoken> C<meta>
tag in the page <head>.  Here is sample code that will work for C<jQuery>:

    $(document).ajaxSend(function(e, xhr, options) {
        var token = $("meta[name='csrftoken']").attr("content");
        xhr.setRequestHeader("X-CSRF-Token", token);
    });

This will include the X-CSRF-Token header with any C<AJAX> requests made from
your javascript.

=back

=head1 OPTIONS

  use Plack::Builder;
  
  my $app = sub { ... }
  
  builder {
    enable 'Session';
    enable 'CSRFBlock',
      parameter_name => 'csrf_secret',
      token_length => 20,
      session_key => 'csrf_token',
      blocked => sub {
        [302, [Location => 'http://www.google.com'], ['']];
      },
      onetime => 0,
      ;
    $app;
  }

=over 4

=item whitelisted (default: sub { 0 })

Whitelisted needs to be a sub reference which is passed the current request
object (L<Plack::Request>) as it's only argument.  The sub needs to return
true if the url should be whitelisted and false otherwise.  By default it
always returns false.

=item parameter_name (default:"SEC")

Name of the input tag for the token.

=item add_meta (default: 0)

Whether or not to append a C<meta> tag to pages that
contains the token.  This is useful for getting the
value of the token from Javascript.  The name of the
meta tag can be set via C<meta_name> which defaults
to C<csrftoken>.

=item meta_name (default:"csrftoken")

Name of the C<meta> tag added to the C<head> tag of
output pages.  The content of this C<meta> tag will be
the token value.  The purpose of this tag is to give
javascript access to the token if needed for AJAX requests.

=item header_name (default:"X-CSRF-Token")

Name of the HTTP Header that the token can be sent in.
This is useful for sending the header for Javascript AJAX requests,
and this header is required for any post request that is not
of type C<application/x-www-form-urlencoded> or C<multipart/form-data>.

=item token_length (default:16);

Length of the token string. Max value is 40.

=item session_key (default:"csrfblock.token")

This middleware uses L<Plack::Middleware::Session> for token storage. this is
the session key for that.

=item blocked (default:403 response)

The application called when CSRF is detected.

Note: This application can read posted data, but DO NOT use them!

=item onetime (default:FALSE)

If this is true, this middleware uses B<onetime> token, that is, whenever
client sent collect token and this middleware detect that, token string is
regenerated.

This makes your applications more secure, but in many cases, is too strict.

=back

=head1 SEE ALSO

L<Plack::Middleware::Session>
