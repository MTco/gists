#!/usr/bin/perl -w
# check-links.pl --- check a URL for dead or moved links.
# Copyright © 1999-2007 Jamie Zawinski <jwz@jwz.org>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or 
# implied warranty.
# Created: 13-Jun-99.

# usage:
#         check-links *.html > /tmp/results.html
# or:
#         find . -name \*.html | xargs check-links.pl > /tmp/results.html
#
# It only checks HTTP URLs and local files, and does not recurse (that is,
# it does not *open* any local file that was not specified on the command
# line, though it will check for the existence of any that are referenced.)

require 5;
use strict;

# We can't "use diagnostics" here, because that library malfunctions if
# you signal and catch alarms: it says "Uncaught exception from user code"
# and exits, even though I damned well AM catching it!
#use diagnostics;

use POSIX;
use Socket;

my $progname = $0; $progname =~ s@.*/@@g;
my $version = q{ $Revision: 1.16 $ }; $version =~ s/^[^0-9]+([0-9.]+).*$/$1/;

my $http_proxy = undef;
my $http_timeout = 10;

my $ok_string = "OK.";

my $head = "<TITLE>link check</TITLE>\n" .
    "<BODY BGCOLOR=\"#FFFFFF\" TEXT=\"#000000\"\n" .
    " LINK=\"#0000EE\" VLINK=\"#551A8B\" ALINK=\"#FF0000\">\n" .
    "\n" .
    "<H1 ALIGN=CENTER>link check</H1>\n" .
    "<CENTER>\n";

my $table_start = "<TABLE BORDER=0 CELLPADDING=2 CELLSPACING=0>\n";
my $table_end = "</TABLE>\n";
my $tail = "</CENTER><HR><P>\n";

my $bgca = "#FFFFFF";
my $bgcb = "#E0E0E0";
my $bgc  = $bgca;

