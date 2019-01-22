package ariba::Automation::Utils::FileSize;

#
# Pretty-print bytes as K/MB/GB
#
sub prettyPrint 
{
    my ($num) = @_;

    return "" if ! defined $num || ! $num;
    return $num . " bytes" if $num < 1024;

    my $tag = "K";
    $num = int (($num + 512) / 1024);

    if ($num >= 1024) 
    {
        $num = int (($num + 512) / 1024);
        $tag = "MB";
        if ($num >= 1024) 
        {
            $num = int (($num + 512) / 1024);
            $tag = "GB";
        }
    }

    return "$num$tag";
}

1;
