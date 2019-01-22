package ariba::monitor::Bpm;

#
# $Id: //ariba/services/monitor/lib/ariba/monitor/Bpm.pm#9 $
#
# List of utility and processing methods related to Business Process Monitoring
#

use strict;
use ariba::monitor::Url;
use ariba::monitor::OutageSchedule;
use ariba::monitor::AppRecycleOutage;
use ariba::monitor::ProductStatus;
use HTML::Entities;
use XML::Simple;
use Data::Dumper;

our $debug = 0;

sub replaceTokens
{
    my $text   = shift;
    my $tokens = shift;

    if ($tokens && ref ($tokens) eq 'HASH')
    {
        while (my ($token, $value) = each (%$tokens))
        {
            $text =~ s/{$token}/$value/gi;
        }
    }

    return $text;
}

sub urlForANApp
{
    my $an  = shift;
    my $app = shift;

    my $productStatus = ariba::monitor::ProductStatus->newWithDetails($an->name(), $an->service(), $an->customer());
    return undef if ($productStatus->inPlannedDownTime());

    return $an->default('AdminSecureFrontDoor') . "/$app.aw/ad/monitorBpm";
}

sub communityUrlsForUrlAndCommunities
{
    my $url         = shift;
    my @communities = @_;
    my %communityUrls;

    return \%communityUrls unless defined ($url);

    foreach my $community (@communities)
    {
        $communityUrls{$community} = $url;
    }

    return \%communityUrls;
}

# Returns a hash (community => url) for the specified product and app
sub communityUrlsForProductAndAppName
{
    my $product = shift;
    my $app     = shift;
    my %communityUrls;

    my $productStatus = ariba::monitor::ProductStatus->newWithDetails($product->name(), $product->service(), $product->customer());
    return \%communityUrls if ($productStatus->inPlannedDownTime());

    my @appInstances = $product->appInstances();
    foreach my $instance (@appInstances)
    {
        next unless ($instance->appName() eq $app);

        my $outageName = ariba::monitor::AppRecycleOutage->instanceName($instance->productName(), $instance->instanceName());
        if (ariba::monitor::AppRecycleOutage->objectWithNameExists($outageName))
        {
            my $outage = ariba::monitor::AppRecycleOutage->new($outageName);
            next if ($outage);
        }

        if ($product->name() eq 'buyer')
        {
            $communityUrls{$instance->community()} = $instance->businessProcessMonitorURL() unless ($communityUrls{$instance->community()});
        }
        elsif ($product->name() eq 'an')
        {
            $communityUrls{$instance->community()} = $instance->monitorBpmURL() unless ($communityUrls{$instance->community()});
        }
        else
        {
            $communityUrls{$instance->community()} = "communityUrlsForProductAndAppName is not implemented for product " . $product->name();
        }
    }

    return \%communityUrls;
}

# Returns a hash with the following structure:
#   $responses->{communityId}->{url} = Full url of the GET request
#                            ->{content} = Xml content from url
#                            ->{error} = Request errors
sub getResponsesForUrlsAndParams
{
    my $urls                = shift;
    my $params              = shift;
    my $addCommunityToParam = shift;

    my %responses;

    return \%responses unless (ref ($urls) eq 'HASH' && ref ($params) eq 'HASH');

    my @communities = keys (%$urls);
    foreach my $community (sort @communities)
    {
        my $url = $urls->{$community};
        $params->{community} = $community if ($addCommunityToParam);

        unless ($url)
        {
            $responses{$community}{error} = "No url specified for community $community";
            next;
        }

        my $request = ariba::monitor::Url->new($url);
        $request->setParams($params);
        $request->setTimeout(30);

        my $fullUrl = $request->fullUrl();
        $responses{$community}{url} = $fullUrl;

        print "Checking $fullUrl\n" if ($main::debug);

        my $response;
        eval {$response = $request->request();};

        if ($request->error() || $@)
        {
            my $error = $request->error() || $@;
            $responses{$community}{error} = "HTTP request error for community $community: $error";
            next;
        }

        unless ($response)
        {
            $responses{$community}{error} = "HTTP request has no response for community $community";
            next;
        }

        $responses{$community}{content} = $response;
    }

    return \%responses;
}