sub check_http_status {
  my ($url) = @_;

  if (! ($url =~ m@^http://@i)) {
    return "Not an HTTP URL";
  }

  my ($url_proto, $dummy, $serverstring, $path) = split(/\//, $url, 4);
  $path = "" unless $path;

  my ($them,$port) = split(/:/, $serverstring);
  $port = 80 unless $port;

  my $them2 = $them;
  my $port2 = $port;
  if ($http_proxy) {
    $serverstring = $http_proxy if $http_proxy;
    ($them2,$port2) = split(/:/, $serverstring);
    $port2 = 80 unless $port2;
  }

  my ($remote, $iaddr, $paddr, $proto, $line);
  $remote = $them2;
  if ($port2 =~ /\D/) { $port2 = getservbyname($port2, 'tcp') }
  if (!$port2) {
    return "Unrecognised port: $port2";
  }
  $iaddr   = inet_aton($remote);
  if (!$iaddr) {
    return "Host not found: $remote";
  }
  $paddr = sockaddr_in($port2, $iaddr);

  $proto = getprotobyname('tcp');
  if (!socket(S, PF_INET, SOCK_STREAM, $proto)) {
    return "socket: $!";
  }
  if (!connect(S, $paddr)) {
    return "connect: $serverstring: $!";
  }

  select(S); $| = 1; select(STDOUT);

  # have to use GET, not HEAD, because some servers are stupid.
  print S "GET " . ($http_proxy ? $url : "/$path")  . " HTTP/1.0\r\n";
  print S "Host: $them\r\n";
  print S "User-Agent: $progname/$version\r\n";
  print S "\r\n";

  my $http = <S>;

  $_  = $http;
  s/[\r\n]+$//s if (defined ($http));

  my $location;
  while (<S>) {
    if (m@^$@) {
      last;
    } elsif (m@Location: (.*)@i) {
      $location = $1;
      $location =~ s/[\r\n ]+$//;
    }
  }

  close(S);

  if (!$http) {
    return "Null response";
  }


  if ($location && $location eq "") {
    $location = undef;
  }

  if ($location && ! ($location =~ m/^[a-z]+:/i)) { # relative url
    if ($location =~ m@^/@) { # begins with slash
      my $hp = $them;
      if ($port2 && $port2 ne "80") { $hp .= ":$port"; }
      $location = "http://$hp$location";
    } else { # relative downward
      my $head = $url;
      $head =~ s@/[^/]*$@/@;
      $location = "$head$location";
    }
  }

  $_ = $http;
  if (m@^HTTP/[0-9.]+ ([0-9]+)[ \t\r\n]@) {
    my $code = $1;
    if ($code == 200) {
      return $ok_string;
    } elsif ($code == 301) {
      if ($location) {
        return "Moved <A HREF=\"$location\"><B>here</B></A>.";
      } else {
        return "301 (\"Moved Permanently\"), but with no new URL.";
      }
    } elsif ($code == 302) {
      if ($location) {
        return "Moved <A HREF=\"$location\"><B><I>here</B></B></A> " .
               "(temporarily).";
      } else {
        return "301 (\"Moved Temporarily\"), but with no new URL.";
      }
    } elsif ($code == 401) {
      return "Password Protected.";
    } elsif ($code == 403 || $code == 404) {
      return "Dead.";
    } elsif ($code == 500) {
      return "Server error.";
    } else {
      return "Unknown code \"$code\" in \"$http\".";
    }
  } else {
    return "non-HTTP response \"$http\".";
  }
}


sub check_http_status_with_timeout {
  my ($url, $timeout) = @_;
  my $status = undef;

  @_ =
    eval {
      local $SIG{ALRM} = sub {
        die "alarm\n";
      };
      alarm $timeout;
      $status = check_http_status ($url);
    };
  die if ($@ && $@ ne "alarm\n");       # propagate errors
  if ($@) {
    $status = "Timed out!";
  } else {
    # didn't
    alarm 0;
  }
  return $status;
}


my $tick = 0;
my $tick2 = 0;
sub check_url {
    my ($url, $title, $orig_url) = @_;
    my $next_url = undef;

    $_ = $url;

    print "<TR><TD ALIGN=RIGHT VALIGN=TOP BGCOLOR=\"$bgc\">";
    if ($title) {
      print "<A HREF=\"$url\">$title</A>: ";
      print STDERR "  $title... ";
    } else {
      print "<B><A HREF=\"$url\">redirect</A>:</B> ";
      print STDERR "  (redirect)... ";
    }
    print "</TD><TD ALIGN=LEFT VALIGN=TOP BGCOLOR=\"$bgc\">";

    if (m@^http://@) {
        my $status = check_http_status_with_timeout ($url, $http_timeout);

        # If the original URL had more than one path component;
        # and the final URL does not; then chances are, someone has
        # redirected us somewhere stupid (like, a root page.)
        #
        if ($orig_url =~ m@^http://.+/.+@ &&
            ! ($url   =~ m@^http://.+/.+@)) {
          $status = "Redirected somewhere dumb?";
        }

        # If we got redirected to a page that has "error" in its name,
        # then assume that the dumbass webmaster doesn't know what 30x
        # error codes are for.
        #
        if ($url =~ m@404|error|not[^a-z]*found|domain@i) {
          $status = "Dead (probably)";
        }

        if ($status ne $ok_string) {
            print "<B>$status</B>";
        } else {
            print $status;
        }

        if ($status =~ m/unknown/i) {
            print STDERR $status;
        }

        if ($status =~ m@HREF=\"([^\"]+)\"@) {
          $next_url = $1;
        }

    } elsif (m@^mailto:@) {
        print $ok_string;

    } elsif (m@^file:(.*)@) {
        $_ = $1;
        s/\#.*$//;   #  strip off anchors
        s/\?.*$//;   #  strip off CGI args
        if (-r $_) {
            print $ok_string;
          } elsif ( m@/latest\.html$@ ) {
            # dnalounge.com hack: don't whine for files called "latest.html"
            print "<I>$ok_string</I>";
        } else {
            print "<B>File does not exist</B>";
        }
    } else {
        m/^([a-zA-Z]+)/;
        print "Skipping $1 URL.";
    }

    print STDERR "\n";
    print "</TD></TR>\n";

    if (++$tick == 3) {
        $tick = 0;
        if ($bgc eq $bgca) { $bgc = $bgcb; }
        else { $bgc = $bgca; }

        if (++$tick2 == 30) {
            $tick2 = 0;
            print $table_end;
            print $table_start;
        }
    }
    return $next_url;
}

my $count = 0;
sub read_file {
    my ($file) = @_;
    my $body = "";
    my $base = "file:$file";

    $base =~ s@[^/]*$@@;

    if (open (IN, "<$file")) {
        while (<IN>) {
            $body .= $_;
        }
        close (IN);

        # nuke comments
        $_ = $body;
        1 while (s@<!--.*?-->@ @s);
        $body = $_;

        # compact all whitespace
        $body =~ s/[ \t\n]+/ /go;

        # Convert IMG tags to A tags, for simplicity...
        $body =~ s@(<A\b[^<>]*>)(<IMG\b)@$1\[IMAGE\]</A>$2@gsi;
        $body =~ s@<IMG\b([^<>]*)\bSRC=([^<>]*>)@<A$1HREF=$2\[IMAGE\]</A>@gsi;
        $body =~ s@<EMBED\b([^<>]*)\bSRC=([^<>]*>)@<A$1HREF=$2\[EMBED\]</A>@gsi;
        $body =~ s@</(IMG|EMBED)\b@</A@gsi;
        $body =~ s@(</?)LINK\b@$1A@gsi;

        # put a newline before each <A> and after each </A>
        $body =~ s@(<A\b)@\n$1@goi;
        $body =~ s@(</A>)@$1\n@goi;

        $body .= "\n";

        foreach (split(/\n/, $body)) {
            if (m@<A\b[^<>]*\bHREF=\"([^\"]+)\"[^<>]*>(.*?)</A>@i ||
                m@<A\b[^<>]*\bHREF=([^\"<>\s]+)[^\"<>]*>(.*?)</A>@i
               ) {
                my $url = $1;
                my $title = $2;

                $_ = $url;
                if (! m@[a-zA-Z]+:@) {
                    $url = "$base$url";
                    while ($url =~ s@[^/]+/[.][.]/@@) { }
                    while ($url =~ s@/[.]/@/@) { }
                }

                $url  =~ s/#.*$//;
                $url   =~ s/[\r\n ]+$//g;
                $url   =~ s/^[\r\n ]+//g;
                $title =~ s/[\r\n ]+$//g;
                $title =~ s/^[\r\n ]+//g;
                $title =~ s/[&][lg]t;//g;
                $title =~ s/<IMG[^>]*>/[ image ]/;
                $title =~ s/<[^>]+>//g;

                my $redir_count = 0;
                my $orig_url = $url;
                while ($url) {
                  $url = check_url($url, $title, $orig_url);
                  $title = undef;
                  $count++;
                  $url = undef if (++$redir_count > 8);
                }

            } elsif (m@http://@) {
                print STDERR "$progname: missed: $_\n";
            }
        }
    }
}


sub usage {
  print STDERR "usage: $progname [ files ... ]\n";
  exit 1;
}

sub main {

  $http_proxy = $ENV{http_proxy} || $ENV{HTTP_PROXY};

  my @files = ();

  while ($_ = $ARGV[0]) {
    shift @ARGV;
    if (m/^-./) { usage; }
    else { push @files, $_; }
  }

  usage() if ($#files == -1);

  print $head;

  foreach (@files) {
    my $file = $_;
    print STDERR "\nChecking $file...\n";
    if (! m@^/@) {
      $file = getcwd . "/" . $file;
    }
    print "<P><HR><P><A HREF=\"file:$file\"><B>$file</B></A><P>\n";
    print $table_start;
    read_file($file);
    print $table_end;
  }
  print $tail;
}

main;
exit (0);
