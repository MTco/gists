#!/usr/bin/perl -w
# Copyright © 2007-2016 Jamie Zawinski <jwz@jwz.org>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or 
# implied warranty.
#
# Given an RSS file, creates a Podcast XML file from it, inlining any
# movies or MP3 files that it finds in the content of the original feed.
#
# Created: 23-Jul-2007.

require 5;
use diagnostics;
use strict;
use LWP::Simple;
use Date::Parse;
use POSIX;

use open ":encoding(utf8)";

my $progname = $0; $progname =~ s@.*/@@g;
my ($version) = ('$Revision: 1.41 $' =~ m/\s(\d[.\d]+)\s/s);

my $verbose = 0;
my $self_url_base = 'https://www.jwz.org/cheesegrater/';


# Returns true if the two files differ (by running "cmp")
#
sub cmp_files($$) {
  my ($file1, $file2) = @_;

  my @cmd = ("cmp", "-s", "$file1", "$file2");
  print "$progname: executing \"" . join(" ", @cmd) . "\"\n" if ($verbose > 2);

  system (@cmd);
  my $exit_value  = $? >> 8;
  my $signal_num  = $? & 127;
  my $dumped_core = $? & 128;

  error ("$cmd[0]: core dumped!") if ($dumped_core);
  error ("$cmd[0]: signal $signal_num!") if ($signal_num);
  return $exit_value;
}


# If the two files differ:
#   mv file2 file1
# else
#   rm file2
#
sub rename_or_delete($$) {
  my ($file, $file_tmp) = @_;

  my $changed_p = cmp_files ($file, $file_tmp);

  if ($changed_p) {

    if (!rename ("$file_tmp", "$file")) {
      unlink "$file_tmp";
      error ("mv $file_tmp $file: $!");
    }
    print STDERR "$progname: wrote $file\n" if ($verbose);

  } else {
    unlink "$file_tmp" || error ("rm $file_tmp: $!\n");
    print STDERR "$progname: $file unchanged\n" if ($verbose > 1);
    print STDERR "$progname: rm $file_tmp\n" if ($verbose > 2);
  }
}


# Write the given body to the file, but don't alter the file's
# date if the new content is the same as the existing content.
#
sub write_file_if_changed($$) {
  my ($outfile, $body) = @_;

  my $file_tmp = "$outfile.tmp";
  open (my $out, '>', $file_tmp) || error ("$file_tmp: $!");
  print $out $body || error ("$file_tmp: $!");
  close $out || error ("$file_tmp: $!");

  rename_or_delete ("$outfile", "$file_tmp");
}


sub url_quote($) {
  my ($u) = @_;
  $u =~ s|([^-a-zA-Z0-9.\@/_\r\n])|sprintf("%%%02X", ord($1))|ge;
  return $u;
}

sub html_quote($) {
  my ($u) = @_;
  $u =~ s/&/&amp;/g;
  $u =~ s/</&lt;/g;
  $u =~ s/>/&gt;/g;
  $u =~ s/\"/&quot;/g;
  return $u;
}

# Convert any HTML entities to Unicode characters.
#
sub html_unquote($) {
  my ($s) = @_;
  return HTML::Entities::decode_entities ($s);
}


