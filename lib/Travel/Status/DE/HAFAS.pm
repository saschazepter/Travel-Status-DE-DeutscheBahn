package Travel::Status::DE::HAFAS;

use strict;
use warnings;
use 5.014;
use utf8;

no if $] >= 5.018, warnings => 'experimental::smartmatch';

use Carp qw(confess);
use DateTime;
use DateTime::Format::Strptime;
use Digest::MD5 qw(md5_hex);
use Encode      qw(decode encode);
use JSON;
use List::Util qw(any);
use LWP::UserAgent;
use POSIX qw(strftime);
use Travel::Status::DE::HAFAS::Message;
use Travel::Status::DE::HAFAS::Result;
use Travel::Status::DE::HAFAS::StopFinder;

our $VERSION = '3.01';

my %hafas_instance = (
	DB => {
		stopfinder  => 'https://reiseauskunft.bahn.de/bin/ajax-getstop.exe',
		mgate       => 'https://reiseauskunft.bahn.de/bin/mgate.exe',
		name        => 'Deutsche Bahn',
		productbits => [qw[ice ic_ec d regio s bus ferry u tram ondemand]],
		salt        => 'bdI8UVj4' . '0K5fvxwf',
		request     => {
			client => {
				id   => 'DB',
				v    => '20100000',
				type => 'IPH',
				name => 'DB Navigator',
			},
			ext  => 'DB.R21.12.a',
			ver  => '1.15',
			auth => {
				type => 'AID',
				aid  => 'n91dB8Z77' . 'MLdoR0K'
			},
		},
	},
	NAHSH => {
		mgate       => 'https://nah.sh.hafas.de/bin/mgate.exe',
		stopfinder  => 'https://nah.sh.hafas.de/bin/ajax-getstop.exe',
		name        => 'Nahverkehrsverbund Schleswig-Holstein',
		productbits => [qw[ice ice ice regio s bus ferry u tram ondemand]],
		request     => {
			client => {
				id   => 'NAHSH',
				v    => '3000700',
				type => 'IPH',
				name => 'NAHSHPROD',
			},
			ver  => '1.16',
			auth => {
				type => 'AID',
				aid  => 'r0Ot9FLF' . 'NAFxijLW'
			},
		},
	},
	NASA => {
		mgate       => 'https://reiseauskunft.insa.de/bin/mgate.exe',
		stopfinder  => 'https://reiseauskunft.insa.de/bin/ajax-getstop.exe',
		name        => 'Nahverkehrsservice Sachsen-Anhalt',
		productbits => [qw[ice ice regio regio regio tram bus ondemand]],
		request     => {
			client => {
				id   => 'NASA',
				v    => '4000200',
				type => 'IPH',
				name => 'nasaPROD',
				os   => 'iPhone OS 13.1.2',
			},
			ver  => '1.18',
			auth => {
				type => 'AID',
				aid  => 'nasa-' . 'apps',
			},
			lang => 'deu',
		},
	},
	NVV => {
		mgate      => 'https://auskunft.nvv.de/auskunft/bin/app/mgate.exe',
		stopfinder =>
		  'https://auskunft.nvv.de/auskunft/bin/jp/ajax-getstop.exe',
		name        => 'Nordhessischer VerkehrsVerbund',
		productbits =>
		  [qw[ice ic_ec regio s u tram bus bus ferry ondemand regio regio]],
		request => {
			client => {
				id   => 'NVV',
				v    => '5000300',
				type => 'IPH',
				name => 'NVVMobilPROD_APPSTORE',
				os   => 'iOS 13.1.2',
			},
			ext  => 'NVV.6.0',
			ver  => '1.18',
			auth => {
				type => 'AID',
				aid  => 'Kt8eNOH7' . 'qjVeSxNA',
			},
			lang => 'deu',
		},
	},
	'ÖBB' => {
		mgate       => 'https://fahrplan.oebb.at/bin/mgate.exe',
		stopfinder  => 'https://fahrplan.oebb.at/bin/ajax-getstop.exe',
		name        => 'Österreichische Bundesbahnen',
		productbits =>
		  [qw[ice ice ice regio regio s bus ferry u tram ice ondemand ice]],
		request => {
			client => {
				id   => 'OEBB',
				v    => '6030600',
				type => 'IPH',
				name => 'oebbPROD-ADHOC',
			},
			ver  => '1.41',
			auth => {
				type => 'AID',
				aid  => 'OWDL4fE4' . 'ixNiPBBm',
			},
			lang => 'deu',
		},
	},
	VBB => {
		mgate       => 'https://fahrinfo.vbb.de/bin/mgate.exe',
		stopfinder  => 'https://fahrinfo.vbb.de/bin/ajax-getstop.exe',
		name        => 'Verkehrsverbund Berlin-Brandenburg',
		productbits => [qw[s u tram bus ferry ice regio]],
		request     => {
			client => {
				id   => 'VBB',
				type => 'WEB',
				name => 'VBB WebApp',
				l    => 'vs_webapp_vbb',
			},
			ext  => 'VBB.1',
			ver  => '1.33',
			auth => {
				type => 'AID',
				aid  => 'hafas-vb' . 'b-webapp',
			},
			lang => 'deu',
		},
	},
	VBN => {
		mgate       => 'https://fahrplaner.vbn.de/bin/mgate.exe',
		stopfinder  => 'https://fahrplaner.vbn.de/hafas/ajax-getstop.exe',
		name        => 'Verkehrsverbund Bremen/Niedersachsen',
		productbits => [qw[ice ice regio regio s bus ferry u tram ondemand]],
		salt        => 'SP31mBu' . 'fSyCLmNxp',
		micmac      => 1,
		request     => {
			client => {
				id   => 'VBN',
				v    => '6000000',
				type => 'IPH',
				name => 'vbn',
			},
			ver  => '1.42',
			auth => {
				type => 'AID',
				aid  => 'kaoxIXLn' . '03zCr2KR',
			},
			lang => 'deu',
		},
	},
);

