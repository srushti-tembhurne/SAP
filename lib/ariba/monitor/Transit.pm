package ariba::monitor::Transit;

use strict;use warnings;
use 5.006;
#use IPC::Transit::Internal; #XX hack
use Storable;
use Data::Dumper;
#use JSON; #XX hack
#use HTTP::Lite; #XX hack

use vars qw(
    $VERSION
    $config_file $config_dir
    $local_queues
);

our $wire_header_arg_translate = {
    destination => 'd',
    compression => 'c',
    serializer => 's'
};
our $wire_header_args = {
    s => {  #serializer
        json => 1,
        yaml => 1,
        storable => 1,
        dumper => 1,
    },
    c => {  #compression
        zlib => 1,
        snappy => 1,
        none => 1
    },
    d => 1, #destination address
    t => 1, #hop TTL
    q => 1, #destination qname
};
our $std_args = {
    message => 1,
    qname => 1,
    nowait => 1,
};
$VERSION = '0.72';

sub send {
    my $args;
    {   my @args = @_;
        die 'ariba::monitor::Transit::send: even number of arguments required'
            if scalar @args % 2;
        my %args = @args;
        $args = \%args;
    }
    $args->{serializer} = 'dumper'; #XX hack
    my $qname = $args->{qname};
    die "ariba::monitor::Transit::send: parameter 'qname' required"
        unless $qname;
    die "ariba::monitor::Transit::send: parameter 'qname' must be a scalar"
        if ref $qname;
    my $message = $args->{message};
    die "ariba::monitor::Transit::send: parameter 'message' required"
        unless $message;
    die "ariba::monitor::Transit::send: parameter 'message' must be a HASH reference"
        if ref $message ne 'HASH';
    $message->{'.ipc_transit_meta'} = {} unless $message->{'.ipc_transit_meta'};
    $message->{'.ipc_transit_meta'}->{send_ts} = time;
    if($args->{destination}) {
        $args->{destination_qname} = $args->{qname};
        $args->{qname} = 'transitd';
        $args->{ttl} = 9 unless $args->{ttl};
    }

    if($local_queues and $local_queues->{$qname}) {
        push @{$local_queues->{$qname}}, $args;
        return $args;
    }

    my $to_queue = ariba::monitor::Transit::Internal::_initialize_queue(%$args);
    pack_message($args);
    return $to_queue->snd(1,$args->{serialized_wire_data}, ariba::monitor::Transit::Internal::_get_flags('nonblock'));
}

sub stats {
    my $info = ariba::monitor::Transit::Internal::_stats();
    return $info;
}
sub stat {
    my %args;
    {   my @args = @_;
        die 'ariba::monitor::Transit::stat: even number of arguments required'
            if scalar @args % 2;
        %args = @args;
    }
    my $qname = $args{qname};
    if($local_queues and $local_queues->{$qname}) {
        return {
            qnum => scalar @{$local_queues->{$qname}}
        };
    }
    die "ariba::monitor::Transit::stat: parameter 'qname' required"
        unless $qname;
    die "ariba::monitor::Transit::stat: parameter 'qname' must be a scalar"
        if ref $qname;
    my $info = ariba::monitor::Transit::Internal::_stat(%args);
}

sub receive {
    my %args;
    {   my @args = @_;
        die 'ariba::monitor::Transit::receive: even number of arguments required'
            if scalar @args % 2;
        %args = @args;
    }
    my $qname = $args{qname};
    die "ariba::monitor::Transit::receive: parameter 'qname' required"
        unless $qname;
    die "ariba::monitor::Transit::receive: parameter 'qname' must be a scalar"
        if ref $qname;
    if($local_queues and $local_queues->{$qname}) {
        my $m = shift @{$local_queues->{$qname}};
        return $m->{message};
    }
    my $flags = 0;
    $flags = ariba::monitor::Transit::Internal::_get_flags('nowait') if $args{nonblock};
    my $from_queue = ariba::monitor::Transit::Internal::_initialize_queue(%args);
    my $serialized_wire_data;
    $from_queue->rcv($serialized_wire_data, 1024000, 0, $flags);
    return undef unless $serialized_wire_data;
    my $message = {
        serialized_wire_data => $serialized_wire_data,
    };
    unpack_data($message);
    if($message->{message}->{'.ipc_transit_meta'} and $message->{message}->{'.ipc_transit_meta'}->{destination_qname}) {
        #this message is destined for a queue that is different
        #than the one it landed on. Most likely a remote transit
        #this means that we are likely running inside remote-transitd, and
        #we need to post out
#        return post_remote($message); #XX hack
    }
    if($args{raw}) {
        return $message;
    } else {
        return $message->{message};
    }
}

