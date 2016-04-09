#!/usr/bin/env perl
use Mojolicious::Lite;
use Cache::File;
use DBI;
use Encode qw(decode encode);
use Travel::Status::DE::IRIS;
use Travel::Status::DE::IRIS::Stations;
use 5.014;
use utf8;

no if $] >= 5.018, warnings => "experimental::smartmatch";

our $VERSION = qx{git describe --dirty} || '0.01';

app->defaults( layout => 'default' );

app->attr(
	dbh => sub {
		my $self = shift;

		my $dbname = 'dbdb';
		my $host   = $ENV{DBDB_HOST} // 'localhost';
		my $port   = $ENV{DBDB_PORT} // '5432';
		my $dbh = DBI->connect( "dbi:Pg:dbname=$dbname;host=$host;port=$port",
			'dbdb', $ENV{DBDB_PASSWORD}, { RaiseError => 1 } );

		return $dbh;
	}
);

helper barplot_args => sub {
	my ($self) = @_;

	my %translation = Travel::Status::DE::IRIS::Result::dump_message_codes();
	my $messages;

	for my $key ( keys %translation ) {
		$messages->{$key} = { desc => $translation{$key} };
	}

	return {
		x => {
			hour => {
				desc  => 'Stunde',
				label => 'Angebrochene Stunde',
			},
			line => {
				desc => 'Linie',
			},
			month => {
				desc => 'Monat',
			},
			station => {
				desc => 'Bahnhof',
			},
			train_type => {
				desc => 'Zugtyp',
			},
			weekday => {
				desc => 'Wochentag',
			},
			weekhour => {
				desc  => 'Wochentag und Stunde',
				label => 'Wochentag und angebrochene Stunde',
			},
		},
		y => {
			avg_delay => {
				desc    => 'Durchschnittliche Verspätung',
				label   => 'Minuten',
				yformat => '.1f',
			},
			cancel_num => {
				desc  => 'Anzahl Zugausfälle',
				label => 'Zugausfälle',
			},
			cancel_rate => {
				desc    => 'Zugausfälle',
				yformat => '.1%',
			},
			delay0_rate => {
				desc    => 'Verspätung = 0 Min.',
				label   => 'Verspätung = 0 Min.',
				yformat => '.1%',
			},
			delay5_rate => {
				desc    => 'Verspätung > 5 Min.',
				label   => 'Verspätung über 5 Min.',
				yformat => '.1%',
			},
			realtime_rate => {
				desc    => 'Echtzeitdaten vorhanden',
				yformat => '.1%',
			},
		},
		msg => $messages,
	};
};

helper barplot_filters => sub {
	my ($self) = @_;
	my $dbh = $self->app->dbh;

	my $cache = Cache::File->new(
		cache_root => $ENV{DBDB_CACHE} // '/tmp/dbdb-web-cache',
		default_expires => '12 hours',
		lock_level      => Cache::File::LOCK_LOCAL(),
	);

	my $ret = $cache->thaw('barplot_filters');
	if ($ret) {
		return $ret;
	}

	$ret = {
		lines => [
			q{},
			map { [ $_->[2] . ' ' . $_->[3], $_->[0] . '.' . $_->[1] ] } @{
				$dbh->selectall_arrayref(
					qq{
					select distinct train_type, line_no, train_types.name,
					lines.name from departures
					join train_types on train_type = train_types.id
					join lines on line_no = lines.id
					where line_no is not null
					order by train_types.name, lines.name
				}
				)
			}
		],
		train_types => [
			q{},
			map { [ $_->[0], $_->[1] ] } @{
				$dbh->selectall_arrayref(
					qq{
					select name, id from train_types order by name
				}
				)
			}
		],
		stations => [
			q{},
			map {
				[
					Travel::Status::DE::IRIS::Stations::get_station( $_->[0] )
					  ->[1],
					$_->[1]
				]
			  } @{
				$dbh->selectall_arrayref(
					qq{
					select name, id from station_codes order by name
				}
				)
			  }
		],
		destinations => [
			q{},
			map { [ decode( 'utf-8', $_->[0] ), $_->[1] ] } @{
				$dbh->selectall_arrayref(
					qq{
					select name, id from stations order by name
				}
				)
			}
		],
	};

	$cache->freeze( 'barplot_filters', $ret );

	return $ret;
};

