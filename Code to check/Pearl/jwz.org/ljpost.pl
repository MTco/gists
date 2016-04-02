#!/opt/local/bin/perl -w
# Copyright © 2008-2016 Jamie Zawinski <jwz@jwz.org>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or 
# implied warranty.

# ===========================================================================
#
# This is how I post to my blog via email.  It takes an incoming mail
# message, extracts the images and saves them to a directory of your
# choice, then constructs HTML from those images and the rest of the
# message, and posts that.  If there are images and they have location
# data in them, it marks the post with that location.  It also allows
# you to write your text using Markdown instead of HTML.
#
# Attached images are resized, thumbnailed, and hosted on your own server.
# The code supports posting to WordPress, Twitter and/or Livejournal.
# (Hey, remember when Livejournal existed?  This code is old.)
#
# It also handles attached videos, saving them locally and embedding them
# with <OBJECT>.  (Posting them to Youtube first would be preferable, but
# that's not implemented.)
#
# ===========================================================================
# Installation:
# ===========================================================================
#
# When the mail server runs this script, you need to arrange for it to run
# as a user who can create files in $image_dir.  To make this work with
# Postfix:
#
#   /etc/postfix/main.cf:
#     alias_maps     = hash:/etc/aliases, hash:/etc/postfix/aliases-jwz
#     alias_database = hash:/etc/aliases, hash:/etc/postfix/aliases-jwz
#
#   /etc/postfix/aliases-jwz:
#     post-wp:   "|/Users/jwz/www/hacks/ljpost.pl --wp USER"
#     post-twit: "|/Users/jwz/www/hacks/ljpost.pl --twit USER"
#
#   chown root:wheel /etc/postfix/aliases-jwz*
#   newaliases
#   chown jwz /etc/postfix/aliases-jwz*
#     (this must be done after newaliases!)
#
#
# To post, you would send email to the address "ljpost+XYZ@example.com"
# where "XYZ" is the password in "~/.ljpost-pass" on the server.  Keep
# that secret, as anyone who knows it can post as you.  However, if you
# trust the sanctity of your address book, you might want to save it there.
#
#
# ===========================================================================
# Configuration:
# ===========================================================================
#
# To post to a WordPress blog, invoke this script with "--wp WPUSER".
# This will run my "wppost.php" script to do the actual hosting (which see).
# This assumes that your blog is on the same host as your mail server;
# and that the user this script is running as has access to WordPress's
# SQL database.
#
# To post to LiveJournal, set up "post by email" on LJ and invoke this
# script with "--lj LJUSER".  To post to a Livejournal community instead
# of a user account, use "--lj LJUSER.COMMUNITY".
#
# To post to Twitter, use "--twit TWITUSER".  It will convert HTML to
# plain text and truncate things sensibly.
#
# The password that protects *this* script is read from ~/.ljpost-pass.
#
# The password for the LJ account for user FOO is read from ~/.FOO-lj-pass.
# Likewise, the Twitter API keys are read from ~/.FOO-twitter-pass.
#
# All of those files should be readable by the user running this script
# and nobody else, so make them have the proper owner and "chmod og-w".
#
# The twitter-pass file needs to have four lines in it, the keys needed to
# drive your Twitter API Oauth Application thingy (see dev.twitter.com).
#
#    consumer        = ...DATA...
#    consumer_secret = ...DATA...
#    access          = ...DATA...
#    access_secret   = ...DATA...
# 
# Created: 27-Apr-2008.
#
# ===========================================================================


require 5;
use diagnostics;
use strict;

use POSIX;
use MIME::Parser;
use MIME::Entity;
use Encode qw/decode/;
use Image::Magick;
use Text::Markdown;
BEGIN { eval 'use Net::Twitter;' }	# Optional


my $progname = $0; $progname =~ s@.*/@@g;
my ($version) = ('$Revision: 1.107 $' =~ m/\s(\d[.\d]+)\s/s);

$ENV{PATH} = "/opt/local/bin:$ENV{PATH}";   # macports

my $verbose = 0;
my $debug_p = 0;

my $image_max_size = 1024;   # create a thumb if bigger than this.


my $image_quality = 95;
my $image_dir     = '/home/jwz/www/images';
my $image_url     = 'https://www.jwz.org/images/';

my $exec_dir      = $0; $exec_dir =~ s@/[^/]+$@@s;
my $wp_post	  = "$exec_dir/wppost.php";

# What directory do you need to be in for wppost.php to work?
my $wp_dir = $ENV{HOME} . "/www/blog";


my $default_lj_tags       = 'firstperson';
my $default_lj_photo_tags = 'photography';


my $sendmail = "/usr/sbin/sendmail -t -oi";


sub url_quote($) {
  my ($u) = @_;
  $u =~ s|([^-a-zA-Z0-9.\@/_\r\n])|sprintf("%%%02X", ord($1))|ge;
  return $u;
}

sub url_unquote($) {
  my ($u) = @_;
  $u =~ s/[+]/ /g;
  $u =~ s/%([a-z0-9]{2})/chr(hex($1))/ige;
  return $u;
}

sub html_quote($) {
  my ($u) = @_;
  $u =~ s/&/&amp;/g;
  $u =~ s/</&lt;/g;
  $u =~ s/>/&gt;/g;
#  $u =~ s/\"/&quot;/g;
  return $u;
}

# Check and print error status from various Image::Magick commands,
# and die if it's not just a warning.
#
sub imagemagick_check_error($) {
  my ($err) = @_;
  return unless $err;
  my ($n) = ($err =~ m/(\d+)/);

  if ($n && $n == 395 && $err =~ m/unable to open module file/) {
    #
    # This error is bullshit: ignore it:
    #
    #    Exception 395: unable to open module file
    #      `/opt/local/lib/ImageMagick-6.3.0/modules-Q16/coders/008d1bed.la':
    #      No such file or directory
    #
    return;
  }

  print STDERR "$progname: $err\n";
  print STDERR "$progname: maybe \$TMPDIR (".
               ($ENV{TMPDIR} || "/tmp") . ") filled up?\n"
    if ($err =~ m/pixel cache/i);

  exit (1) if ($n >= 400);
}


