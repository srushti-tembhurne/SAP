#!/usr/local/bin/perl -w
#
# This script is used for aws-route53 network failover/failback
###

use strict;
use FindBin;
use lib qw(/usr/local/ariba/lib);

use Digest::HMAC_SHA1;
use MIME::Base64 qw(encode_base64);
use IO::Handle;
use XML::Simple;
use Data::Dumper;
use ariba::rc::Passwords;
use ariba::rc::InstalledProduct;

sub usage {
    my $error = shift;

    print <<USAGE;
Usage: $0 -getSign | <-hostedZoneName "hosted.zone.name" -mainDNS "main.domain.name" -primary "primary.DNS.after.Failover" -secondary "secondary.DNS.after.Failover" -awsKey "awsKey" -sign "sign"> | -h 

    -getSign            get the encrypted signature along with date stamp(JMCL compatible format).
    
    -hostedZoneName     Name of the hosted zone.
    -mainDNS            Main Domain name.
    -primary            DNS name which is expected to work as primary after failover.
    -secondary          DNS name which is expected to work as secondary after failover.
    -awsKey             AWS access key ID.
    -sign               Encrypted signature along with date stamp.
    
    -h                  Shows this help.

USAGE

    print "(error) $error\n" if ($error);

    exit();
}

my $logFile = '/tmp/route53.log';
open my $fh, ">", $logFile or die "Can't open the file: $!";

my $datestring = gmtime();

print $fh "\n ***** Route53 Network failover *****\n";
print $fh "Script execution started at:". $datestring." GMT\n";