helper count_unique_column => sub {
	my ( $self, $column ) = @_;
	my $dbh = $self->app->dbh;

	if ( not $column ) {
		return
		  scalar $dbh->selectall_arrayref('select count(*) from departures')
		  ->[0][0];
	}
	return
	  scalar $dbh->selectall_arrayref(
		"select count(distinct $column) from departures")->[0][0];
};

helper single_query => sub {
	my ( $self, $query ) = @_;

	return scalar $self->app->dbh->selectall_arrayref($query)->[0][0];
};

helper globalstats => sub {
	my ($self) = @_;
	my $dbh = $self->app->dbh;

	my $cache = Cache::File->new(
		cache_root      => '/tmp/dbdb',
		default_expires => '12 hours',
		lock_level      => Cache::File::LOCK_LOCAL(),
	);

	my $ret = $cache->thaw('globalstats');
	if ($ret) {
		return $ret;
	}

	my $stations = [
		map { Travel::Status::DE::IRIS::Stations::get_station($_)->[1] } @{
			$self->app->dbh->selectcol_arrayref(
				"select name from station_codes")
		}
	];

	$ret = {
		departures  => $self->count_unique_column(),
		stationlist => $stations,
		stations    => $self->count_unique_column('station'),
		realtime    => $self->single_query(
			"select count(*) from departures where delay is not null"),
		realtime_rate => $self->single_query(
			"select avg((delay is not null)::int) from departures"),
		ontime => $self->single_query(
"select count(*) from departures where delay < 1 and not is_canceled"
		),
		ontime_rate => $self->single_query(
			"select avg((delay < 1 and not is_canceled)::int) from departures"),
		days => $self->count_unique_column(
			'(scheduled_time at time zone \'GMT\')::date'),
		delayed => $self->single_query(
"select count(*) from departures where delay > 5 and not is_canceled"
		),
		delayed_rate => $self->single_query(
			"select avg((delay > 5 and not is_canceled)::int) from departures"),
		canceled => $self->single_query(
			"select count(*) from departures where is_canceled"),
		canceled_rate =>
		  $self->single_query("select avg(is_canceled::int) from departures"),
		delay_sum => $self->single_query(
			"select sum(delay) from departures where not is_canceled"),
		delay_avg => $self->single_query(
			"select avg(delay) from departures where not is_canceled"),
	};

	$cache->freeze( 'globalstats', $ret );

	return $ret;
};

helper parse_filter_args => sub {
	my $self         = shift;
	my $where_clause = q{};

	my %filter = (
		line         => scalar $self->param('filter_line'),
		train_no     => scalar $self->param('filter_train_no'),
		train_type   => scalar $self->param('filter_train_type'),
		station      => scalar $self->param('filter_station'),
		destination  => scalar $self->param('filter_destination'),
		cancellation => scalar $self->param('filter_cancellation'),
		delay_min    => scalar $self->param('filter_delay_min'),
		delay_max    => scalar $self->param('filter_delay_max'),
		date_start   => scalar $self->param('filter_date_start'),
		date_stop    => scalar $self->param('filter_date_stop'),
	);

	for my $key ( keys %filter ) {
		$filter{$key} =~ tr{._a-zA-Z0-9öäüÖÄÜß }{}cd;
	}

	$filter{delay_min}
	  = length( $filter{delay_min} ) ? int( $filter{delay_min} ) : undef;
	$filter{delay_max}
	  = length( $filter{delay_max} ) ? int( $filter{delay_max} ) : undef;
	$filter{train_no}
	  = length( $filter{train_no} ) ? int( $filter{train_no} ) : undef;

	if ( $filter{line} ) {
		my ( $train_type, $line_no ) = split( /\./, $filter{line} );
		$where_clause .= " and train_type = $train_type and line_no = $line_no";
	}
	if ( $filter{train_type} ) {
		$where_clause .= " and train_type = '$filter{train_type}'";
	}
	if ( $filter{station} ) {
		$where_clause .= " and station = '$filter{station}'";
	}
	if ( $filter{destination} ) {
		$where_clause .= " and destination = '$filter{destination}'";
	}
	if ( $filter{cancellation} ) {
		if ( $filter{cancellation} eq 'only_cancelled' ) {
			$where_clause .= ' and is_canceled';
		}
		else {
			$where_clause .= ' and not is_canceled';
		}
	}
	if ( $filter{date_start} ) {
		$where_clause .= " and scheduled_time >= '$filter{date_start}'";
	}
	if ( $filter{date_stop} ) {
		$where_clause .= " and scheduled_time < '$filter{date_stop}'";
	}
	if ( defined $filter{delay_min} ) {
		$where_clause .= " and delay >= $filter{delay_min}";
	}
	if ( defined $filter{delay_max} ) {
		$where_clause .= " and delay <= $filter{delay_max}";
	}
	if ( defined $filter{train_no} ) {
		$where_clause .= " and train_no = $filter{train_no}";
	}

	return ( \%filter, $where_clause );
};

