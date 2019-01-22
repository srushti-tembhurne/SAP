package TestUtils;

use strict;
use FindBin;
use lib "$FindBin::Bin/../../../lib";
use ariba::monitor::QueryManager;
use JSON;
use Data::Dumper;

sub new
{
	my ($class,$args) = @_;
	my $self;

	$self->{queries} = $args->{queries};
	bless ($self, $class);
	return $self;
}

sub validate_query_keys
{
	my $self = shift;
	my $args = shift;
	my $q = $args->{queries} || $self->{queries};
	my $msg = '';
	my $rc = 1;
	if (defined($q->{influx_details}))
	{
		$msg = "influx_details key found.";
		if (ref ($q->{influx_details}) eq 'HASH' && $q->{influx_details}->{measurement})
		{
			$msg .= " influx_details->measurement found.";
		}
		else
		{
			$msg .= " influx_details->measurement not found.";
			$rc = 0;
		}
		
		if (scalar(keys %$q) == 1)
		{
			$msg .= " qm contains no influx fields data.";
			$rc = 0;
		}

	}
	else
	{
		$msg = 'influx_details is missing.';
		$rc = 0;
	}

	return ($rc, $msg);
}

sub validate_qm_output
{
	my $self = shift;
	my $args = shift;
	my $script = $args->{script};


	my $measurement_data = $args->{measurement_data};
	my @measurement_list = (keys %$measurement_data);
	my $measurement_regex = '(' . join (')|(', @measurement_list) . ')';
	my $measurement_data_regex;

	#print "measurement_regex = $measurement_regex\n";
 
	foreach my $m (keys %$measurement_data)
	{
		my $tags = $measurement_data->{$m}->{tags};
		my $fields = $measurement_data->{$m}->{fields};
		(my $tag_str = $tags) =~ s/,/=[^=]*,/g;
		(my $field_str = $fields) =~ s/,/=[^=]*,/g;
		$tag_str .= '=[^=]*';
		$field_str .=  '=[^=]*';
		$measurement_data_regex .= "($m,$tag_str $field_str)|";
	}
	$measurement_data_regex =~ s/\|$//;	
	my @script_output = `$script`;
	my $line_count = 0;
	foreach my $line (@script_output)
	{
		$line_count++;
		next if $line !~ /^($measurement_regex)/;
		if ($line !~ /$measurement_data_regex/)
		{
			#print "failed influxdb: line = $line\nregex = $measurement_data_regex\n" if $line !~ /$measurement_data_regex/;
			return (0, "influxdb output is wrong at line $line_count of script output");
		}
	}
	return (1, "influxdb output looks good!");
}

sub validate_a_script
{
	my $self = shift;
	my $args = shift;
	my $script = $args->{script};
	my $measurement_data = $args->{measurement_data};
	my ($rc,$msg) = $self->validate_qm_output({script => $script, measurement_data => $measurement_data});
	return ($rc,$msg);
}	

sub run_test_from_json
{
	my $self = shift;
	my $args = shift;

	my $single_test = $args->{single_test};
	my $results;

	my $test_conf  = $args->{test_conf};
	open (my $fh, '<', "$test_conf") or die "can't open $test_conf for reading: $!\n";
	my $conf_json;
	while(<$fh>)
	{
		$conf_json .= $_;
	}
	close ($fh) or die "can't close $test_conf: $!\n";

	my $test_conf_hash = from_json($conf_json, {utf8 => 1});
	foreach my $script_data (@{$test_conf_hash->{scripts}})
	{
		my $script_name = $script_data->{script};
		if (defined $single_test)
		{
			next if $script_name !~ $single_test;
		}
		my $measurement_data = $script_data->{measurement_data};
		my $input_data = {};
		foreach my $measurement (@$measurement_data)
		{
			my ($field_str, $tag_str);
			my $measurement_name = $measurement->{measurement_name};
			my $tags = $measurement->{tags};
			my $fields = $measurement->{fields};
			foreach my $field (@$fields)
			{
				$field_str .= qq|"?$field"?,|
			}
			foreach my $tag (@$tags)
			{
				$tag_str .= qq|"?$tag"?,|;
			}
			$field_str =~ s/,$//;
			$tag_str =~ s/,$//;
			$input_data->{$measurement_name} = {tags => $tag_str, fields => $field_str};
		}
		(my $script_path = $script_name) =~ s/^(.*?) .*$/$1/;
		my ($rc,$msg) = $self->validate_a_script({script => $script_name, measurement_data => $input_data});
		my $rc_string = ($rc == 1) ? 'PASSED':'FAILED';
		print qq|test_result_summary,conf_file=$test_conf,test=$script_path rc=$rc,msg="$msg",result="$rc_string"\n|;
	}
}



















1;
