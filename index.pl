#!/usr/bin/env perl
use Mojolicious::Lite;
use DBI;
use Travel::Status::DE::IRIS;
use Travel::Status::DE::IRIS::Stations;
use 5.014;
use utf8;

no if $] >= 5.018, warnings => "experimental::smartmatch";

#our $VERSION = qx{git describe --dirty} || '0.01';

my $table = $ENV{DBDB_TABLE} // 'departures';

app->defaults( layout => 'default' );

app->attr(
	dbh => sub {
		my $self = shift;

		my $dbname = $ENV{DBDB_FILE} // 'iris.sqlite';
		my $dbh = DBI->connect( "dbi:SQLite:dbname=$dbname", q{}, q{} );

		return $dbh;
	}
);

helper count_unique_column => sub {
	my ($self, $column) = @_;
	my $dbh = $self->app->dbh;

	if (not $column) {
		return scalar $dbh->selectall_arrayref("select count() from $table")->[0][0];
	}
	return scalar $dbh->selectall_arrayref("select count(distinct $column) from $table")->[0][0];
};

helper single_query => sub {
	my ($self, $query) = @_;

	return scalar $self->app->dbh->selectall_arrayref($query)->[0][0];
};

helper globalstats => sub {
	my ($self) = @_;
	my $dbh = $self->app->dbh;

	my $stations = [ map { Travel::Status::DE::IRIS::Stations::get_station($_)->[1] }
		@{ $self->app->dbh->selectcol_arrayref(
		"select distinct station from $table") } ];

	my $ret = {
		departures => $self->count_unique_column(),
		stationlist => $stations,
		stations => $self->count_unique_column('station'),
		realtime => $self->single_query("select count() from $table where delay is not null"),
		realtime_rate => $self->single_query("select avg(delay is not null) from $table"),
		ontime => $self->single_query("select count() from $table where delay < 1"),
		ontime_rate => $self->single_query("select avg(delay < 1) from $table"),
		days => $self->count_unique_column('strftime("%Y%m%d", scheduled_time, "unixepoch")'),
		delayed => $self->single_query("select count() from $table where delay > 5"),
		delayed_rate => $self->single_query("select avg(delay > 5) from $table"),
		canceled => $self->single_query("select count() from $table where is_canceled > 0"),
		canceled_rate => $self->single_query("select avg(is_canceled > 0) from $table"),
		delay_sum => $self->single_query("select sum(delay) from $table"),
		delay_avg => $self->single_query("select avg(delay) from $table"),
	};

	return $ret;
};

get '/by_hour.json' => sub {
	my $self = shift;

	my $json = [];

	my $res = $self->app->dbh->selectall_arrayref(
		qq{
		select strftime("%H", scheduled_time, "unixepoch") as time,
		avg(delay) as date from $table group by time}
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

get '/2ddata.tsv' => sub {
	my $self      = shift;
	my $aggregate = $self->param('aggregate') // 'hour';
	my $metric    = $self->param('metric') // 'delay';
	my $msgnum    = int( $self->param('msgnum') // 0 );

	my @weekdays = qw(So Mo Di Mi Do Fr Sa);

	if ( $msgnum < 0 or $msgnum > 99 ) {
		$msgnum = 0;
	}

	my $where_clause = '1 = 1';

	my $res = "x\ty\n";

	my $query;
	my $format = 'strftime("%H", scheduled_time, "unixepoch")';

	given ($aggregate) {
		when ('weekday') {
			$format = 'strftime("%w", scheduled_time, "unixepoch")';
		}
		when ('weekhour') {
			$format = 'strftime("%w%H", scheduled_time, "unixepoch")';
		}
		when ('line') {
			$format       = 'train_type || " " || line_no';
			$where_clause = 'line_no is not null';
		}
		when ('train_type') {
			$format = 'train_type';
		}
	}

	given ($metric) {
		when ('cancel_num') {
			$query = qq{
				select $format as aggregate,
				count(is_canceled) from $table where $where_clause group by aggregate
			};
		}
		when ('cancel_rate') {
			$query = qq{
				select $format as aggregate,
				avg(is_canceled) from $table where $where_clause group by aggregate
			};
		}
		when ('delay') {
			$query = qq{
				select $format as aggregate,
				avg(delay) from $table where not is_canceled and $where_clause group by aggregate
			};
		}
		when ('message_rate') {
			$query = qq{
				select $format as aggregate,
				avg(msgtable.train_id is not null) from $table
				left outer join msg_$msgnum as msgtable using
				(scheduled_time, train_id) where $where_clause group by aggregate
			};
		}
		when ('realtime_rate') {
			$query = qq{
				select $format as aggregate,
				avg(delay is not null) from $table
				where $where_clause group by aggregate
			};
		}
	}

	my $dbres = $self->app->dbh->selectall_arrayref($query);

	if ( $aggregate eq 'weekday' ) {
		@{$dbres} = map { [ $weekdays[ $_->[0] ], $_->[1] ] }
		  ( @{$dbres}[ 1 .. 6 ], $dbres->[0] );
	}
	elsif ( $aggregate eq 'weekhour' ) {
		@{$dbres} = map {
			[
				$weekdays[ substr( $_->[0], 0, 1 ) ] . q{ }
				  . substr( $_->[0], 1 ),
				$_->[1]
			]
		} ( @{$dbres}[ 1 * 24 .. 6 * 24 ], $dbres->[0] );
	}

	for my $row ( @{$dbres} ) {
		$res .= sprintf( "%s\t%s\n", @{$row} );
	}

	$self->render( data => $res );
	return;
};

get '/' => sub {
	my $self = shift;

	$self->render('intro');
	return;
};

get '/all' => sub {
	my $self = shift;
	my $dbh  = $self->app->dbh;

	my $num_departures = $dbh->selectall_arrayref(
		qq{
		select count() from $table}
	)->[0][0];

	$self->render(
		'main',
		num_departures => $num_departures,
	);
	return;
};

get '/bar' => sub {
	my $self = shift;
	$self->render('bargraph');
	return;
};

app->config(
	hypnotoad => {
		accepts  => 10,
		listen   => ['http://*:8093'],
		pid_file => '/tmp/db-fake.pid',
		workers  => $ENV{DBDB_WORKERS} // 2,
	},
);

app->types->type( json => 'application/json; charset=utf-8' );
app->start();