helper translate_filter_arg => sub {
	my ( $self, $argtype, @args ) = @_;
	if ( $argtype eq 'line' ) {
		return $self->single_query(
			qq{
			select train_types.name || ' ' || lines.name
			from train_types, lines
			where train_types.id = $args[0]
			and lines.id = $args[1]
		}
		);
	}
	return $self->single_query(
		qq{
		select name
		from ${argtype}s
		where id = $args[0]
	}
	);
};

get '/by_hour.json' => sub {
	my $self = shift;

	my $json = [];

	my $res = $self->app->dbh->selectall_arrayref(
		qq{
		select extract(hour from scheduled_time at time zone \'GMT\') as time,
		avg(delay) as date from departures group by time}
	);

	for my $row ( @{$res} ) {
		push(
			@{$json},
			{
				hour     => $row->[0],
				avgdelay => $row->[1]
			}
		);
	}

	$self->render( json => $json );
	return;
};

helper 'get_2ddata' => sub {
	my $self      = shift;
	my $aggregate = $self->param('aggregate') // 'hour';
	my $metric    = $self->param('metric') // 'avg_delay';
	my $msgnum    = int( $self->param('msgnum') // 0 );

	my ( $filter, $filter_clause ) = $self->parse_filter_args;

	my @weekdays = qw(So Mo Di Mi Do Fr Sa);
	my @months   = qw(BUG Jan Feb Mär Apr Mai Jun Jul Aug Sep Okt Nov Dez);
	$months[3] = encode( 'utf-8', $months[3] );

	if ( $msgnum < 0 or $msgnum > 99 ) {
		$msgnum = 0;
	}

	my $where_clause = '1 = 1';
	my $join_clause  = q{};

	my $header;

	my $query;
	my $format = 'extract(hour from scheduled_time at time zone \'GMT\')';

	given ($aggregate) {
		when ('weekday') {
			$format = 'extract(dow from scheduled_time at time zone \'GMT\')';
		}
		when ('weekhour') {
			$format
			  = 'extract(dow from scheduled_time at time zone \'GMT\') || \' \' || to_char(scheduled_time at time zone \'GMT\', \'HH24\')';
		}
		when ('month') {
			$format = 'extract(month from scheduled_time at time zone \'GMT\')';
		}
		when ('line') {
			$format       = 'train_types.name || \' \' || lines.name';
			$where_clause = 'line_no is not null';
			$join_clause  = 'join train_types on train_type = train_types.id '
			  . 'join lines on line_no = lines.id';
		}
		when ('station') {
			$format      = 'station_codes.name';
			$join_clause = 'join station_codes on station = station_codes.id';
		}
		when ('train_type') {
			$format      = 'train_types.name';
			$join_clause = 'join train_types on train_type = train_types.id';
		}
	}

	$where_clause .= $filter_clause;

	given ($metric) {
		when ('avg_delay') {
			$header = [qw[x y y_total]];
			$query  = qq{
				select $format as aggregate, avg(delay), count(delay)
				from departures
				$join_clause
				where not is_canceled and $where_clause
				group by aggregate
				order by aggregate
			};
		}
		when ('cancel_num') {
			$header = [qw[x y y_total]];
			$query  = qq{
				select $format as aggregate, count(*), count(*)
				from departures
				$join_clause
				where is_canceled and $where_clause
				group by aggregate
				order by aggregate
			};
		}
		when ('cancel_rate') {
			$header = [qw[x y y_total y_matched]];
			$query  = qq{
				select $format as aggregate, avg(is_canceled::int), count(is_canceled),
					sum(is_canceled::int)
				from departures
				$join_clause
				where $where_clause
				group by aggregate
				order by aggregate
			};
		}
		when ('delay0_rate') {
			$header = [qw[x y y_total y_matched]];
			$query  = qq{
				select $format as aggregate, avg((delay < 1)::int), count(delay),
					sum((delay < 1)::int)
				from departures
				$join_clause
				where $where_clause
				group by aggregate
				order by aggregate
			};
		}
		when ('delay5_rate') {
			$header = [qw[x y y_total y_matched]];
			$query  = qq{
				select $format as aggregate, avg((delay > 5)::int), count(delay),
					sum((delay > 5)::int)
				from departures
				$join_clause
				where $where_clause
				group by aggregate
				order by aggregate
			};
		}
		when ('message_rate') {
			$header = [qw[x y y_total y_matched]];
			$query  = qq{
				select $format as aggregate,
				avg((msgtable.train_id is not null)::int), count(*),
				sum((msgtable.train_id is not null)::int)
				from departures
				$join_clause
				left outer join msg_$msgnum as msgtable using
				(scheduled_time, train_id) where $where_clause
				group by aggregate
				order by aggregate
			};
		}
		when ('realtime_rate') {
			$header = [qw[x y y_total y_matched]];
			$query  = qq{
				select $format as aggregate, avg((delay is not null)::int),
					count(*),
					sum((delay is not null)::int)
				from departures
				$join_clause
				where $where_clause
				group by aggregate
				order by aggregate
			};
		}
	}

	my $dbres = $self->app->dbh->selectall_arrayref($query);

	if ( $aggregate eq 'weekday' ) {
		for my $row ( @{$dbres} ) {
			splice( @{$row}, 0, 1, $weekdays[ $row->[0] ] );
		}

		# SQL starts on sunday, we'd like to start on monday
		@{$dbres} = ( @{$dbres}[ 1 .. 6 ], $dbres->[0] );
	}
	elsif ( $aggregate eq 'month' ) {
		for my $row ( @{$dbres} ) {
			splice( @{$row}, 0, 1, $months[ $row->[0] ] );
		}
	}
	elsif ( $aggregate eq 'weekhour' ) {

		# the result only contains columns for datetimes with departures, so
		# it may have less than 24 * 7 elements. However, we'd like to
		# return a 0 for 'missing' times, so we rebuild the reply here.
		my $newres;
		my $row_index = 0;

		for my $weekday ( 0 .. 6 ) {
			for my $hour ( 0 .. 23 ) {
				my ( $row_weekday, $row_hour )
				  = split( / /, $dbres->[$row_index][0] );
				if ( $weekday == $row_weekday and $hour == $row_hour ) {
					$newres->[ $weekday * 24 + $hour ] = $dbres->[$row_index];
					$row_index++;
				}
				else {
					$newres->[ $weekday * 24 + $hour ]
					  = [ "$weekday $hour", 0, 0, 0, 0, 0 ];
				}
			}
		}
		$dbres = $newres;

		for my $row ( @{$dbres} ) {
			splice( @{$row}, 0, 1,
				$weekdays[ substr( $row->[0], 0, 1 ) ] . q{ }
				  . substr( $row->[0], 2 ) );
		}

		# Fix weekday ordering (start on Monday, not Sunday)
		@{$dbres} = ( @{$dbres}[ 1 * 24 .. 7 * 24 - 1 ], @{$dbres}[ 0 .. 23 ] );
	}
	elsif ( $aggregate eq 'station' ) {
		for my $row ( @{$dbres} ) {
			$row->[0] = encode( 'utf-8',
				Travel::Status::DE::IRIS::Stations::get_station( $row->[0] )
				  ->[1] );
		}
	}

	return ( $header, $dbres );
};

get '/2ddata.json' => sub {
	my ($self) = shift;

	my ( $header, $dbres ) = $self->get_2ddata;

	my $json = {};

	for my $i ( 0 .. $#{$header} ) {
		$json->{data}->{ $header->[$i] } = [ map { $_->[$i] } @{$dbres} ];
	}

	$self->render(
		json => $json,
	);
	return;
};

get '/2ddata.tsv' => sub {
	my $self = shift;

	my ( $header, $dbres ) = $self->get_2ddata;

	my $res = join( "\t", @{$header} ) . "\n";

	for my $row ( @{$dbres} ) {
		if ( $row and @{$row} ) {
			$res .= join( "\t", @{$row} ) . "\n";
		}
	}

	$self->render( data => $res );
	return;
};

get '/' => sub {
	my $self = shift;

	$self->render( 'intro', version => $VERSION );
	return;
};

get '/all' => sub {
	my $self = shift;
	my $dbh  = $self->app->dbh;

	my $num_departures = $dbh->selectall_arrayref(
		qq{
		select count(*) from departures}
	)->[0][0];

	$self->render(
		'main',
		num_departures => $num_departures,
		version        => $VERSION,
	);
	return;
};

get '/bar' => sub {
	my $self = shift;

	my $xsource  = $self->param('xsource');
	my $ysource  = $self->param('ysource');
	my $want_msg = $self->param('want_msg');
	my $msgnum   = $self->param('msgnum');
	my ( $title, @title_filter_strings );

	my %args = %{ $self->barplot_args };

	if ($want_msg) {
		$self->param( ysource => 'message_rate' );
		$self->param( ylabel  => $args{msg}{$msgnum}{desc} );
		$self->param( yformat => '.1%' );
		$title = sprintf( '"%s" pro %s',
			$args{msg}{$msgnum}{desc},
			$args{x}{$xsource}{desc} );
	}
	else {
		$title = sprintf( '%s pro %s',
			$args{y}{$ysource}{desc},
			$args{x}{$xsource}{desc} );
	}

	if ( $self->param('filter_line') ) {
		my @translate_args = split( /\./, $self->param('filter_line') );
		push( @title_filter_strings,
			'Linie ' . $self->translate_filter_arg( 'line', @translate_args ) );
	}
	if ( $self->param('filter_train_type') ) {
		if ( $self->param('filter_train_no') ) {
			push(
				@title_filter_strings,
				$self->translate_filter_arg( 'train_type',
					$self->param('filter_train_type') )
				  . q{ }
				  . $self->param('filter_train_no')
			);
		}
		else {
			push(
				@title_filter_strings,
				'Zugtyp '
				  . $self->translate_filter_arg(
					'train_type', $self->param('filter_train_type')
				  )
			);
		}
	}
	elsif ( $self->param('filter_train_no') ) {
		push( @title_filter_strings, 'Zug ' . $self->param('filter_train_no') );
	}
	if ( $self->param('filter_station') ) {
		push(
			@title_filter_strings,
			'in '
			  . Travel::Status::DE::IRIS::Stations::get_station(
				$self->translate_filter_arg(
					'station_code', $self->param('filter_station')
				)
			  )->[1]
		);
	}
	if ( $self->param('filter_destination') ) {
		push(
			@title_filter_strings,
			'Züge nach '
			  . decode(
				'utf-8',
				$self->translate_filter_arg(
					'station', $self->param('filter_destination')
				)
			  )
		);
	}
	if ( $self->param('filter_date_start') ) {
		push( @title_filter_strings,
			'ab ' . $self->param('filter_date_start') );
	}
	if ( $self->param('filter_date_stop') ) {
		push( @title_filter_strings,
			'vor ' . $self->param('filter_date_stop') );
	}
	if (@title_filter_strings) {
		$title .= ' (' . join( ', ', @title_filter_strings ) . ')';
	}

	$self->param( title => $title );

	if ( not $self->param('xlabel') ) {
		$self->param( xlabel => $args{x}{$xsource}{label}
			  // $args{x}{$xsource}{desc} );
	}
	if ( not $self->param('ylabel') ) {
		$self->param( ylabel => $args{y}{$ysource}{label}
			  // $args{y}{$ysource}{desc} );
	}
	if ( not $self->param('xformat') and $args{x}{$xsource}{xformat} ) {
		$self->param( xformat => $args{x}{$xsource}{xformat} );
	}
	if ( not $self->param('yformat') and $args{y}{$ysource}{yformat} ) {
		$self->param( yformat => $args{y}{$ysource}{yformat} );
	}

	$self->render(
		'bargraph',
		title   => 'bargraph',
		version => $VERSION,
	);
	return;
};

get '/individual' => sub {
	my $self          = shift;
	my $where_clause  = '1=1';
	my $order_param   = $self->param('order_by') || 'scheduled_time.d';
	my $with_messages = $self->param('with_messages');
	my $order;
	my $res;
	my %translation = Travel::Status::DE::IRIS::Result::dump_message_codes();
	my ( $filter, $filter_clause ) = $self->parse_filter_args;
	my $dbh = $self->app->dbh;
	$where_clause .= $filter_clause;

	given ($order_param) {
		when ('scheduled_time.d') { $order = 'scheduled_time desc' }
		when ('scheduled_time.a') { $order = 'scheduled_time asc' }
		when ('delay.d')          { $order = 'delay desc' }
		when ('delay.a')          { $order = 'delay asc' }
	}

	if ( $order_param =~ m{ ^ delay }x ) {
		$where_clause .= ' and delay is not null';
	}

	if ($with_messages) {
		$res = $self->app->dbh->selectall_arrayref(
			qq{
			select station_codes.name, scheduled_time, delay, is_canceled,
			stations.name, train_types.name, train_no, lines.name, platform,
			}
			  . join( ', ', map { "msg$_" } ( 1 .. 99 ) ) . qq{
			from departures_with_messages
			join station_codes on station = station_codes.id
			join stations on destination = stations.id
			join train_types on train_type = train_types.id
			left outer join lines on line_no = lines.id
			where $where_clause
			order by $order
			limit 100
		}
		);
	}
	else {
		$res = $self->app->dbh->selectall_arrayref(
			qq{
			select station_codes.name, scheduled_time, delay, is_canceled,
			stations.name, train_types.name, train_no, lines.name, platform
			from departures
			join station_codes on station = station_codes.id
			join stations on destination = stations.id
			join train_types on train_type = train_types.id
			left outer join lines on line_no = lines.id
			where $where_clause
			order by $order
			limit 100
		}
		);
	}

	for my $i ( 0 .. $#{$res} ) {
		my @messages;
		my $row = $res->[$i];

		$row->[0]
		  = Travel::Status::DE::IRIS::Stations::get_station( $row->[0] )->[1];

		if ($with_messages) {
			for my $msg ( 1 .. 99 ) {
				if ( $row->[ 8 + $msg ] ) {
					push( @messages, $translation{$msg} // $msg );
				}
			}
			$row->[9] = [@messages];
		}
	}

	$self->render(
		'individuallist',
		title   => 'foo',
		list    => $res,
		version => $VERSION,
	);
};

get '/top' => sub {
	my $self         = shift;
	my $where_clause = '1=1';

	my ( $filter, $filter_clause ) = $self->parse_filter_args;
	my %translation = Travel::Status::DE::IRIS::Result::dump_message_codes();

	my @rates;
	my $dbh = $self->app->dbh;

	$where_clause .= $filter_clause;

	my $total = $dbh->selectall_arrayref(
		"select count(*) from departures where $where_clause")->[0][0];

	for my $msgnum ( 1 .. 99 ) {
		my $query = qq{
			select count(*)
			from departures
			join msg_$msgnum as msgtable using
			(scheduled_time, train_id) where $where_clause
		};
		$rates[$msgnum] = $self->app->dbh->selectall_arrayref($query)->[0][0];
	}

	my @argsort = reverse sort { $rates[$a] <=> $rates[$b] } ( 1 .. 99 );
	my @toplist;
	if ( $total > 0 ) {
		@toplist = map {
			[
				$translation{$_} // $_,
				sprintf( '%.2f%%', $rates[$_] * 100 / $total ),
				$rates[$_]
			]
		} @argsort;
	}

	$self->render(
		'toplist',
		title   => 'toplist',
		toplist => \@toplist,
		version => $VERSION,
	);
	return;
};

app->config(
	hypnotoad => {
		accepts  => 10,
		listen   => [ $ENV{DBDB_LISTEN} // 'http://*:8093' ],
		pid_file => '/tmp/dbdb.pid',
		workers  => $ENV{DBDB_WORKERS} // 2,
	},
);

app->types->type( json => 'application/json; charset=utf-8' );
app->start();
