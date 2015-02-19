#!/usr/bin/env perl
use Mojolicious::Lite;
use DBI;
use Travel::Status::DE::IRIS;
use Travel::Status::DE::IRIS::Stations;
use 5.014;
use utf8;

no if $] >= 5.018, warnings => "experimental::smartmatch";

#our $VERSION = qx{git describe --dirty} || '0.01';

app->defaults( layout => 'default' );

app->attr(dbh => sub {
	my $self = shift;

	my $dbname = $ENV{DBDB_FILE} // 'iris.sqlite';
	my $dbh = DBI->connect("dbi:SQLite:dbname=$dbname", q{}, q{} );

	return $dbh;
});

get '/by_hour.json' => sub {
	my $self = shift;

	my $json = [];

	my $res = $self->app->dbh->selectall_arrayref(qq{
		select strftime("%H", scheduled_time, "unixepoch") as time,
		avg(delay) as date from departures group by time});

	for my $row (@{$res}) {
		push(@{$json}, { hour => $row->[0], avgdelay => $row->[1] } );
	}

	$self->render( json => $json );
	return;
};

get '/by_hour.tsv' => sub {
	my $self = shift;

	my $text = "hour\tavgdelay\n";

	my $res = $self->app->dbh->selectall_arrayref(qq{
		select strftime("%H", scheduled_time, "unixepoch") as time,
		avg(delay) as date from departures group by time});

	for my $row (@{$res}) {
		$text .= sprintf("%s\t%s\n", @{$row});
	}

	$self->render( data => $text );
	return;
};

get '/' => sub {
	my $self = shift;
	my $dbh = $self->app->dbh;

	my $table = $ENV{DBDB_TABLE} // 'departures';

	my $num_departures = $dbh->selectall_arrayref(qq{
		select count() from $table})->[0][0];

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