sub main {
    my $hostedZoneName;
    my $mainDomainName;
    my $primary;
    my $secondary;
    my $sign;
    my $awsKey;
    my $getSign;
    my $failoverTime = 120; # Tentative time taken to failover after swapping weights of primary & secondary DNS.

    while (my $arg = shift) {
        if ($arg =~ /^-h$/o)                   { usage();            next; }
        elsif ($arg =~ /^-hostedZoneName$/o)   { $hostedZoneName   = shift; }
        elsif ($arg =~ /^-mainDNS$/o)          { $mainDomainName   = shift; }
        elsif ($arg =~ /^-primary$/o)          { $primary          = shift; }
        elsif ($arg =~ /^-secondary$/o)        { $secondary        = shift; }
        elsif ($arg =~ /^-awsKey$/o)           { $awsKey           = shift; }
        elsif ($arg =~ /^-sign$/o)             { $sign             = shift; }
        
        elsif ($arg =~ /^-getSign$/o)           { $getSign           = 1; }
        else { usage("Invalid argument: $arg"); }
    }
    
    unless( $getSign || ($hostedZoneName && $mainDomainName && $primary && $secondary && $sign && $awsKey) ){
        usage("All required parameters should be passed.\n");
    }
    

    ##########
    # Acts as getter function of script
    if ($getSign){
        #Initialize master password
        my $monProd = ariba::rc::InstalledProduct->new("mon");
        my $service = $monProd->service();
        ariba::rc::Passwords::initialize($service);

        my $plainText = ariba::rc::Passwords::lookup( 'awsPassword' );
        
        unless( $plainText ){
            print $fh "Error: Failed to get awsPassword\n";
            close $fh;
            exit 1;
        }
        
        my $hmac = Digest::HMAC_SHA1->new($plainText);
    
        my $date = gmtime();

        # Forming signature with latest timestamp
        $hmac->add($date);
        my $signature = encode_base64($hmac->digest, "");
        #NOTE: DO NOT change following format of STDOUT. This is how JMCL expects o/p from this script.
        print "signature|$date|$signature\n";
        
        print $fh "Output Date: $date\nOutput Signature: $signature\n";
        close $fh;
        exit 0;
    }
    
    my ($text, $date, $signature) = split(/\|/, $sign);
    
    chomp($date, $signature);
    print $fh "Input Date: $date\nInput Signature: $signature\n";

    #########
    # Acts as setter part of script

    my $cmd1 = "curl -k --url https://route53.amazonaws.com/2013-04-01/hostedzone --progress-bar --header \"Date: $date\" --header \"X-Amzn-Authorization: AWS3-HTTPS AWSAccessKeyId=$awsKey,Algorithm=HmacSHA1,Signature=$signature\"";
    
    my $zoneList = `$cmd1`;

    curlCallValidation($cmd1, $zoneList);
    print $fh "\n \n === \n $zoneList\n\n";

    my $xml = XML::Simple->new;
    my $zoneListXml = eval{ $xml->XMLin($zoneList, KeyAttr => { HostedZone => 'Name' } ) };
    if ($@) {
        print $fh "Error: XML conversion failed: $@\n";
        exitRoutine(0);
    }
    
    my $hostedZoneId = $zoneListXml->{HostedZones}->{HostedZone}->{$hostedZoneName}->{Id};
    
    my $cmd2 = "curl -k --url https://route53.amazonaws.com/2013-04-01$hostedZoneId/rrset  --progress-bar --header \"Date: $date\" --header \"X-Amzn-Authorization: AWS3-HTTPS AWSAccessKeyId=$awsKey,Algorithm=HmacSHA1,Signature=$signature\"";
    
    my $zoneInfo = `$cmd2`;
    curlCallValidation($cmd2, $zoneInfo);
    print $fh "\n \n === \n $zoneInfo\n\n";
    
    #print $fh "Info: Checking DNS configuration before change \n";
    #domainIPValidation($zoneInfo, $mainDomainName);
    
    my $currentDnsHash = returnPrimarySecondaryDnsHash( $zoneInfo, $mainDomainName );
    my $newDnsHash;
    #print Dumper($currentDnsHash);
    # Check whether primary/secondary DNS names input by user are actually present or not
    
    print $fh "Action: Checking whether the primary DNS name entry is present under main domain name\n";
    
    if ( $primary eq $currentDnsHash->{Primary}->{AliasTarget}->{DNSName} ){
        print $fh "Success: Primary DNS name entry found under main domain name\n";
        $newDnsHash->{Primary} = $currentDnsHash->{Primary};
        
    } elsif ( $primary eq $currentDnsHash->{Secondary}->{AliasTarget}->{DNSName} ){
        print $fh "Success: Primary DNS name entry found under main domain name\n";
        $newDnsHash->{Primary} = $currentDnsHash->{Secondary};
    } else {
        print $fh "Error: Primary DNS name [$primary] not found under main domain name ResourceRecordSet\n";
        exitRoutine(0);
    }
    
    print $fh "Action: Checking whether the secondary DNS name entry is present under main domain name\n";
    
    if ( $secondary eq $currentDnsHash->{Primary}->{AliasTarget}->{DNSName} ){
        print $fh "Success: Primary DNS name entry found under main domain name\n";
        $newDnsHash->{Secondary} = $currentDnsHash->{Primary};
        
    } elsif ( $secondary eq $currentDnsHash->{Secondary}->{AliasTarget}->{DNSName} ){
        print $fh "Success: Primary DNS name entry found under main domain name\n";
        $newDnsHash->{Secondary} = $currentDnsHash->{Secondary};
    } else {
        print $fh "Error: Primary DNS name [$primary] not found under main domain name ResourceRecordSet\n";
        exitRoutine(0);
    }

    #print Dumper($newDnsHash);

    #Assigning primary dns the higher weight than secondary dns
    $newDnsHash->{Primary}->{Weight} = 20;
    $newDnsHash->{Secondary}->{Weight} = 0;

    # Changing back to xml format;
    my $primaryXml = eval { XMLout( $newDnsHash->{Primary}, rootname => 'ResourceRecordSet', noattr => 1  ) };
    if ($@) {
        print $fh "Error: XML conversion failed: $@\n";
        exitRoutine(0);
    }
    my $secondaryXml = eval { XMLout( $newDnsHash->{Secondary}, rootname => 'ResourceRecordSet', noattr => 1 ) };
    if ($@) {
        print $fh "Error: XML conversion failed: $@\n";
        exitRoutine(0);
    }
    
    chomp($primaryXml);
    chomp($secondaryXml);
    
    print $fh "Action: Changing weight of new primary node to ". $newDnsHash->{Primary}->{Weight}. "\n";
    
    my $cmd3 = "curl -k -X POST --header \"Content-Type:application/xml\" --header \"Date: $date\" --header \"X-Amzn-Authorization: AWS3-HTTPS AWSAccessKeyId=$awsKey,Algorithm=HmacSHA1,Signature=$signature\" --data '<?xml version=\"1.0\" encoding=\"UTF-8\"?><ChangeResourceRecordSetsRequest xmlns=\"https://route53.amazonaws.com/doc/2013-04-01/\"><ChangeBatch><Comment>Changing primary to secondary</Comment><Changes><Change><Action>UPSERT</Action>$primaryXml</Change></Changes></ChangeBatch></ChangeResourceRecordSetsRequest>' https://route53.amazonaws.com/2013-04-01$hostedZoneId/rrset";

    my $opPrimary = `$cmd3`;
    curlCallValidation($cmd3, $opPrimary);

    print $fh "\n \n === \n $opPrimary \n \n";
    
     print $fh "Action: Changing weight of new secondary node to ". $newDnsHash->{Secondary}->{Weight}. "\n";
     
     my $cmd4 = "curl -k -X POST --header \"Content-Type:application/xml\" --header \"Date: $date\" --header \"X-Amzn-Authorization: AWS3-HTTPS AWSAccessKeyId=$awsKey,Algorithm=HmacSHA1,Signature=$signature\" --data '<?xml version=\"1.0\" encoding=\"UTF-8\"?><ChangeResourceRecordSetsRequest xmlns=\"https://route53.amazonaws.com/doc/2013-04-01/\"><ChangeBatch><Comment>Changing secondary to primary</Comment><Changes><Change><Action>UPSERT</Action>$secondaryXml</Change></Changes></ChangeBatch></ChangeResourceRecordSetsRequest>' https://route53.amazonaws.com/2013-04-01$hostedZoneId/rrset";

     my $opSecondary = `$cmd4`;
     curlCallValidation($cmd4, $opSecondary);
     print $fh "\n \n === \n $opSecondary \n \n";
    
    # Wait for sometime to divert the traffic via new DNS.
    sleep $failoverTime;
    
    print $fh "Info: Verifying DNS configuration after change \n";
    
    my $cmd5 = "curl -k --url https://route53.amazonaws.com/2013-04-01$hostedZoneId/rrset  --progress-bar --header \"Date: $date\" --header \"X-Amzn-Authorization: AWS3-HTTPS AWSAccessKeyId=$awsKey,Algorithm=HmacSHA1,Signature=$signature\"";
    
    my $finalOutput = `$cmd5`;
     curlCallValidation($cmd5, $finalOutput);
     
    print $fh "\n \n === \n $finalOutput\n\n";
    
    domainIPValidation($finalOutput, $mainDomainName, $primary, $secondary);

    print $fh "Success: DNS failover executed successfuly\n";
    
    #Return a specific exit status to JMCL where from this script is called.
    exitRoutine(1);
}


