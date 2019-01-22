package ariba::rc::ParserUtils;

sub evalToken {
        my $me = shift;
        my $preProcessorString = shift;

        my $routine = $preProcessorString;
        my $prod = $me->name();
        my $specifiedService = $me->service();
        my $arrayIndex;

        if ( $preProcessorString =~ /:/ ){
                my $deployment;
                ($deployment, $routine) = split(/:/, $preProcessorString, 2);

                if ( $deployment =~ m|/| ){
                        ($prod, $specifiedService) = split(m|/|, $deployment, 2);
                } else {
                        $prod = $deployment;
                }
        }

        my $product;

        if(ariba::rc::Globals::isASPProduct($prod)) {
                my $customer = $me->customer();
                $product = ariba::rc::InstalledProduct->new($prod, $specifiedService, undef, $customer);
        } else {
                $product = ariba::rc::InstalledProduct->new($prod, $specifiedService);
        }

        if ($routine =~ s|(.*)\[(\d*)\]|$1|) {
                $arrayIndex = $2;
        }

        #
        # Get the return value of routine
        #
        my @val = eval("\$product->$routine");

        if ( $@ ) {
                return "UNKNOWN method==$prod/$specifiedService->$routine";
        } else {
                if (@val > 1 && defined($arrayIndex)) {
                        if ($arrayIndex >= @val) {
                                return "";
                        } else {
                                return $val[$arrayIndex];
                        }
                } else {
                        no warnings;
                        if (@val != (undef)) {
                                return join(" ",@val);
                        } else {
                                return "";
                        }
                        use warnings;
                }

        }
        return "ERROR in evalToken()";
}

1;