sub img_loc($) {
  my ($img) = @_;
  my $loc = sprintf ("%s %s, %s %s",
           $img->Get('EXIF:GPSLatitude'),  $img->Get('EXIF:GPSLatitudeRef'),
           $img->Get('EXIF:GPSLongitude'), $img->Get('EXIF:GPSLongitudeRef'));

  # For some insane reason, ImageMagick reports GPS coordinates like this:
  #
  #   37/1, 4625/100, 0/1 N, 122/1, 2477/100, 0/1 W
  #
  # This regexp converts that to
  #
  #   37.770833 N, 122.412833 W
  #
  $loc =~ s@\b (\d+) / (\d+), \s+
               (\d+) / (\d+), \s+
               (\d+) / (\d+)  \b
           @{ sprintf ("%.6f",
                       ($1 / $2) +
                       ($3 / $4 / 60) +
                       ($5 / $6 / 3600));
            }@gsex;

  $loc =~ s/(^\s+|\s+$)//gs;
  $loc = undef unless ($loc =~ m/\d/);  # Avoid ", ".
  $loc = undef unless $loc;
  return $loc;
}


sub geofence($$$) {
  my ($user, $img, $name) = @_;
  my $loc = img_loc ($img);

  return unless $loc;

  my ($tags, $page) = location_tags ($user, $loc);

  return unless $page;
  return unless ($page =~ m/\bGEOFENCE\b/si);

  # Really I just want to clear GPS, but that doesn't work:
  #
  foreach my $k ('exif:GPSAltitude',
                 'exif:GPSAltitudeRef',
                 'exif:GPSDestBearing',
                 'exif:GPSDestBearingRef',
                 'exif:GPSImgDirection',
                 'exif:GPSImgDirectionRef',
                 'exif:GPSInfo',
                 'exif:GPSLatitude',
                 'exif:GPSLatitudeRef',
                 'exif:GPSLongitude',
                 'exif:GPSLongitudeRef',
                 'exif:GPSSpeed',
                 'exif:GPSSpeedRef',
                 'exif:GPSTimeStamp') {
    $img->Set($k, '');
  }

  # So instead I have to clear everything:
  #
  $img->Strip();

  print STDERR "$progname: $name: geofence cleared: $loc\n"
    if $verbose;
}


sub save_image($$$$) {
  my ($user, $name, $ct, $data) = @_;

  $name = lc($name);
  $name =~ s/[^-_.a-z\d]/_/gsi;  # map stupid characters to underscores

  # "Photo 1.jpg" => "photo.jpg", since iPhone 3.x always names the first
  # attachment "Photo.jpg", the second "Photo 2.jpg", etc.  This numbers
  # them in order ("photo_37.jpg", "photo_38.jpg") instead of in a dumb
  # order like e.g. "photo-37.jpg", "photo_2-14.jpg".
  #
  # Likewise, iPhone 4.x names them "image.jpeg".
  # OSX Mail.app sometimes names them "JPG.JPG"!
  #
  # Oh and sometimes we get "fullsizerender", if it has been edited.
  #
  if (! $debug_p) {
    $name =~ s/^(image|jpe?g|fullsizerender)\./photo./si;
    $name =~ s/^(photo)[-_]*\d*(\.[a-z]+)$/$1$2/gsi;
    $name =~ s/\.p?jpe?g$/.jpg/si;
  }

  my $video_p = ($ct =~ m@^video/@si);

  my ($img, $fw, $fh);
  if ($video_p) {
    ($fw, $fh) = (320, 240);	#### Wild-assed guess.
    $img = undef;
  } else {
    $img = Image::Magick->new;
    $img->BlobToImage ($data);
    geofence ($user, $img, $name);
    ($fw, $fh) = $img->Get ('width', 'height');
    error ("$name: unparsable") unless ($fw > 0 && $fh > 0);
    $data = $img->ImageToBlob();
  }

  my ($w, $h) = ($fw, $fh);

  my $big = $name;

  # Add a numeric suffix before the extension until we have a unique one.
  #
  while (-f "$image_dir/$big") {
    my ($head, $n, $tail) = ($big =~ m@^(.*?)(-\d+)?(\.[^.]+)$@s);
    $n = ($n || 0) - 1;
    $big = "$head$n$tail";
  }
#  error ("$image_dir/$big already exists")
#    if (-f "$image_dir/$big" && !$debug_p);

  my $file = "$image_dir/$big";

  if ($debug_p) {
    print STDERR "$progname: not writing $file ($w x $h)\n"
      if ($verbose);

    $file = sprintf ("%s/msg%08x", ($ENV{TMPDIR} || "/tmp"),
                     rand(0xFFFFFFFF));
    unlink $file;
  }

  umask 022;
  open (my $out, '>', "$file") || error ("$big: $!");
  (print $out $data)           || error ("$big: $!");
  close $out                   || error ("$big: $!");
  print STDERR "$progname: $name: wrote $file ($w x $h)\n" 
    if ($verbose);


  #
  # Extract the GPS location from the image.
  #
  my $loc = img_loc ($img) if $img;

  print STDERR "$progname: $name: location: $loc\n" if $loc;


  #
  # Rotate the image according to EXIF orientation.
  # (Note that this doesn't rotate the EXIM thumbnail.)
  #

  if ($img) {
    my ($orient) = $img->Get('exif:orientation');
    $orient = 1 unless defined($orient); # Top-Left
    if ($orient != 1) {
      print STDERR "$progname: $name: auto-rotating orient=$orient\n"
        if ($verbose);
      my $status = $img->AutoOrient();
      imagemagick_check_error ($status);

      my ($nw, $nh) = $img->Get ('width', 'height');
      if ($nw != $fw || $nh != $fh) {
        print STDERR "$progname: $name: rotated: ${fw}x$fh => ${nw}x$nh\n"
          if ($verbose);
        ($fw, $fh) = ($nw, $nh);
        ($w, $h)   = ($fw, $fh);
      } elsif ($verbose) {
        print STDERR "$progname: $name: size unchanged\n";
      }
    }
  }

  unlink $file if $debug_p;


  #
  # Create a second file to use as a thumbnail image, if the original
  # is big.
  #

  my $thumb = $big;
  if ($img &&
      ($fw > $image_max_size || $fh > $image_max_size)) {

    $thumb =~ s/(\.[^.]+)$/-thumb$1/s;
    error ("$thumb already exists")
      if (-f "$image_dir/$thumb" && !$debug_p);

    my $wscale = $image_max_size / $fw;
    my $hscale = $image_max_size / $fh;
    my $scale = ($wscale < $hscale ? $wscale : $hscale);
    my $status = $img->Scale (width  => int ($fw * $scale),
                              height => int ($fh * $scale));
    imagemagick_check_error ($status);
    $status = $img->Set (quality => $image_quality);
    imagemagick_check_error ($status);

    ($w, $h) = $img->Get ('width', 'height');
    error ("$thumb: resize didn't work") unless ($w > 0 && $h > 0);

    if ($debug_p) {
      print STDERR "$progname: not writing $image_dir/$thumb ($w x $h)\n"
        if ($verbose);
    } else {
      $status = $img->Write (filename => "$image_dir/$thumb");
      imagemagick_check_error ($status);

      print STDERR "$progname: wrote $image_dir/$thumb ($w x $h)\n" 
        if ($verbose);
    }
  }

  undef $img;

  $big   = $image_url . url_quote($big);
  $thumb = $image_url . url_quote($thumb);

  return ($big, $thumb, $w, $h, $loc);
}