sub new {
	my ( $obj, %conf ) = @_;
	my $service = $conf{service};

	my %lwp_options = %{ $conf{lwp_options} // { timeout => 10 } };

	my $ua = LWP::UserAgent->new(%lwp_options);

	$ua->env_proxy;

	if ( not $conf{station} ) {
		confess('You need to specify a station');
	}

	if ( not defined $service and not defined $conf{url} ) {
		$service = $conf{service} = 'DB';
	}

	if ( defined $service and not exists $hafas_instance{$service} ) {
		confess("The service '$service' is not supported");
	}

	my $ref = {
		active_service => $service,
		arrivals       => $conf{arrivals},
		developer_mode => $conf{developer_mode},
		exclusive_mots => $conf{exclusive_mots},
		excluded_mots  => $conf{excluded_mots},
		messages       => [],
		results        => [],
		station        => $conf{station},
		ua             => $ua,
		now            => DateTime->now( time_zone => 'Europe/Berlin' ),
	};

	bless( $ref, $obj );

	if ( $hafas_instance{$service}{mgate} ) {
		return $ref->new_mgate(%conf);
	}
	return $ref->new_legacy(%conf);
}

sub new_mgate {
	my ( $self, %conf ) = @_;
	my $json    = JSON->new->utf8;
	my $service = $conf{service};

	my $now  = $self->{now};
	my $date = ( $conf{datetime} // $now )->strftime('%Y%m%d');
	my $time = ( $conf{datetime} // $now )->strftime('%H%M%S');

	my $lid;
	if ( $self->{station} =~ m{ ^ [0-9]+ $ }x ) {
		$lid = 'A=1@L=' . $self->{station} . '@';
	}
	else {
		$lid = 'A=1@O=' . $self->{station} . '@';
	}

	my $mot_mask = 2**@{ $hafas_instance{$service}{productbits} } - 1;

	my %mot_pos;
	for my $i ( 0 .. $#{ $hafas_instance{$service}{productbits} } ) {
		$mot_pos{ $hafas_instance{$service}{productbits}[$i] } = $i;
	}

	if ( my @mots = @{ $self->{exclusive_mots} // [] } ) {
		$mot_mask = 0;
		for my $mot (@mots) {
			$mot_mask |= 1 << $mot_pos{$mot};
		}
	}

	if ( my @mots = @{ $self->{excluded_mots} // [] } ) {
		for my $mot (@mots) {
			$mot_mask &= ~( 1 << $mot_pos{$mot} );
		}
	}

	my $req = {
		svcReqL => [
			{
				req => {
					type     => ( $conf{arrivals} ? 'ARR' : 'DEP' ),
					stbLoc   => { lid => $lid },
					dirLoc   => undef,
					maxJny   => 30,
					date     => $date,
					time     => $time,
					dur      => -1,
					jnyFltrL =>
					  [ { type => "PROD", mode => "INC", value => $mot_mask } ]
				},
				meth => 'StationBoard'
			}
		],
		%{ $hafas_instance{$service}{request} }
	};

	$req = $json->encode($req);
	$self->{post} = $req;

	my $url = $conf{url} // $hafas_instance{$service}{mgate};

	if ( my $salt = $hafas_instance{$service}{salt} ) {
		if ( $hafas_instance{$service}{micmac} ) {
			my $mic = md5_hex( $self->{post} );
			my $mac = md5_hex( $mic . $salt );
			$url .= "?mic=$mic&mac=$mac";
		}
		else {
			$url .= '?checksum=' . md5_hex( $self->{post} . $salt );
		}
	}

	if ( $conf{json} ) {
		$self->{raw_json} = $conf{json};
	}
	else {
		if ( $self->{developer_mode} ) {
			say "requesting $req from $url";
		}

		my $reply = $self->{ua}->post(
			$url,
			'Content-Type' => 'application/json',
			Content        => $self->{post}
		);
		if ( $reply->is_error ) {
			$self->{errstr} = $reply->status_line;
			return $self;
		}

		if ( $self->{developer_mode} ) {
			say decode( 'utf-8', $reply->content );
		}

		$self->{raw_json} = $json->decode( $reply->content );
	}

	$self->check_mgate;
	$self->parse_mgate;

	return $self;
}

sub check_mgate {
	my ($self) = @_;

	if ( $self->{raw_json}{err} and $self->{raw_json}{err} ne 'OK' ) {
		$self->{errstr} = $self->{raw_json}{errTxt}
		  // 'error code is ' . $self->{raw_json}{err};
		$self->{errcode} = $self->{raw_json}{err};
	}
	elsif ( defined $self->{raw_json}{cInfo}{code}
		and $self->{raw_json}{cInfo}{code} ne 'OK'
		and $self->{raw_json}{cInfo}{code} ne 'VH' )
	{
		$self->{errstr}  = 'cInfo code is ' . $self->{raw_json}{cInfo}{code};
		$self->{errcode} = $self->{raw_json}{cInfo}{code};
	}
	elsif ( @{ $self->{raw_json}{svcResL} // [] } == 0 ) {
		$self->{errstr} = 'svcResL is empty';
	}
	elsif ( $self->{raw_json}{svcResL}[0]{err} ne 'OK' ) {
		$self->{errstr}
		  = 'svcResL[0].err is ' . $self->{raw_json}{svcResL}[0]{err};
		$self->{errcode} = $self->{raw_json}{svcResL}[0]{err};
	}

	return $self;
}

sub errcode {
	my ($self) = @_;

	return $self->{errcode};
}

sub errstr {
	my ($self) = @_;

	return $self->{errstr};
}

sub similar_stops {
	my ($self) = @_;

	my $service = $self->{active_service};

	if ( $service and exists $hafas_instance{$service}{stopfinder} ) {

		my $sf = Travel::Status::DE::HAFAS::StopFinder->new(
			url            => $hafas_instance{$service}{stopfinder},
			input          => $self->{station},
			ua             => $self->{ua},
			developer_mode => $self->{developer_mode},
		);
		if ( my $err = $sf->errstr ) {
			$self->{errstr} = $err;
			return;
		}
		return $sf->results;
	}
	return;
}

sub add_message {
	my ( $self, $json, $is_him ) = @_;

	my $short = $json->{txtS};
	my $text  = $json->{txtN};
	my $code  = $json->{code};
	my $prio  = $json->{prio};

	if ($is_him) {
		$short = $json->{head};
		$text  = $json->{text};
		$code  = $json->{hid};
	}

	# Some backends use remL for operator information. We don't want that.
	if ( $code eq 'OPERATOR' ) {
		return;
	}

	for my $message ( @{ $self->{messages} } ) {
		if ( $code eq $message->{code} and $text eq $message->{text} ) {
			$message->{ref_count}++;
			return $message;
		}
	}

	my $message = Travel::Status::DE::HAFAS::Message->new(
		short     => $short,
		text      => $text,
		code      => $code,
		prio      => $prio,
		ref_count => 1,
	);
	push( @{ $self->{messages} }, $message );
	return $message;
}

sub messages {
	my ($self) = @_;
	return @{ $self->{messages} };
}

sub parse_mgate {
	my ($self) = @_;

	$self->{results} = [];

	if ( $self->{errstr} ) {
		return $self;
	}

	$self->{strptime_obj} //= DateTime::Format::Strptime->new(
		pattern   => '%Y%m%dT%H%M%S',
		time_zone => 'Europe/Berlin',
	);

	my @locL  = @{ $self->{raw_json}{svcResL}[0]{res}{common}{locL}  // [] };
	my @prodL = @{ $self->{raw_json}{svcResL}[0]{res}{common}{prodL} // [] };
	my @opL   = @{ $self->{raw_json}{svcResL}[0]{res}{common}{opL}   // [] };
	my @icoL  = @{ $self->{raw_json}{svcResL}[0]{res}{common}{icoL}  // [] };
	my @remL  = @{ $self->{raw_json}{svcResL}[0]{res}{common}{remL}  // [] };
	my @himL  = @{ $self->{raw_json}{svcResL}[0]{res}{common}{himL}  // [] };
	my @jnyL  = @{ $self->{raw_json}{svcResL}[0]{res}{jnyL}          // [] };

	for my $result (@jnyL) {
		my $date = $result->{date};
		my $time_s
		  = $result->{stbStop}{ $self->{arrivals} ? 'aTimeS' : 'dTimeS' };
		my $time_r
		  = $result->{stbStop}{ $self->{arrivals} ? 'aTimeR' : 'dTimeR' };
		my $datetime_s
		  = $self->{strptime_obj}->parse_datetime("${date}T${time_s}");
		my $datetime_r
		  = $time_r
		  ? $self->{strptime_obj}->parse_datetime("${date}T${time_r}")
		  : undef;
		my $delay
		  = $datetime_r
		  ? ( $datetime_r->epoch - $datetime_s->epoch ) / 60
		  : undef;

		my $destination  = $result->{dirTxt};
		my $is_cancelled = $result->{isCncl};
		my $jid          = $result->{jid};
		my $platform     = $result->{stbStop}{dPlatfS};
		my $new_platform = $result->{stbStop}{dPlatfR};

		my $product    = $prodL[ $result->{prodX} ];
		my $train      = $product->{prodCtx}{name};
		my $train_type = $product->{prodCtx}{catOutS};
		my $line_no    = $product->{prodCtx}{line};

		my $operator;
		if ( defined $product->{oprX} ) {
			if ( my $opref = $opL[ $product->{oprX} ] ) {
				$operator = $opref->{name};
			}
		}

		my @messages;
		for my $msg ( @{ $result->{msgL} // [] } ) {
			if ( $msg->{type} eq 'REM' and defined $msg->{remX} ) {
				push( @messages, $self->add_message( $remL[ $msg->{remX} ] ) );
			}
			elsif ( $msg->{type} eq 'HIM' and defined $msg->{himX} ) {
				push( @messages,
					$self->add_message( $himL[ $msg->{himX} ], 1 ) );
			}
			else {
				say "Unknown message type $msg->{type}";
			}
		}

		push(
			@{ $self->{results} },
			Travel::Status::DE::HAFAS::Result->new(
				sched_datetime => $datetime_s,
				rt_datetime    => $datetime_r,
				datetime       => $datetime_r // $datetime_s,
				datetime_now   => $self->{now},
				delay          => $delay,
				is_cancelled   => $is_cancelled,
				train          => $train,
				operator       => $operator,
				route_end      => $destination,
				platform       => $platform,
				new_platform   => $new_platform,
				messages       => \@messages,
			)
		);
	}
	return $self;
}

sub results {
	my ($self) = @_;
	return @{ $self->{results} };
}

# static
sub get_services {
	my @services;
	for my $service ( sort keys %hafas_instance ) {
		my %desc = %{ $hafas_instance{$service} };
		$desc{shortname} = $service;
		push( @services, \%desc );
	}
	return @services;
}

# static
sub get_service {
	my ($service) = @_;

	if ( defined $service and exists $hafas_instance{$service} ) {
		return $hafas_instance{$service};
	}
	return;
}

sub get_active_service {
	my ($self) = @_;

	if ( defined $self->{active_service} ) {
		return $hafas_instance{ $self->{active_service} };
	}
	return;
}

1;

__END__

=head1 NAME

Travel::Status::DE::HAFAS - Interface to HAFAS-based online arrival/departure
monitors

=head1 SYNOPSIS

	use Travel::Status::DE::HAFAS;

	my $status = Travel::Status::DE::HAFAS->new(
		station => 'Essen Hbf',
	);

	if (my $err = $status->errstr) {
		die("Request error: ${err}\n");
	}

	for my $departure ($status->results) {
		printf(
			"At %s: %s to %s from platform %s\n",
			$departure->time,
			$departure->line,
			$departure->destination,
			$departure->platform,
		);
	}

=head1 VERSION

version 3.01

=head1 DESCRIPTION

Travel::Status::DE::HAFAS is an interface to HAFAS-based
arrival/departure monitors, for instance the one available at
L<http://reiseauskunft.bahn.de/bin/bhftafel.exe/dn>.

It takes a station name and (optional) date and time and reports all arrivals
or departures at that station starting at the specified point in time (now if
unspecified).

=head1 METHODS

=over

=item my $status = Travel::Status::DE::HAFAS->new(I<%opts>)

Requests the departures/arrivals as specified by I<opts> and returns a new
Travel::Status::DE::HAFAS element with the results.  Dies if the wrong
I<opts> were passed.

Supported I<opts> are:

=over

=item B<station> => I<station>

The station or stop to report for, e.g.  "Essen HBf" or
"Alfredusbad, Essen (Ruhr)".  Mandatory.

=item B<datetime> => I<DateTime object>

Date and time to report for.  Defaults to now.

=item B<excluded_mots> => [I<mot1>, I<mot2>, ...]

By default, all modes of transport (trains, trams, buses etc.) are returned.
If this option is set, all modes appearing in I<mot1>, I<mot2>, ... will
be excluded. The supported modes depend on B<service>, use
B<get_services> or B<get_service> to get the supported values.

Note that this parameter does not work if the B<url> parameter is set.

=item B<exclusive_mots> => [I<mot1>, I<mot2>, ...]

If this option is set, only the modes of transport appearing in I<mot1>,
I<mot2>, ...  will be returned.  The supported modes depend on B<service>, use
B<get_services> or B<get_service> to get the supported values.

Note that this parameter does not work if the B<url> parameter is set.

=item B<language> => I<language>

Set language for additional information. Accepted arguments are B<d>eutsch,
B<e>nglish, B<i>talian and B<n> (dutch), depending on the used service.

=item B<lwp_options> => I<\%hashref>

Passed on to C<< LWP::UserAgent->new >>. Defaults to C<< { timeout => 10 } >>,
you can use an empty hashref to override it.

=item B<mode> => B<arr>|B<dep>

By default, Travel::Status::DE::HAFAS reports train departures
(B<dep>).  Set this to B<arr> to get arrivals instead.

=item B<service> => I<service>

Request results from I<service>, defaults to "DB".
See B<get_services> (and C<< hafas-m --list >>) for a list of supported
services.

=item B<url> => I<url>

Request results from I<url>, defaults to the one belonging to B<service>.

=back

=item $status->errcode

In case of an error in the HAFAS backend, returns the corresponding error code
as string. If no backend error occurred, returns undef.

=item $status->errstr

In case of an error in the HTTP request or HAFAS backend, returns a string
describing it.  If no error occurred, returns undef.

=item $status->results

Returns a list of arrivals/departures.  Each list element is a
Travel::Status::DE::HAFAS::Result(3pm) object.

If no matching results were found or the parser / http request failed, returns
undef.

=item $status->similar_stops

Returns a list of hashrefs describing stops whose name is similar to the one
requested in the constructor's B<station> parameter. Returns nothing if
the active service does not support this feature.
This is most useful if B<errcode> returns 'H730', which means that the
HAFAS backend could not identify the stop.

See Travel::Status::DE::HAFAS::StopFinder(3pm)'s B<results> method for details
on the return value.

=item $status->get_active_service

Returns a hashref describing the active service when a service is active and
nothing otherwise. The hashref contains the keys B<url> (URL to the station
board service), B<stopfinder> (URL to the stopfinder service, if supported),
B<name>, and B<productbits> (arrayref describing the supported modes of
transport, may contain duplicates).

=item Travel::Status::DE::HAFAS::get_services()

Returns an array containing all supported HAFAS services. Each element is a
hashref and contains all keys mentioned in B<get_active_service>.
It also contains a B<shortname> key, which is the service name used by
the constructor's B<service> parameter.

=item Travel::Status::DE::HAFAS::get_service(I<$service>)

Returns a hashref describing the service I<$service>. Returns nothing if
I<$service> is not supported. See B<get_active_service> for the hashref layout.

=back

=head1 DIAGNOSTICS

None.

=head1 DEPENDENCIES

=over

=item * Class::Accessor(3pm)

=item * DateTime(3pm)

=item * DateTime::Format::Strptime(3pm)

=item * LWP::UserAgent(3pm)

=back

=head1 BUGS AND LIMITATIONS

The non-default services (anything other than DB) are not well tested.

=head1 SEE ALSO

Travel::Status::DE::HAFAS::Result(3pm), Travel::Status::DE::HAFAS::StopFinder(3pm).

=head1 AUTHOR

Copyright (C) 2015-2020 by Daniel Friesel E<lt>derf@finalrewind.orgE<gt>

=head1 LICENSE

This module is licensed under the same terms as Perl itself.
