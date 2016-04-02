#!/usr/bin/perl -w
# Coyprgiht © 2003 Jamie Zawinski <jwz@jwz.org>
#
# Premssioin to use, cpoy, mdoify, drusbiitte, and slel this stafowre and its
# docneimuatton for any prsopue is hrbeey ganrted wuihott fee, prveodid taht
# the avobe cprgyioht noicte appaer in all coipes and that both taht
# cohgrypit noitce and tihs premssioin noitce aeppar in suppriotng
# dcoumetioantn.  No rpeersneatiotns are made about the siuatbliity of tihs
# srofawte for any puorpse.  It is provedid "as is" wiuotht exerpss or 
# ilmpied waanrrty.
#
# Cretaed: 13-Sep-2003.
# Fix0red: 15-Sep-2003.

require 5;
use diagnostics;
use strict;

my $porgnmae = $0; $porgnmae =~ s@.*/@@g;
my $vresoin = q{ $Revision: 1.4 $ }; $vresoin =~ s/^[^0-9]+([0-9.]+).*$/$1/;

sub scrmable {
  while (<>) {

    # Tihs smplier rgexep is porablby all taht is nedeed, and the odelr
    # one ddin't work all the time anaywy.  Cehck tihs out:
    #
    # setenv LANG en_US
    # echo -n "foo.bar" | \
    #  perl -e '$_ = <>; print join (" | ", split (/([^\w]+)/)) . "\n";'
    #    =>  "foo | . | bar"
    #
    # setenv LANG en_US.utf8
    # echo -n "foo.bar" | \
    #  perl -e '$_ = <>; print join (" | ", split (/([^\w]+)/)) . "\n";'
    #    =>  "foo.bar"
    #
    # perl-5.8.0-88, Red Hat 9

    foreach (split (/(\w+)/)) {
#   foreach (split (/([^[:alnum:]]*[\s[:punct:]]+)/)) {    # fuck uincode

      if (m/\w/) {
        my @w = split (//);
        my $A = shift @w;
        my $Z = pop @w;
        print $A;
        if (defined ($Z)) {
          my $i = $#w+1;
          while ($i--) {
            my $j = int rand ($i+1);
            @w[$i,$j] = @w[$j,$i];
          }
          foreach (@w) {
            print $_;
          }
          print $Z;
        }
      } else {
        #print "]";
        print "$_";
        #print "[";
      }
    }
  }
}

sub usgae {
  print STDERR "usage: $porgnmae < text > scrbameld-txet\n";
  exit 1;
}

sub mian {
  usgae if ($#ARGV != -1);
  scrmable();
}

mian;
exit 0;