######
# This function accepts a hostedZone info retured by curl call. Based on the mainDomainName provided as another input,
# it checks whether there are exactly two DNS entries associated to that particular domain. It compares the weights of both DNS &
# prepares hash by naming higher weighted DNS as primary and lower as secondary. Anything found unexpected is returned as failure.
sub returnPrimarySecondaryDnsHash {
    my $zoneInfo = shift;
    my $mainDomainName = shift;
    
    my $xml = XML::Simple->new;
    my $zoneInfoXml = eval { $xml->XMLin($zoneInfo, KeyAttr => [] ) };
    if ($@) {
        print $fh "Error: XML conversion failed: $@\n";
        exitRoutine(0);
    }
    
    my @dnsArray;

    # Collecting all ResourceRecordSets with same domain name as provided in input
    foreach my $rrSet ( @{ $zoneInfoXml->{ResourceRecordSets}->{ResourceRecordSet} } ){
        if ( $rrSet->{Name} eq $mainDomainName ){
            if ( exists $rrSet->{AliasTarget}->{DNSName} ){
                push (@dnsArray, $rrSet);
            }
        }
    }

    my $currentDnsHash = {};

    # Checking if max two entries (primary and secondary) exist
    if (scalar(@dnsArray) != 2){
        print $fh "Error: ResourceRecordSet $mainDomainName has more or less than 2 DNS entries.\n Please check network configuration!\n";
        exitRoutine(0);
    } else {
                # Calculate current primary and secondary DNSName
                if ( $dnsArray[0]->{Weight} > $dnsArray[1]->{Weight} ){
                    $currentDnsHash->{Primary} = $dnsArray[0];
                    $currentDnsHash->{Secondary} = $dnsArray[1];
                    
                } elsif ( $dnsArray[0]->{Weight} < $dnsArray[1]->{Weight} ) {
                    $currentDnsHash->{Primary} = $dnsArray[1];
                    $currentDnsHash->{Secondary} = $dnsArray[0];
                    
                } elsif ( $dnsArray[0]->{Weight} == $dnsArray[1]->{Weight} ) {
                    print $fh "Error: Both DNS has same weight. No action taken to change weight.\n Please check network configuration!\n";
                    exitRoutine(0);
                } else {
                    print $fh "Error: Could not check DNS weights as expected.\n Please check network configuration!\n";
                    exitRoutine(0);
                }

                print $fh "Info: Primary DNS is ".$currentDnsHash->{Primary}->{AliasTarget}->{DNSName}."\n";
                print $fh "Info: Secondary DNS is ".$currentDnsHash->{Secondary}->{AliasTarget}->{DNSName}."\n";
                
                return $currentDnsHash;
        }
}


