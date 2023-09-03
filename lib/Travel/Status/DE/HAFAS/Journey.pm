package Travel::Status::DE::HAFAS::Journey;

# vim:foldmethod=marker

use strict;
use warnings;
use 5.014;

no if $] >= 5.018, warnings => 'experimental::smartmatch';

use parent 'Class::Accessor';
use DateTime::Format::Strptime;
use List::Util qw(any);
use Travel::Status::DE::HAFAS::Stop;

our $VERSION = '4.16';

Travel::Status::DE::HAFAS::Journey->mk_ro_accessors(
	qw(datetime sched_datetime rt_datetime
	  is_cancelled is_partially_cancelled
	  station station_eva platform sched_platform rt_platform operator
	  id name type type_long class number line line_no load delay
	  route_end route_start origin destination direction)
);

# {{{ Constructor

sub new {
	my ( $obj, %opt ) = @_;

	my @locL  = @{ $opt{common}{locL}  // [] };
	my @prodL = @{ $opt{common}{prodL} // [] };
	my @opL   = @{ $opt{common}{opL}   // [] };
	my @icoL  = @{ $opt{common}{icoL}  // [] };
	my @tcocL = @{ $opt{common}{tcocL} // [] };
	my @remL  = @{ $opt{common}{remL}  // [] };
	my @himL  = @{ $opt{common}{himL}  // [] };

	my $hafas   = $opt{hafas};
	my $journey = $opt{journey};

	my $date = $journey->{date};

	my $direction = $journey->{dirTxt};
	my $jid       = $journey->{jid};

	my $is_cancelled        = $journey->{isCncl};
	my $partially_cancelled = $journey->{isPartCncl};

	my $product  = $prodL[ $journey->{prodX} ];
	my $name     = $product->{addName} // $product->{name};
	my $line_no  = $product->{prodCtx}{line};
	my $train_no = $product->{prodCtx}{num};
	my $cat      = $product->{prodCtx}{catOut};
	my $catlong  = $product->{prodCtx}{catOutL};
	if ( $name and $cat and $name eq $cat ) {
		$name .= ' ' . $product->{nameS};
	}
	if ( defined $train_no and not $train_no ) {
		$train_no = undef;
	}
	if (
		    not defined $line_no
		and defined $product->{prodCtx}{matchId}
		and
		( not defined $train_no or $product->{prodCtx}{matchId} ne $train_no )
	  )
	{
		$line_no = $product->{prodCtx}{matchId};
	}

	my $operator;
	if ( defined $product->{oprX} ) {
		if ( my $opref = $opL[ $product->{oprX} ] ) {
			$operator = $opref->{name};
		}
	}

	my @messages;
	for my $msg ( @{ $journey->{msgL} // [] } ) {
		if ( $msg->{type} eq 'REM' and defined $msg->{remX} ) {
			push( @messages, $hafas->add_message( $remL[ $msg->{remX} ] ) );
		}
		elsif ( $msg->{type} eq 'HIM' and defined $msg->{himX} ) {
			push( @messages, $hafas->add_message( $himL[ $msg->{himX} ], 1 ) );
		}
		else {
			say "Unknown message type $msg->{type}";
		}
	}

	my $date_ref = ( split( qr{[|]}, $jid ) )[4];
	if ( length($date_ref) < 7 ) {
		warn("HAFAS, not even once -- midnight crossing may be bogus");
	}
	if ( length($date_ref) == 7 ) {
		$date_ref = "0${date_ref}";
	}
	my $datetime_ref = DateTime::Format::Strptime->new(
		pattern   => '%d%m%Y',
		time_zone => 'Europe/Berlin'
	)->parse_datetime($date_ref);

	my $class = $product->{cls};

	my @stops;
	my $route_end;
	for my $stop ( @{ $journey->{stopL} // [] } ) {
		my $loc       = $locL[ $stop->{locX} ];
		my $sched_arr = $stop->{aTimeS};
		my $rt_arr    = $stop->{aTimeR};
		my $sched_dep = $stop->{dTimeS};
		my $rt_dep    = $stop->{dTimeR};

		# dIn. / aOut. -> may passengers enter / exit the train?

		my $sched_platform   = $stop->{aPlatfS}  // $stop->{dPlatfS};
		my $rt_platform      = $stop->{aPlatfR}  // $stop->{dPlatfR};
		my $changed_platform = $stop->{aPlatfCh} // $stop->{dPlatfCh};

		for my $timestr ( $sched_arr, $rt_arr, $sched_dep, $rt_dep ) {
			if ( not defined $timestr ) {
				next;
			}

			$timestr = handle_day_change(
				input    => $timestr,
				date     => $date,
				strp_obj => $hafas->{strptime_obj},
				ref      => $datetime_ref
			);

		}

		my $arr_delay
		  = ( $sched_arr and $rt_arr )
		  ? ( $rt_arr->epoch - $sched_arr->epoch ) / 60
		  : undef;

		my $dep_delay
		  = ( $sched_dep and $rt_dep )
		  ? ( $rt_dep->epoch - $sched_dep->epoch ) / 60
		  : undef;

		my $arr_cancelled = $stop->{aCncl};
		my $dep_cancelled = $stop->{dCncl};

		my $tco = {};
		for my $tco_id ( @{ $stop->{dTrnCmpSX}{tcocX} // [] } ) {
			my $tco_kv = $tcocL[$tco_id];
			$tco->{ $tco_kv->{c} } = $tco_kv->{r};
		}

		push(
			@stops,
			{
				loc   => $loc,
				extra => {
					sched_arr           => $sched_arr,
					rt_arr              => $rt_arr,
					arr                 => $rt_arr // $sched_arr,
					arr_delay           => $arr_delay,
					arr_cancelled       => $arr_cancelled,
					sched_dep           => $sched_dep,
					rt_dep              => $rt_dep,
					dep                 => $rt_dep // $sched_dep,
					dep_delay           => $dep_delay,
					dep_cancelled       => $dep_cancelled,
					delay               => $dep_delay // $arr_delay,
					direction           => $stop->{dDirTxt},
					sched_platform      => $sched_platform,
					rt_platform         => $rt_platform,
					is_changed_platform => $changed_platform,
					platform            => $rt_platform // $sched_platform,
					load                => $tco,
				}
			}
		);
		$route_end = $loc->{name};
	}

	if ( $journey->{stbStop} ) {
		if ( $hafas->{arrivals} ) {
			$route_end = $stops[0]->{name};
			pop(@stops);
		}
		else {
			shift(@stops);
		}
	}

	my $ref = {
		id                     => $jid,
		name                   => $name,
		number                 => $train_no,
		line                   => $name,
		line_no                => $line_no,
		type                   => $cat,
		type_long              => $catlong,
		class                  => $class,
		operator               => $operator,
		direction              => $direction,
		is_cancelled           => $is_cancelled,
		is_partially_cancelled => $partially_cancelled,
		route_end              => $route_end // $direction,
		messages               => \@messages,
		route                  => \@stops,
	};

	if ( $journey->{stbStop} ) {
		if ( $hafas->{arrivals} ) {
			$ref->{origin} = $ref->{route_end};
			$ref->{is_cancelled} ||= $journey->{stbStop}{aCncl};
		}
		else {
			$ref->{destination} = $ref->{route_end};
			$ref->{is_cancelled} ||= $journey->{stbStop}{dCncl};
		}
	}
	else {
		$ref->{route_start} = $stops[0]{name};
	}

	bless( $ref, $obj );

	if ( $journey->{stbStop} ) {
		$ref->{station}     = $locL[ $journey->{stbStop}{locX} ]->{name};
		$ref->{station_eva} = 0 + $locL[ $journey->{stbStop}{locX} ]->{extId};
		$ref->{sched_platform} = $journey->{stbStop}{dPlatfS};
		$ref->{rt_platform}    = $journey->{stbStop}{dPlatfR};
		$ref->{platform}       = $ref->{rt_platform} // $ref->{sched_platform};

		my $time_s
		  = $journey->{stbStop}{ $hafas->{arrivals} ? 'aTimeS' : 'dTimeS' };
		my $time_r
		  = $journey->{stbStop}{ $hafas->{arrivals} ? 'aTimeR' : 'dTimeR' };

		for my $timestr ( $time_s, $time_r ) {
			if ( not defined $timestr ) {
				next;
			}

			$timestr = handle_day_change(
				input    => $timestr,
				date     => $date,
				strp_obj => $hafas->{strptime_obj},
				ref      => $datetime_ref,
			);

		}

		my $datetime_s = $time_s;
		my $datetime_r = $time_r;

		my $delay
		  = $datetime_r
		  ? ( $datetime_r->epoch - $datetime_s->epoch ) / 60
		  : undef;

		$ref->{sched_datetime} = $datetime_s;
		$ref->{rt_datetime}    = $datetime_r;
		$ref->{datetime}       = $datetime_r // $datetime_s;
		$ref->{delay}          = $delay;

		if ( $ref->{delay} ) {
			$ref->{datetime} = $ref->{rt_datetime};
		}
		else {
			$ref->{datetime} = $ref->{sched_datetime};
		}

		my %tco;
		for my $tco_id ( @{ $journey->{stbStop}{dTrnCmpSX}{tcocX} // [] } ) {
			my $tco_kv = $tcocL[$tco_id];
			$tco{ $tco_kv->{c} } = $tco_kv->{r};
		}
		if (%tco) {
			$ref->{load} = \%tco;
		}
	}
	if ( $opt{polyline} ) {
		$ref->{polyline} = $opt{polyline};
	}

	return $ref;
}

# }}}

sub handle_day_change {
	my (%opt)   = @_;
	my $date    = $opt{date};
	my $timestr = $opt{input};
	if ( length($timestr) == 8 ) {

		# arrival time includes a day offset
		my $offset_date = $opt{ref}->clone;
		$offset_date->add( days => substr( $timestr, 0, 2, q{} ) );
		$offset_date = $offset_date->strftime('%Y%m%d');
		$timestr = $opt{strp_obj}->parse_datetime("${offset_date}T${timestr}");
	}
	else {
		$timestr = $opt{strp_obj}->parse_datetime("${date}T${timestr}");
	}
	return $timestr;
}

# {{{ Accessors

# Legacy
sub station_uic {
	my ($self) = @_;
	return $self->{station_eva};
}

sub is_changed_platform {
	my ($self) = @_;

	if ( defined $self->{rt_platform} and defined $self->{sched_platform} ) {
		if ( $self->{rt_platform} ne $self->{sched_platform} ) {
			return 1;
		}
		return 0;
	}
	if ( defined $self->{rt_platform} ) {
		return 1;
	}

	return 0;
}

sub messages {
	my ($self) = @_;

	if ( $self->{messages} ) {
		return @{ $self->{messages} };
	}
	return;
}

sub polyline {
	my ($self) = @_;

	if ( $self->{polyline} ) {
		return @{ $self->{polyline} };
	}
	return;
}

sub route {
	my ($self) = @_;

	if ( $self->{route} ) {
		if ( $self->{route}[0] and $self->{route}[0]{extra} ) {
			$self->{route}
			  = [ map { Travel::Status::DE::HAFAS::Stop->new( %{$_} ) }
				  @{ $self->{route} } ];
		}
		return @{ $self->{route} };
	}
	return;
}

sub route_interesting {
	my ( $self, $max_parts ) = @_;

	my @via = $self->route;
	my ( @via_main, @via_show, $last_stop );
	$max_parts //= 3;

	# Centraal: dutch main station (Hbf in .nl)
	# HB:  swiss main station (Hbf in .ch)
	# hl.n.: czech main station (Hbf in .cz)
	for my $stop (@via) {
		if ( $stop->{name}
			=~ m{ HB $ | hl\.n\. $ | Hbf | Hauptbahnhof | Bf | Bahnhof | Centraal | Flughafen }x
		  )
		{
			push( @via_main, $stop );
		}
	}
	$last_stop = pop(@via);

	if ( @via_main and $via_main[-1]{name} eq $last_stop->{name} ) {
		pop(@via_main);
	}
	if ( @via and $via[-1]{name} eq $last_stop->{name} ) {
		pop(@via);
	}

	if ( @via_main and @via and $via[0]{name} eq $via_main[0]{name} ) {
		shift(@via_main);
	}

	if ( @via < $max_parts ) {
		@via_show = @via;
	}
	else {
		if ( @via_main >= $max_parts ) {
			@via_show = ( $via[0] );
		}
		else {
			@via_show = splice( @via, 0, $max_parts - @via_main );
		}

		while ( @via_show < $max_parts and @via_main ) {
			my $stop = shift(@via_main);
			if ( any { $_->{name} eq $stop->{name} } @via_show
				or $stop->{name} eq $last_stop->{name} )
			{
				next;
			}
			push( @via_show, $stop );
		}
	}

	for my $stop (@via_show) {
		$stop->{name} =~ s{ \s? Hbf .* }{}x;
	}

	return @via_show;

}

sub TO_JSON {
	my ($self) = @_;

	my $ret = { %{$self} };

	for my $k ( keys %{$ret} ) {
		if ( ref( $ret->{$k} ) eq 'DateTime' ) {
			$ret->{$k} = $ret->{$k}->epoch;
		}
	}
	$ret->{route} = [ map { $_->TO_JSON } $self->route ];

	return $ret;
}

# }}}

1;

__END__

=head1 NAME

Travel::Status::DE::HAFAS::Journey - Information about a single
journey received by Travel::Status::DE::HAFAS

=head1 SYNOPSIS

	for my $departure ($status->results) {
		printf(
			"At %s: %s to %s from platform %s\n",
			$departure->datetime->strftime('%H:%M'),
			$departure->line,
			$departure->destination,
			$departure->platform,
		);
	}

	# or (depending on module setup)
	for my $arrival ($status->results) {
		printf(
			"At %s: %s from %s on platform %s\n",
			$arrival->datetime->strftime('%H:%M'),
			$arrival->line,
			$arrival->origin,
			$arrival->platform,
		);
	}

=head1 VERSION

version 4.16

=head1 DESCRIPTION

Travel::Status::DE::HAFAS::Journey describes a single journey. It is either
a station-specific arrival/departure obtained by a stationboard query, or a
train journey that does not belong to a specific station.

stationboard-specific accessors are annotated with "(station only)" and return
undef for non-station journeys.

=head1 METHODS

=head2 ACCESSORS

=over

=item $journey->name

Returns the journey or line name, either in a format like "Bus SB16" (Bus line
SB16) or "RE 10111" (RegionalExpress train 10111, no line information).  May
contain extraneous whitespace characters.

=item $journey->type

Returns the type of this journey, e.g. "S" for S-Bahn, "RE" for Regional Express
or "STR" for tram / StraE<szlig>enbahn.

=item $journey->type_long

Returns the long type of this journey, e.g. "S-Bahn" or "Regional-Express".

=item $journey->class

Returns an integer identifying the the mode of transport class.
Semantics depend on backend, e.g. "1" and "2" for long-distance trains and
"4" and "8" for regional trains.

=item $journey->line

Returns the journey or line name, either in a format like "Bus SB16" (Bus line
SB16), "RE 42" (RegionalExpress train 42) or "IC 2901" (InterCity train 2901,
no line information).  May contain extraneous whitespace characters.  Note that
this accessor does not return line informatikn for IC/ICE/EC services, even if
it is available. Use B<line_no> for those.

=item $journey->line_no

Returns the line identifier, or undef if it is unknown.
The line identifier may be a single number such as "11" (underground train
line U 11), a single word (e.g. "AIR") or a combination (e.g. "SB16").
May also provide line numbers of IC/ICE services.

=item $journey->number

Returns the journey number (e.g. train number), or undef if it is unknown.

=item $journey->id

Returns tha HAFAS-internal journey ID.

=item $journey->rt_datetime (station only)

DateTime object indicating the actual arrival/departure date and time.
undef if no real-time data is available.

=item $journey->sched_datetime (station only)

DateTime object indicating the scheduled arrival/departure date and time.
undef if no schedule data is available.

=item $journey->datetime (station only)

DateTime object indicating the arrival/departure date and time.
Real-time data if available, schedule data otherwise.
undef if neither is available.

=item $journey->delay (station only)

Returns the delay in minutes, or undef if it is unknown.
Also returns undef if the arrival/departure has been cancelled.

=item $journey->is_cancelled

True if the journey was cancelled, false otherwise.

=item $journey->is_partially_cancelled

True if part of the journey was cancelled, false otherwise.

=item $journey->rt_platform (station only)

Actual arrival/departure platform.
undef if no real-time data is available.

=item $journey->sched_platform (station only)

Scheduled arrival/departure platform.
undef if no scheduled platform is available.

=item $journey->platform (station only)

Arrival/Departure platform. Real-time data if available, schedule data
otherwise. May be undef.

=item $journey->is_changed_platform (station only)

True if the real-time platform is known and it is not the scheduled one.

=item $journey->load (station only)

Expected passenger load (i.e., how full the vehicle is) at the requested stop.
If known, returns a hashref that maps classes (typically FIRST/SECOND) to
load estimation numbers. The DB backend uses 1 (low to medium), 2 (high),
3 (very high), and 4 (exceptionally high, train is booked out).
Undef if unknown.

=item $journey->messages

Returns a list of message strings related to this journey. Messages usually are
service notices (e.g. "missing carriage") or detailed delay reasons
(e.g. "switch damage between X and Y, expect delays").

=item $journey->operator

Returns the operator responsible for this journey. Returns undef
if the backend does not provide an operator.

=item $journey->station (station only)

Name of the station at which this journey was requested.

=item $journey->station_eva (station only)

UIC/EVA ID of the station at which this journey was requested.

=item $journey->route

Returns a list of Travel::Status::DE::HAFAS::Stop(3pm) objects that describe
individual stops along the journey. In stationboard mode, the list only
contains arrivals prior to the requested station or departures after the
requested station. In journey mode, it contains the entire route.

=item $journey->route_interesting([I<count>])

Return up to I<count> (default: B<3>) parts of C<< $journey->route >> that may
be particularly helpful, e.g. main stations or airports.
Returns a list of hashes, see above for the layout.

=item $journey->route_end

Name of the last route station. In arrival mode, this is where the train
started; in all other cases, it is the terminus.

=item $journey->destination

Alias for route_end; only set when requesting departures in station mode.

=item $journey->origin

Alias for route_end; only set when requesting arrivals in station mode.

=item $journey->direction

Train direction; this is typically the text printed on the train itself.
May be different from destination / route_end and may change along the route,
see above.

=item $journey->polyline (journey only)

List of geocoordinates that describe the train's route. Each list entry is
a hash with the following keys.

=over

=item * lon (longitude)

=item * lat (latitude)

=item * name (name of stop at this location, if any. undef otherwise)

=item * eva (EVA ID of stop at this location, if any. undef otherwise)

=back

Note that stop locations in B<polyline> may differ from the coordinates
returned in B<route>. This is a backend issue; Travel::Status::DE::HAFAS
simply passes the returned coordinates on.

=back

=head1 DIAGNOSTICS

None.

=head1 DEPENDENCIES

=over

=item Class::Accessor(3pm)

=back

=head1 BUGS AND LIMITATIONS

None known.

=head1 SEE ALSO

Travel::Status::DE::HAFAS(3pm).

=head1 AUTHOR

Copyright (C) 2015-2022 by Birte Kristina Friesel E<lt>derf@finalrewind.orgE<gt>

=head1 LICENSE

This module is licensed under the same terms as Perl itself.
