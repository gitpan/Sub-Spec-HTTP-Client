package Sub::Spec::HTTP::Client;
BEGIN {
  $Sub::Spec::HTTP::Client::VERSION = '0.04';
}
# ABSTRACT: Call remote functions via HTTP

use 5.010;
use strict;
use warnings;
use Log::Any '$log';

use HTTP::Request;
use HTTP::Response;
use JSON;
use LWP::Debug;
use LWP::Protocol;
use LWP::UserAgent;

require Exporter;
our @ISA       = qw(Exporter);
our @EXPORT_OK = qw(call_sub_http);

our %SPEC;

my @logging_methods = Log::Any->logging_methods();
my $json = JSON->new->allow_nonref;

sub _get_default_log_level {
    if ($ENV{LOG_LEVEL}) {
        return $ENV{LOG_LEVEL};
    } elsif ($ENV{TRACE}) {
        return "trace";
    } elsif ($ENV{DEBUG}) {
        return "debug";
    } elsif ($ENV{VERBOSE}) {
        return "info";
    } elsif ($ENV{QUIET}) {
        return "error";
    }
    "";
}

$SPEC{call_sub_http} = {
    summary => 'Call remote functions via HTTP',
    description => <<'_',

The Sub::Spec::HTTP::Server module can serve function call requests over HTTP.
This function does the requests. Basically what this function does is just
construct HTTP request, encode arguments in JSON format into the request body,
send the request, and read the HTTP response.

The HTTP response can contain log messages in HTTP response chunks, which will
be "rethrown" by this function into Log::Any log calls (or fed into callback
subroutine instead, if a callback is provided).

The remote function's response is encoded in JSON format by the server; this
function will decode and return it.

_
    args => {
        url => ['str*' => {
            summary => 'URL of server',
            arg_pos => 0,
        }],
        module => ['str*' => {
            summary => 'Name of module to call',
            match   => qr/^\w+(::\w+)*$/,
            arg_pos => 1,
        }],
        sub => ['str*' => {
            summary => 'Name of function to call',
            match   => qr/^\w+$/,
            arg_pos => 2,
        }],
        args => ['hash' => {
            summary => 'Function arguments',
            arg_pos => 3,
        }],
        implementor => ['str' => {
            summary => 'If specified, use this class for http '.
                'LWP::Protocol::implementor',
            description => <<'_',

To access Unix socket server instead of a normal TCP one, set this to
'LWP::Protocol::http::SocketUnix'.

_
        }],
        log_level => ['str' => {
            summary => 'Request logging output from server',
            in      => [qw/fatal error warn info debug trace/],
        }],
        log_callback => ['code' => {
            summary => 'Pass log messages to callback subroutine',
            description => <<'_',

If log_callback is not provided, log messages will be "rethrown" into Log::Any
logging methods (e.g. $log->warn(), $log->debug(), etc).

_
        }],
    },
};
sub call_sub_http {
    my %args = @_;

    # XXX schema
    my $url    = $args{url}
        or return [400, "Please specify url"];
    my $module = $args{module}
        or return [400, "Please specify module"];
    $module =~ /\A\w+(::\w+)*\z/
        or return [400, "Invalid module: use 'Foo::Bar' syntax"];
    my $sub    = $args{sub}
        or return [400, "Please specify sub"];
    $sub =~ /\A\w+\z/
        or return [400, "Invalid sub: use alphanums only"];
    my $args   = $args{args} // {};
    ref($args) eq 'HASH'
        or return [400, "Invalid args: must be hash"];
    my $imp = $args{implementor};
    !$imp || $imp =~ /\A\w+(?:::\w+)*\z/
        or return [400, "Invalid implementor: use 'Foo::Bar' syntax"];
    my $log_level = $args{log_level} // _get_default_log_level();
    my $log_callback = $args{log_callback};
    !$log_callback || ref($log_callback) eq 'CODE'
        or return [400, "Invalid log_callback: must be a coderef"];

    state $ua;
    state @body;
    state $http_res;
    state $in_body;
    if (!$ua) {
        $ua = LWP::UserAgent->new;
        $ua->env_proxy;
        $ua->set_my_handler(
            "response_data",
            sub {
                my ($resp, $ua, $h, $data) = @_;
                # LWP::UserAgent can chop a single chunk from server into
                # several chunks
                if ($in_body) {
                    push @body, $data;
                    return 1;
                }

                $data =~ s/(.)//;
                my $chunk_type = $1;
                if ($chunk_type eq 'L') {
                    if ($log_callback) {
                        $log_callback->($data);
                    } else {
                        $data =~ s/^\[(\w+)\]//;
                        my $method = $1;
                        $method = "error" unless $method ~~ @logging_methods;
                        $log->$method("[$url] $data");
                    }
                    return 1;
                } elsif ($chunk_type eq 'R') {
                    $in_body++;
                    push @body, $data;
                    return 1;
                } else {
                    $http_res = [
                        500,
                        "Unknown chunk type from server: $chunk_type"];
                    return 0;
                }
            }
        );
        $ua->set_my_handler(
            "response_done",
            sub {
                my ($resp, $ua, $h) = @_;
                $http_res = HTTP::Response->parse(join "", @body);
            },
        );

    }
    $http_res = undef;
    @body     = ();
    $in_body  = 0;

    my $req = HTTP::Request->new(POST => $url);
    $req->header('Accept' => 'application/json');
    $req->header('X-SS-Log-Level' => $log_level);
    $req->header('X-SS-Mark-Chunk' => 1);
    my $args_s = $json->encode($args) . "\n";
    $req->header('Content-Type' => 'application/json');
    $req->header('Content-Length' => length($args_s));
    $req->content($args_s);
    #use Data::Dump; dd $req;

    my $old_imp;
    if ($imp) {
        $old_imp = LWP::Protocol::implementor("http");
        eval "require $imp" or
            return [500, "Can't load $imp: $@"];
        LWP::Protocol::implementor("http", $imp);
    }

    my $http0_res;
    eval { $http0_res = $ua->request($req) };
    my $eval_err = $@;

    if ($old_imp) {
        LWP::Protocol::implementor("http", $old_imp);
    }

    return [500, "Network failure: ".$http0_res->code." - ".$http0_res->message]
        unless $http0_res->is_success;
    return [500, "Client died: $eval_err"] if $eval_err;
    return [500, "Incomplete chunked response from server"] unless $http_res;
    return [500, "Empty response from server"] if !length($http_res->content);

    my $res;
    eval {
        #$log->debugf("http_res content: %s", $http_res->content);
        $res = $json->decode($http_res->content);
    };
    $eval_err = $@;
    return [500, "Invalid JSON from server: $eval_err"] if $eval_err;

    #use Data::Dump; dd $res;
    $res;
}

