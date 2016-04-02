#!/usr/bin/perl -w
# cheesegrater -- scrapes HTML from web sites into RSS feeds.
# Copyright © 2002-2015 Jamie Zawinski <jwz@jwz.org>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or 
# implied warranty.
#
# Created: 20-Nov-2002.

require 5;
#use diagnostics;   # this screws up error messages when using eval/die.
use strict;
use POSIX;
use Date::Parse;
use HTML::Entities;
use LWP::Simple;

use open ":encoding(utf8)";

my $progname = $0; $progname =~ s@.*/@@g;
my ($version) = ('$Revision: 1.153 $' =~ m/\s(\d[.\d]+)\s/s);
my $progclass = 'CheeseGrater';
my $progurl = 'http://www.jwz.org/cheesegrater/';

my $verbose = 0;

my $min_length = 1024;  # less than this and we assume the page is an error.


$ENV{PATH} .= ":/opt/local/bin:/sw/bin";

my $rss_output_dir = "RSS";
my $html_cache_dir = $rss_output_dir;

my $max_entries   = 150;

my $rss_lang       = "en";
my $rss_webmaster  = "webmaster\@jwz.org";
my $rss_editor     = $rss_webmaster;

# How to parse sites.  Entries in the table are:
#
#    "URL"  =>   [ parse_function, "site name", "site description",
#                  "site logo image url", image_width, image_height,
#                  expirey_minutes
#                ]
#
# The logo url is optional.
# If the url has been checked within expirey_minutes, it's not checked again.
#
my %filter_table = (

 "http://www.mitchclem.com/nothingnice/" =>
                    [ \&do_nothingnice, "Nothing Nice to Say",
                      "Nothing Nice to Say",
     "http://www.mitchclem.com/nothingnice/images/nn2s_header.gif", 278, 100,
                      60 * 6
                    ],

 "http://www.daniellecorsetto.com/gws.html" =>
                    [ \&do_girlswithslingshots, "Girls With Slingshots",
                      "Girls With Slingshots",
 "http://www.daniellecorsetto.com/images/gwsmenu/gwslogoheader.jpg", 172, 57,
                      60 * 6
                    ],

 "http://www.thismodernworld.com/" =>
                    [ \&do_thismodernworld_blog, "This Modern World",
                      "This Modern World weblog, by Tom Tomorrow",
          "http://images.salon.com/comics/tomo/2002/10/28/tomo/lc.gif", 58, 50,
                      60
                    ],

 "http://dir.salon.com/topics/tom_tomorrow/" =>
                    [ \&do_thismodernworld_comic,
                      "This Modern World",
                      "This Modern World comic, by Tom Tomorrow",
          "http://images.salon.com/comics/tomo/2002/10/28/tomo/lc.gif", 58, 50,
                      60
                    ],

# "http://www.workingforchange.com/column_lst.cfm?AuthrId=43" =>
#                    [ \&do_thismodernworld_comic2,
#                      "This Modern World",
#                      "This Modern World comic, by Tom Tomorrow",
#          "http://www.workingforchange.com/webgraphics/WFC/sparky3.gif",
#                      47, 46,
#                      60 * 6
#                    ],

 "http://www.straightdope.com/" =>
                    [ \&do_straightdope,
                      "The Straight Dope",
                      "The Straight Dope, by Cecil Adams",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://antwrp.gsfc.nasa.gov/apod/" =>
                    [ \&do_apod_inline, "Astronomy Picture of the Day",
                      "Each day a different image or photograph of our " .
                      "fascinating universe is featured, along with a " .
                      "brief explanation written by a professional " .
                      "astronomer.",
                      "http://www.nasa.gov/images/hotnasa.gif", 78, 68,
                      60 * 6
                    ],

# "http://www.redmeat.com/redmeat/meatlocker/" =>
#                    [ \&do_redmeat, "Red Meat",
#                      "Red Meat, from the secret files of Max Cannon",
#                  "http://www.redmeat.com/redmeat/images/rm_nav2.gif", 57, 108,
#                      60 * 6
#                    ],

# "http://www.space.com/news/" =>
#                    [ \&do_space_com, "Space Dot Com",
#                      "Space news from space.com.",
#                      undef, 0, 0,
#                      60 * 6
#                    ],

# "http://www.catandgirl.com/" =>
#                    [ \&do_catandgirl_inline, "Cat and Girl",
#                      "A small Girl, a large anthropomorphic Cat, a few " .
#                      "wacky adventures and some pretentious conversation. " .
#                      "Also Beatnik Vampires and Joseph Beuys. " .
#                      "Updated every monday.",
#                      undef, 0, 0,
#                      60 * 6
#                    ],

# "http://www.wtbw.net/geisha/" =>
#                    [ \&do_geisha_asobi, "Geisha asobi blog",
#                      "Geisha asobi blog, by Asobi Tsuchiya",
#                      undef, 0, 0,
#                      60
#                    ],

# "http://www.mnftiu.cc/category/gywo/" =>
#                    [ \&do_gywo, "Get Your War On", "Get Your War On",
#                      "http://www.mnftiu.cc/mnftiu.cc/images/gywo_cover.gif",
#                      120, 81,
#                      60 * 6
#                    ],

 "http://slashdot.org/" =>
                    [ \&do_slashdot, "Slashdot", 
#                     "Slashdot: News for \"nerds.\"  Stuff that \"matters.\"",
                      "Nothing to see here.  Move along." .
                      "&lt;P&gt;You want &lt;lj user=\"slashdot\"&gt;.",
                      undef, 0, 0,
                      60
                    ],

 "http://www.linkfilter.net/" =>
                    [ \&do_linkfilter, "LinkFilter",
                      "A better-formatted (screen-scraped) feed of this site.",
                      undef, 0, 0,
                      60
                    ],

 "http://www.creaturesinmyhead.com/creature.php" =>
                    [ \&do_creaturesinmyhead, "The Creatures in my Head",
                      "By Andrew Bell.",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://www.asofterworld.com/" =>
                    [ \&do_asofterworld, "a softer world",
                      "a softer world",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://www.bobharris.com/" =>
                    [ \&do_bobharris, "Bob Harris", "Bob Harris",
                      undef, 0, 0,
                      60
                    ],

 "http://videos.antville.org/" =>
                    [ \&do_antville_videos, 
                      "videos.antville.org", "videos.antville.org",
                      undef, 0, 0,
                      60
                    ],

 # This site has a feed at http://shes.aflightrisk.org/index.rdf
 # but it truncates at the first paragraph.
 "http://shes.aflightrisk.org/" =>
                    [ \&do_flightrisk, 
                      "She's a Flight Risk", "An International Fugitive.",
                      undef, 0, 0,
                      60
                    ],

# "http://www.doodie.com/" =>
#                    [ \&do_doodie, 
#                      "doodie.com", "Shit, Poop and Crap Cartoons.",
#                      undef, 0, 0,
#                      60 * 6
#                    ],

# "http://feeds.feedburner.com/crooksandliars/YaCP" =>
 "http://www.crooksandliars.com/rss.xml" =>
                    [ \&do_crooks,
                      "Crooks and Liars",
                      "Crooks and Liars, minus 'Music' and 'Open Threads'",
                      undef, 0, 0,
                      60
                    ],

 "http://www.kunstler.com/eyesore.html" =>
                    [ \&do_eyesore, "Eyesore of the Month",
                      "Eyesore of the Month, by James Howard Kunstler",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://www.penny-arcade.com/comic/" =>
                    [ \&do_pennyarcade, "Penny Arcade",
                      "Penny Arcade",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://pipes.yahoo.com/pipes/pipe.run?_id=_j_P8zpm3hGBTmHJHzfpSg&_render=rss" =>
                    [ \&do_oglaf, "Oglaf", "Oglaf",
                      undef, 0, 0,
                      60
                    ],

 "http://popscenesf.wordpress.com/" =>
                    [ \&do_popscene, "Popscene", "Popscene",
                      undef, 0, 0,
                      60
                    ],

 "http://www.yelp.com/biz/dna-pizza-san-francisco?rpp=40&sort_by=date_desc" =>
                    [ \&do_yelp, "Yelp DNA Pizza", "Yelp DNA Pizza",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://www.yelp.com/biz/dna-pizza-san-francisco-2?rpp=40&sort_by=date_desc" =>
                    [ \&do_yelp, "Yelp DNA Pizza 2", "Yelp DNA Pizza 2",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://www.yelp.com/biz/dna-lounge-san-francisco?rpp=40&sort_by=date_desc" =>
                    [ \&do_yelp, "Yelp DNA Lounge", "Yelp DNA Lounge",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://www.yelp.com/biz/death-guild-san-francisco-2?rpp=40&sort_by=date_desc" =>
                    [ \&do_yelp, "Yelp Death Guild", "Yelp Death Guild",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://www.yelp.com/biz/bootie-san-francisco?rpp=40&sort_by=date_desc" =>
                    [ \&do_yelp, "Yelp Bootie", "Yelp Bootie",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://www.yelp.com/biz/blow-up-san-francisco-2?rpp=40&sort_by=date_desc" =>
                    [ \&do_yelp, "Yelp Blow Up", "Yelp Blow Up",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://www.yelp.com/biz/hubba-hubba-revue-san-francisco-2?rpp=40&sort_by=date_desc" =>
                    [ \&do_yelp, "Yelp Hubba", "Yelp Hubba",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://www.yelp.com/biz/trannyshack-san-francisco?rpp=40&sort_by=date_desc" =>
                    [ \&do_yelp, "Yelp Trannyshack", "Yelp Trannyshack",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://www.postmusic.org/wordpress/" =>
                    [ \&do_postmusic, "Postmusic", "Postmusic",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://thequietus.com/feed" =>
                    [ \&do_quietus,
                      "The Quietus",
                      "The Quietus",
                      undef, 0, 0,
                      60 * 6
                    ],

 "https://api.instagram.com/v1/tags/dnalounge/media/recent?client_id=b59fbe4563944b6c88cced13495c0f49" =>
                    [ \&do_instagram_json,
                      "Instagram DNA",
                      "Instagram DNA",
                      undef, 0, 0,
                      60 * 6
                    ],

 "https://api.instagram.com/v1/tags/pointbreaksf/media/recent?client_id=b59fbe4563944b6c88cced13495c0f49" =>
                    [ \&do_instagram_json,
                      "Instagram PBL",
                      "Instagram PBL",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://instagram.com/tags/dnalounge/feed/recent.rss" =>
                    [ \&do_instagram_rss,
                      "Instagram DNA",
                      "Instagram DNA",
                      undef, 0, 0,
                      60 * 6
                    ],

 "http://instagram.com/tags/pointbreaksf/feed/recent.rss" =>
                    [ \&do_instagram_rss,
                      "Instagram PBL",
                      "Instagram PBL",
                      undef, 0, 0,
                      60 * 6
                    ],

);


#############################################################################

my $inside_eval_p = 0;
sub error($) {
  my ($e) = @_;
  if ($inside_eval_p) {  # perl's exception handling sucks
    die $e;
  } else {
    print STDERR "$progname: $e\n";
    exit 1;
  }
}

sub url_unquote($) {
  my ($url) = @_;
  $url =~ s/[+]/ /g;
  $url =~ s/%([a-z0-9]{2})/chr(hex($1))/ige;
  return $url;
}

# Convert any HTML entities to Unicode characters.
#
sub html_unquote($) {
  my ($s) = @_;
  return HTML::Entities::decode_entities ($s);
}


sub capitalize($) {
  my ($s) = @_;
  $s =~ s/_/ /g;
  # capitalize words, from the perl faq...
  $s =~ s/((^\w)|(\s\w))/\U$1/g;
  $s =~ s/([\w\']+)/\u\L$1/g;   # lowercase the rest

  # conjuctions and other small words get lowercased
  $s =~ s/\b((a)|(and)|(in)|(is)|(it)|(of)|(the)|(for)|(on)|(to))\b/\L$1/ig;

  # initial and final words always get capitalized, regardless
  $s =~ s/^(\w)/\u$1/;
  $s =~ s/(\s)(\S+)$/$1\u\L$2/;

  return $s;
}



# expands the first URL relative to the second.
#
sub expand_url($$) {
  my ($url, $base) = @_;

  return ($url) unless defined($url);

  $url =~ s/^\s+//gs;  # lose whitespace at front and back
  $url =~ s/\s+$//gs;

  $url =~ s@^//@https?://@;  # slashdot does this stupidity

  if (! ($url =~ m/^[a-z]+:/)) {

    $base =~ s@(\#.*)$@@;       # strip anchors
    $base =~ s@(\?.*)$@@;       # strip arguments
    $base =~ s@/[^/]*$@/@;      # take off trailing file component

    my $tail = '';
    if ($url =~ s@(\#.*)$@@) { $tail = $1; }         # save anchors
    if ($url =~ s@(\?.*)$@@) { $tail = "$1$tail"; }  # save arguments

    my $base2 = $base;

    $base2 =~ s@^([a-z]+:/+[^/]+)/.*@$1@        # if url is an absolute path
      if ($url =~ m@^/@);

    my $ourl = $url;

    $url = $base2 . $url;
    $url =~ s@/\./@/@g;                         # expand "."
    1 while ($url =~ s@/[^/]+/\.\./@/@g);       # expand ".."

    $url .= $tail;                              # put anchors/args back

    print STDERR "$progname: relative URL: $ourl --> $url\n"
      if ($verbose > 5);

  } else {
    print STDERR "$progname: absolute URL: $url\n"
      if ($verbose > 6);
  }

  return $url;
}


# converts all relative URLs in SRC= or HREF= to absolute URLs,
# relative to the given base.
#
sub expand_urls($$) {
  my ($html, $base) = @_;

  return '' unless defined($html);

  $html =~ s/</\001</g;
  my @tags = split (/\001/, $html);

  foreach (@tags) {
    if (m/^(.*)\b(HREF|SRC)(\s*=\s*\")([^\"]+)(\".*)$/si) {
      my $head = "$1$2$3";
      my $url  = $4;
      my $tail = $5;
      $url = expand_url ($url, $base);
      $_ = "$head$url$tail";
    }
  }

  return join ('', @tags);
}


# Pull an updated copy of the given site into the cache
# directory, unless we've done so very recently (according to the
# expirey/freshness value in this URL's configuration.)
#
sub pull_html($;$) {
  my ($url, $other_url) = @_;

  my $now = time;

  # find the expirey of this URL.  This will error if it's an unknown URL.
  #
  my $expirey = undef;
  {
    my ($fn, $title, $desc, $rss_img, $rss_img_w, $rss_img_h);
    ($fn, $title, $desc, $rss_img, $rss_img_w, $rss_img_h, $expirey) =
      get_filter_data ($url);
    error ("no expirey for $url") unless (defined ($expirey));
  }

  my ($file) = ($url =~ m@^https?://([^/]+)@);
  $file =~ s/^www\.//s;
  $file =~ s/\.wordpress//s;
  $file =~ s/\.[^.]+$//s;

  # Kludges
  $file = 'apod' if ($file eq 'antwrp.gsfc.nasa');
  $file = 'nothingnice' if ($file eq 'mitchclem');
  $file = 'girlswithslingshots' if ($file eq 'daniellecorsetto');
  $file = 'eyesore' if ($file eq 'kunstler');
  $file = 'oglaf' if ($url =~ m/P8zpm3hGBTmHJHzfpSg/i);

  $file = 'yelp-dnalounge' if ($url =~ m@yelp\.com/biz/dna-lounge@i);
  $file = 'yelp-dnapizza2' if ($url =~ m@yelp\.com/biz/dna-pizza.*san-francisco-2@i);
  $file = 'yelp-dnapizza'  if ($url =~ m@yelp\.com/biz/dna-pizza@i && $file !~ m/dnapizza/i);
  $file = 'yelp-dg'        if ($url =~ m@yelp\.com/biz/death-guild@i);
  $file = 'yelp-bootie'    if ($url =~ m@yelp\.com/biz/bootie@i);
  $file = 'yelp-blowup'    if ($url =~ m@yelp\.com/biz/blow-up@i);
  $file = 'yelp-hubba'     if ($url =~ m@yelp\.com/biz/hubba@i);
  $file = 'yelp-tshack'    if ($url =~ m@yelp\.com/biz/trannyshack@i);
  $file = 'instagram-dna'  if ($url =~ m@instagram\.com/.*/dnalounge@i);
  $file = 'instagram-pbl'  if ($url =~ m@instagram\.com/.*/pointbreak@i);

  if ($other_url) {
    $file .= "-2";
    $url = $other_url;
  }

  $file .= '.html';

  my $hfile = "$html_cache_dir/$file";


  # check the expirey, and if we've checked this URL recently, don't
  # re-download the content.
  #
  {
    my ($dev,$ino,$mode,$nlink,$uid,$gid,$rdev,$size,
        $atime,$mtime,$ctime,$blksize,$blocks) = stat($hfile);
    if (!defined ($mtime)) {
      print STDERR "$progname: $hfile does not exist\n" if ($verbose > 3);
    } elsif ($size < 512) {
      print STDERR "$progname: $hfile is only $size bytes\n" if ($verbose > 3);
    } else {
      my $minutes_ago = int (($now - $mtime) / 60);
      if ($minutes_ago < $expirey) {
        print STDERR "$progname: $hfile: modified < $expirey ($minutes_ago) " .
          "minutes ago.\n"
            if ($verbose > 2);
        return $file;
      } else {
        print STDERR "$progname: $hfile last modified $minutes_ago " .
          "minutes ago.\n"
            if ($verbose > 3);
      }
    }
  }

  print STDERR "$progname: loading $url\n" if ($verbose > 2);
  $LWP::Simple::ua->agent("$progname/$version");

  my $retries = 5;
  my $count = 0;
  my $html = undef;
  while (1) {
    $html = LWP::Simple::get ($url);
    $html = '' unless ($html && length($html) > $min_length);
    last if ($html);
    last if (++$count > $retries);
    print STDERR "$progname: $url failed, retrying...\n"
      if ($verbose > 2);
    sleep (1 + $count);
  }

  if ($html) {
    open (my $out, '>', $hfile) || error ("$hfile: $!");
    (print $out $html) || error ("$hfile: $!");
    close $out || error ("$hfile: $!");;
    print STDERR "$progname: wrote $hfile\n" if ($verbose > 2);
  } else {
    print STDERR "$progname: error retrieving $url\n";
    unlink $hfile;
    $file = undef;
  }

  return $file;
}

sub pull_html_cache($$) {
  my ($parent_url, $url) = @_;

  my $file = pull_html ($parent_url, $url);
  error ("$url: no data") unless $file;

  $file = "$html_cache_dir/$file";

  open (my $in, '<', $file) || error ("$file: $!");
  local $/ = undef;  # read entire file
  my $html = <$in>;
  close $in;

  error ("no data: $url") unless $html;
  return $html;
}


# returns the parse rules associated with this URL:
#     ( parse_function, "site name", "site description",
#	"site logo image url", image_width, image_height,
#	expirey_minutes )
# 
sub get_filter_data($) {
  my ($url) = @_;
  my $ref = $filter_table{$url};
  error ("unknown URL: $url") unless defined ($ref);
  return @{$ref};
}


# Parses the given HTML into log entries, based on the parse function
# associated with the URL.  Returns a list of the form:
#
#  (  "site-title" "site-desc" "site-logo-img" img_width img_height
#     "entry-url-1" "entry-date-1" "entry-title-1" "entry-body-1"
#     "entry-url-2" "entry-date-2" "entry-title-2" "entry-body-2"
#     ... )
#
sub split_entries($$) {
  my ($url, $html) = @_;

  my ($fn, $title, $desc, $rss_img, $rss_img_w, $rss_img_h, $expirey) =
    get_filter_data ($url);

  print STDERR "$progname: parsing \"$url\" with \"$title\" rules\n"
    if ($verbose > 3);

  my @entries = &$fn ($url, $html);
  return ($title, $desc,
          $rss_img, $rss_img_w, $rss_img_h,
          @entries);
}


# Parses the given HTML file into log entries, based on the parse function
# associated with the URL.  Writes an RSS file into the cache directory.
# Does not change the existing RSS file if there have been no changes.
#
sub convert_to_rss($$) {
  my ($url, $html_file) = @_;

  my $rss_file = $html_file;
  $rss_file =~ s@\.html$@@s;
  $rss_file .= ".rss";

  $html_file = "$html_cache_dir/$html_file";
  $rss_file  = "$rss_output_dir/$rss_file";

  my $html = "";
  open (my $in, '<', $html_file) || error ("$html_file: $!");
  local $/ = undef;  # read entire file
  $html = <$in>;
  close $in;

  # Check to see whether this file seems to be empty.
  # Strip out all HTML comments and tags, compress whitespace,
  # and count how many characters are left.
  #
  $_ = $html;
  1 while (s@<!--.*?-->@ @gsi);
  s@<(SCRIPT)\b[^<>]*>.*?</\1\s*>@@gsi;
  s/<[^<>]+>//gsi;
  s/\s+/ /gsi;
  error ("$html_file is empty") if ($html =~ m/^\s*$/s);

  my $items = '';

  my @entries = split_entries ($url, $html);

  my $rss_title = shift @entries;
  my $rss_desc  = shift @entries;
  my $rss_img   = shift @entries;
  my $rss_img_w = shift @entries;
  my $rss_img_h = shift @entries;

  my $count = 0;
  while ($#entries >= 0) {
    my $eurl  = shift @entries;
    my $date  = shift @entries;
    my $title = shift @entries;
    my $body  = shift @entries;

    $eurl  = expand_url  ($eurl,  $url);
    $date  = expand_urls ($date,  $url);
    $title = expand_urls ($title, $url);
    $body  = expand_urls ($body,  $url);

    $date =~ s/&/&amp;/g;  # de-HTMLify
    $date =~ s/</&lt;/g;
    $date =~ s/>/&gt;/g;

    $title =~ s/&/&amp;/g;  # de-HTMLify
    $title =~ s/</&lt;/g;
    $title =~ s/>/&gt;/g;

    $body =~ s/&/&amp;/g;  # de-HTMLify
    $body =~ s/</&lt;/g;
    $body =~ s/>/&gt;/g;

    $eurl =~ s/&/&amp;/g;

    $date = str2time ($date);
    if (! $date) {
      $date = '';
    } else {
      $date = strftime ("%a, %e %b %Y %H:%M:%S GMT", gmtime ($date));
      $date = "  <pubDate>$date</pubDate>\n";
    }

    my %dups;
    my $enclosure = '';
    my $body2 = $body;
    $body2 =~ s@\b(https?://[a-z.]*(youtube|vimeo)\.com/[^\'\"\s]+)@{
      my $url = html_unquote($1);
      if (!$dups{$url}) {
        $enclosure .= " <enclosure url=\"$url\"" .
                      " type=\"application/x-shockwave-flash\" />\n";
        $dups{$url} = 1;
      }
      "";
    }@gsexi;

    my $item = ("<item>\n" .
                " <title>$title</title>\n" .
                " <link>$eurl</link>\n" .
                $date .
                " <description>\n" .
                "  $body\n" .
                " </description>\n" .
                $enclosure .
                "</item>\n");

    $item =~ s/^/  /gm;

    print STDERR "$progname:   entry: " . ($title || $eurl) . "\n"
      if ($verbose > 3);

    if (++$count < $max_entries) {
      $items .= $item;
    }
  }

  error ("$html_file: no entries parsed!") if ($count <= 0);

  if ($verbose > 2) {
    if ($count > $max_entries) {
      print STDERR "$progname:  $count entries (trimmed to $max_entries)\n";
    } else {
      print STDERR "$progname: $count entries\n";
    }
  }

  my $pubdate = strftime ("%a, %e %b %Y %H:%M:%S GMT", gmtime);
  my $builddate = $pubdate;

  my $rurl = $url;
  $rurl =~ s/&/&amp;/g;

  my $rss = ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" .
             "<rss" .
             " xmlns:itunes=\"http://www.itunes.com/dtds/podcast-1.0.dtd\"" .
             " version=\"2.0\">\n" .
             " <channel>\n" .
             "  <generator>$progclass $version -- $progurl</generator>\n" .
             "  <title>$rss_title</title>\n" .
             "  <link>$rurl</link>\n" .
             "  <description>$rss_desc</description>\n" .
             "  <language>$rss_lang</language>\n" .
             "  <webMaster>$rss_webmaster</webMaster>\n" .
#            "  <managingEditor>$rss_editor</managingEditor>\n" .
             "  <pubDate>$pubdate</pubDate>\n" .
             "  <lastBuildDate>$builddate</lastBuildDate>\n" .
#            "  <itunes:author>$rss_editor</itunes:author>\n" .
#            "  <itunes:owner>\n" .
#            "   <itunes:name>$rss_editor</itunes:name>\n" .
#            "   <itunes:email>$rss_editor</itunes:email>" .
#            "  </itunes:owner>\n" .
#            "  <itunes:category text=\"$rss_cat\"></itunes:category>\n" .
             ($rss_img
              ? ("  <image>\n" .
                 "   <title>$rss_title</title>\n" .
                 "   <url>$rss_img</url>\n" .
                 "   <width>$rss_img_w</width>\n" .
                 "   <height>$rss_img_h</height>\n" .
                 "   <link>$rurl</link>\n" .
                 "  </image>\n")
              : "") .
             $items .
             " </channel>\n" .
             "</rss>\n");

  # de-Windows-ify.  (convert common CP-1252 to ISO-8859-1.)
  #
  $rss =~ s/\205/ --/gs;
  $rss =~ s/\221/\`/gs;
  $rss =~ s/\222/\'/gs;
  $rss =~ s/\223/``/gs;
  $rss =~ s/\224/''/gs;
  $rss =~ s/\225/*/gs;
  $rss =~ s/\226/-/gs;
  $rss =~ s/\227/ --/gs;
  $rss =~ s/\230/~/gs;
  $rss =~ s/\240/ /gs;    # nbsp
  $rss =~ s/\201/E/gs;    # euro symbol?

  # strip out other unknowns, since some RSS parsers are super anal about it.
  $rss =~ s/[\000-\010\013-\037\177-\237]/?/gs;

  my $body = $rss;
  my $nbody = "$body";
  my $obody = "";


  if (open (my $in, '<', $rss_file)) {
    while (<$in>) { $obody .= $_; }
    close $in;
  }

  # strip the dates out of both files, for comparison purposes
  #
  $nbody =~ s@<([a-z]+Date)>(.*?)</\1>@<$1>...</$1>@gsi;
  $obody =~ s@<([a-z]+Date)>(.*?)</\1>@<$1>...</$1>@gsi;

  if ($nbody eq $obody) {
    print STDERR "$progname: $rss_file unchanged\n" if ($verbose > 2);
  } else {
    open (my $out, '>', $rss_file) || error ("$rss_file: $!");
    (print $out $body) || error ("$rss_file: $!");
    close $out || error ("$rss_file: $!");;
    print STDERR "$progname: wrote $rss_file\n" if ($verbose);
  }
}


# Downloads the given URL, and updates the RSS file if necessary.
#
sub scrape($) {
  my ($url) = @_;

  @_ =
    eval {
      $inside_eval_p = 1;
      my $html_file = pull_html ($url);
      return unless defined ($html_file);
      convert_to_rss ($url, $html_file);
      return ();
    };
  $inside_eval_p = 0;
  if ($@) {
    print STDERR "\n" if ($verbose);
    print STDERR "$progname: ERROR: " . join(' ', $@) . "\n";
    print STDERR "\n" if ($verbose);
    $@ = undef;
    return 1;
  } else {
    return 0;
  }
}


#############################################################################
#
# Site-specific parse functions
# These are referenced by the %filter_table at the top of the file.
#
#############################################################################


sub do_thismodernworld_blog($$) {
  my ($url, $html) = @_;

  $_ = $html;

  1 while (s@<!--.*?-->@ @gsi);  # lose comments

#  s@^.*?<DIV\b[^<>]*\bCLASS=\"posts\"[^<>]*>\s*@@is ||
#    error ("unable to trim head in $url");
#  s@\s*<DIV\b[^<>]*\bCLASS=\"mt\"[^<>]*>.*$@@is ||
#    error ("unable to trim tail in $url");

  s@(<DIV\b[^<>]*\bCLASS=\"post\"[^<>]*>)@\n\001\001\001\n$1@gi;

  my @sec1 = split (/\n\001\001\001\n/s);
  my @sec2 = ();
  shift @sec1;
  pop @sec1;
  foreach (@sec1) {
    next if (m/^\s*$/s);
    s/[\r\n]/ /gs;

#    next if (m/^(<[pb]>\s*)*Attention Tom-Mart Shoppers/i);  # kludge...
#    next if (m/^(<[pb]>\s*)*Support this site!</i);          # kludge...
#    next if (m/^(<[pb]>\s*)*New design in the store:</i);    # kludge...
#    next if (m/^(<[pb]>\s*)*THE GREAT BIG BOOK OF /i);       # kludge...
#    next unless (m/^\s*<A NAME=/i);

    next if (m/cafepress/i);

    # lose any embedded dates (they occur only daily, not per entry)
#    s@\s------+\s*<DIV\b[^<>]*CLASS=\"postdate\"[^<>]*>.*?</DIV>\s*@@is;
    s@<DIV\b[^<>]*CLASS=\"postdate\"[^<>]*>.*?</DIV>\s*@@is;

#    # lose "posts" class
#    s@\s*<DIV\b[^<>]*CLASS=\"posts\"[^<>]*>\s*@@is;

#    s@^\s*<A\b[^<>]*?\bREL=\"([^<>\"]+)\"[^<>]*>\s*</A>\s*@@is ||
#      error ("unparsable entry (anchor) in $url");
#    my $anchor = $1;

    s@<DIV\s*CLASS=\"post\"\s*ID="post-(\d+)\"[^<>]*>@@is ||
      error ("unparsable entry (anchor) in $url");
    my $anchor = $1;

    my $date   = "";

    s@<DIV\b[^<>]*?\bCLASS=\"posttitle\"[^<>]*>\s*(.*?)\s*</DIV>\s*@@is ||
      error ("unparsable entry (title) in $url");
    my $title  = $1;
    $title =~ s@</?B>@@gi;

    m@<A HREF=\"([^\"]+)\"[^<>]*>[^a-z<>]*\blink\b\s*</A>@i ||
      error ("unparsable entry (link) in $url");
    my $eurl = $1;

    # loose footer crud
    s@<DIV\b[^<>]*CLASS=\"postfoot\"[^<>]*>.*?</DIV>\s*@@is;

    # lose all DIVs
    s@</?DIV\b[^<>]*>\s*@@gis;

    # lose trailing P and /DIV
    1 while (s@\s*</?(P|DIV)\b[^<>]*>\s*$@@is);
    s@\s*</DIV>\s*$@@is;

    # lose trailing crap on last entry, so it doesn't update every
    # time something falls off the log.
#    s@</div>.*?$@@is;

    s@\s+@ @gsi;

    my $body = $_;

    push @sec2, ($eurl, $date, $title, $body);
  }

  return @sec2;
}


# from salon.com, which no longer works
sub do_thismodernworld_comic($$) {
  my ($url, $html) = @_;

  $_ = $html;

  1 while (s@<!--.*?-->@ @gsi);  # lose comments
  s@[\r\n]+@ @gs;
  s@(<A\b)@\n$1@igs;

  my @sec = ();
  foreach (split (/\n/)) {
    next unless m@/comics/tomo/@;
    next unless m@Tom Tomorrow@;
    s@<A\b[^<>]*\bHREF=\"([^\"]+)\"[^<>]*>@@i
      || error ("unparsable entry (href) in $url");
    my $eurl = $1;
    my $date = "";

    s@<SCRIPT[^<>]*>.*?</SCRIPT>@@gi;

    s@<[^<>]*>@ @g;

    s@^\s*@@s; s@\s*$@@s;
    my @text = split (/\s\s+/);

#    my $title = "$text[0]: $text[1]";
    my $title = "$text[1]";

    $eurl =~ s@/index\.html$@/@;

    my $iurl = $eurl;
    $iurl .= "story.jpg";

    my $body = "<IMG SRC=\"$iurl\">";

    push @sec, ($eurl, $date, $title, $body);
  }

  return @sec;
}


## from workingforchange.com
#sub do_thismodernworld_comic2($$) {
#  my ($url, $html) = @_;
#
#  $_ = $html;
#
#  1 while (s@<!--.*?-->@ @gsi);  # lose comments
#  s@</?(TR|TD|TABLE|FONT|B|I|H\d)\b[^<>]*>\s*@@gsi;  # lost most tags
#  s@&nbsp;@ @g;
#  s@[\r\n]+@ @gs;
#  s@(<A\b)@\n$1@igs;
#
#  my @sec = ();
#  foreach (split (/\n/)) {
#    next unless m@<A[^<>]*\bHREF=\"([^<>\"]+)\"[^<>]*>\s*
#                  This\s+Modern\s+World:\s*([^<>]+)(.*)@xi;
#    my $eurl = $1;
#    my $title = $2;
#    my $rest = $3;
#    $_ = $rest;
#    my ($mm, $dd, $yy) = m@\b(\d\d?)\.(\d\d?)\.(\d\d)\b@;
#    error ("noo date?") unless ($yy);
#    my $date = sprintf("%02d-%02d-%04d", $yy+2000, $mm, $dd);
#
#    $mm = sprintf("%02d", $mm);
#    $dd = sprintf("%02d", $dd+1);  # don't ask me, man...
#
#    my $iurl = ("http://workingforchange.speedera.net/" .
#                "www.workingforchange.com/webgraphics/wfc/" .
#                "TMW$mm-$dd-$yy.jpg");
#
#    my $body = "<IMG SRC=\"$iurl\">";
#
#    push @sec, ($eurl, $date, $title, $body);
#  }
#
#  return @sec;
#}


sub do_straightdope($$) {
  my ($url, $html) = @_;

  $_ = $html;

  1 while (s@<!--.*?-->@ @gsi);  # lose comments

  my ($eurl) = (m@Today[^a-z]*s Question:.*?<A HREF="(.*?)"@si);
  error ("no url") unless $eurl;

  $html = pull_html_cache($url, $eurl);

  my ($title) = ($html =~ m@<title>(.*?)</title>@si);
  my $date = '';

  $html =~ s@<SCRIPT[^<>]*>.*?</SCRIPT>@@gsi;
  $html =~ s@^.*?(<div id="article")@$1@gs  || error ("$eurl: no head");
  $html =~ s@<div class="sd_link.*$@@gs || error ("$eurl: no tail");
  $html =~ s@class=".*?"@@gs;
  $html = expand_urls ($html, $eurl);

  return ($eurl, $date, $title, $html);
}


# generate a single-entry RSS file with an inline image.
#
sub do_apod_inline($$) {
  my ($url, $html) = @_;

  $_ = $html;

  1 while (s@<!--.*?-->@ @gsi);  # lose comments

  s/[\r\n]+/ /gs;

  s@^.*?discover the cosmos.*?<p>\s*@@si ||
    error ("unable to trim head in $url");

  s@</?(p|br)>\s*(<[^<>]+>\s*)*Tomorrow\'s picture:.*?$@@ ||
    error ("unable to trim tail in $url");

  s@^(\s*<[^<>]+>\s*)+@@s; # lose leading tags
  s@^\s*((\d{4})[- ]([a-z]+)[- ](\d\d?))\b\s*(<(BR|P)>\s*)*@@i ||
    error ("$url: unable to find date");

  my $date  = $1;
  my $year  = $2;
  my $month = $3;
  my $dotm  = $4;

  s@</?(TR|TD|TBODY|TABLE)\b[^<>]*>\s*@@gsi;  # lose table tags
  s@</?CENTER>@<P>@gsi;
  s@( <A\b[^<>]*> \s* <IMG\b[^<>]*> \s* </A> \s* ) ( .* )$@
    <DIV ALIGN=CENTER>$1</DIV>
    <DIV STYLE="max-width:40em">$2</DIV>@six;
  s/[\r\n]+/ /gs;
  s/\s+/ /gs;

  my $body = $_;

  my %m = ( "Jan" => 1, "Feb" => 2,  "Mar" => 3,  "Apr" => 4,
            "May" => 5, "Jun" => 6,  "Jul" => 7,  "Aug" => 8,
            "Sep" => 9, "Oct" => 10, "Nov" => 11, "Dec" => 12);
  $month =~ s/^(...).*/$1/;
  $month = $m{$month} || error ("unparsable month: $month");

  my $eurl = $url . sprintf ("ap%02d%02d%02d.html",
                             $year % 100, $month, $dotm);

  s@<(P|BR)\b[^<>]*>@\n@gsi;  # expand newlines
  s@<[^<>]*>@@g;              # lose other tags

  my ($title) = m@^\s*(.*?)\s*$@m;

  return ($eurl, $date, $title, $body);
}


#sub do_redmeat($$) {
#  my ($url, $html) = @_;
#
#  $url =~ s@/[^/]*$@/@;  # take off last path component
#
#  $_ = $html;
#
#  1 while (s@<!--.*?-->@ @gsi);  # lose comments
#
#  s@[\r\n]+@ @gs;
#
#  s@^.*?(<LI)@$1@is || error ("unable to trim head in $url");
#  
#  s@(<LI)@\n$1@gsi;
#
#  my @sec = ();
#  foreach (split (/\n/)) {
#    next unless m@<A\b@i;
#    s@</UL\b.*$@@is;
#    s@^.*<A\b[^<>]*\bHREF=\"([^\"]+)\"[^<>]*>(.*?)</A>.*$@@i
#      || error ("unparsable entry in $url");
#    my $eurl  = $1;
#    my $title = $2;
#
#    $_ = $eurl;
#    my ($date) = m@\b(\d{4}-\d{2}-\d{2})\b@;
#    $date = '' unless $date;
#
#    $eurl =~ s@/index\.html?$@/@i;
#
#    my $rbody = ("<DIV STYLE=\"background: \#FFF\">" .
#                 "<IMG SRC=\"$eurl/index-1.gif\" BORDER=0 HSPACE=8 VSPACE=8>" .
#                 "</DIV>");
#    my $body  = "<A HREF=\"$eurl\">$rbody</A>";
#    push @sec, ($eurl, $date, $title, $body);
#  }
#
#  return @sec;
#}


#sub do_space_com($$) {
#  my ($url, $html) = @_;
#
#  $_ = $html;
#
#  1 while (s@<!--.*?-->@ @gsi);  # lose comments
#  1 while (s@<SCRIPT\b[^<>]*>.*?</SCRIPT\b[^<>]*>@@gsi);  # lose javascript
#
#  s@[\r\n]+@ @gs;
#
#  s@(<TR\b)@\n$1@gsi;
#
#  my @sec = ();
#  foreach (split (/\n/)) {
#    s@</TR\b.*$@@is;
#
#    next unless m@<TR\b@i;
#    next unless m@<IMG\b@i;
#    next unless m@<A\b@i;
#
#    s@</?(TABLE|TD|TR)\b[^<>]*>@@gsi;
#
#    m@^.*<A\b[^<>]*\bHREF=\"([^\"]+)\"[^<>]*>@i
#      || error ("unparsable entry (url) in $url");
#    my $eurl = $1;
#
#    m@^.*<IMG\b[^<>]*\bSRC=\"([^\"]+)\"[^<>]*>@i
#      || error ("unparsable entry (image) in $url");
#    my $img = $1;
#
#    next if ($eurl =~ m@(/navigation|/template|doubleclick)@i);
#    next if ($img  =~ m@(/navigation|/template|doubleclick)@i);
#
#    # now let's munge the HTML a little...
#    s@(<IMG )@$1ALIGN=LEFT @igs;
#    s@</?FONT\b[^<>]*>@@igs;
#    $_ .= "<BR CLEAR=LEFT>";
#    s@>>+@&gt;&gt;@gsi;  # dummies
# 
#    my $body = $_;
#    my $date = '';   # note: could parse this from $eurl pathname
#
#    s@<(BR|P)\b[^<>]*>@\n@gsi;  # put newlines back
#    s@<[^<>]*>@@gs;             # lose all tags
#    s@\n.*$@@s;                 # delete all but first line
#    my $title = $_;
#
#    next if ($eurl =~ m/\bads\.space\.com/i);
#
#    push @sec, ($eurl, $date, $title, $body);
#  }
#
#  return @sec;
#}


# generate a single-entry RSS file with an inline image of the latest cartoon.
#
#sub do_catandgirl_inline($$) {
#  my ($url, $html) = @_;
#
#  $_ = $html;
#
#  1 while (s@<!--.*?-->@ @gsi);  # lose comments
#
#  s/[\r\n]+/ /gs;
#
#  s@(<(A|IMG)\b)@\n$1@gsi;
#
#  my $number = 0;
#  my ($eurl, $title, $body);
#  foreach (split (/\n/)) {
#
#    if (m@^<A\b[^<>]*\bHREF=\"(view\.(cgi|php)\?)(loc=)?(\d+)\"@i) {
#      my $base = $1;
#      my $n = $4;
#      if ($n > $number) {
#        $number = $n + 1;
#        $eurl = $base . $number;
#      }
#
#    } elsif (m@^<IMG\b[^<>]*\bSRC=\"([^<>\"]+)\"[^<>]*\bALT=\"([^<>\"]+)\"@i) {
#      my ($img, $alt) = ($1, $2);
#      s/>.*$/>/s;
#      if ($img =~ m@\barchive/@) {
#        $body = $_;
#        $title = $alt;
#      }
#    }
#  }
#
#  error ("couldn't find image number? ($number) in $url")
#    unless ($number > 123);
#  error ("couldn't find image in $url") unless (defined ($body));
#
#  my $date = '';
#  return ($eurl, $date, $title, $body);
#
#}


#sub do_geisha_asobi($$) {
#  my ($url, $html) = @_;
#
#  $_ = $html;
#
#  s@\r\n@\n@gs;
#  s@\r@\n@gs;
#
#  s@^.*<!-- start of content of your blog -->@@is ||
#    error ("unable to trim head in $url");
#  s@<!-- end of content of your blog -->.*$@@is ||
#    error ("unable to trim tail in $url");
#
#  s@^.*?(<!--TIME-->)@$1@is ||
#    error ("unable to trim head-2 in $url");
#
#  s@<!--TIME-->(\s*<TABLE)@<!--TIMEA-->$1@gsi;  # make start/end differ
#  s@<!--TIMEA-->.*?<!--TIME-->@@gis;
#
#  s@\s+@ @gs;  # lose newlines, compress whitespace
#
#  s@<HR\b[^<>]*>@\n@gsi;
#
#  my @sec = ();
#  foreach (split ('\n', $_)) {
#    next if (m/^\s*$/s);
#
#    s@</?FONT\b[^<>]*>@@gsi;   # lose fonts
#    s@(<A\b[^<>]*?)\s*\bTARGET=\"?[^<>\"]+\"@$1@gsi;   # lose TARGETs in A
#
#    s/\s+/ /gs;
#    s/^\s+//gs;
#    s/\s+$//gs;
#
#    my $body = $_;
#
#    m@\bposted by .* (on|at)\s+<A HREF=\"([^<>\"]+)\">([^<>]+)</A>@i ||
#      error ("unparsable time in $url");
#    my ($eurl, $date) = ($2, $3);
#    $date =~ s/\s+$//g;
#    $date =~ s/^\s+//g;
#
#    # try for a title on the first line
#    my $title = $body;
#    $title =~ s@<(BR|P|IMG)\b[^<>]*>@\n@gsi;
#    $title =~ s@</A\b.*$@@gmi;
#    $title =~ s@<[^<>]*>@ @gs;
#    $title =~ s@^[ \t]*@@;
#    $title =~ s@[ \t]*$@@;
#    $title =~ s@\n.*$@@s;
#    $title =~ s@\s+$@@s;
#
#    push @sec, ($eurl, $date, $title, $body);
#  }
#
#  return @sec;
#}


sub do_penn($$) {
  my ($url, $html) = @_;

  $_ = $html;

  1 while (s@<!--.*?-->@ @gsi);  # lose comments
  s/\s+/ /gs;

  s@<A HREF="\([^\"]*\)\">@@gi;  # bogosity

  s/(<A\s+[^\s<>])/\n$1/gi;
  s@(</?UL)@\n$1@gi;

  my @sec = ();
  foreach (split (/\n/)) {
    last if ($#sec > 0 && m@</UL@i);
    next unless (m/^<A\b/i);
    next if (m/<IMG/i);
    my ($eurl) = m@<A\s+HREF\s*=\s*\"([^<>\"]+)\"@i;
    error ("unable to find url: $url") unless ($eurl);

    $_ =~ s@<[^<>]+>@@g;
    my ($title, $date) = m@^(.+)(\d\d?[\s/]+\d\d?[\s/]+\d+)[^a-z\d]+$@;
    error ("unable to find title: $url $_") unless ($title);
    error ("unable to find date: $url") unless ($date);

    $title =~ s@^\s+@@s;
    $title =~ s@[^a-z]+$@@s;

    $date =~ s@^\s+@@s;
    $date =~ s@\s+$@@s;

    my $body = "<A HREF=\"$eurl\">$title ($date)</A>";

    push @sec, ($eurl, $date, $title, $body);
  }

  return @sec;
}


#sub do_gywo($$) {
#  my ($url, $html) = @_;
#
#  $_ = $html;
#
#  s/(<IMG\b)/\n$1/gi;
#
#  my @sec = ();
#  foreach (split (/\n/)) {
#    s/>.*$/>/s;
#    my ($img) = m@\bSRC\s*=\s*\"([^<>\"]+)\"@si;
#    next unless $img;
#    next unless ($img =~ m@/blog/images/gywo\.@);
#    my ($title) = ($img =~ m@/([^/]+)$@s);
#    $title =~ s/^gywo\.//s;
#    $title =~ s/\.[^.]+$//s;
#    my $tt = $title;
#    $title =~ s/[-_.]/ /gs;
#    $title = "get your war on: $title";
#    my $date  = "";
#
#    my $html = "<IMG SRC=\"$img\">";
#
#    my $eurl = "$url#$tt";
#    unshift @sec, ($eurl, $date, $title, $html);
#  }
#  return @sec;
#}


sub do_slashdot($$) {
  my ($url, $html) = @_;

  $_ = $html;

  1 while (s@<!--.*?-->@ @gsi);  # lose comments
  s/\s+/ /gs;

#  s/(<h3 id=\"title)/\n$1/gsi;
  s/(<h3 class="story)/\n$1/gsi;
  s/^[^\n]*\n//si;   # lose head
  s/\n[^\n]*$//si;   # lose tail

  my @sec = ();
  foreach (split (/\n/)) {

    s@<span\s+class="date">\s*(.*?)\s*</span>@@si;
    my $date = $1 || '';
    $date =~ s/^\s*on\s*//s;

    my ($title) = m@<a[^<>]*?class=\"datitle[^<>]*>\s*(.*?)\s*</[^<>]+>@si;
    my ($body)  = m@<div\s+[^<>]*class="details[^<>]*>(.*)$@si;
    next unless defined ($title);

    my ($eurl) = ($body =~ m@<A\s+HREF\s*=\s*\"([^<>\"]+)\" class="more"@si);

    $body =~ s@<DIV CLASS="tag[^<>]*>.*?</DIV>@ @gsi;
    $body =~ s@<A CLASS="edit[^<>]*>.*?</A>@ @gsi;
    $body =~ s@<SPAN CLASS="(comment|sd-|type)[^<>]*>.*?</SPAN>@ @gsi;
    $body =~ s@<SPAN ID="updown[^<>]*>.*?</SPAN>@ @gsi;
    $body =~ s@<A HREF="#[^<>]*>.*?</A>@ @gsi;
    $body =~ s@<A[^<>]*?ID="comment[^<>]*>.*?</A>@ @gsi;
    $body =~ s@<A[^<>]*CLASS="more".*$@@gsi;

    $body =~ s@</?(SPAN|IMG|FORM|INPUT)\b[^<>]*>@ @gsi;
    $body =~ s@</?DIV[^<>]*>@<P>@gsi;
    $body =~ s@<A\b[^<>]*>\s*</A>@@gsi;
    $body =~ s@<HR[^<>]*>@ @gsi;
    $body =~ s@(\s*<P>\s*)+@<P>@gsi;


    error ("unable to find entry URL in $url") unless defined ($eurl);

    $title =~ s@<[^<>]*>@@gs;
    $body =~ s@</P>@@gsi;
    $body =~ s@</?(DIV|SPAN)\b[^<>]*>@ @gsi;

    $title =~ s/\s+/ /gsi;
    $body  =~ s/\s+/ /gsi;
    $title =~ s/(^\s+|\s+$)//gsi;
    $body  =~ s/(^\s+|\s+$)//gsi;

    # WTF
    $body =~ s@<P>background: url\([^()]*\); width:\d+px; height:\d+px;@<P>@si;
    $body =~ s@(<A\s+)style="[^"]*"@$1@gsi;
    $body =~ s@\s+onclick="[^"]*"@@si;

    1 while ($body =~ s@\s*<P\b[^<>]*>\s*$@@gsi);

    $eurl  = expand_url  ($eurl, $url);

    # Slashdot is inconsistent with it's URLs.  Canonicalize them.
    # old: http://hardware.slashdot.org/article.pl?sid=09/02/21/2157206
    # new: http://hardware.slashdot.org/hardware/09/02/21/2157206.shtml
    #
    $eurl =~ s@^(http://([a-z]+)\.slashdot\.org/)article.pl\?sid=(.*)$
              @$1$2/$3.shtml@six;

    # Also: 
    # old: http://tech.slashdot.org/story/09/05/25/1553220/Subject-Blah-Blah
    # new: http://tech.slashdot.org/story/09/05/25/1553220.shtml
    $eurl =~ s@(/\d\d\d\d\d+)/[^/]+$@$1.shtml@gsi;

    # Also: 
    # old: http://tech.slashdot.org/tech/09/05/25/1553220.shtml
    # new: http://tech.slashdot.org/story/09/05/25/1553220.shtml
    $eurl =~ s@^(http://[a-z.]+)/[a-z]+/@$1/story/@si;

    # Also: 
    # old: http://tech.slashdot.org/story/09/05/25/1553220.shtml
    # new: http://slashdot.org/story/09/05/25/1553220.shtml
    $eurl =~ s@^(http://)([a-z]+\.)(slashdot\.org/)@$1$3@si;

    push @sec, ($eurl, $date, $title, $body);
  }
  return @sec;
}


sub do_linkfilter($$) {
  my ($url, $html) = @_;

  $_ = $html;

  1 while (s@<!--.*?-->@ @gsi);  # lose comments

  s@&nbsp;@ @gs;
  s@\s+@ @gsi;
  s@\s*(<TD\b[^<>]*?\bCLASS=\"td-head\">)\s*@\n$1@gsi;

  my @sec1 = split (/\n/);
  my @sec2 = ();

  shift @sec1;

  foreach (@sec1) {
    next if (m/^\s*$/s);

    s@^\s*<TD\b[^<>]*>\s*@@si || error ("no TD in entry in $url");

    s@^\s*<A\b[^<>]*?\bHREF=\"([^<>\"]+)\"[^<>]*>\s*(.*?)\s*</A>@@is ||
      error ("unparsable entry (anchor) in $url");
    my $eurl = $1;
    my $title = $2;

    $eurl =~ s@;cmd=go$@@;  # bah.

    s@(</?)(SPAN|TD|TR)\b[^<>]*>@$1P>@gsi;  # fuck SPAN

    # lose the category and submitter links
    s@<A HREF=\"/\?(category|s)=[^<>]*>.*?</A>\s*@@gsi;

    # lose leading P, BR, and DIV
    1 while (s@^\s*</?(P|BR|DIV)\b[^<>]*>\s*@@is);
    # compact <P>
    s@(</?P\b[^<>]*>\s*)+@<P>@gsi;

    my ($date) = m@submitted(.*?)<BR>@si;

    s@^Link\b(.*?)<BR>\s*@@gsi || error ("no date line in $url");

    $date =~ s@^.* on @@;
    $date =~ s@\s*\.?\s*\(.*$@@;


    s@\s+\bONCLICK=\"[^\"]+\"@@gsi;

    # you chumps.  undo link-tracking BS.
    s@<A\b[^<>]*>\s*(http:[^<>\"]+)\s*</A>\s*@@si;
    my $turl = $1;
    my $oturl = $turl;

    error ("no url found in $url") unless defined ($turl);

    # FUCK!  assholes!  we have to use their redirector if the link was
    # long, because they truncate it.
    if ($turl =~ m/\.\.\.$/) {
      $turl = "$eurl;cmd=go";
    }

    # lose trailing Comments links
    s@<A HREF=\"\?id[^<>]*>\s*Comments\b.*$@@si;

    # lose trailing P, BR, and DIV
    1 while (s@\s*</?(P|BR|DIV)\b[^<>]*>\s*$@@is);

    my $body = $_;

    $body = "<A HREF=\"$turl\">$oturl</A><P>$body";

    push @sec2, ($eurl, $date, $title, $body);
  }

  return @sec2;
}


sub do_creaturesinmyhead($$) {
  my ($url, $html) = @_;

  $_ = $html;

  1 while (s@<!--.*?-->@ @gsi);  # lose comments

  s@&nbsp;@ @gs;
  s@\s+@ @gsi;

  my ($img, $title) = m@(<IMG \s+ SRC=\"/?creatures/\d+[^<>]*>)
                         \s* (.*?)</TD>
                       @xsi;
  error ("no image in $url") unless defined ($img);

  $img =~ s/\s+ALT\s*=\s*\"[^<>\"]*\"\s*/ /gsi;
  $title =~ s@<[^<>]*>@ @gsi;
  $title =~ s@\s+@ @g;
  $title =~ s@^\s+@@g;
  $title =~ s@\s+$@@g;

  my ($date) = ($img =~ m@creatures/(\d{6})[^\d]@);
  error ("no date in $img") unless defined ($date);

  my $eurl = "/creature.php?date=$date";

  $date =~ s@^(\d\d)(\d\d)(\d\d)$@$1/$2/$3@;
  $title =~ s@^[-\s\d/]+:\s*@@gs;

  my $body = "<BR CLEAR=BOTH><P ALIGN=CENTER>" .
             "<A HREF=\"$eurl\">$img<BR>$title</A></P>";

  my @sec = ($eurl, $date, $title, $body);
  return @sec;
}


# generate a single-entry RSS file with an inline image of the latest cartoon.
#
sub do_asofterworld($$) {
  my ($url, $html) = @_;

  $_ = $html;

  1 while (s@<!--.*?-->@ @gsi);  # lose comments
  s@\s+@ @gsi;

  my ($img, $eurl) = m@(<IMG\s*SRC=\"([^<>\"]*?\.jpg)\"[^<>]*>)@si;
  my ($title) = ($img =~ m@\bTITLE=\"([^<>\"]*)\"@si);
  my $date = '';

  error ("couldn't find url in $url") unless ($eurl);
  error ("couldn't find title in $url") unless ($title);

  $eurl = $url;
  return ($eurl, $date, $title, $img);
}


sub do_bobharris($$) {
  my ($url, $html) = @_;

  $_ = $html;

  1 while (s@<!--.*?-->@ @gsi);  # lose comments

  s@^.*?(<TABLE\b[^<>]*\bCLASS=\"contentpaneopen\"[^<>]*>)@$1@is ||
    error ("unable to trim head in $url");
  s@\s*<SPAN\b[^<>]*\bCLASS=\"pagenav\"[^<>]*>.*$@@is ||
    error ("unable to trim tail in $url");

  s/\s+/ /gs;
  s@(<TD\b[^<>]*\bCLASS=\"contentheading\"[^<>]*>)@\n$1@gi;

  my @sec1 = split (/\n/s);
  my @sec2 = ();
  shift @sec1;
  foreach (@sec1) {
    next if (m/^\s*$/s);

#   m/[\"\']([^<>\"\']+?task=view[^<>\"\']+)[\"\']/ ||
    m/<A\s+HREF=\"([^<>\"]+)\"[^<>]*class=\"contentpagetitle\"/si ||
      error ("no href in $url");
    my $href = $1;

    s@<TD\b[^<>]*\bCLASS=\"createdate\"[^<>]*>\s*(.*?)\s*</TD>@<BR>@si ||
      error ("no date in $url");
    my $date = $1;

    s@CLASS=\"contentheading\"[^<>]*>\s*(.*?)</TD@@si ||
      error ("no title in $url");
    my $title = $1;
    $title =~ s/<[^<>]*>/ /gsi;
    $title =~ s/\s+/ /gsi;
    $title =~ s/^\s+|\s+$//gsi;

    s@</?(TABLE|TR|TD|TBODY)\b[^<>]*>@@gsi;
    s@<A HREF=\"javascript[^\"]*[^<>]*>.*?</A>@@gsi;
    s@<IMG\b[^<>]*?\bSRC=[\"'][^<>]*?/(components|tooltips)/[^<>]*>@@gsi;
   #s@</?DIV\b[^<>]*>@@gsi;
    s@<BR />@<BR>@gsi;
    s@<BR>\s*<BR>@<P>@gsi;
    s@<(/P|P */)>@<P>@gsi;
    s@<P>(\s*</?(BR|P)>)+@<P>@gsi;

    s@\b(CLASS|TARGET)=\"[^\"]+\"@@gsi;

    s@^\s*</?(BR|P)\s*/?>\s*@@gsi;

    my $body = $_;

    $href =~ s/&amp;/&/g;

    next if ($title =~ m/\bpudublog/i); # fuck this shit

    push @sec2, ($href, $date, $title, $body);
  }

  return @sec2;
}


sub do_antville_videos($$) {
  my ($url, $html) = @_;

  $_ = $html;

  1 while (s@<!--.*?-->@ @gsi);  # lose comments

  s/\s+/ /gs;
  s@(<SPAN\b[^<>]*\bCLASS=\"storyDate)@\n$1@gi;
  s@<DIV\s+CLASS=\"pagelinkBottom.*$@@si;

  my @sec1 = split (/\n/s);
  my @sec2 = ();
  shift @sec1;
  foreach (@sec1) {
    next if (m/^\s*$/s);

    s@<SPAN\b[^<>]*\bCLASS=\"storyDate\"[^<>]*>\s*(.*?)\s*</SPAN>@@si ||
      error ("no date in $url");
    my $date = $1;
    $date =~ s@</?[^<>]*>@@gs;

    s@<SPAN\b[^<>]*\bCLASS=\"storyTitle\"[^<>]*>\s*(.*?)\s*</SPAN>@@si ||
      error ("no title in $url");
    my $title = $1;
    $title =~ s@</?[^<>]*>@@gs;

    m@<A\b[^<>]*\bHREF=\"([^<>\"]*?/stories/\d[^<>\"]*?)\"@si ||
      error ("no url in $url");
    my $href = $1;

    s@\(?\s*<A\b[^<>]*>\s*\d*\s*comments?!?\s*</A>\s*\)?\s*@@gsi;

    s@&nbsp;@ @gs;
    s@\b(CLASS|TARGET)=\"[^\"]+\"@@gsi;

    s@</?SPAN\s*>@<P>@gsi;
    s@<BR />@<BR>@gsi;
    s@<BR>\s*<BR>@<P>@gsi;
    s@<(/P|P */)>@<P>@gsi;
    s@<P>(\s*</?(BR|P)>)+@<P>@gsi;
    s@\s+@ @gsi;

    my $body = $_;

    $href =~ s/&amp;/&/g;

    push @sec2, ($href, $date, $title, $body);
  }

  return @sec2;
}


sub do_flightrisk($$) {
  my ($url, $html) = @_;

  $_ = $html;

  1 while (s@<!--.*?-->@ @gsi);  # lose comments

  s@^.*?(<H2\s+CLASS="date")@$1@is ||
    error ("unable to trim head in $url");

  s/\s+/ /gs;

  s@<H2 CLASS="date">\s*(.*?)\s*</H2>\s*@@gsi;
  s@(<DIV\s+CLASS="blogbody")@\n$1@gis;
  s@\s*</DIV>\s*</DIV>(\s*</?BODY>)?(\s*</?HTML>)?\s*$@@si;


  my @sec1 = split (/\n/s);
  my @sec2 = ();
  shift @sec1;
  foreach (@sec1) {
    next if (m/^\s*$/s);

    s@</?(TABLE|TR|TD|TBODY)\b[^<>]*>@@gsi;

    m@<SPAN CLASS="title">\s*(.*?)\s*</SPAN>@si || error ("no title in $url");
    my $title = $1;

    m@<DIV CLASS="posted">[^<>]*<A HREF=\"([^<>\"]+)\"@si ||
      error ("no href in $url");
    my $href = $1;

    s@\s*<SPAN CLASS="title">[^<>]*</SPAN>\s*@@gsi;
    s@\s*<A NAME=\"[^<>\"]+\">\s*</A>\s*@@gsi;
    s@\s*<DIV CLASS="posted">.*?</DIV>\s*@@gsi;
    s@\s*<IMG SRC=\"/images/topics/[^<>]*>\s*@@gsi;

    s@^\s*<DIV\b[^<>]*>\s*(.*)\s*</DIV>\s*$@$1@si;
    1 while s@\s*(</P>|&nbsp;)\s*$@@gsi;
    s@^(\s*</?\s*(P|BR)\s*/?\s*>)+\s*@@gsi;
    s@\s*(</?\s*(P|BR)\s*/?\s*>\s*)+$@@gsi;

    my $body = $_;
    my $date = '';

    push @sec2, ($href, $date, $title, $body);
  }

  return @sec2;
}


#sub do_doodie($$) {
#  my ($url, $html) = @_;
#
#  $_ = $html;
#  1 while (s@<!--.*?-->@ @gsi);  # lose comments
#  s/[ \t]+/ /gs;
#  s/\r\n/\n/gs;
#
#  my ($target) = m@(<IMG\s+SRC=\"[^\"]*/pics/.*?)<IMG\b@si;
#  error ("$url unparsable") unless ($target);
#
#  my ($img) = ($target =~ m/<IMG\s*SRC=\"([^\"]+)\"/si);
#  error ("no img in $url") unless ($target);
#  $target =~ s@<[^<>]*>@@gsi;
#  $target =~ s@^\s+|\s+$@@gsi;
#  $target =~ s@\n@<BR>@gsi;
#
##  my ($date) = ($img =~ m/\.(\d+)$/s);
##  error ("no date in $img") unless ($date);
#
##  my $href = "/index.php?date=$date";
#  my $href = $url;
#  my $body = ("<DIV ALIGN=CENTER>" .
#              "<A HREF=\"$href\">" .
#              "<IMG SRC=\"$img\">" .
#              "<BR>$target" .
#              "</A></DIV>");
#  $target =~ s@<BR>@ -- @gsi;
#
#  return ($href, '', $target, $body);
#}

sub do_nothingnice($$) {
  my ($url, $html) = @_;

  $_ = $html;
  1 while (s@<!--.*?-->@ @gsi);  # lose comments
  s@<SCRIPT.*?</SCRIPT>@@gsi;
  s/[ \t]+/ /gs;
  s/\r\n/\n/gs;

  my ($img) = m@(<IMG\b[^<>]*?SRC=\"[^<>\"]*?/comics/[^<>\"]*\">)@si;
  error ("$url unparsable") unless ($img);

  my ($n) = m@/(\d+)/">\s*Previous@si;
  $n++;

  my $href = "$n/";

  my ($title) = m@\[\s*(.*?)\s*\]@si;
  my $body = ("<DIV ALIGN=CENTER>" .
              "<A HREF=\"$href\">" .
              $img .
              "</A></DIV>");

  return ($href, '', $title, $body);
}

sub do_girlswithslingshots($$) {
  my ($url, $html) = @_;

  $_ = $html;
  1 while (s@<!--.*?-->@ @gsi);  # lose comments
  s@<SCRIPT.*?</SCRIPT>@@gsi;
  s/[ \t]+/ /gs;
  s/\r\n/\n/gs;

  my ($img) = m@(<IMG\b[^<>]*?SRC=\"[^<>\"]*?images/gws/[^<>\"]*\"[^<>]*>)@si;
  error ("$url unparsable") unless ($img);

  my ($title) = ($img =~ m@/(GWS\d+)\.@si);
  my $href = "/$title.html";

  my $body = ("<DIV ALIGN=CENTER>" .
              "<A HREF=\"$href\">" .
              $img .
              "</A></DIV>");

  return ($href, '', $title, $body);
}

sub do_crooks($$) {
  my ($url, $html) = @_;

  $_ = $html;
  s/(<item>)/\001/gs;
  my @sec1 = split(m/\001/s);
  my @sec2 = ();
  shift @sec1;

  foreach (@sec1) {
    next if (m/^\s*$/s);
    my ($href)  = m@<link>(.*?)</link>@si;
    my ($date)  = m@<pubDate>(.*?)</pubDate>@si;
    my ($title) = m@<title>(.*?)</title>@si;
    my ($body)  = m@<content:encoded>(.*?)</content:encoded>@si;
    ($body) = m@<description>(.*?)</description>@si unless $body;
    $body =~ s@^\s*<\!\[CDATA\[(.*)\]\]>\s*$@$1@si;
    $body = html_unquote ($body);

    next if ($title =~ m/Open Thread|Music Club|Blog Round|Bobble\s*heads?\s*Thread/i);

    push @sec2, ($href, $date, $title, $body);
  }

  return @sec2;
}


sub do_popscene($$) {
  my ($url, $html) = @_;

  $_ = $html;

  1 while (s@<!--.*?-->@ @gsi);  # lose comments

  s/\s+/ /gs;
  s@^.*<div id="content">@@si;

  s@(<div class="post)@\n$1@gsi;

  my @sec1 = split (/\n/s);
  my @sec2 = ();
  shift @sec1;
  foreach (@sec1) {

    s@<hr style=.*$@@gsi;

    next if (m/^\s*$/s);

    my ($href, $title) =
      m@<a HREF="([^<>"]+)" rel="bookmark"[^<>]*>([^<>]+)@si;
    $href =~ s/&amp;/&/g;
    $title =~ s/&nbsp;/ /g;

    s@</?div[^<>]*>@<p>@gsi;
    s@</?span[^<>]*>@ @gsi;

    my $body = $_;
    my $date = '';
    push @sec2, ($href, $date, $title, $body);
  }

  return @sec2;
}


# generate a single-entry RSS file with an inline image.
#
sub do_eyesore($$) {
  my ($url, $html) = @_;

  $_ = $html;

  1 while (s@<!--.*?-->@ @gsi);  # lose comments
  s@\s+@ @gsi;

  s@^.*Eyesore of the Month.*?</h2>@@si;
  s@\bPrevious Eyesore.*$@@si;
  s@</?(font|strong|div|blockquote)\b[^<>]*>@@gsi;
  s@</?p\b[^<>]*>@<p>@gsi;
  s@&nbsp;@ @gi;
  s@<br>@<p>@gsi;
  s@<a\b[^<>]*>\s*$@@gsi;

  my ($name) = m@src=\"(eyesore_[a-z\d]+)\.jpg@si;
  my $eurl = $url;
  $eurl =~ s@/[^/]+$@/$name.html@;

  return ($eurl, '', '', $_);
}


# generate a single-entry RSS file with an inline image.
#
sub do_pennyarcade($$) {
  my ($url, $html) = @_;

  my ($title) = ($html =~ m@<title>([^<>]*)</title>@si);
  my ($yyyy, $mm, $dd) = ($html =~ m@ value="(\d{4})(\d\d)(\d\d)"@si);
  my $href = sprintf ("/comic/%d/%d/%d/", $yyyy, $mm, $dd);

  $title =~ s@Penny Arcade! - @@si;

  $html =~ s@^.*<div class="title">@@si;
  $html =~ s@<div class="clear">.*$@@si;
  $html =~ s@</?div[^<>]*>@ @gsi;
  $html =~ s@\s+@ @gsi;

  return ($href, '', $title, $html);
}


sub do_oglaf($$) {
  my ($url, $html) = @_;

  my @secs = split(m/<item>/, $html);
  shift @secs;
  my @sec2;
  foreach my $item (@secs) {

    my ($title) = ($item =~ m@<title>([^<>]*)</title>@si);
    my ($href)  = ($item =~ m@<link>([^<>]*)</link>@si);
    next unless $href;
    my $img = $href;
    $img =~ s@/([^/]+)\.html/?$@/media/comic/$1.jpg@gsi;  # old style
    $img =~ s@/([^/]+)/(\d+)/$@/media/comic/$1$2.jpg@si;  # new style
    $img =~ s/[-_]+//gsi;

    $img =~ s@/([^/]+)/epilogue(\d+)/$@/media/comic/$1_epi$2.jpg@si;  # wtf
    $img =~ s@/([^/]+)/epilogue/$@/media/comic/$1_epi1.jpg@si;

    # Can't fix:
    # http://oglaf.com/human-women/1/
    # http://oglaf.com/potion/1/
    # http://oglaf.com/emancipation/1/
    # http://oglaf.com/cavalcade.html
    # http://oglaf.com/bliss.html
    # http://oglaf.com/sonofkronar1.html
    # http://oglaf.com/sonofkronar2.html
    # http://oglaf.com/alsoelves.html
    # http://oglaf.com/freshhorses1.html
    # http://oglaf.com/100_eyes2.html
    # http://oglaf.com/100_eyes1.html
    # http://oglaf.com/booklove4.html
    # http://oglaf.com/booklove3.html
    # http://oglaf.com/booklove2.html
    # http://oglaf.com/booklove1.html

    my $body = "<a href=\"$href\"><img src=\"$img\"></a>";
    my $date = '';
    $title = "Oglaf: $title";
    push @sec2, ($href, $date, $title, $body);
  }
  return @sec2;
}


sub do_yelp($$) {
  my ($url, $html) = @_;

  $_ = $html;
  1 while (s@<!--.*?-->@ @gsi);  # lose comments

  s/\s+/ /gs;
  # There seem to be several random ways they are delimited/marked up.
  s@(<[^<>]*?class=\"review[ \"])@\n$1@gs;
  s@(<li id=\"review_)@\n$1@gs;

  my $now = time();

  my @sec1 = split (/\n/s);
  my @sec2 = ();
  shift @sec1;
  foreach (@sec1) {

    next if (m/^\s*$/s);

    next if (m/>Start your review of/s);

#   my ($id) = m@id="review_([a-zA-Z\d]{2,})@s;
#   my ($href) = (m@<a class=\"linkToThis\" .*?href=\"([^<>\"]+)@si);
    my ($href) = (m@\bhref=\"(/biz/[-a-z\d]+\#hrid:[-_a-zA-Z\d]{20,})\"@si);
    if (! $href) {
      ($href) = (m@return_url=([^\"]*?%2Fbiz%2F[^\"]+?reviewid=[^\"]+)@si);
      $href = url_unquote (html_unquote ($href)) if $href;
    }
    if (! $href) {
      my ($id) = m@/review/([-_a-zA-Z\d]{10,})@s;
      my ($u2) = ($url =~ m/^(.*?)\?/s);
      $href = "$u2?hrid=$id" if $id;
    }

    next unless $href; ####
    error ("yelp: no href\n$_") unless $href;

    my ($title) = (m@>(Review from .*?)</@si);
    if (! $title) {
      ($title) = (m@itemprop="author".*?content="([^\"]+)"@si);
      $title = "Review from $title" if $title;
    }
    my ($date)  = (m@content="(\d{4}-\d\d-\d\d)"@si);
    $title =~ s@<.*?>@@gsi;

    my ($yyyy, $mm, $dd) = ($date =~ m/^(\d{4})-(\d\d)-(\d\d)$/s);
    error ("unparsable date: $date") unless $dd;
    my $etime = mktime (0, 0, 0, $dd, $mm-1, $yyyy-1900, 0, 0, -1);

    # Ignore everything older than 2 weeks
    my $skip_p = ($etime < $now - (60 * 60 * 24 * 14));
    $skip_p = 0 unless @sec2; # But keep at least one, or we get a warning.
    if ($skip_p) {
      print STDERR "$progname: skipping old entry: $date ($title)\n" 
        if ($verbose);
      next;
    }

    my ($rating) = (m@alt=\"([^\s]+ star rating)\"@si);
    $title .= " -- $rating";

    s@<div class=\"rateReview.*$@@si;
    s@<img[^<>]*?stars_map[^<>]*>@ @gsi;

    1 while (s@(<[^<>]*?)\s+(class|id|style|title)=\"[^\"]*\"@$1@gsi);
    s@ href=\"#[^\"]+\"@@gsi;
    s@</?(ul|li|span|div)\s*>@ @gsi;
    s@&nbsp;@ @gs;
    s@[\240\302]@ @gs;
    s@<([a-z\d]+)\s*>\s*</\1>@ @gsi;
    s@<a>(.*?)</a>@$1@gsi;
    s@<h4>.*?</h4>@$title\n<P>@gsi;

    s@<img[^<>]*?(SRC=[\\\"'].*?[\\\"'])[^<>]*>@
      <IMG $1 style="float:left; margin: 0 2em 1em 0;">@gsix;
    s@/ss\.jpg@/m.jpg@gs;

    $href = expand_url  ($href, $url);
    $_ = "<A HREF=\"$href\">$href</A>\n\n<P>$_";

    s@</?(li|div|meta)\b[^<>]*>@@gsi;
    s@(<(p)\b)[^<>]*>@$1>@gsi;

    s/\s+/ /gsi;
    my $body = $_;

    push @sec2, ($href, $date, $title, $body);
  }

  error ("no yelp entries parsed") unless @sec2;

  return @sec2;
}


# Bah, this doesn't work.
sub do_postmusic($$) {
  my ($url, $html) = @_;

  my ($url2, $title) = 
    ($html =~ m@<a href=\"([^\"]+)\" rel="bookmark" title=\"([^\"]+)\"@si);
  $title =~ s/^Permanent Link to //s;

  my $body = '';
  $html =~ s@\b(https?://[a-z.]*(youtube|vimeo)\.com/[^\'\"\s]+)@{
    my $url = html_unquote($1);
    my ($id) = ($url =~ m!(?:v=|/v/|vimeo\.com/)([^?&/]+)!si);
    my $url2 = ($url =~ m/youtube\.com/si
                ? "http://www.youtube.com/embed/$id"
                : "http://player/vimeo.com/video/$id");
    $body .= "<IFRAME WIDTH=560 HEIGHT=315 SRC=\"$url2\" ALLOWFULLSCREEN>" .
             "</IFRAME><P>\n";
    "";
  }@gsexi;
  my $date = '';
  return ($url2, $date, $title, $body);
}



sub do_quietus($$) {
  my ($url, $html) = @_;

  # it's actually RSS, not HTML
  $_ = $html;

  s/^.*?<entry>//si;

  my ($eurl) = (m@<link.*?href="(.*?)"@si);
  error ("no url") unless $eurl;

  $html = pull_html_cache($url, $eurl);

  my ($title) = ($html =~ m@<title>(.*?)</title>@si);
  my $date = '';

  $html =~ s@<SCRIPT[^<>]*>.*?</SCRIPT>@@gsi;
  $html =~ s@^.*<!--\s+Article Start\s*-->@@gsi;
  $html =~ s@<!--\s+Article End\s*-->.*$@@gsi;
  $html =~ s@class=".*?"@@gs;
  $html = expand_urls ($html, $eurl);

  return ($eurl, $date, $title, $html);
}


sub do_instagram_json($$) {
  my ($url, $html) = @_;

  # it's actually JSON, not HTML
  $_ = $html;

  s/("link")/\001$1/gs;
  my @chunks = split(/\001/, $_);
  shift @chunks;

  my @sec = ();
  foreach (@chunks) {
    s/\\//gs;
    my ($href) = m/"link":\s*"(.*?)"/s;
    my ($img) = m/"standard_resolution":{"url":\s*"(.*?)"/s;
       ($img) = m/"url":\s*"(.*?)"/s unless $url;
    my ($title) = m/"caption":{[^{}]*?"text":"(.*?)"/si;
    my ($date) = m/"caption":{[^{}]*"created_time":"(.*?)"/si;
    my ($user) = m/"username":"(.*?)"/si;
    my ($name) = m/"full_name":"(.*?)"/si;
    next unless ($url && $img);
    $date = strftime ("%a, %e %b %Y %H:%M:%S GMT", gmtime ($date))
      if $date;
    $name = "$user ($name)" if $user;
    $title = "$name: $title" if $name;
    my $body = "<A HREF=\"$href\"><IMG SRC=\"$img\"></A>";
    $body = expand_urls ($body, $href);
    push @sec, ($href, $date, $title, $body);
  }

  return @sec;
}


sub do_instagram_rss($$) {
  my ($url, $html) = @_;

  # it's actually JSON, not HTML
  $_ = $html;

  s/(<item)/\001$1/gs;
  my @chunks = split(/\001/, $_);
  shift @chunks;

  my @sec = ();
  foreach (@chunks) {
    my ($title) = m/<title>(.*?)</si;
    my ($name)  = m/<media:credit role="photographer">(.*?)</si;
    my ($img)   = m/<link>(.*?)</si;
    my ($date)  = m/<pubDate>(.*?)</si;
    my $href = $img;
    next unless $img;

    $title = "$name: $title" if $name;
    my $body = "<A HREF=\"$href\"><IMG SRC=\"$img\"></A>";
    $body = expand_urls ($body, $href);
    push @sec, ($href, $date, $title, $body);
  }

  return @sec;
}




#############################################################################
#
# Command line and glue.
#
#############################################################################


sub usage() {
  print STDERR "usage: $progname [--verbose] [urls...]\n";
  exit 1;
}

sub main() {
  my @urls = ();
  my $file = undef;
  while ($_ = $ARGV[0]) {
    shift @ARGV;
    if ($_ eq "--verbose") { $verbose++; }
    elsif (m/^-v+$/) { $verbose += length($_)-1; }
    elsif (m/^-./) { usage; }
    elsif (m/^https?:/) { push @urls, $_; }
    else { usage; }
  }

  usage unless ($#urls >= 0);

  error "$rss_output_dir: output directory does not exist"
    unless (-d $rss_output_dir);
  error "$html_cache_dir: cache directory does not exist"
    unless (-d $html_cache_dir);

  my $err_count = 0;
  foreach (@urls) {
    $err_count += scrape ($_);
  }
  exit ($err_count);
}

main;
exit 0;