sub trim_signature($) {
  my ($s) = @_;

  if ($s =~ s@<span id="signature".*?</span>@@si) {
    $s =~ s@\s*(<(p|br)>\s*)+$@@si;
  } elsif ($s =~ s@<br>\s*<br>\s*--\s*<br>.*$@@si) {
  } else {
    $s =~ s/(^|\n)-- *\n.*$//s;
    $s = '' if ($s =~ m/^\s+$/s);
  }
  return $s;
}


# Extend Markdown's syntax with two additional ways of typing links.
#
sub jwz_markdown($) {
  my ($md) = @_;

  # If there is a URL following a bracketed phrase, convert it from
  # "abc[def]ghi URL" to "abc[def](URL)ghi".  Be careful not to mess
  # with text already in "[anchor](URL)" form.
  #
  $md =~ s@ ( \[ [^][]+ \] )					# 1 [anchor]
            ( [^(] )						# 2 not (
            ( [^][()]*? )					# 3 stuff
            \b ((https?|mailto)://[^\s\[\]()<>\"\']+[a-z\d/])	# 4 url
            @$1($4)$2$3@gsix;

  # If there is a naked URL (not in parens) convert it to be a markdown
  # anchor on the preceding text on the source line, e.g.,
  # "abc def! URL ghi" => "[abc def](URL)! ghi".
  #
  $md =~ s@ ^[ \t]*
	     (.*?)						# 1 anchor
	     ([^a-z\d\s*;]*)[ \t]+				# 2 punc.
            \b ((https?|mailto)://[^\s\[\]()<>\"\']+[a-z\d/])	# 3 url
            @[$1]($3)$2@gmix;

  # Now process everything else using the normal Markdown rules.
  #
  return Text::Markdown::markdown($md);
}


sub split_tag_headers($) {
  my ($txt) = @_;
  my $head = '';
  my $tags = '';
  $txt =~ s/^\s*//s;
  if ($txt =~ m/^ ( (?: \s* <[^<>]*> )+ ) ( .* )$/six) {
    ($head, $txt) = ($1, $2);
  }
  while ($txt =~ m/^ ( (?: lj-)? (?: tags?|security) : [^\n]* \n ) (.*) $/six) {
    $tags .= $1;
    $txt = $2;
  }

  $txt = $head . $txt;
  return ($tags, $txt);
}


sub clean_html($) {
  my ($html) = @_;

  # Lose the multipart/related inline image stubs: we handle images manually.
  $html =~ s@<img\s+src="cid:[^<>]*>\s*@@gsi;

  # What I would like is: if I have typed Markdown text into the mail 
  # composition window, but the app has chosen to send that as HTML,
  # interpret it as Markdown anyway -- but, if there happens to be
  # "real" HTML in there (<B> or whatnot) then pass that through.
  #
  # But, the HTML generated by the iPhone is just too much of a pain
  # in the ass to deal with, so instead, we'll just convert the HTML
  # to plain-text and then interpret *that* as Markdown.  This means
  # that if you type raw HTML into the compose window, it will work,
  # but if you use a rich-text editor or cut-and-paste from a web
  # browser, it will strip out the markup.  Oh well, I can live with
  # that.

  $html = html_to_text($html);
  $html = trim_signature($html);

  my $tags;
  ($tags, $html) = split_tag_headers ($html);

  $html = jwz_markdown ($html);

  $html =~ s@\s*</P>\s*@<P>@gsi;
  $html =~ s@(\s*<P>)+@<P>@gsi;

  $html = "$tags\n$html" if $tags;

  return $html;
}


sub html_to_text($) {
  my ($html) = @_;
  my $txt = $html;
  $txt =~ s/&nbsp;/ /gs;
  $txt =~ s/\s+/ /g;
  $txt =~ s@</DIV>\s*<DIV>@\n@gsi;	             # join adjascent DIVs
  $txt =~ s@[ \t]*</?\s*P\b[^<>]*>[ \t]*@\n\n@gsi;   # <P>
  $txt =~ s@[ \t]*</?\s*BR\b[^<>]*>[ \t]*@\n@gsi;    # <BR>
  $txt =~ s@[ \t]*</?\s*DIV\b[^<>]*>[ \t]*@\n@gsi;   # <DIV>

  $txt =~ s@\s*<IMG[^<>]*?SRC=[\"']?([^<>\"']+)[^<>]*>\s*@ $1 @gsi;  # <IMG SRC
# $txt =~ s@\s*<A[^<>]*?HREF=[\"']?([^<>\"']+)[^<>]*>\s*@ $1 @gsi;   # <A HREF

  $txt =~ s@<[^<>]*>@@gs;  # all other tags

  $txt =~ s@&lt;@<@gs;
  $txt =~ s@&gt;@>@gs;
  $txt =~ s@&nbsp;@ @gs;
  $txt =~ s@&amp;@&@gs;

  return $txt;
}


# Run the URL through http://tinyurl.com/ and return the shortened one.
#
#sub tinyurlify($) {
#  my ($url) = @_;
#  return $url if ($url =~ m@^https?://tinyurl@s);
#  my $ua = LWP::UserAgent->new;
#  $ua->agent ("$progname/$version");
#
#  # See if the URL has a <LINK REL="shortlink"> tag.
#  # (This doesn't work if there's an #anchor).
#  if ($url !~ m/#/s) {
#    my $body = LWP::Simple::get($url) || '';
#    if ($body =~ m@<LINK\b [^<>]*? \b REL \s* = \s* [\"\']? shortlink [\"\']?
#                   [^<>]*? \b HREF \s* = \s* [\"\']? ([^\"\'<>]+)@six) {
#      return $1 if (length ($1) < length($body));
#    }
#  }
#
#  # Otherwise use tinyurl.com.
#  # For some reason we have to post for it to preserve the #anchor in the URL.
#  my $res = $ua->post ('http://tinyurl.com/api-create.php',
#                      { 'url' => $url });
#  my $url2 = ($res->is_success ? $res->decoded_content : '');
#  print STDERR "tinyurl: $url\n     ==> $url2\n" if ($verbose);
#  return $url unless $url2;
#  return $url2 if (length($url2) < length($url));
#  return $url;
#}


# Run URLs in the text through http://tinyurl.com/ until the text is less
# than 140 characters.  Only shrink URLs until the text is short enough;
# leave remaining URLs un-shrunk as soon as the text is short enough.
#
# Mar 2016: This is no longer helpful, because now Twitter expands those
# urls and deducts the full URL length against our 140 characters anyway.
# Dicks.
#
#sub shorten_urls($) {
#  my ($txt) = @_;
#
#  my $max_length = 140 - 10;	# slack for re-twits
#  #$max_length = 10;		# always shrink 'em
#
#  return $txt if (length($txt) <= $max_length);
#
#  my @chunks = split(m@(\bhttps?://[^\s<>]+[A-Za-z\d/])@s, $txt);
#  foreach my $chunk (@chunks) {
#    next unless ($chunk =~ m@^https?://@s);
#    $chunk = tinyurlify ($chunk);
#
#    $txt = join ('', @chunks);
#    last if (length($txt) <= $max_length);
#  }
#
#  return $txt;
#}


# Returns the distance between two lat/long coords in meters.
#
sub lat_long_distance($$$$) {
  my ($lat1, $lon1, $lat2, $lon2) = @_;

  sub deg2rad($) {
    my ($d) = @_;
    my $pi = 3.141592653589793;
    return $d * $pi / 180;
  }

  my $dlat = deg2rad($lat2-$lat1);
  my $dlon = deg2rad($lon2-$lon1); 
  my $a = (sin($dlat/2) * sin($dlat/2) +
           cos(deg2rad($lat1)) * cos(deg2rad($lat2)) * 
           sin($dlon/2) * sin($dlon/2));
  my $c = 2 * atan2(sqrt($a), sqrt(1-$a)); 
  my $R = 6371;            # radius of Earth in KM
  my $d = $R * $c * 1000;  # distance in M
  return $d;
}


# The ~/.$USER-facebook-places file contains a map of lat/long coords
# and radius in meters to Facebook page names, and to tags, e.g.,
#
#   37.771007, -122.412694  50	dnalounge	music, sf, dnalounge
#   37.771500, -122.413167  50	slimssf		music, sf
#   37.808167, -122.270667  50	pages/Fox-Oakland-Theatre/119932041386403 music
#
# If the lat/long of this post are within the radius of any of those
# coordinates, then the post will have those tags added. First match wins.
#
# This file doesn't use the FB places, but fbmirror.pl does.
#
sub location_tags($$) {
  my ($app, $loc) = @_;

  return unless $loc;

  # Convert "122.412694 W" to "-122.412694".
  $loc =~ s@\b(\d+\.\d+)\s*([NSEW])\b@{ my ($n, $c) = ($1, uc($2));
                                        $n = -$n if ($c eq 'S' || $c eq 'W');
                                        "$n"; }@gsexi;

  my ($lat, $lon) = ($loc =~ m@^ \s* ( -? \d+ [.\d]+ ) [\s,;]+
				     ( -? \d+ [.\d]+ ) \s* $
			      @six);
  error ("unparsable: $loc") unless ($lat || $lon);

  my $file = "$ENV{HOME}/.$app-facebook-places";
  return unless open (my $in, '<', $file);

  print STDERR "$progname: read $file\n" if ($verbose);
  my @places = ();
  while (<$in>) { 
    s/#.*$//s;
    s/\s*$//s;
    my ($lat2, $lon2, $r, $page, $tags) = m@^ \s* ( -? \d+ [.\d]* ) [\s,;]+
                                             ( -? \d+ [.\d]* ) \s+
                                             ( \d+ [.\d]* )    \s+
                                             ( [^\s]+ )
                                             (?: \s+ ( .*? ) \s* )?
                                            $@six;
    error ("$file: unparsable: $_") unless ($page);
    push @places, [ $lat2, $lon2, $r, $page, $tags ];
  }
  close $in;

  foreach my $p (@places) {
    my ($lat2, $lon2, $r, $page, $tags) = @$p;
    my $dist = lat_long_distance ($lat, $lon, $lat2, $lon2);
    if ($dist <= $r) {
      print STDERR "$progname: location: $page ($tags)\n" if ($verbose);
      return ( $tags, $page );
    }
  }
  return undef;
}


sub ljpost_1($$$$$$) {
  my ($user, $from, $subj, $loc, $pretty_loc, $html) = @_;

  my $tags;
  ($tags, $html) = split_tag_headers ($html);

  my $def =  $default_lj_tags;
  if ($html =~ m/<IMG/si) {
    $def .= ", " if $def;
    $def .= $default_lj_photo_tags;
  }

  my ($tags2, $page) = location_tags ($user, $loc) if $loc;
  $def .= ($def ? ", " : "") . $tags2
    if ($tags2);

  # Append default tags to existing tags header.
  if (! ($tags =~ s/^( (?: lj-)? tags?: [^\n]* )/$1, $def/six)) {
    # Or add the tag header if it didn't already exist.
    $tags .= "lj-tags: $def\n";
  }

  $tags .= "lj-location: $pretty_loc\n" if ($pretty_loc);
  $tags .= "lj-security: private\n" if ($debug_p);

  $tags =~ s/^\s+//s;

  return ($html, $tags);
}


sub ljpost($$$$$$) {
  my ($user, $from, $subj, $loc, $pretty_loc, $html) = @_;

  my $passfile = "$ENV{HOME}/.$user-lj-pass";
  my $pass = 'UNKNOWN';
  if (open (my $in, "<$passfile")) {
    $pass = <$in>;
    chop ($pass);
    close $in;
    error ("$passfile: no password") unless $pass;
  } elsif (!$debug_p) {
    error ("$passfile: $!");
  }

  my $tags;
  ($html, $tags) = ljpost_1 ($user, $from, $subj, $loc, $pretty_loc, $html);

  $html = "$tags\n$html" if $tags;

  # The HTML has to have long lines, since LJ interprets \n in HTML as BR.
  # Therefore, we need to QP-encode, else SMTP inserts random newlines.

  my $to = "${user}+${pass}\@post.livejournal.com";
  my $msg = MIME::Entity->build (Type     =>"text/html",
                                 Encoding => "quoted-printable",
                                 From     => $from,
                                 To       => $to,
                                 Subject  => $subj,
                                 Data     => $html);

  if ($debug_p) {
    print STDERR ("#" x 72) . "\nResultant message:\n" . ("#" x 72) . "\n";
    $msg->print(\*STDERR);
    print "\n";
  } else {
    open my $mail, "| $sendmail" || error ("sendmail: $!");
    $msg->print($mail);
    close $mail;
  }
}


sub wppost($$$$$$$) {
  my ($user, $from, $subj, $date, $loc, $pretty_loc, $html) = @_;

  my $tags;
  ($html, $tags) = ljpost_1 ($user, $from, $subj, $loc, $pretty_loc, $html);

  my $priv_p = ($tags && $tags =~ m/^(lj-)?security:/mi);

  if ($tags && $tags =~ s/^ (?:lj-)? tags?: \s* (.*?) \s* $/$1/mix) {
    $tags = $1;
  } else {
    $tags = undef;  # maybe other lj-crud, but not lj-tags.
  }

  my @cmd = ($wp_post, "--user", $user, "--body", $html);
  push @cmd, ("--subject", $subj) if $subj;
  push @cmd, ("--date", $date)    if $date;
  push @cmd, ("--tags", $tags)    if $tags;
  push @cmd, ("--draft")          if $priv_p;
  push @cmd, ("--location", $pretty_loc) if $pretty_loc;

  chdir ($wp_dir) || error ("cd $wp_dir/: $!")
    if defined ($wp_dir);

  if ($debug_p) {
    print STDERR ("#" x 72) . "\nWould have run:\n" . ("#" x 72) . "\n";
    foreach my $a (@cmd) {
      $a =~ s/^\s+|\s+$//gs;
      if ($a =~ m%[^-a-z\d/_.,]%si) {
        $a =~ s/'/\\'/gs;
        $a = "'$a'";
      }
    }
    print STDERR join(' ', @cmd) . "\n";
  } else {
    # Discard stdout since wppost prints the post-id.
    open (my $o, '>&', \*STDOUT);
    open (STDOUT, '>', '/dev/null') unless ($verbose);
    system (@cmd);
    open (STDOUT, '>&', $o);
  }
}



sub load_keys($) {
  my ($user) = @_;

  my $consumer        = 'UNKNOWN';
  my $consumer_secret = 'UNKNOWN';
  my $access          = 'UNKNOWN';
  my $access_secret   = 'UNKNOWN';

  # Read our twitter tokens
  my $twitter_pass_file = "$ENV{HOME}/.$user-twitter-pass";
  if (open (my $in, '<', $twitter_pass_file)) {
    print STDERR "$progname: read $twitter_pass_file\n" if ($verbose);
    while (<$in>) { 
      s/#.*$//s;
      if (m/^\s*$/s) {
      } elsif (m/^consumer\s*=\s*(.*?)\s*$/) { 
        $consumer = $1;
      } elsif (m/^consumer_secret\s*=\s*(.*?)\s*$/) { 
        $consumer_secret = $1;
      } elsif (m/^access\s*=\s*(.*?)\s*$/) { 
        $access = $1;
      } elsif (m/^access_secret\s*=\s*(.*?)\s*$/) { 
        $access_secret = $1;
      } else {
        error ("$twitter_pass_file: unparsable line: $_");
      }
    }
    close $in;

  } elsif ($debug_p) {
    print STDERR "$progname: $twitter_pass_file: $!\n";
  } else {
    error ("$twitter_pass_file: $!");
  }

  return ($consumer, $consumer_secret, $access, $access_secret);
}


# For shrinking twits until they fit.
# Take off the last word, leaving any trailing URLs.
#
sub remove_last_word($) {
  my ($text) = @_;
  my ($head, $tail) = ($text =~ m/^(.*?)((\s*https?:[^\s]+)*)$/si);
  $head =~ s/\s+[^\s]+[\s.]*$//s;
  $head .= '...' unless ($head =~ m/\.$/s);
  $text = $head . $tail;
  return $text;
}


sub twitter_status_update($$$$$) {
  my ($user, $txt, $lat, $long, $attach) = @_;

  my ($consumer, $consumer_secret, $access, $access_secret) = load_keys($user);

#  $txt = shorten_urls ($txt);
  print STDERR "$progname: twit [" . length($txt) . "]: $txt" .
        ($attach ? "[" . scalar(keys %$attach) . " imgs]" : "") .
        "\n"
    if ($verbose);

  my $nt = Net::Twitter->new (
      traits              => [qw/OAuth API::RESTv1_1 WrapError/],
      ssl		  => 1,  # Required as of 7-Jan-2014
      source              => '',
      consumer_key        => $consumer,
      consumer_secret     => $consumer_secret,
      access_token        => $access,
      access_token_secret => $access_secret,
  );

  my $retries = 8;
  my $start = time();
  my $err;
  for (my $i = 0; $i < $retries; $i++) {
    my %args;
    $args{status} = $txt;

    my $retry_delay = 4;

    if ($lat || $long) {
      $args{lat}  = $lat;
      $args{long} = $long;
      $args{display_coordinates} = 1;
    }

    # If we have an image, try to upload it and attach it to the twit.
    #
    my $count = 0;
    foreach my $url (keys %$attach) {
      my ($img_name) = ($url =~ m@^.*?([^/]+)$@si);
      my ($ct, $img_data) = @{$attach->{$url}};
      my $media = [ undef, $img_name,
                    Content_Type => $ct,
                    Content => $img_data ];

      if ($debug_p) {
        print STDERR "$progname: not uploading: $img_name (" .
          int(length($img_data) / 1024) . "K)\n";
      } else {
        my $ret = $nt->upload ($media);
        if ($ret && $ret->{media_id}) {
          my $id = $ret->{media_id};
          print STDERR "$progname: uploaded: $img_name (" .
                       int(length($img_data) / 1024) . "K, id = $id)\n"
              if ($verbose);
          $args{media_ids} = (($args{media_ids} ? $args{media_ids} . "," :"") .
                              $id);
        } else {
          $err = $nt->get_error();
          $err = (($err && $err->{error}) ||
                  ($err &&
                   $err->{errors} &&
                   $err->{errors}[0] &&
                   $err->{errors}[0]->{message}) ||
                  'no media_id returned');
          print STDERR "$progname: uploading $img_name: $err\n";
          $err = undef;
        }
      }

      last if (++$count > 4);  # Only 4 images allowed
    }

    if ($debug_p) {
      print STDERR "$progname: debug: not twitting: $user: $txt" .
                   " [$lat $long]\n";
      last;
    } else {
      my $ret = $nt->update (\%args);
      last if defined ($ret);
      $err = $nt->get_error();
      $err = (($err && $err->{error}) ||
              ($err &&
               $err->{errors} &&
               $err->{errors}[0] &&
               $err->{errors}[0]->{message}) ||
              'null response');

      # You fucking piece of shit. Twitter has lost the ability to do math,
      # and is now telling me that 120 character twits are over 140 characters.
      # I guess it's counting URLs differently, even if it is not actually
      # expanding them? Give me a fucking break.
      #
      if ($err && $err =~ m@ is over 140@si) {
        my $t2 = remove_last_word ($txt);
        if ($t2 ne $txt) {
          print STDERR "twitter: shrinking \"$txt\" to \"$t2\"\n"
            if $verbose;
          $txt = $t2;
          $args{status} = $txt;
          $retry_delay = 0;
          $retries++;
          $err = undef;
        }
      }
    }

    print STDERR "twitter: $err (retrying in $retry_delay secs)\n" 
      if ($err && $verbose);
    sleep ($retry_delay) if ($retry_delay);
  }
  my $elapsed = time() - $start;
  error ("twitter: $err (after $retries tries in $elapsed secs) [$txt]")
    if $err;
}


sub twit($$$$$$) {
  my ($user, $subj, $loc, $pretty_loc, $html, $attach) = @_;

  # If any files were attached, omit them from the HTML,
  # since we attach them to the twit.
  #
  foreach my $url (keys %$attach) {
    $html =~ s@<IMG\s+SRC=\"\Q$url\E\"[^<>]*>@@gs;
  }

  my $txt = html_to_text ($html);

  # Lose all newlines.
  $txt =~ s/\s+/ /gsi;
  $txt  =~ s/^\s+|\s+$//gsi;
  $subj =~ s/^\s+|\s+$//gsi;
  if ($subj) {
    $subj .= "." unless ($subj =~ m/[^\sA-Z\d]\s*$/si);
    $txt = "$subj $txt";
    $txt =~ s/\.\.\.+\s+\.+/.../g;  # conv "subj... ...body" to "subj... body"
  }
  $txt  =~ s/^\s+|\s+$//gsi;

#  $txt = shorten_urls ($txt);

  # Last resort: if the text is still too long, and there are URLs at the
  # end, truncate before the URLs instead of after.
  #
  1 while (length($txt) >= 140 &&
           $txt =~ s/^(.*?).((\s+https?:[^\s]+)+)\s*$/$1$2/s);

  # If that fails, just truncate.
  $txt =~ s/^(.{140}).*$/$1/si;


  my ($lat, $long);
  if ($loc) {
    # Convert "122.412694 W" to "-122.412694".
    $loc =~ s@\b(\d+\.\d+)\s*([NSEW])\b@{ my ($n, $c) = ($1, uc($2));
                                          $n = -$n if ($c eq 'S' || $c eq 'W');
                                          "$n"; }@gsexi;
    # Extract the two floats.
    ($lat, $long) = ($loc =~ m/^\s*(-?\d+\.\d+),?\s+(-?\d+\.\d+)\s*$/s);
  }

  twitter_status_update ($user, $txt,
                         $lat || '', $long || '',
                         $attach);
}


sub checkin($@) {
  my ($from, @files) = @_;

  my $files = join (' ', sort(@files));
####  return unless $files;

  # Fucking Apache. git needs this.
  $ENV{HOME} = ((getpwuid($<))[7]) unless ($ENV{HOME});

  my $q = ($verbose ? "" : "-q");
  my $cmd = join (" && ",
                  ("cd $image_dir",
                   "git add $files",
                   "git commit $q -m '$progname $version' $files",
                   "git push $q"));

  # Note: this fixed it: chown -R jwz /home/jwz/www/.git /cvsroot/jwz.git

  if ($debug_p) {
    print STDERR "$progname: not running: $cmd\n" if ($verbose);
  } else {
    print STDERR "$progname: exec: $cmd\n" if ($verbose);

    # If the command printed anything at all, email it back to me.

    my $result = `( $cmd ) 2>&1`;
    system ('logger', '-t', $progname, "exec: $cmd");
    if ($result) {
      print STDERR "$progname: ERROR: $result\n";
      system ('logger', '-t', $progname, $result);
      $from =~ s/[\r\n]*$//s;
      my $msg = ("From: $from\n" .
                 "To: $from\n" .
                 "Subject: $progname error\n" .
                 "\n" .
                 "+ $cmd\n\n" .
                 "$result\n\n");
      system ('logger', '-t', $progname, "MAIL [$sendmail] [$msg]"); ####

      open my $mail, "| $sendmail" || error ("sendmail: $!");
      print $mail $msg;
      close $mail;
    }
  }
}


# In a multipart/related, there will be an HTML part with IMG tags in it
# refering to "cid:" URLs, then a bunch of parts with those IDs.  This
# divides up the HTML part and interleaves the images in a list.  So
# we start with something like (HTML, IMG-1, IMG-2, IMG-3) and end up
# with (HTML-1, IMG-1, HTML-2, IMG-2, HTML-3, IMG-3, HTML-4).
#
sub splice_related($$) {
  my ($main, $imgs) = @_;

  my @result = ("");
  foreach my $s (split (m/(<IMG[^<>]*>)/si, $main)) {
    if ($s =~ m@^<img [^<>]*? \b src=[\"\'] cid: ([^\"\'<>]+) @six) {
      my $id = $1;
      my $img = $imgs->{$id};
      error ("unmatched cid: $id") unless $img;
      push @result, ($img, "");
    } else {
      $result[$#result] .= $s;
    }
  }
  return @result;
}


# Recursively processes the MIME::Entity, handling multipart entities.
# Returns a list of text-chunks and images, in the order encountered.
#
sub process_part($$@);
sub process_part($$@) {
  my ($part, $depth, @imgs) = @_;
  my $type = lc($part->effective_type);
  my $body = $part->bodyhandle;
  my @result = ();

  print STDERR "$progname: " . ("  " x $depth) .
    "Content-Type: $type\n" if ($verbose > 1);
  if ($type eq 'text/plain') {
    $body = html_quote($body->as_string());
    $body =~ s/\n/<BR>\n/gsi;
    $body .= "<P>\n";
    push @result, $body;

  } elsif ($type eq 'text/html') {
    $body = $body->as_string() . '<P>';
    push @result, $body;

  } elsif ($type =~ m@^(image|video)/@) {
    push @result, $part;

  } elsif ($type eq 'multipart/mixed') {
    foreach my $subpart ($part->parts) {
      push @result, process_part ($subpart, $depth+1, @imgs);
    }

  } elsif ($type eq 'multipart/related') {
    my $main;
    my %imgs;
    foreach my $subpart ($part->parts) {
      my @p = process_part ($subpart, $depth+1, @imgs);
      error ("unparsable $type") if ($#p != 0);
      my $p = $p[0];
      if (ref($p) =~ m/^MIME/s) {  # It's an image
        my $id = $subpart->head->get('Content-ID');
        error ("no Content-ID in $p") unless $id;
        $id =~ s/^[\s<]*|[\s>]*$//gsi;
        $imgs{$id} = $p;
      } elsif ($main) {
        error ("multiple roots in $type");
      } else {
        $main = $p;
      }
    }
    push @result, splice_related ($main, \%imgs);

  } elsif ($type eq 'multipart/alternative') {
    #
    # multipart/alternative types are sorted from least to most preferred.
    # Take the last one in the list that is plain-text, html, or an image.
    # Ignore all others.
    #
    my $prev = undef;
    foreach my $subpart ($part->parts) {
      my $subtype = lc($subpart->effective_type);
      print STDERR "$progname: " . ("  " x $depth) .
                   "Subtype: $subtype\n" if ($verbose > 1);
      if ($subtype =~ m@^text/(plain|html)$@ ||
          $subtype =~ m@^(image|multipart)/@) {
        $prev = $subpart;
      } else {
        print STDERR "$progname: " . ("  " x $depth) .
                     " SKIP: $subtype\n" if ($verbose > 1);
      }
    }
    error ("no known subtypes in $type") unless $prev;

    push @result, process_part ($prev, $depth+1, @imgs);

  } else {
    error ("unknown type $type");
  }

  return @result;
}



# If the HTML contains two or more, assume the layout is two per line.
# If any two on the same line mix portrait and landscape orientation,
# adjust their width percentages until they are roughly the same height.
#
sub adjust_image_layout($$) {
  my ($total_images, $html) = @_;

  $html =~ s@(</A>)\s*(<A)@$1\001$2@gs;
  my @imgs = split(/\001/, $html);

  my @sizes;
  my $i = 0;
  foreach my $img (@imgs) {
    my ($w) = ($img =~ m/max-width:\s*(\d+)px/si);
    my ($h) = ($img =~ m/max-height:\s*(\d+)px/si);
    $sizes[$i] = [$w, $h, ($w > $h)];
    $i++;
  }

  my $line_max = 0;
  for (my $j = 0; $j < $i; $j += 2) {
    my $w = (($sizes[$j][0]   || 0) +
             ($sizes[$j+1][0] || 0));
    $w += 8;  # margin
    $line_max = $w if ($w > $line_max);
  }

  $line_max = 1280 if ($line_max > 1280);

  for (my $j = 0; $j < $i; $j += 2) {

    if (! defined($imgs[$j+1])) {		# single image on line

      my $w = ($total_images == 1 ? 100 :	# only image on page
               $sizes[$j][2]      ? 65 :	# landscape, on last line
               50);				# portrait, on last line
      $imgs[$j] =~ s/(width:\s*)\d+%/$1${w}%/s;

    } elsif ($sizes[$j][2] != $sizes[$j+1][2]) {	# orientation differs
      my $r = ($sizes[$j][0] /				# ratio of scaled width
               ($sizes[$j][0] + 
                ($sizes[$j][1] * ($sizes[$j+1][0] / $sizes[$j+1][1]))));
      my $ww = 100;
      my $w1 = sprintf("%.1f", $ww * $r);
      my $w2 = sprintf("%.1f", $ww * (1 - $r));
      $imgs[$j]   =~ s/(width:\s*)\d+%/$1${w1}%/s;
      $imgs[$j+1] =~ s/(width:\s*)\d+%/$1${w2}%/s;

    } else {					# same orientation, same width
      my $w = 50;
      $imgs[$j]   =~ s/(width:\s*)\d+%/$1${w}%/s;
      $imgs[$j+1] =~ s/(width:\s*)\d+%/$1${w}%/s;
    }
  }

  if ($i > 1) {
    # Wrap each IMG in a DIV so that box-sizing works properly.
    # <img width=50%>   ==>   <div width=50%> <img width=100%> </div>
    #
    foreach my $img (@imgs) {
      my $img2 = $img;
      if ($img2 =~ s@\b(margin:)(\s*[^;\"\']+)@$1 0@s) {
        my $m = $2;
        if ($img2 =~ s@\b(width:)(\s*[^;\"\']+)@$1 100%@s) {
          my $w = $2;

          my ($mw) = ($img2 =~ m@max-width:\s*([^;\"\']+)@s);
          my ($mh) = ($img2 =~ m@max-height:\s*([^;\"\']+)@s);

          $img = "<DIV STYLE=\"display: inline-block;" .
                 " width: $w; box-sizing: border-box;" .
                 ($mw ? " max-width:$mw;"  : "") .
                 ($mh ? " max-height:$mh;" : "") .
                 " padding: $m;\">$img2</DIV>";
        }
      }
    }
  }

  my $imgs = join ('', @imgs);

  # If the window is super wide, don't let things get stupid.
  if ($i > 1 && $line_max) {
    $imgs = "<DIV STYLE=\"max-width:${line_max}px\">$imgs</DIV>";
  }

  return $imgs;
}


sub post($$$) {
  my ($lj, $wp, $twit) = @_;

  my $pass;
  my $passfile = "$ENV{HOME}/.ljpost-pass";
  if (open (my $in, "<$passfile")) {
    $pass = <$in>;
    chop ($pass);
    close $in;
  } elsif ($debug_p) {
    print STDERR "$progname: $passfile: $!\n";
    $pass = 'DEBUG';
  } else {
    error ("$passfile: $!");
  }
  error ("$passfile: no password") unless ($pass);

  my $ent;
  {
    my $parser = new MIME::Parser;
    $parser->ignore_errors(1);
    $parser->tmp_to_core(1);
    $parser->output_to_core(1);
    eval { $ent = $parser->parse(\*STDIN); };
    my $err = ($@ || $parser->last_error);
    $parser->filer->purge;
    error ("parse failed: $err") if ($err);
  }

  if ($debug_p > 1) {
    print STDERR ("#" x 72) . "\nSource message:\n" . ("#" x 72) . "\n";
    $ent->print(\*STDERR);
    print STDERR "\n" . ("#" x 72) . "\n";
  }

  my $head = $ent->head;
  my $from = $head->get('From');
  my $date = $head->get('Date');
  my $to = $head->get('To');
  my $dto = $head->get('Delivered-To');
  my $subj = $head->get('Subject') || '';
  my ($topass) = ($to  =~ m/^[^\+@]+\+([^\+@]+)\@/s);
     ($topass) = ($dto =~ m/^[^\+@]+\+([^\+@]+)\@/s)
       if ($dto && !defined($topass));
  error ("no posting password provided: $to") 
    unless ($debug_p || defined($topass));
  error ("password mismatch") unless ($debug_p || $pass eq $topass);

  $subj = decode ('MIME-Header', $subj);	# Fucking Unicrud.

  # Sadly, sending photos with SMS to this address causes the URL on
  # Sprint's site to reveal my phone number.  Avoid mistakenly sending
  # an SMS instead of an email by just refusing messages from Sprint's
  # gateway.
  #
  error ("no SMS to this address!")
    if ($from =~ m/sprintpcs\.com/);

  my $html = "";
  my $img_count = 0;
  my $loc;

  my %files;
  my %file_bodies;

  foreach my $part (process_part ($ent, 0, ())) {

    if (ref($part) =~ m/^MIME/s) {  # It's an image
      $img_count++;
      my $name = $part->head->recommended_filename;
      my $ct = $part->head->mime_type;
      my $data = $part->bodyhandle->as_string();
      my ($big, $thumb, $w, $h, $loc2) =
        save_image ($wp || $twit, $name, $ct, $data);
      my $video_p = ($ct =~ m@video/@si);
      
      $file_bodies{$thumb} = [ $ct, $data ] if ($thumb && $data);

      $files{$1} = $big   if ($big   && $big   =~ m@([^/]+)$@si);
      $files{$1} = $thumb if ($thumb && $thumb =~ m@([^/]+)$@si);

      if ($w < $h) {			# if it's portrait, shrink it by 1/3rd
        $w = int($w * 0.666 + 0.5);
        $h = int($h * 0.666 + 0.5);
      }

      my $hh = $h + 16;  # for controller
      $part = ($video_p
               ? (" <OBJECT DATA=\"$big\" TYPE=\"$ct\" WIDTH=$w HEIGHT=$hh>\n" .
                  "  <PARAM NAME=\"movie\" VALUE=\"$big\" />\n" .
                  "  <PARAM NAME=\"allowFullScreen\" VALUE=\"true\" />\n" .
                  "  <PARAM NAME=\"controller\" VALUE=\"true\" />\n" .
                  "  <PARAM NAME=\"autoplay\" VALUE=\"false\" />\n" .
                  "  <PARAM NAME=\"scale\" VALUE=\"aspect\" />\n" .
                  " </OBJECT>"
                 )
               : ("<A HREF=\"$big\">" .
                  "<IMG SRC=\"$thumb\" STYLE=\"width:100%; height:auto;" .
                     " max-width:${w}px; max-height:${h}px;" .
                     " border: 1px solid; box-sizing: border-box;" .
                     " margin: 2px;\">" .
                  "</A>"));
      $part = ("<DIV ALIGN=CENTER>" .
               $part .
               "</DIV>\n");
      $loc = $loc2 if $loc2;
    } else {
      $part = trim_signature($part);
      $part = clean_html($part);
    }
    $html .= $part;
  }

  # Group adjacent images together into the same DIV.
  #
  1 while ($html =~ s@( <DIV[^<>]*> \s* )
                      (( <A[^<>]*> \s* <IMG[^<>]*> \s* </A> \s* )+ )
                      </DIV> \s*
                      \1
                     @$1$2@gsix);

  # If two adjascent images are portrait+landscape, adjust their target widths.
  #
  $html =~ s@( <DIV[^<>]*> \s* )
             ( (?: <A[^<>]*> \s* <IMG[^<>]*> \s* </A> \s* )+ )
             ( \s* </DIV> )
            @{ $1 . adjust_image_layout ($img_count, $2) . $3 }@gsexi;

  my $tags;
  ($tags, $html) = split_tag_headers ($html);

  # Trim newlines since LJ preformats that shit.
  $html =~ s/\s+/ /gsi;
  $html =~ s@\s+(</?(DIV|P))@$1@gsi;
  $html =~ s/\s+$/\n/si;

  $html = "$tags\n$html" if $tags;

  my $priv_p = ($tags && $tags =~ m/^(lj-)?security:/mi);

  # LJ and WordPress can have prettier locations.  Twitter requires floats.
  #
  # Convert: "37.771007 N, 122.412694 W"
  #      to: "37° 46' 15.63" N 122° 24' 45.70 W"
  #      or: "37.771007, -122.412694"
  #      to: "37° 46' 15.63" -122° 24' 45.70"
  #
  my $pretty_loc = $loc;
  $pretty_loc =~ s@\b([-+]?\d+\.\d+)\b
                  @{ my $d = $1;
                     my $m = (60 * ($d - int($d)));
                     my $s = (60 * ($m - int($m)));
                     sprintf("%d\302\260 %d' %.2f\"", $d, $m, $s);
                   }@gsexi
    if $pretty_loc;

  $subj =~ s/^\s+|\s+$//gsi;

  ljpost ($lj, $from, $subj, $loc, $pretty_loc, $html)
    if ($lj);
  wppost ($wp, $from, $subj, $date, $loc, $pretty_loc, $html)
    if ($wp);
  twit ($twit, $subj, $loc, $pretty_loc, $html, \%file_bodies)
    if ($twit && !$priv_p);
  checkin ($from, sort keys (%files));
}


sub error($) {
  my ($err) = @_;
  print STDERR "$progname: $err\n";
  exit 1;
}

sub usage() {
  print STDERR "usage: $progname [--verbose] [--debug] " .
    "[--livejournal user] [--twitter user] [--wordpress user]\n";
  exit 1;
}

sub main() {
  my ($lj, $wp, $twit);

  while ($#ARGV >= 0) {
    $_ = shift @ARGV;
    if (m/^--?verbose$/) { $verbose++; }
    elsif (m/^-v+$/) { $verbose += length($_)-1; }
    elsif (m/^--?debug$/) { $debug_p++; }
    elsif (m/^--?(lj|livejournal)$/) { $lj = shift @ARGV; }
    elsif (m/^--?(wp|wordpress)$/) { $wp = shift @ARGV; }
    elsif (m/^--?twit(ter)?$/) { $twit = shift @ARGV; }
    elsif (m/^-./) { usage; }
    else { usage; }
  }

  if ($debug_p > 1) {
    my $f = "/tmp/ljpost.log";
    unlink $f;
    print STDERR "$progname: logging to $f\n";
    open (STDOUT, ">$f") || error ("$f: $!");
    *STDERR = *STDOUT;
  }

  usage unless (defined($lj) || defined($wp) || defined($twit));
  post ($lj, $wp, $twit);
}

main();
POSIX::_exit(0);  # Something is causing a SEGV at exit!
exit 0;
