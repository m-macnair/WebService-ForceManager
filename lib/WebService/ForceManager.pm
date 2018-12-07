use strict;
package WebService::ForceManager;
use 5.006;
use warnings;
use Carp qw/carp croak/;
use Module::Runtime qw/ require_module /;
=head1 NAME

	WebService::ForceManager;

=head1 VERSION

	Version 0.01

=cut

our $VERSION = '0.01';


=head1 SYNOPSIS

	Perl wrapper around the www.forcemanager.com (FM) JSON API v4 with guard rails and sugar

=head1 Dependencies
	JSON
	Carp
	LWP::UserAgent
	Module::Runtime
=head1 EXPORT

	None - this module is a self contained OO contraption with plugins.

=head1 SUBROUTINES/METHODS
=head2 Critical Path
=head3 new
	Required
		apiuser - The API user ident, this significantly is *NOT* a web service or mobile application user name and would be issued by FM seperately
		apipassword - Should be issued by FM with the username
	
	optional parameters 
		baseurl - all API calls go to $this value with some suffix or other - defaults to "https://api.forcemanager.net/api/v4"
		debug - debug mode to this and all child modules, 0/undef for none , 1 for "basic", 2 for "and dump the json while you're at it"
		skipsessioninit - FM Transactions are based around an hour~ long key issued. If this parameter is supplied it's assumed one already exists and we're using it

		modules - A href of pre-initialised modules using the full package name as the key. Absence will cause this module to create new instances on demand.
			JSON - JSON set to utf8
			LWP::UserAgent
			WebService::ForceManager::EndPoint::*

=cut

sub new {
	my ( $proto, $conf ) = @_;
	my $class = ref ( $proto ) || $proto;
	my $self = bless {}, $class;
	for(qw/ apiuser apipassword /){
		die "required new() parameter [$_] not supplied" unless $conf->{$_};
		$self->{conf}->{$_} = $conf->{$_};
	}

	for ( qw/baseurl debug skipsessioninit/ ) {
		$self->{conf}->{$_} = $conf->{$_} if exists ( $conf->{$_} );
	}
	
	
	if(ref($conf->{modules}) eq 'HASH'){
		for (qw/
			JSON
		/){
			if (
				$conf->{modules}->{$_}
				and ref($conf->{modules}->{$_}) eq $_
			){
				$self->{modules}->{$_} = $conf->{modules}->{$_};
			}
		}
	}

	$self->{conf}->{baseurl} ||= "https://api.forcemanager.net/api/v4";

	return $self;

}

=head3 sessionkey
	Get/set the sessionkey, generating a new one if the existing one has timed out
	This sets the identifier for the communication session between the module and FM and is valid for 1hr~
	
	Params
		t - pass this to explicitly set the key, will need validfrom parameter as well otherwise a new session will be started
		validfrom - local epoch seconds since the key was issued
		init - set this to a true value to generate a new session, ignores the other values
=cut

sub session_token {
	my ($self,$params) = @_;

	if(ref($params) eq 'HASH' ){
		if($params->{init}){
			$self->getsessionkey();
		} else {
			for(qw/token validfrom/){
				$self->{session}->{$_} = $params->{$_};
			}
		}
	}

	if((time - $self->{session}->{validfrom}) > 3600 ) {
		delete $self->{session};
		$self->getsessionkey();
	}

	return $self->{session}->{token};
}


=head3 _get_session
	Initialise a session and store the token
=cut


sub _get_session {

	my ( $self ) = @_;
	my $req = $self->generic_request(
		'/login',
		'post',
		{
			username => $self->{conf}->{apiuser},
			password => $self->{conf}->{apipassword},
		}
	);
	my $json_response = $req->{response}->decoded_content();
	die( "Did not recieve json in session key request response : " . $req->{response}->status_line ) unless $json_response;
	
	#TODO check this actually works
	my $credentials = $self->{modules}->{JSON}->decode_json( $json );

	
	$self->{session}->{token} = { 'X-Session-Key' => $credentials->{token} };
	$self->{sessionstart} = time;

}