sub post_remote {
    #This is very simple, first-generation logic.  It assumes that every
    #message that is received that has a qname set is destined for off box.

    #so here, we want to post this message to the destination over http
    my $message = shift;
    my $http = HTTP::Lite->new;
    my $vars = {
        message => $message->{serialized_wire_data},
    };
    $http->prepare_post($vars);
    my $url = 'http://' . $message->{message}->{'.ipc_transit_meta'}->{destination} . ':9816/message';
    my $req = $http->request($url)
        or die "Unable to get document: $!";
    return $req;
}

sub local_queue {
    my %args;
    {   my @args = @_;
        die 'ariba::monitor::Transit::local_queue: even number of arguments required'
            if scalar @args % 2;
        %args = @args;
    }
    my $qname = $args{qname};
    $local_queues = {} unless $local_queues;
    $local_queues->{$qname} = [];
    return 1;
}

sub pack_message {
    my $args = shift;
    $args->{message}->{'.ipc_transit_meta'} = {}
        unless $args->{message}->{'.ipc_transit_meta'};
    foreach my $key (keys %$wire_header_arg_translate) {
        next unless $args->{$key};
        $args->{$wire_header_arg_translate->{$key}} = $args->{$key};
    }
    foreach my $key (keys %$args) {
        next if $wire_header_args->{$key};
        next if $std_args->{$key};
        $args->{message}->{'.ipc_transit_meta'}->{$key} = $args->{$key};
    }
    $args->{serialized_message} = freeze($args);
    serialize_wire_meta($args);
    my $l = length $args->{serialized_wire_meta_data};
    $args->{serialized_wire_data} = "$l:$args->{serialized_wire_meta_data}$args->{serialized_message}";
    return $args->{serialized_wire_data};
}

sub unpack_data {
    my $args = shift;
    my ($length, $header_and_message);
    my $s = $args->{serialized_wire_data};
    if($s =~ s/^(\d+)://) {
        $length = $1;
        $header_and_message = $s;
    } else {
        die 'passed serialized_wire_data malformed';
    }
    $args->{serialized_header} = substr($header_and_message, 0, $length, '');
    $args->{serialized_message} = $header_and_message;
    deserialize_wire_meta($args);
    thaw($args);
    return $args;
}

sub serialize_wire_meta {
    my $args = shift;
    my $s = '';
    foreach my $key (keys %$args) {
        my $translated_key = $wire_header_arg_translate->{$key};
        if($translated_key and $wire_header_args->{$translated_key}) {
            if($wire_header_args->{$translated_key} == 1) {
                $s = "$s$translated_key=$args->{$key},";
            } elsif($wire_header_args->{$translated_key}->{$args->{$key}}) {
                $s = "$s$translated_key=$args->{$key},";
            } else {
                die "passed wire argument $translated_key had value of $args->{$translated_key} not of allowed type";
            }
        }
    }
    chop $s; #no trailing ,
    $args->{serialized_wire_meta_data} = $s;
}

sub deserialize_wire_meta {
    my $args = shift;
    my $h = $args->{serialized_header};
    my $ret = {};
    foreach my $part (split ',', $h) {
        my ($key, $val) = split '=', $part;
        $ret->{$key} = $val;
    }
    $args->{wire_headers} = $ret;
}

sub freeze {
    my $args = shift;
    if(not defined $args->{serializer} or $args->{serializer} eq 'json') {
        return encode_json $args->{message};
    } elsif($args->{serializer} eq 'dumper') {
        return Data::Dumper::Dumper $args->{message};
    } elsif($args->{serializer} eq 'storable') {
        return Storable::freeze $args->{message};
    } else {
        die "freeze: undefined serializer: $args->{serializer}";
    }
}

sub thaw {
    my $args = shift;
    if(not defined $args->{wire_headers}->{s} or $args->{wire_headers}->{s} eq 'json') {
        return $args->{message} = decode_json($args->{serialized_message});
    } elsif($args->{wire_headers}->{s} eq 'dumper') {
        our $VAR1;
        eval $args->{serialized_message};
        return $args->{message} = $VAR1;
    } elsif($args->{wire_headers}->{s} eq 'storable') {
        return $args->{message} = Storable::thaw($args->{serialized_message});
    } else {
        die "thaw: undefined serializer: $args->{wire_headers}->{s}";
    }
}

1;


=head1 NAME

IPC::Transit - A framework for high performance message passing

=head1 NOTES