1;


=pod

=head1 NAME

Sub::Spec::HTTP::Client - Call remote functions via HTTP

=head1 VERSION

version 0.04

=head1 SYNOPSIS

 use Sub::Spec::HTTP::Client qw(call_sub_http);
 my $res = call_sub_http(
     url    => 'https://localhost:1234/',
     module => 'Foo::Bar',
     sub    => 'my_sub',
     args   => {arg1=>1, arg2=>2},
 );

=head1 DESCRIPTION

This module provides one function, B<call_sub_http>.

This module uses L<Log::Any>.

This module's functions has L<Sub::Spec> specs.

=head1 FUNCTIONS

None are exported, but they can be.

=head2 call_sub_http(%args) -> [STATUS_CODE, ERR_MSG, RESULT]


Call remote functions via HTTP.

The Sub::Spec::HTTP::Server module can serve function call requests over HTTP.
This function does the requests. Basically what this function does is just
construct HTTP request, encode arguments in JSON format into the request body,
send the request, and read the HTTP response.

The HTTP response can contain log messages in HTTP response chunks, which will
be "rethrown" by this function into Log::Any log calls (or fed into callback
subroutine instead, if a callback is provided).

The remote function's response is encoded in JSON format by the server; this
function will decode and return it.

Returns a 3-element arrayref. STATUS_CODE is 200 on success, or an error code
between 3xx-5xx (just like in HTTP). ERR_MSG is a string containing error
message, RESULT is the actual result.

Arguments (C<*> denotes required arguments):

=over 4

=item * B<url>* => I<str>

URL of server.

=item * B<module>* => I<str>

Name of module to call.

=item * B<sub>* => I<str>

Name of function to call.

=item * B<args> => I<hash>

Function arguments.

=item * B<implementor> => I<str>

If specified, use this class for http LWP::Protocol::implementor.

To access Unix socket server instead of a normal TCP one, set this to
'LWP::Protocol::http::SocketUnix'.

=item * B<log_callback> => I<code>

Pass log messages to callback subroutine.

If log_callback is not provided, log messages will be "rethrown" into Log::Any
logging methods (e.g. $log->warn(), $log->debug(), etc).

=item * B<log_level> => I<str>

Value must be one of:

 ["fatal", "error", "warn", "info", "debug", "trace"]


Request logging output from server.

=back

=head1 BUGS/LIMITATIONS/TODOS

If you use the L<LWP::Protocol::http::SocketUnix> implementor, you will get a
network failure error: "500 - No Host option provided". This is a reported bug
in LWP::Protocol::http::SocketUnix. For detailed description and remedy, see:

 https://rt.cpan.org/Public/Bug/Display.html?id=65670

=head1 SEE ALSO

L<Sub::Spec>

L<Sub::Spec::HTTP::Server>

=head1 AUTHOR

Steven Haryanto <stevenharyanto@gmail.com>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2011 by Steven Haryanto.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut


__END__

