#!/usr/bin/perl -w
# Copyright © 2002-2013 Jamie Zawinski <jwz@jwz.org>
# Constructs a web page out of a set of RSS files.
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or 
# implied warranty.
#
# Created: 21-Nov-2002.

require 5;
use diagnostics;
use strict;
use POSIX;
use HTML::Entities;

use open ":encoding(utf8)";

my $progname = $0; $progname =~ s@.*/@@g;
my $version = q{ $Revision: 1.42 $ }; $version =~ s/^[^0-9]+([0-9.]+).*$/$1/;

my $verbose = 0;

my $max_rss_file_entries = 500;
my $max_total_entries = 8000;


my $html_title = "jwz portal";
my $html_header = ("<HEAD>\n" .
                   "<TITLE>$html_title</TITLE>\n" .
                   "<META CHARSET=\"utf-8\">\n" .
                   "<STYLE TYPE=\"text/css\">\n" .
                   "<!--\n" .
                   " body { margin-left: 4em; }\n" .
                   "  .entry {\n" .
                   "     overflow: auto; max-height: 25em;\n" .
                   "  }\n" .
                   "  .entry_table {\n" .
                   "     color:      #000;\n" .
                   "     background: #FFF;\n" .
                   "     border: 2px outset;\n" .
                   "     width: 100%;\n" .
                   "  }\n" .
                   "  .entry_title {\n" .
                   "     color:      #000;\n" .
                   "     background: #CCC;\n" .
                   "     border: 2px inset;\n" .
                   "     padding: 8px;\n" .
                   "  }\n" .
                   "  .entry_date {\n" .
                   "     float:      right;\n" .
                   "     text-align: right;\n" .
                   "     font-style: italic;\n" .
                   "     font-size:  x-small;\n" .
                   "     width: 12em;\n" .
                   "  }\n" .
                   "  .entry_author {\n" .
                   "     font-weight: bold;\n" .
                   "     display: block;\n" .
                   "     float: left;\n" .
                   "     width: 10em;\n" .
                   "     height: 3em;\n" .
                   "     overflow:hidden;\n" .
                   "  }\n" .
                   "  .entry_body {\n" .
                   "     padding: 0.5em 1em 0.5em 3em;\n" .
                   "  }\n" .
                   "  .entry_source {\n" .
                   "     display:    block;\n" .
                   "     float:      right;\n" .
                   "     text-align: right;\n" .
                   "     font-style: italic;\n" .
                   "     font-size:  x-small;\n" .
                   "     padding-left: 8px;\n" .
                   "     float:      right;\n" .
                   "     width:      8em;\n" .
                   "     overflow:hidden;\n" .
                   "  }\n" .
                   "  H1 {\n" .
                   "     color: #FFF;\n" .
                   "     text-align: center;\n" .
                   "     font-size: large;\n" .
                   "  }\n" .
                   "-->\n" .
                   "</STYLE>\n" .
                   "\n" .
                   "</HEAD>\n" .
                   "<BODY BGCOLOR=\"#000000\">\n" .
                   "<H1>$html_title</H1>\n"
                   );


# Convert any HTML entities to Unicode characters.
#
sub html_unquote($) {
  my ($s) = @_;
  $s =~ s@<!\[CDATA\[(.*?)\]\]>@$1@s;
  return HTML::Entities::decode_entities ($s);
}

sub url_unquote($) {
  my ($s) = @_;
  $s =~ s/[+]/ /g;
  $s =~ s/%([a-z0-9]{2})/chr(hex($1))/ige;
  return $s;
}


