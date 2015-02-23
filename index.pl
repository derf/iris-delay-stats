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
	my $self = shift;
	my $aggregate = $self->param('aggregate') // 'hour';
	my $metric = $self->param('metric') // 'delay';
	my $msgnum = int($self->param('msgnum') // 0);

	if ($msgnum < 0 or $msgnum > 99) {
		$msgnum = 0;
	}

	my $where_clause = '1 = 1';

	my $res = "x\ty\n";

	my $query;
	my $format = 'strftime("%H", scheduled_time, "unixepoch")';

	given($aggregate) {
		when ('weekday') {
			$format = 'strftime("%w", scheduled_time, "unixepoch")';
		}
		when ('weekhour') {
			$format = 'strftime("%w%H", scheduled_time, "unixepoch")';
		}
		when ('line') {
			$format = 'train_type || " " || line_no';
			$where_clause = 'line_no is not null';
		}
		when ('train_type') {
			$format = 'train_type';
		}
	}

	given ($metric) {
		when ('delay') {
			$query = qq{
				select $format as aggregate,
				avg(delay) from $table where not is_canceled and $where_clause group by aggregate
			};
		}
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
		when ('message_rate') {
			$query = qq{
				select $format as aggregate,
				avg(msgtable.train_id is not null) from departures
				left outer join msg_$msgnum as msgtable using
				(scheduled_time, train_id) where $where_clause group by aggregate
			};
		}
	}

	my $dbres = $self->app->dbh->selectall_arrayref($query);

	for my $row ( @{$dbres} ) {
		$res .= sprintf( "%s\t%s\n", @{$row} );
	}

	$self->render( data => $res );
	return;
};

get '/' => sub {
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