=head2 request
	Send a href to FM with the correct headers
=cut


sub request {

	my ( $self, $action, $method, $contenthref, $headers ) = @_;

	#The request response may matter more than the content
	$contenthref ||= {};
	my $json = $self->json->encode( $contenthref );
	warn $json if $self->{debug};
	my $rqurl = $self->url_for( $action );

	return $self->exact_request( $rqurl, $method, \$json, $headers );

}
=head2
	TODO make this more useful
	To exactly $rqurl, using $method, send exactly $$conteref with $headers
=cut

sub exact_request {
	my ( $self, $rqurl, $method, $contentref, $headers ) = @_;

	$headers ||= {};

	#methods must be lower case
	$rqurl = lc ( $rqurl );

	#universally required (apparently)
	my $localheaders = {
		Accept => '*/*',
		%{$headers}
	};

	if ( $$contentref ) {
		$localheaders->{"Content-Type"} = 'application/json';
		$localheaders->{"Content"} = $$contentref;
	}

	require ;
	my $ua = LWP::UserAgent->new();
	warn "$method : $rqurl content : $$contentref " if $self->{debug};
	return {
		pass => 1,
		ua => $ua,
		response => $ua->$method( $rqurl, %$localheaders ),
	};

}



=head2 Utility

=head3 _lload
	using Module::Runtime, assign a module to $self correctly - should only be used by wrappers
=cut

sub _lload {
	my ( $self, $p ) = @_;

	#what else might be needed? :|
	for ( qw/ module / ) {
		die unless $p->{$_};
	}

	#defaults
	my $tag      = $p->{tag}      || 'default';
	

	#create new unless exists already
	unless ( $self->{modules}->{ $p->{module} } ) {
		die "module loading failed : $! " unless require_module( $p->{module} );
		if ( $p->{initsub} ) {
			$self->{modules}->{ $p->{module} } = &{ $p->{initsub} }( $p );
		} else {
			$self->{modules}->{ $p->{module} } = "$p->{module}"->new();
		}
	}
	return $self->{modules}->{ $p->{module} };
}
=head3 _lloadwrappers
=head4 json
	Create a JSON instance with utf8 set to 'yes'
=cut
sub json {
	my ( $self, $p ) = @_;
	return $self->_lload({
		module => 'JSON',
		initsub => \&_init_json
	});
}
sub _init_json { 
	my ($self) = @_;
	return "JSON"->new->utf8();
}

sub useragent { 
	my ( $self, $p ) = @_;
	return $self->_lload({
		module => 'LWP::UserAgent',
	});

}



=head1 AUTHOR

mmacnair, C<< <mmacnair at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-webservice-forcemanager at rt.cpan.org>, or through
the web interface at L<https://rt.cpan.org/NoAuth/ReportBug.html?Queue=WebService-ForceManager>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.


=head1 SUPPORT
	The ForceManager API itself is under active development, you can find the up-to-date documentation for the API itself here L<https://developer.forcemanager.net/>
	Any useful documentation missing from WebService::ForceManager should be considered a bug!

=over 4

=item * RT: CPAN's request tracker (report bugs here)

L<https://rt.cpan.org/NoAuth/Bugs.html?Dist=WebService-ForceManager>


=item * CPAN Ratings

L<https://cpanratings.perl.org/d/WebService-ForceManager>

=item * Search CPAN

L<https://metacpan.org/release/WebService-ForceManager>

=back


=head1 ACKNOWLEDGEMENTS
	TravelTek (L<httpsL//www.traveltek.com>) for granting me permission to adapt ready::DataInterfaces::ForceManager into this distribution
	Forcemanager : Armand Dalmau & Luke White

=head1 LICENSE AND COPYRIGHT

Copyright 2018 mmacnair.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut

1; # End of WebService::ForceManager