# Read the HTML file, if it exists, and return a list of the entries in it.
# See also, rss_to_html, which is the generator for the thing we're parsing.
#
sub parse_portal_html($) {
  my ($html_file) = @_;
  return () unless (-f $html_file);
  open (my $in, '<', $html_file) || error ("$html_file: $!");
  my $body = '';
  while (<$in>) { $body .= $_; }
  close $in;

  $body =~ s@^.*?(<DIV\b[^<>]*\bCLASS=\"entry\"[^<>]*>)@$1@is; # strip head
  $body =~ s@\s*<DIV\b[^<>]*\bCLASS=\"footer\"[^<>]*>.*$@@is;  # strip tail

  $body =~ s@(<DIV\b[^<>]*\bCLASS=\"entry\"[^<>]*>)@\001\001\001$1@gsi;
  my @hentries = split (/\001\001\001/, $body);

  my @hentries2 = ();      # this crud is to strip out empty entries
  foreach (@hentries) {
    next if (m/^$/);
    push @hentries2, $_;
    if ($verbose > 5) {
      my $e = "$_";
      $e =~ s/\n/\\n/gs;
      print STDERR "$progname: parsed HTML entry: $e\n";
    }
  }

  print STDERR "$progname: $html_file: " . ($#hentries2+1) . " items\n"
    if ($verbose > 1);

  return @hentries2;
}


# Strip link-tracking BS.
#
sub clean_urls($) {
  my ($txt) = @_;
  $txt =~ s@\b http://[^\s<>\"\']+?    [;&] url=
              (http://[^\s<>\"\';&]+)  [^\s<>\"\']*
           @{ url_unquote($1) }@gsexi;
  return $txt;
}


# Parses an RSS file and returns a list of RSS-item objects.
#
sub parse_rss($) {
  my ($file) = @_;
  open (my $in, '<', $file) || error ("$file: $!");
  print STDERR "$progname: reading $file...\n" if ($verbose > 1);
  my $body = '';
  while (<$in>) { $body .= $_; }
  close $in;


  if ($body =~ m/^\s*$/gs) {
    print STDERR "$progname: $file is empty: skipping.\n";
    return ();
  }

  if ($body =~ m/^\s*(<!DOCTYPE|<HTML|<HEAD)/gs) {
    print STDERR "$progname: $file is HTML, not RSS! skipping.\n";
    return ();
  }

  if (! ($body =~ s@^(.*?)(<(ITEMS?|ENTRY)>)@$2@is)) { # strip (and save) head
    print STDERR "$progname: $file: no items\n";
    return ();
  }

  my $head = $1;
  #$body =~ s@\s*</CHANNEL>.*$@@is;    # strip tail

  $body =~ s@(<(ITEM|ENTRY))@\001\001\001$1@gsi;

  $_ = $head;
  m@<TITLE>(.*?)</TITLE>@is || error ("$file: unparsable channel title");
  my $chan_title = $1;
  my $chan_url = undef;
  if (m@<LINK>(.*?)</LINK>@is) { $chan_url = $1; }
  if (m@<LINK[^<>]*?\bHREF=\"([^\"<>]+)\"@is) { $chan_url = $1; }

  if (m@<IMAGE>(.*?)</IMAGE>@is) {
    $_ = $1;
    my ($url) = m@<URL>(.*?)</URL>@is;
    my ($w) = m@<WIDTH>(.*?)</WIDTH>@is;
    my ($h) = m@<HEIGHT>(.*?)</HEIGHT>@is;
    if ($url) {
      $url = "<IMG SRC=\"$url\"";
      $url .= " WIDTH=\"$w\"" if ($w);
      $url .= " HEIGHT=\"$h\"" if ($h);
      $url .= ">";
      $chan_title = "$url<BR>$chan_title";
    }
  }

  my @items = ();
  foreach my $item (split (/\001\001\001/, $body)) {
    $_ = $item;
    next if (m/^$/);
	  next if (m/<TEXTINPUT.+\/>/is);
		next if (m/<IMAGE.+\/>/is);
		next if (m/<ITEMS/is);
#   m@<TITLE>(.*?)</TITLE[^<>]*>@is || error ("$file: unparsable item (title)");

    my ($title) = m@<TITLE[^<>]*>(.*?)</TITLE>@is;
    $title = '???' unless defined ($title);

    my ($date)   = m@<PUBDATE>(.*?)</PUBDATE>@is;
    my ($author) = m@<AUTHOR>(.*?)</AUTHOR>@is;
    ($author) = m@<dc:creator>(.*?)</dc:creator>@is unless $author;
    $author = '' unless defined ($author);

    m@<(LINK|GUID\b[^<>]*)>(.*?)</(LINK|GUID)>@is ||
    m@<(LINK[^<>]*?)\bHREF=\"([^\"<>]+)\"@is ||
      error ("$file: unparsable item url: $title");
    my $url = $2;
    my $desc = '';
    if (m@<(content(:encoded)?)\b[^<>]*>(.*?)</\1>@is) {
      $desc = $3;
    } elsif (m@<(DESCRIPTION)\b[^<>]*>(.*?)</\1>@is) {
      $desc = $2;
    }

    $desc  = html_unquote ($desc);
    $title = html_unquote ($title);

    $url   = clean_urls ($url);
    $desc  = clean_urls ($desc);
    $title = clean_urls ($title);

    my $itemref = { 'title'  => $title,
                    'author' => $author,
                    'date'   => $date,
                    'ctitle' => $chan_title,
                    'curl'   => $chan_url,
                    'url'    => $url,
                    'body'   => $desc,
                  };
    print STDERR "$progname: $file: parse: " . ($title || $url) . "\n"
      if ($verbose > 3);

    push @items, $itemref;
  }

  print STDERR "$progname: $file: " . ($#items+1) . " items\n"
    if ($verbose > 1);

  return @items;
}


# For comparison purposes, strip all tags and non-alphabetics; downcase.
sub comparison_string($) {
  my ($str) = @_;
  $str =~ s@<!--.*?-->@@gsi;
  $str =~ s@<[^<>]*>@@gsi;
  $str =~ s@[^a-z]@@gsi;
  $str = lc($str);
  return $str;
}

# returns true if the given RSS entry is present in the list of HTML entries.
#
sub entry_present($@) {
  my ($rss_entry, @html_entries) = @_;
  my $rss_url   = $rss_entry->{'url'} || '';
  my $rss_body  = $rss_entry->{'body'};
  my $rss_title = $rss_entry->{'title'};
  error ("no url in rss entry: " . $rss_title) unless ($rss_url);

  $rss_body  = comparison_string($rss_body);
  $rss_title = comparison_string($rss_title);

  $rss_body = $rss_title unless $rss_body;  # empty body

  foreach (@html_entries) {
    my ($body) = m@<DIV\b[^<>]*\bCLASS=\"rss_body\"[^<>]*>(.*?)</DIV>@s;
    my ($url)  = m@<A\b[^<>]*\bCLASS=\"entry_url\"[^<>]*HREF=\"([^\"<>]*)\">@i;

    if (! $url) {
      s/\n/\\n/g;
#      s/^(.{100}).*$/$1/s;
      error ("no url in html entry: $_");
    }

    $body  = comparison_string($body);

    my $url_p = ($url eq $rss_url);
    my $body_p = ($body eq $rss_body);

    if ($url_p && $body_p) {
      print STDERR "$progname: URL+body present: $url\n"
        if ($verbose > 3);
      # both match - this is a dup.
      return 1;

    } elsif ($body_p) {
      print STDERR "$progname: body present but URL different: $url\n"
        if ($verbose > 3);
      # URL changed, but body is the same - this is a dup.
      return 1;

    } elsif ($url_p) {
      print STDERR "$progname: URL present but body different: $url\n"
        if ($verbose > 3);
      # URL is a dup, but body changed - this is probably a dup.
      return 1;
    }
  }

  print STDERR "$progname: new entry: " .
    ($rss_entry->{'title'} || $rss_entry->{'url'}) . "\n"
    if ($verbose > 4);

  return 0;
}

# Write the HTML entries to the file.
#
sub write_html($$@) {
  my ($file, $new_count, @hentries) = @_;

  my $body = '';
  my $count = 0;

  my $head = $html_header;
  my $date = strftime ("<BR> %a, %e %b %l:%M%p", localtime);
  $head =~ s@(<H1\b[^<>]*>)(.*?)(</H1[^<>]*>)@$1$2$date$3@;

  $body .= "$head\n";
  foreach my $hentry (@hentries) {
    $body .= "$hentry\n";
    $count++;
  }

  $body =~ s/(\n\n)\n+/$1/gs;

  open (my $out, '>', $file) || error ("$file: $!");
  print $out $body;
  close $out || error ("$file: $!");
  print STDERR "$progname: wrote $file ($count entries, $new_count new)\n"
    if ($verbose);
}


# Converts an RSS entry object to an HTML string.
# Note that parse_portal_html parses this text.
#
sub rss_to_html($) {
  my ($entry) = @_;
  my $title  = $entry->{'title'};
  my $ctitle = $entry->{'ctitle'};
  my $url    = $entry->{'url'};
  my $curl   = $entry->{'curl'};
  my $body   = $entry->{'body'};
  my $author = $entry->{'author'};
  my $date   = $entry->{'date'};

  $date = strftime ("%a, %e %b %l:%M%p", localtime)
    unless $date;
  $date =~ s/\s+(\d\d?:\d\d)/<BR>$1/s;
  $date =~ s/\s+\d{4}\b//s;
  $date =~ s/\b(\d\d?:\d\d):\d\d\b/$1/s;

  $title  = "<A CLASS=\"entry_url\" HREF=\"$url\">$title</A>"     if ($url);
  $ctitle = "<A CLASS=\"channel_url\" HREF=\"$curl\">$ctitle</A>" if ($curl);

  $author .= ": " if $author;
  $body = ("<DIV CLASS=\"entry\">\n" .
           " <TABLE CLASS=\"entry_table\">\n" .
           "  <TR><TD CLASS=\"entry_title\">" .
                 "<SPAN CLASS=\"entry_source\">$ctitle</SPAN>" .
                 "<SPAN CLASS=\"entry_date\">$date</SPAN>" .
                 "<SPAN CLASS=\"entry_author\">$author</SPAN>" .
                 "$title" .
           "</TD></TR>\n" .
           "  <TR><TD CLASS=\"entry_body\">" .
               "<DIV CLASS=\"rss_body\">$body</DIV></TD></TR>\n" .
           " </TABLE>\n" .
           "</DIV>\n" .
           "<P>\n\n");
  return $body;
}


# Read each of the RSS input files, and update the output html file.
# If an entry is already present in the HTML file, it is not added again.
# New entries are added at the top.
#
sub portalize($@) {
  my ($outfile, @infiles) = @_;

  print STDERR "$progname: reading $outfile...\n" if ($verbose > 1);
  my @old_entries = parse_portal_html ($outfile);
  my @new_entries = ();
  my $changed_p = 0;

  foreach my $file (@infiles) {
    my @rss_entries = parse_rss ($file);

    if ($#rss_entries > $max_rss_file_entries) {
      print STDERR "$progname: $file: $#rss_entries entries; ".
        "truncating to $max_rss_file_entries.\n"
          if ($verbose > 2);
      @rss_entries = @rss_entries[0 .. $max_rss_file_entries-1];
    }

    foreach my $entry (@rss_entries) {
      if (entry_present ($entry, @old_entries)) {
        print STDERR "$progname: $file: skipping: " .
          ($entry->{'title'} || $entry->{'url'}) . "\n"
          if ($verbose > 3);
      } else {
        print STDERR "$progname: $file: adding: " .
          ($entry->{'title'} || $entry->{'url'}) . "\n"
          if ($verbose > 1);
        push @new_entries, rss_to_html ($entry);
        $changed_p++;
      }
    }

  }

  if ($#old_entries + $#new_entries + 1 > $max_total_entries) {
    my $n = ($max_total_entries - $#new_entries - 2);
    $n = 0 if ($n < 0);
    print STDERR "$progname: $outfile: " .
      ($#old_entries + $#new_entries + 1) . " total entries; ".
        "truncating to $n old entries.\n"
          if ($verbose > 2);
    @old_entries = @old_entries[0 .. $n];

    if ($#old_entries + $#new_entries + 1 > $max_total_entries) {
      print STDERR "$progname: $outfile: truncating to $n new entries.\n"
        if ($verbose > 2);
      @new_entries = @new_entries[0 .. $max_total_entries-1];
    }
  }

  if ($changed_p) {
    write_html ($outfile, $#new_entries+1, (@new_entries, @old_entries));
  } else {
    print STDERR "$progname: $outfile unchanged\n" if ($verbose);
  }
}


sub error($) {
  my ($e) = @_;
  print STDERR "$progname: $e\n";
  exit 1;
}

sub usage() {
  print STDERR "usage: $progname [--verbose] output.html [ input.rss ... ]\n";
  exit 1;
}

sub main() {
  my @infiles = ();
  my $outfile = undef;
  while ($_ = $ARGV[0]) {
    shift @ARGV;
    if ($_ eq "--verbose") { $verbose++; }
    elsif (m/^-v+$/) { $verbose += length($_)-1; }
    elsif (m/^-./) { usage; }
    elsif (!defined ($outfile)) { $outfile = $_; }
    else { push @infiles, $_; }
  }
  usage unless ($#infiles >= 0);
  portalize ($outfile, @infiles);
}

main;
exit 0;