######
# This function performs following two validations:
# 1. Checks whether primary & secondary dns are set properly (based on weights) as per the script input
# 2. Checks whether main domain traffic is going through primary DNS (higher weighted) or not.
# Anything found not as exepected is returned as failure
sub domainIPValidation {
    my $zoneInfo        = shift;
    my $mainDomainName  = shift;
    my $primary         = shift;
    my $secondary       = shift;

    my $modifiedDnsHash = returnPrimarySecondaryDnsHash( $zoneInfo, $mainDomainName );
    
    my $primaryDnsName = $modifiedDnsHash->{Primary}->{AliasTarget}->{DNSName};
    my $secondaryDnsName = $modifiedDnsHash->{Secondary}->{AliasTarget}->{DNSName};

    # Parse xml based on ResourceRecordSet Names
    my $xml = XML::Simple->new;
    my $zoneListXml = eval { $xml->XMLin($zoneInfo, KeyAttr => { ResourceRecordSet => 'Name' } ) };
    if ($@) {
        print $fh "Error: XML conversion failed: $@\n";
        exitRoutine(0);
    }
    my $primaryIp = $zoneListXml->{ResourceRecordSets}->{ResourceRecordSet}->{$primaryDnsName}->{ResourceRecords}->{ResourceRecord}->{Value};
    my $secondaryIp = $zoneListXml->{ResourceRecordSets}->{ResourceRecordSet}->{$secondaryDnsName}->{ResourceRecords}->{ResourceRecord}->{Value};
    
    print $fh "\n \nInfo: Primary DNS IP is [$primaryIp]\n";
    print $fh "Info: Secondary DNS IP is [$secondaryIp]\n";

    print $fh "Action: Checking if primary/secondary DNS are modified as expected\n";
    if ( $primary ne $primaryDnsName ){
        print $fh "Failure: Primary DNS modification failed\n";
        exitRoutine(0);
    }
    
    if ( $secondary ne $secondaryDnsName ){
        print $fh "Failure: Secondary DNS modification failed\n";
        exitRoutine(0);
    }
    print $fh "Success: Primary & secondary DNS are modified as expected\n";
    
    print $fh "Action: Getting IP associated with domain $mainDomainName\n";
    my $output = `host -t a $mainDomainName`;
    # Sample $output = "drtest.glb.ariba.com has address xxx.xxx.xxx.xxx"
    my @array = split(' ',$output);
    chomp(@array);
    my $mainDomainIP = $array[3];
    print $fh "Info: IP associated with [$mainDomainName] is [$mainDomainIP] \n";

    if( $primaryIp ne $mainDomainIP ){
        print $fh "Failure: Domain IP validtaion failed since network traffic is not going through higher weight i.e. primary DNS\n";
        exitRoutine(0);
    }
    
    print $fh "Success: Domain IP validation is successful\n\n";
    return 1;
}

######
# Just a basic check for the curl call response
sub curlCallValidation {
    my $cmd = shift;
    my $output = shift;
    if( $output =~ /ErrorResponse/ ){
        print $fh "This curl call failed with an error\n\n CMD: [$cmd]\n\n Error: [$output]\n";
        exitRoutine(0);
    }
}


######
# Function to print a specific format of result to STDOUT which inturn is read by JMCL
sub exitRoutine{
    my $status = shift;
    close $fh;
    if($status){
        # Send final status to JMCL which will read it from STDOUT
        print "Network failover succeeded|$logFile\n";
        exit 0;
    } else {
        # Send final status to JMCL which will read it from STDOUT
        print "Network failover failed|$logFile\n";
        exit 1;
    }
}

main(@ARGV);

__END__