sub splitResponsesBetween4xxAndNon4xx
{
    my $responses          = shift;
    my $responsesFor4xx    = {};
    my $responsesForNon4xx = {};

    my @communities = keys (%$responses);
    foreach my $community (@communities)
    {
        # Set common fields
        foreach my $field (qw(url error))
        {
            $responsesFor4xx->{$community}{$field}    = $responses->{$community}{$field};
            $responsesForNon4xx->{$community}{$field} = $responses->{$community}{$field};
        }

        # Split xml based on isNon4xx attribute
        next unless ($responses->{$community}{content});

        my @contentFor4xx;
        my @contentForNon4xx;
        my $isNon4xx;
        foreach my $line (split (/\r?\n/, $responses->{$community}{content}))
        {
            if ($line =~ / isNon4xx="(\w+)" / || $isNon4xx)
            {
                $isNon4xx = $1 if ($1);
                if ($isNon4xx eq 'true')
                {
                    push (@contentForNon4xx, $line);
                }
                else
                {
                    push (@contentFor4xx, $line);
                }

                undef ($isNon4xx) if ($line =~ /\/>$|<\/Object>/);
            }
            else
            {
                push (@contentFor4xx,    $line);
                push (@contentForNon4xx, $line);
            }
        }

        $responsesFor4xx->{$community}{content}    = join ("\n", @contentFor4xx);
        $responsesForNon4xx->{$community}{content} = join ("\n", @contentForNon4xx);
    }

    return ($responsesFor4xx, $responsesForNon4xx);
}

sub removeProcessedPayloadIdsFromResponses
{
    my $processedPayloadIds = shift;
    my $responses           = shift;

    my @communities = keys (%$responses);
    foreach my $community (@communities)
    {
        next unless ($responses->{$community}{content});

        my @content;
        my $objectContent = '';
        my $inObject;
        my $discard;
        foreach my $line (split (/\r?\n/, $responses->{$community}{content}))
        {
            if ($inObject || $line =~ /<Object .* payloadID="([^"]+)"/)
            {
                if ($1)
                {
                    $inObject = 1;
                    $discard = $processedPayloadIds->{$1} ? 1 : 0;
                }

                if ($line =~ /\/>$|<\/Object>/)
                {
                    $inObject = 0;
                }

                push (@content, $line) unless ($discard);
            }
            else
            {
                push (@content, $line);
            }
        }

        $responses->{$community}{content} = join ("\n", @content);
    }
}