This module is wire incompatable with previous releases.  The wire
protocol in 0.4 and before was meant as a prototype and naive.

This is the final wire protocol.

The serialization is currently hard-coded to JSON.

=head1 SYNOPSIS

  use strict;
  use IPC::Transit;
  IPC::Transit::send(qname => 'test', message => { a => 'b' });

  #...the same or a different process on the same machine
  my $message = IPC::Transit::receive(qname => 'test');

  #remote transit
  remote-transitd &  #run 'outgoing' transitd gateway
  IPC::Transit::send(qname => 'test', message => { a => 'b' }, destination => 'some.other.box.com');

  #On 'some.other.box.com':
  remote-transit-gateway &  #run 'incoming' transitd gateway
  my $message = IPC::Transit::receive(qname => 'test');

=head1 DESCRIPTION

This queue framework has the following goals:
    
=over 4

=item * Serverless

=item * High Throughput

=item * Usually Low Latency

=item * Relatively Good Reliability

=item * CPU and Memory efficient

=item * Cross UNIX Implementation

=item * Multiple Language Compability

=item * Very few module dependencies

=item * Supports old version of Perl

=item * Feature stack is modular and optional

=back

This queue framework has the following anti-goals:

=over 4

=item * Guaranteed Delivery

=back

=head1 FUNCTIONS

=head2 send(qname => 'some_queue', message => $hashref, serializer => 'some serializer')

This sends $hashref to 'some_queue'.  some_queue may be on the local
box, or it may be in the same process space as the caller.

This call will block until the destination queue has enough space to
handle the serialized message.

The serialize_with argument is optional, and defaults to Data::Dumper.
Currently, we are using the module Data::Serializer::Raw; any serialization
scheme that module supports can be used here.

NB: there is no need to define the serialization type in receive.  It is
automatically detected and utilized.

=head2 receive(qname => 'some_queue', nonblock => [0|1])

This function fetches a hash reference from 'some_queue' and returns it.
By default, it will block until a reference is available.  Setting nonblock
to a true value will cause this to return immediately with 'undef' is
no messages are available.


=head2 stat(qname => 'some_queue')

Returns various stats about the passed queue name, per IPC::Msg::stat:

 print Dumper IPC::Transit::stat(qname => 'test');
 $VAR1 = {
          'ctime' => 1335141770,
          'cuid' => 1000,
          'lrpid' => 0,
          'uid' => 1000,
          'lspid' => 0,
          'mode' => 438,
          'qnum' => 0,
          'cgid' => 1000,
          'rtime' => 0,
          'qbytes' => 16384,
          'stime' => 0,
          'gid' => 1000
 }

=head2 stats()

Return an array of hash references, each containing the information 
obtained by the stat() call, one entry for each queue on the system.

=head1 SEE ALSO

A zillion other queueing systems.

=head1 TODO

Crypto

much else

=head1 BUGS

Patches, flames, opinions, enhancement ideas are all welcome.

I am not satisfied with not supporting Windows, but it is considered
secondary.  I am open to the possibility of adding abstractions for this
kind of support as long as it doesn't greatly affect the primary goals.

=head1 COPYRIGHT

Copyright (c) 2012, 2013 Dana M. Diederich. All Rights Reserved.

=head1 LICENSE