sub cheesecast($$) {
  my ($rss_url, $outfile) = @_;

  my @st = stat($outfile);
  my $age = time() - ($st[9] || 0);

  $LWP::Simple::ua->agent("$progname/$version");
  $LWP::Simple::ua->timeout(20);
  my $rss = LWP::Simple::get ($rss_url) || '';

  $rss = imvdb_convert($rss_url, $rss)
    if ($rss_url =~ m@imvdb\.com@si);

  # Silently fail if the URL has been unloadable for a short time.
  #
  if (! ($rss =~ m/^\s*<\?xml/s)) {
    my $err = ($rss =~ m/^\s*$/s ? "empty" : "not RSS");
    my $after = int ($age / 60 / 60);
    $after = ($after < 72 ? "$after hours" : int ($after / 24 + .5) . " days");
    if ($age > 60 * 60 * 16) {
      # Touch the file to quiet the warning for another N hours.
#      open (my $o, '>>', $outfile) || error ("$outfile: $!");
#      print $o "";
#      close $o;
      system ("touch '$outfile'");
      error ("$rss_url: $err (after $after)");
    }
    print STDERR "$progname: $rss_url: $err (recent)\n" if ($verbose);
    exit (0);
  }

  $rss =~ s/[\r\n]/ /gsi;
  $rss =~ s/(<(entry|item)\b)/\n$1/gsi;
  my @items = split("\n", $rss);
  shift @items;

  my @new_items = ();

  error ("$rss_url: no items!") unless @items;

  foreach my $item (@items) {

    $_ = $item;
    my ($title) = m@<title\b[^<>]*>([^>]*)@s;
    $title = 'untitled' unless $title;
    my ($author) = m@<author\b[^<>]*>\s*<name\b[^<>]*>([^<>]*)@s;
       ($author) = m@<itunes:author\b[^<>]*>([^<>]*)@s unless $author;
       ($author) = m@<dc:creator\b[^<>]*>([^<>]*)@s unless $author;
       ($author) = m@<author\b[^<>]*>\s*([^<>]*)@s unless $author;
       $author = 'unknown' unless $author;

#    my $subtitle = '';
#    my $summary = '';
    my ($date) = m@<published\b[^<>]*>([^<>]*)@s;
       ($date) = m@<pubDate\b[^<>]*>([^<>]*)@s unless ($date);
       $date = '' unless ($date);
#    my $keywords = ''; #### <category .. term='xx'>
    my ($html) = m@<content\b[^<>]*>\s*(.*?)</content@s;
       ($html) = m@<summary\b[^<>]*>\s*(.*?)</summary@s unless ($html);
       ($html) = m@<description\b[^<>]*>\s*(.*?)</description@s unless ($html);

    $title =~ s@<!\[CDATA\[\s*(.*?)\s*\]*>*\s*(</title>\s*)?$@$1@gs;
    $title =~ s@</title.*$@@s; # wtf

    if (! defined($html)) {
      print STDERR "$progname: $rss_url: no body for \"$title\"\n"
        if ($verbose);
      next;
    }

    $html =~ s@<!\[CDATA\[\s*(.*)\s*\]\]>@$1@gs;
    $html =~ s@&lt;@<@gs;
    $html =~ s@&gt;@>@gs;
    $html =~ s@&amp;@&@gs;

    my @urls = ();
    $html =~ s!\b(https?:[^\'\"\s<>]+)!{push @urls, $1; $1;}!gxse;

    print STDERR "$progname: $title: " . ($#urls+1) . " urls\n"
      if ($verbose > 1);

    my ($vid_mov, $vid_wmv, $vid_flv, $vid_fla, $vid_mp3, $vid_m4a, $vid_m4v);
    foreach my $url (@urls) {
      $url =~ s@&quot;$@@s; # wtf
      print STDERR "$progname:   url: $url\n" if ($verbose > 2);

      $url =~ s@^(https?://([^/.]+\.)?youtube\.com/)embed/@$1v/@si;

      if    ($url =~ m@\.(mov|mp4)$@) { $vid_mov = $url; }
      elsif ($url =~ m@\.(wm[va])$@)  { $vid_wmv = $url; }
      elsif ($url =~ m@\.(flv)$@)     { $vid_flv = $url; }
      elsif ($url =~ m@\.(mp3)$@)     { $vid_mp3 = $url; }
      elsif ($url =~ m@\.(m4a)$@)     { $vid_m4a = $url; }
      elsif ($url =~ m@\.(m4v)$@)     { $vid_m4v = $url; }
      elsif ($url =~ m@youtube\.com/get_video@) { 
        my ($id) = ($url =~ m@id=([^<>?&;\"\']+)@si);
        $vid_fla = "http://www.youtube.com/v/$id";
      }
      elsif ($url =~ m@^https?:// (?:[a-z]+\.)? youtube \.com/
			(?: (?: watch )? (?: \? | \#! ) v= | v/ )
			([^<>?&,'"]+) ($|[?&]) @sx) {
        # Youtube /watch?v= or /watch#!v= or /v/ URLs. 
        $vid_fla = "http://www.youtube.com/v/$1";
      }
      elsif ($url =~ m@^https?://(?:[a-z]+\.)?vimeo\.com/(\d+)@s) {
        # Vimeo /NNNNNN URLs.
        $vid_fla = "http://www.vimeo.com/$1";
      }
      elsif ($url =~ m@^https?://(?:[a-z]+\.)?vimeo\.com/.*/?videos?/(\d+)@s) {
        # Vimeo /videos/NNNNNN URLs.
        $vid_fla = "http://www.vimeo.com/$1";
      }
      elsif ($url =~ m@^https?://(?:[a-z]+\.)?vimeo\.com/moogaloop .*
                       (?: clip_id = | clip: ) (\d+)@sx) {
        # Vimeo /moogaloop/load/clip:NNNNNN URLs.
        $vid_fla = "http://www.vimeo.com/$1";
      }
      elsif ($url =~ m@^https?://(?:[a-z]+\.)?(vimeo|youtube)\.com/@s) {
#       error ("$rss_url: missed $1: $url");
#       print STDERR "$progname: WARNING: $rss_url missed $1: $url\n";
      }
    }

    $html =~ s@<P\b[^<>]*>@\n\n@gsi;
    $html =~ s@<BR\b[\s/]*>@\n@gsi;
    $html =~ s@<[^<>]*>@ @gsi;

    my $summary = html_quote ($html);

    my ($duration) = ($html =~ m@Duration:\s+([\d:]+)@si);
    $duration = 0 unless defined ($duration);
    my $length = 0;

    my ($vid, $mp3);
    if    ($vid_mov) { $vid = [ $vid_mov, 'video/quicktime' ]; }
    elsif ($vid_wmv) { $vid = [ $vid_wmv, 'video/x-ms-wmv'  ]; }
    elsif ($vid_fla) { $vid = [ $vid_fla, 'application/x-shockwave-flash' ]; }
    elsif ($vid_flv) { $vid = [ $vid_flv, 'video/flv'       ]; }
    elsif ($vid_m4v) { $vid = [ $vid_m4v, 'video/m4v'       ]; }

# Eh, not interested in audio files.
#    if    ($vid_mp3) { $mp3 = [ $vid_mp3, 'audio/mpeg'      ]; }
#    elsif ($vid_m4a) { $mp3 = [ $vid_m4a, 'audio/mpeg'      ]; }

    print STDERR "$progname: no usable URLs!\n"
      if ($verbose > 1 && !($vid || $mp3));

    foreach my $pair ($vid, $mp3) {
      next unless $pair;
      my ($url, $ct) = @$pair;
      print STDERR "$progname: using: $url\n" if ($verbose > 1);
      $url =~ s/&/&amp;/g;
      my $url2 = $url;
      $url2 =~ s@(youtube\.com)/v/@$1/watch?v=@si;

      push @new_items,
        join ("\n ",
              "<item>",
              "<title>$title</title>",
              "<itunes:author>$author</itunes:author>",
#             "<itunes:subtitle>$subtitle</itunes:subtitle>",
              "<itunes:summary>($ct) $summary</itunes:summary>",
              "<itunes:explicit>no</itunes:explicit>",
              "<enclosure url=\"$url\" length=\"$length\" type=\"$ct\" />",
              "<guid isPermaLink=\"true\">$url2</guid>",
              "<pubDate>$date</pubDate>",
              "<itunes:duration>$duration</itunes:duration>",
#             "<itunes:keywords>$keywords</itunes:keywords>",
              "</item>");
    }
  }

  $_ = $rss;
  s/<(entry|item)\b.*$//gs;
  my ($channel_title) = m@<title\b[^<>]*>([^<>]*)@s;
  my ($base_url) = 
    m@<link\b[^<>]*text/html\b[^<>]*href=['\"]([^<>'\"]+)['\"]@s;
  ($base_url) = m@<link\b[^<>]*>([^<>]*)@s unless $base_url;
#  my $copyright = '';
#  my $channel_subtitle = '';
  my ($channel_author) = m@<author\b[^<>]*>\s*<name\b[^<>]*>([^<>]*)@s || '';
#  my $channel_summary = '';
  my $channel_desc = $channel_title;
  my $channel_owner = $channel_author;
  my $channel_email = 'unknown@example.com';
#  my $channel_logo = '';
  my $channel_cat = 'Music';

  my $self = $self_url_base . $outfile;

  my $output = 
    join ("\n",
          ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
           "<rss" .
           " xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"" .
           " xmlns:atom=\"http://www.w3.org/2005/Atom\"" .
           " version=\"2.0\">",
           "<channel>",
           "<title>$channel_title</title>",
           "<link>$base_url</link>",
           "<language>en-us</language>",
#           "<copyright>$copyright</copyright>",
#           "<itunes:subtitle>$channel_subtitle</itunes:subtitle>",
           "<itunes:author>$channel_author</itunes:author>",
           "<itunes:explicit>no</itunes:explicit>",
#           "<itunes:summary>$channel_summary</itunes:summary>",
           "<description>$channel_desc</description>",
           "<itunes:owner>",
           "<itunes:name>$channel_owner</itunes:name>",
           "<itunes:email>$channel_email</itunes:email>",
           "</itunes:owner>",
#           "<itunes:image href=\"$channel_logo\" />",
           "<itunes:category text=\"$channel_cat\">",
           "</itunes:category>",
           "<atom:link href=\"$self\"\n" .
           " rel=\"self\" type=\"application/rss+xml\" />\n" .

           join ("\n", @new_items),
           "</channel>",
           "</rss>",
           ""));

  write_file_if_changed ($outfile, $output);
}


# Blaaahhhhh, maybe this should be its own script instead.
#
sub imvdb_convert($$) {
  my ($url, $body) = @_;
  my ($base) = ($url =~ m@^(https?://[^/]+/)@si);

  my $title;
  {
    my $retries = 5;
    do {
      ($title) = ($body =~ m@<title[^<>]*>(.*?)<@si);
      last if $title;
      sleep (2);
      print STDERR "$progname: reloading $url\n" if ($verbose);
      $body = LWP::Simple::get ($url) || '';
    } while (--$retries > 0);
  }

  return '' unless $body;

  error ("no title: $url") unless $title;
  $title = html_quote($title);

  my @pages = ();
  $body =~ s%href="(.*?)"%{
    push @pages, $1;
  }%gsexi;

  $body = ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" .
           "<rss version=\"2.0\">\n" .
           " <channel>\n" .
           "  <link>$url</link>\n" .
           "  <title>$title</title>\n" .
           "");
  my %dups;
  my $max = 50;
  my $count = 0;
  foreach my $page (@pages) {
    $page =~ s@^/@$base@si;
    next unless ($page =~ m@imvdb.com/video/@);
    next if ($dups{$page});
    $dups{$page} = 1;

    my $retries = 5;
    my ($body2, $title2, $url2, $date);

    while (--$retries > 0) {

      print STDERR "$progname: loading $page\n" if ($verbose);
      $body2 = LWP::Simple::get ($page) || '';

      ($title2) = ($body2 =~ m@<meta property="og:title" content="(.*?)"@si);
      ($url2)   = ($body2 =~ m@<link rel="video_src" href="(.*?)"@si);
      ($date)   = ($body2 =~ m@<meta property="og:video:release_date" content="(.*?)">@si);

      last if $url2;
      sleep (2);
    }

    next unless $body2;
    error ("no body: $page") unless $body2;
    error ("no title: $page") unless $title2;
    next unless $url2;  # Eh, skip it
    error ("no video_src: $page") unless $url2;

    $url2 = html_unquote($url2);

    $title2 =~ s@ \| .*?$@@s;

    # Convert ISO8601 date to RFC822 date
    $date = str2time ($date);
    $date = strftime ("%a, %d %b %Y %H:%M:%S %Z", localtime ($date));

    $title2 = html_quote($title2);
    $url2   = html_quote($url2);
    $date   = html_quote($date);

    $body .= ("  <item>\n" .
              "   <title>$title2</title>\n" .
              "   <summary>$url2</summary>\n" .
              "   <guid isPermaLink=\"true\">$url2</guid>\n" .
              "   <pubDate>$date</pubDate>" .
              "  </item>\n");

    last if (++$count >= $max);
  }

  error ("no videos: $url") unless $count;

  $body .= (" </channel>\n" .
            "</rss>\n");
  return $body;
}


sub error($) {
  my ($err) = @_;
  print STDERR "$progname: $err\n";
  exit 1;
}

sub usage() {
  print STDERR "usage: $progname [--verbose] url outfile\n";
  exit 1;
}

sub main() {
  my ($in, $out);
  while ($#ARGV >= 0) {
    $_ = shift @ARGV;
    if ($_ eq "--verbose") { $verbose++; }
    elsif (m/^-v+$/) { $verbose += length($_)-1; }
    elsif (m/^-./) { usage; }
    elsif (! defined($in))  { $in  = $_; }
    elsif (! defined($out)) { $out = $_; }
    else { usage; }
  }
  cheesecast ($in, $out);
}

main();
exit 0;