sub processResultsFromResponses
{
    my $responses           = shift;
    my $processedPayloadIds = shift;

    my @output;
    my @xmlOutput;
    my @errors;
    my $commonStyle = "white-space:nowrap;padding-right:1em;text-align:left";
    my @fields      = qw(documentNumber payloadID currentStatus stuckMinutes stuckTime documentSubmitTime errorReason ErrorReason);
    my %inf_fields = (
                      documentNumber     => 'document_number',
                      payloadID          => 'payload_id',
                      currentStatus      => 'current_status',
                      stuckMinutes       => 'stuck_mins',
                      stuckTime          => 'stuck_time',
                      documentSubmitTime => 'document_submit_time',
                      ErrorReason        => 'error_reason'
                     );
    my @headers;
    my $outage = ariba::monitor::OutageSchedule->new('sat 19:00-23:00');

	my @communities = keys(%$responses);
	foreach my $community (sort @communities) { 
		my $response = $responses->{$community}{content} || ''; 
		my $url = $responses->{$community}{url};
		my $error = $responses->{$community}{error};

		$self->setUrl($url);

		if ($error) {
			push(@errors, $error); 
			next;
		}

		unless ($response =~ /BusinessProcessMonitoringResponse/) {
			push(@errors, "Non-XML or bad response: " . HTML::Entities::encode_entities($response)); 
			next
		}

		my $xml = eval { XMLin($response, ForceArray => [qw/Threshold Buyer Supplier Object/], KeyAttr => [qw/level anid id/]); }; 
		if ($@) {
			push(@errors, "XML parse error for content: $@"); 
			next;
		}
		
		unless ($xml && ref($xml) eq 'HASH') {
			push(@errors, "Response is empty or not XML");
			next;
		}

		$response =~ s/<\?.*\?>//;			# Remove the xml declaration
		$response =~ s/^\s+</</gm;			# Remove white space before tag
		$response =~ s/>\s*\r?\n\s*/>/g;	# Remove white space/return/newline after tag
		push(@xmlOutput, "<Community name=\"$community\">$response</Community>");
		
		
		my $thresholdDescription = '{level} is {threshold}';
		if ($xml->{Metric}) {
			$thresholdDescription = $xml->{Metric}{ThresholdDescription} if ($xml->{Metric}{ThresholdDescription});
			$self->setDescription($xml->{Metric}{Description}) if (!$self->description() && $xml->{Metric}{Description});
		}

		foreach my $thresholdType (qw(critical warning)) {
			next unless ($xml->{Threshold} && $xml->{Threshold}{$thresholdType} && 
				$xml->{Threshold}{$thresholdType}{Buyer}); 
			my $defaultThreshold = $xml->{Threshold}{$thresholdType}{default};
			my $buyerData = $xml->{Threshold}{$thresholdType}{Buyer};
			my $status = 'warn';
			$status = 'crit' if ($thresholdType eq 'critical');
			if ($self->severity() && $thresholdType eq 'critical' && scalar(keys(%$buyerData)) > 1) {
				$self->setSeverity(0);
				$shouldPage = 1; 
			}

			foreach my $buyerId (keys(%$buyerData)) {
				my $supplierData = $buyerData->{$buyerId}{Supplier};
				next unless ($supplierData);
				my $buyerThreshold = $buyerData->{$buyerId}{threshold};
				my $buyerName = $buyerData->{$buyerId}{name}; 
				
				foreach my $supplierId (keys(%$supplierData)) {
					my $data = $supplierData->{$supplierId}{Object};
					next unless ($data);
					my $supplierThreshold = $supplierData->{$supplierId}{threshold}; 
					my $supplierName = $supplierData->{$supplierId}{name}; 

					foreach my $row (@$data) {
						my $buildHeaders = !@headers;
						push(@headers, qw(Buyer Supplier)) if ($buildHeaders);
						my @columns = ("$buyerId ($buyerName)", "$supplierId ($supplierName)");
						my $errorReason;

						foreach my $field (@fields) {
							next unless exists($row->{$field});

							my $value = $row->{$field};
		
							if ($buildHeaders) {	
								if ($field eq 'stuckTime') {
									push(@headers, ucfirst('stuckMinutes')); 
								} elsif ($field !~ /errorReason/i) {
									push(@headers, ucfirst($field)); 
								}
							}

							if ($field =~ /stuck(?:Time|Minutes)/) {
								$value = int($value) if (defined($value));
							}

							if ($field =~ /errorReason/i) {
								$value =~ s/<|>//g;
								$value =~ s/\r?\n/<br>/g;
								$errorReason = $value;
							} else {
								push(@columns, $value);
							}

							if (ref($processedPayloadIds) eq 'HASH' && $field eq 'payloadID') {
								$processedPayloadIds->{$value} = 1;	
							}
						}

						my $thresholdTip = replaceTokens($thresholdDescription, {
								level => $thresholdType, 
								threshold => $supplierThreshold || $buyerThreshold || $defaultThreshold
							});
						my $thresholdSource = 'internal';
						if ($supplierThreshold) {
							$thresholdSource = 'supplier'; 
							$shouldPage = 1;
						} elsif ($buyerThreshold) {
							$thresholdSource = 'buyer'; 
							$shouldPage = 1;
						}
						$thresholdTip .= " ($thresholdSource)";
						$thresholdTip =~ s/'/\\'/g;
						
                        my $statusForColor = $status;
                        my %toolTips = (
                                        Status    => ucfirst ($thresholdType),
                                        Threshold => $thresholdTip,
                                       );

                        $toolTips{'Error Reason'} = $errorReason if ($errorReason);
                        my $toolTip = '';
                        foreach my $field (sort keys (%toolTips))
                        {
                            my $value = $toolTips{$field};
                            $value =~ s/'/"/g;    # Prevent breaking title html below
                            $toolTip .= "<p class=\"indentSecondLine\"><b>$field</b>: $value</p>";
                        }
                        push (@output, join ("||", @columns));

                    }
                }
            }
        }
    }

    if (@errors)
    {
        unshift (@output, @errors);
    }

    return (@output);
}

return 1;