This module is free software. It may be used, redistributed
and/or modified under the terms of the Perl Artistic License
(see http://www.perl.com/perl/misc/Artistic.html)

=head1 AUTHOR

Dana M. Diederich <diederich@gmail.com>

=cut

package ariba::monitor::Transit::Internal;

use strict;
use IPC::SysV;
use IPC::Msg;
use POSIX;


use vars qw(
    $config
);

{
my $queue_cache = {};
sub _initialize_queue {
    my %args = @_;
    my $qid = _get_queue_id(%args);
    if(not $queue_cache->{$qid}) {
        $queue_cache->{$qid} = IPC::Msg->new($qid, _get_flags('create_ipc'))
            or die "failed to _initialize_queue: failed to create queue_id $qid: $!\n";
    }
    return $queue_cache->{$qid};
}

sub _remove {
    my %args = @_;
    my $qname = $args{qname};
    my $qid = _get_queue_id(%args);
    $queue_cache->{$qid}->remove if $queue_cache->{$qid};
    unlink _get_transit_config_dir() . "/$qname";
}

sub _stat {
    my %args = @_;
    my $qid = _get_queue_id(%args);
    _initialize_queue(%args);
    my @heads = qw(uid gid cuid cgid mode qnum qbytes lspid lrpid stime rtime ctime);
    my $ret = {};
    my @items = @{$queue_cache->{$qid}->stat};
    foreach my $item (@items) {
        $ret->{shift @heads} = $item;
    }
    $ret->{qname} = $args{qname};
    return $ret;
}
}

sub _drop_all_queues {
    foreach my $qname (keys %{$config->{queues}}) {
        _remove(qname => $qname);
    }
}
sub _stats {
    my $ret = [];
    _gather_queue_info();
    foreach my $queue_name (keys %{$config->{queues}}) {
        push @$ret, ariba::monitor::Transit::stat(qname => $queue_name);
    }
    return $ret;
}

sub _get_transit_config_dir {
    my $dir = $ariba::monitor::Transit::config_dir || '/tmp/ipc_transit/';
    return $dir;
}

sub _lock_config_dir {
    my $lock_file = _get_transit_config_dir() . '/.lock';
    my ($have_lock, $fh);
    for (1..2) {
        if(sysopen($fh, $lock_file, _get_flags('exclusive_lock'))) {
            chmod 666, $lock_file;
            $have_lock = 1;
            last;
        }
        sleep 1;
    }
    if(not $have_lock) {
        _unlock_config_dir();
        sysopen($fh, $lock_file, _get_flags('exclusive_lock'));
        chmod 666, $lock_file;
    }
    #we have the advisory lock for sure now
}


sub _unlock_config_dir {
    my $lock_file = _get_transit_config_dir() . '/.lock';
    unlink $lock_file or die "_unlock_config_dir: failed to unlink $lock_file: $!";
}

sub _gather_queue_info {
    _mk_queue_dir();
    $config->{queues} = {} unless $config->{queues};
    foreach my $filename (glob _get_transit_config_dir() . '/*') {
        my $info = {};
        open my $fh, '<', $filename
            or die "ariba::monitor::Transit::Internal::_gather_queue_info: failed to open $filename for reading: $!";
        while(my $line = <$fh>) {
            chomp $line;
            my ($key, $value) = split '=', $line;
            $info->{$key} = $value;
        }
        die 'required key "qid" not found' unless $info->{qid};
        die 'required key "qname" not found' unless $info->{qname};
        $config->{queues}->{$info->{qname}} = $info;
    }
}

sub _get_queue_id {
    my %args = @_;
    _mk_queue_dir();
    my $qname = $args{qname};

    #return it if we have it
    return $config->{queues}->{$qname}->{qid}
        if $config->{queues} and $config->{queues}->{$qname};

    #we don't have it; let's load it and try again
    _gather_queue_info();
    return $config->{queues}->{$qname}->{qid}
        if $config->{queues} and $config->{queues}->{$qname};

    #we still don't have it; get a lock, load it, try again, ane make
    #it if necessary
    _lock_config_dir();
    eval {
        #now re-load the config
        _gather_queue_info();

        #if we now have it, unlock and return it
        if($config->{queues} and $config->{queues}->{$qname}) {
            _unlock_config_dir();
            return $config->{queues}->{$qname}->{qid};
        }

        #otherwise, we need to make one
        {   my $file = _get_transit_config_dir() . "/$qname";
            open my $fh, '>', $file or die "ariba::monitor::Transit::Internal::_get_queue_id: failed to open $file for writing: $!";
            chmod 0666, $file;
            my $new_qid = IPC::SysV::ftok($file, 1);
            print $fh "qid=$new_qid\n";
            print $fh "qname=$qname\n";
            close $fh;
        }
        _unlock_config_dir();
    };
    if($@) {
        _unlock_config_dir();
    }
    _gather_queue_info();
    return $config->{queues}->{$qname}->{qid};
}

sub _mk_queue_dir {
    mkdir _get_transit_config_dir(), 0777
        unless -d _get_transit_config_dir();
    chmod 0777, _get_transit_config_dir();
}

#gnarly looking UNIX goop hidden below
{
my $flags = {
    create_ipc =>       IPC::SysV::S_IRUSR() |
                        IPC::SysV::S_IWUSR() |
                        IPC::SysV::S_IRGRP() |
                        IPC::SysV::S_IWGRP() |
                        IPC::SysV::S_IROTH() |
                        IPC::SysV::S_IWOTH() |
                        IPC::SysV::IPC_CREAT(),

    nowait =>           IPC::SysV::IPC_NOWAIT(),

    exclusive_lock =>   POSIX::O_RDWR() |
                        POSIX::O_CREAT() |
                        POSIX::O_EXCL(),

    nonblock =>         POSIX::O_NONBLOCK(),
};

sub
_get_flags {
    my $name = shift;
    return $flags->{$name};
}
}
1;
