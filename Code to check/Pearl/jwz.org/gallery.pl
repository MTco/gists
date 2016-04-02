#!/usr/bin/perl -w
# Copyright © 2000-2016 Jamie Zawinski <jwz@jwz.org>
#
# Permission to use, copy, modify, distribute, and sell this software and its
# documentation for any purpose is hereby granted without fee, provided that
# the above copyright notice appear in all copies and that both that
# copyright notice and this permission notice appear in supporting
# documentation.  No representations are made about the suitability of this
# software for any purpose.  It is provided "as is" without express or 
# implied warranty.
#
# Created: 13-Sep-2000.
#
# Generates an HTML gallery of images, with thumbnail pages, plus an HTML
# page for each image, with previous/next/etc links.
#
# For an example of the kinds of pages this script generates, see the
# DNA Lounge photo galleries:
#
#    http://www.dnalounge.com/gallery/
#
# Usage:  gallery.pl *.jpg
#
#    For each xyz.jpg file, it will create xyz-thumb.jpg and xyz.html, plus
#    a top-level index.html file displaying the thumbnails.  There are a
#    number of additional options:
#
#    --thumb-height N	When generating thumbnail images, how tall they
#			should be.  Note: thumbnails are only generated if
#			the thumb JPG file does not already exist, so if you
#			change your mind about the thumb height, delete all
#			the *-thumb.jpg files first to make them be
#			regenerated.
#
#    --width N		How wide the thumbnail index page should be (by using
#	 		a max-width div.)  Default unlimited.
#
#    --exif-keywords	If this is specified, then the EXIF keywords in the
#			image files will be used as implicit --heading options.
#
#    --title STRING	What to use for the index.html title.
#
#    --verbose		Be loud; to be louder, "-vvvvv".
#
#    --debug		Don't write any files but show what would happen.
#
#    --re-thumbnail     In this mode, no HTML is generated; instead, it
#                       re-builds any thumbnail files that are older than
#                       their corresponding images.  In this mode (and only
#                       in this mode) the thumbs will be built with the same
#                       dimensions as before.
#
#    --guess            Instead of generating anything, this just looks at
#                       the "index.html" file in the current directory and
#                       prints out a guess as to which gallery.pl args were
#                       used to create it (including --width, --heading flags
#                       and image order).
#
#    --byline "Name URL"  Inserts a "Photos by ..." line.
#
#    --youtube "Title URL"  Inserts a Youtube video.
#
#    --thumb JPG	Marks this image with REL="thumb" and creates a square
#			"thumb.jpg" from it representing the whole gallery.
#
#
#    Additional options are the names of the image files, which can be GIF or
#    JPEG files.  Files ending with "-thumb.jpg" and ".html" are ignored, as
#    are emacs backup files, so it's safe to do "gallery.pl *" without
#    worrying about the extra stuff the wildcard will match.
#
#    Additionally, the option "--heading HTML-STRING" can appear mixed in
#    with the images: it emits a subheading at that point on the index page.
#    So, the arguments
#
#        1.jpg 2.jpg 3.jpg --heading 'More Images' 4.jpg 5.jpg 6.jpg
#
#    would put a line break and the "More Images" heading between images
#    4 and 5.  It will also place a corresponding named anchor there.
#
#    Files are never overwritten unless their contents would have changed,
#    so you can re-run this without your write dates getting lost.


require 5;
use diagnostics;
use strict;
use Config;
use POSIX qw(mktime strftime);
use IPC::Open2;
use Cwd;
use HTML::Entities;

my $progname = $0; $progname =~ s@.*/@@g;
my ($version) = ('$Revision: 1.154 $' =~ m/\s(\d[.\d]+)\s/s);

my @signames = split(' ', $Config{sig_name});

my $verbose = 0;
my $debug_p = 0;

my $page_width = undef;
my $thumb_height = 360;  # was 120
my $do_last_link_p = 1;
my $re_thumb_p = 0;
my $url_base = undef;
my $js_hack = undef;

# Ignore any EXIF keywords beginning with "§"
my $excluded_exif_keywords = "^\302\244 ";

my $title = "Gallery";

my $thumb_page_header = 
'<!DOCTYPE HTML PUBLIC "-//W3C//DTD HTML 4.01 Transitional//EN"
	  "http://www.w3.org/TR/html4/loose.dtd">
<HTML>
 <HEAD>
  <TITLE>%%TITLE%%</TITLE>
%%LINKS%%
  <STYLE TYPE="text/css">
   <!--
    body { font-family: Arial,Helvetica,sans-serif; font-size:10pt;
           color: #0F0; background: #000; }
    td   { font-size:10pt; }

    .navL { color: #666; font-weight: bold; float: left;  }
    .navR { color: #666; font-weight: bold; float: right; text-align:right; }
    .navC { color: #666; font-weight: bold; }

    .photo { width: 100%; height: auto; margin: 4px 0; border: 1px solid;
             display: block; }
    .thumb {
       width: auto; height: 11em; min-width: 7em;
       border: 1px solid; margin: 0.2em;
    }
    a:link    { color: #0DF; }
    a:visited { color: #AD0; }
    a:active  { color: #F63; }
    @media print {
     * { color: black !important;
         border-color: black !important;
         background: white !important; }
     .noprint { display: none !important; }
     .navL    { display: none !important; }
     .navR    { display: none !important; }
     .navC    { display: none !important; }
    }
   -->
  </STYLE>
 </HEAD>
 <BODY>
  <H1 ALIGN=CENTER>%%TITLE%%</H1>
';

my $image_page_header = $thumb_page_header;

my $thumb_page_footer = " </BODY>\n</HTML>\n";
my $image_page_footer = " </BODY>\n</HTML>\n";

# Converts &, <, >, " and any UTF8 characters to HTML entities.
# Does not convert '.
#
sub html_quote($) {
  my ($s) = @_;
  return HTML::Entities::encode_entities ($s,
    # Exclude "=042 &=046 <=074 >=076
    '^ \t\n\040\041\043-\045\047-\073\075\077-\176');
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

  # "O'Foo"
  $s =~ s/\b([OD]\')(\w)/$1\U$2/g;

  # conjuctions and other small words get lowercased
  $s =~ s/\b(a|and|in|is|it|of|the|for|on|to|y|et|le|la|el|von|de|der)\b/\L$1/ig;

  # initial and final words always get capitalized, regardless
  $s =~ s@(^|[-/]\s*)(\w)@$1\u$2@gs;
  $s =~ s/(\s)(\S+)$/$1\u\L$2/;

  # force caps for some things (CD numbers, roman numerals)
  $s =~ s/\b(((cd|ep|lp|sf|dj)\d*)|([ivxcdm]{3,}))\b/\U$1/ig;

  # kludge: downcase some entities
  $s =~ s/(&(amp|lt|gt|apos|quot);)/\L$1/ig;

  # In-word entities are downcased.
  $s =~ s/([a-z]&[a-z\d]+;)/\L$1/ig;
  $s =~ s/(&[a-z\d]+;[a-z])/\L$1/ig;

  # Guh, &apos;S
  $s =~ s/(&apos;s\b)/\L$1/ig;

  # Downcase &#xFFF;
  $s =~ s/(&#x[a-f\d]+;)/\L$1/ig;

  $s =~ s/([:,+]) the\b/$1 The/ig;
  $s =~ s/([:,]) la\b/$1 La/ig;
  $s =~ s/( vs\.? )/\L$1/ig;

  $s =~ s/-ts/-Ts/ig;
  $s =~ s/\b(GWAR|KMFDM|VNV|RX|XP|VTG|XPQ|DNA)\b/\U$1/ig;
  $s =~ s/brokeNCYDE/brokeNCYDE/ig;
  $s =~ s/\b(McCool)/McCool/ig;
  $s =~ s/\b(B\.C\.)/\U$1/ig;
  $s =~ s/BloodWIRE/BloodWIRE/ig;
  $s =~ s/-ettes\b/-Ettes/ig;
  $s =~ s/-volts\b/-Volts/ig;

  $s =~ s/The y Axes/The Y Axes/g;
  $s =~ s/Dkstr/DKSTR/g;
  $s =~ s/Qbert/QBert/g;
  $s =~ s/Acxdc/ACxDC/g;
  $s =~ s/\bnyc\b/NYC/g;

  $s =~ s/K&#x14c;Ban/K&#X14c;ban/g;
  $s =~ s/K&#x14d;Ban/K&#X14c;ban/g;

  return $s;
}


# returns an anchor string from some HTML text
#
sub make_anchor($$) {
  my ($anchor, $count) = @_;

  return '' unless $anchor;
  $anchor =~ s@^(\s*</?(BR|P)\b[^<>]*>\s*)+@@sgi; # lose leading white tags
  $anchor =~ s@</?(BR|P)\b[^<>]*>.*$@@sgi;        # only use first line

  $anchor =~ s@&[^;\s]+;@@gi;		# lose entities
  $anchor =~ s@</?(BR|P)\b[^<>]*>@ @gi; # tags that become whitespace
  $anchor =~ s/<[^<>]*>//g;             # lose all other tags
  $anchor =~ s/\'s/s/gi;		# posessives
  $anchor =~ s/\.//gi;			# lose dots
  $anchor =~ s/[^a-z\d]/ /gi;           # non alnum -> space
  $anchor =~ s/^ +//;                   # trim leading/trailing space
  $anchor =~ s/ +$//;
  $anchor =~ s/\s+/_/g;                 # convert space to underscore
  $anchor =~ tr/A-Z/a-z/;               # downcase

  $anchor =~ s/^((_?[^_]+){5}).*$/$1/;  # no more than 5 words

  if ($anchor eq '' && $count > 0) {
    # kludge for when we had some headings, but then go back to "no heading"
    # at the end of the gallery...
    $anchor = 'bottom';
  }

  return $anchor;
}

my $noindex_p = 0;   # kludge for the --noindex option


# If there's an index.html file, load the default <HEAD> and stylesheet
# for all pages (thumbnail indexes and single image pages) from that.
#
sub load_template() {
  my $file = "index.html";

  my $galthumb = undef;
  if (open (my $in, '<', $file)) {
    print STDERR "$progname: reading template $file\n" if ($verbose > 1);
    local $/ = undef;  # read entire file
    my $body = <$in>;
    close $in;

    $body =~ s@(<TITLE>).*?(</TITLE>)@$1%%TITLE%%$2@s;
    $body =~ s@( [ \t]* < 
                 (?: LINK | META ) \s+ 
                 (?: REL | PROPERTY | NAME ) = 
                 \" ( image_src | og:image | twitter:image\d* |
                      twitter:card | medium | description |
                      top | up | prev | next | first | last )
                     \" [^<>]* > [ \t]* \n)+
              @%%LINKS%%@s;

    $body =~ s@^([ \t]*</HEAD>)@%%LINKS%%\n$1@mix
      unless ($body =~ m@%%LINKS%%@);

    if ($body =~ m@^( .* <!-- \s %%BOTTOM_START%% \s --> \s* )
                    .*
                    ( <!-- \s %%BOTTOM_END%% \s --> .* )$@six) {
      ($thumb_page_header, $thumb_page_footer) = ($1, $2);
      ($image_page_header, $image_page_footer) = ($1, $2);
    } else {
      $body =~ s@(<BODY\b[^<>]*>).*$@$1\n@si;

      $thumb_page_header = $body;
      $image_page_header = $body;
    }
  }
}


# Returns true if the two files differ (by running "cmp")
#
sub cmp_files($$) {
  my ($file1, $file2) = @_;

  my @cmd = ("cmp", "-s", "$file1", "$file2");
  print STDERR "$progname: executing \"" . join(" ", @cmd) . "\"\n"
    if ($verbose > 3);

  system (@cmd);
  my $exit_value  = $? >> 8;
  my $signal_num  = $? & 127;
  my $dumped_core = $? & 128;

  error ("$cmd[0]: core dumped!") if ($dumped_core);
  error ("$cmd[0]: signal $signal_num!") if ($signal_num);
  return $exit_value;
}


sub diff_files($$) {
  my ($file1, $file2) = @_;

  my @cmd = ("diff", 
#             "-U2",
             "-U1",
             "--unidirectional-new-file", "$file1", "$file2");
  print STDERR "$progname: executing \"" . join(" ", @cmd) . "\"\n"
    if ($verbose > 3);

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
sub rename_or_delete($$;$) {
  my ($file, $file_tmp, $suffix_msg) = @_;

  my $changed_p = cmp_files ($file, $file_tmp);

  if ($changed_p && $debug_p) {
    print STDOUT "\n" . ('#' x 79) . "\n";
    diff_files ("$file", "$file_tmp");
    $changed_p = 0;
  }

  if ($changed_p) {

    if (!rename ("$file_tmp", "$file")) {
      unlink "$file_tmp";
      error ("mv $file_tmp $file: $!");
    }
    print STDERR "$progname: wrote $file" .
      ($suffix_msg ? " $suffix_msg" : "") . "\n";

  } else {
    unlink "$file_tmp" || error ("rm $file_tmp: $!\n");
    print STDERR "$file unchanged" .
                 ($suffix_msg ? " $suffix_msg" : "") . "\n"
        if ($verbose);
    print STDERR "$progname: rm $file_tmp\n" if ($verbose > 2);
  }
}


# If we are in a DNA Lounge directory, go through Menuify.pm instead
# of writing the file directly.
#
sub dna_write_file ($$) {
  my ($file, $body) = @_;

  my $menuify = 'utils/menuify.pl';
  my ($n, $d);
  for ($n = 0; $n < 5; $n++) {
    $d = "../" x $n;
    last if -f "$d$menuify";
  }
  return 0 unless -f "$d$menuify";

  # Make sure DNA NNN.html files have the magic javascript.
  #
  if ($file !~ m@index\.html$@si) {
    my $d2 = $d;
    $d2 =~ s@^\.\./@@s;

    my $js = undef;
    foreach my $d0 ($d2, "${d2}gallery/",
                    $d,  "${d}gallery/") {
      $js = "${d0}gallery.js" unless ($js && -e $js);
    }
    error ("can't find $js") unless (-e $js);

    $js = "  <SCRIPT type=\"text/javascript\" SRC=\"${js}?1\"></SCRIPT>";
    $body =~ s@( *</HEAD>)@$js$1@si;
  }

  my $cwd = getcwd();

  # Make the pathname be relative to the web root.
  $file = "$cwd/$file";
  $file =~ s@ ^ .*? ( ( [^/]+ / ){$n} [^/]* ) $@$1@sx;

  # Fix the "top" link to point to the web root.
  $body =~ s@( <LINK \s+ REL=[\'\"] top [\'\"] \s+ HREF=[\'\"] ) [^\'\"]+
            @$1$d@gsix;

  my @cmd = ($menuify, '--stdin', $file);
  push @cmd, '--debug' if ($debug_p);
  # push @cmd, '--validate';  # This fails if it's the first galleryize.pl run

  print STDERR "$progname: executing: " . join(' ', @cmd) . "\n"
    if ($verbose > 2);

  chdir ($d);

  my ($in, $out);
  my $pid = open2 ($out, $in, @cmd);
  print $in $body;
  close ($in);
  local $/ = undef;  # read entire file
  while (<$out>) { print STDOUT $_; }
  waitpid ($pid, 0);
    
  chdir ($cwd);
    
  return 1;
}


# Write the given body to the file, but don't alter the file's
# date if the new content is the same as the existing content.
#
sub write_file_if_changed($$;$) {
  my ($outfile, $body, $suffix_msg) = @_;

  return if dna_write_file ($outfile, $body);

  my $file_tmp = "$outfile.tmp";
  open (my $out, '>', $file_tmp) || error ("$file_tmp: $!");
  (print $out $body) || error ("$file_tmp: $!");
  close $out || error ("$file_tmp: $!");
  rename_or_delete ($outfile, $file_tmp, $suffix_msg);
}


# Look at an index.html file and try to guess what gallery.pl args were
# used to create it...
#
sub guess() {
  open (my $in, '<', "index.html") || error ("index.html does not exist");
  print STDERR "$progname: reading index.html\n" if ($verbose > 1);
  local $/ = undef;  # read entire file
  my $body = <$in>;
  close $in;

  my ($title) = ($body =~ m@<TITLE>([^<>]*)</TITLE>@si);
  $title =~ s@, \d\d+ [A-Z][a-z][a-z] \d{4}$@@s; # lose date
  $title =~ s/&apos;/'/gs;
  $title =~ s/&quot;/"/gs;

  my $titleb = $title;
  $titleb =~ s@:([^ ])@\001$1@gs;
  $titleb =~ s@: [^:]+?$@@s;  # top-level title minus last subtitle
  my $titlec = $titleb;
  $titlec =~ s@: [^:]+?$@@s;  # minus last two
  $titleb =~ s@\001@:@gs;
  $titlec =~ s@\001@:@gs;


  $body =~
   s@^\s*<!--[\s#]*cross-reference kludge:\s*<B>(.*?)</B>\s*-->$@--xref $1<P>@gmi;

  $body =~ s@<!--.*?-->@@gsi;

  if ($body =~ s@^(.*?\s*)(<BR CLEAR=BOTH>\n\s*<DIV ALIGN=CENTER>\n)\s*@@si ||
      $body =~ s@^.*?\s*<DIV\s+ALIGN=CENTER>\s*<(NOBR|TABLE\b[^<>]*)>\s*@@si) {
    my $head = $1;
    $body =~ s/\s+/ /gs;

    my ($byline) = 
      ($head =~ m@ \b Photos \s+ by \s+
		   ( <A\b [^<>]* > .*? </A> \s* |
		     [^<>]+
                   )
                  @six);
    if ($byline) {
      $byline =~ s/\s+/ /gs;
      $body = "Photos by $byline\n$body";
    }

    $body =~   #### KLUDGE
      s@<SPAN STYLE="font-size: smaller">MY LIFE WITH THE<BR></SPAN>@@gsi;

    $body =~ s@(<P>)(\s*<BR>)+@$1@gs;

    $body =~ s@(<P>\s*)+@$1@gsi;

    $body =~ s@(<(P|A|BR|OBJECT))\b@\n$1@gsi;
    $body =~ s@(--xref)@\n$1@gsi;

    $body =~ s@(Photos by)\s+@$1 @gsi;		# unwrap photos href
    $body =~ s@(<IFRAME.*?</IFRAME>)@{		# unwrap inside object
      $_ = $1; s/\n/ /gs; $_; }@gsexi;
    $body =~ s@\s*(<IFRAME)@\n$1@gsi;

    $body =~ s@<BR>\s*(Photos by)@$1@gs;
    $body =~ s@(Photos by [^\n]*?)(\s*<P>\s*)+\s*@$1\n@gsi;

    $body =~ s@(?:<P>\s*)*(<A[^<>]*><B>.*?</B></A>)\s*(?:<P>\s*)*@$1\n@gsi;

    my $max_width = 0;
    my $width = 0;
    my $last_subheading = '';
    my $galthumb = undef;

    my @cmd = ();
    foreach my $line (split (/\n+/, $body)) {
      if ($line =~ m@^<A HREF=\"([^.]+)\.html\"[^<>]*><IMG SRC=\"\1-@si) {
        my $img = $1;
        my ($iw) = ($line =~ m/\bWIDTH=(\d+)\b/si);
        ($iw) = ($line =~ m/\bmax-width:\s*(\d+)\s*px\b/si)
          unless $iw;
        $width += $iw + 2 + 4 + 8
          if $iw;

        open (my $in, '<', "$img.html") || error ("$img.html does not exist");
        print STDERR "$progname: reading $img.html\n" if ($verbose > 1);
        local $/ = undef;  # read entire file
        my $body2 = <$in>;
        close $in;

        my ($it) = ($body2 =~ m@<TITLE>([^<>]*)</TITLE>@si);
        error ("$img.html: no title") unless $it;
        $it =~ s/, \d\d+ [A-Z][a-z][a-z] \d{4}$//s; # lose date
        $it =~ s@[,:] \d+$@@s; # lose digits
        my $itb = $it;

        $itb =~ s@:([^ ])@\001$1@gs;
        $itb =~ s@: ([^:]+?)$@@s;  # title minus last subtitle
        my $itb2 = $1 || '';
        $itb  =~ s@\001@:@gs;
        $itb2 =~ s@\001@:@gs;

        $itb  = html_quote (uc (html_unquote ($itb)));
        $itb2 = html_quote (uc (html_unquote ($itb2)));

        $body2 =~ s/^.*<!-- %%BOTTOM_START%% -->//s;
        my ($img2) = ($body2 =~ m@<IMG SRC=\"([^<>\"]+)"@si);
        error ("$img.html: no image") unless $img2;

        $galthumb = $img2 if ($line =~ m@REL="thumb"@si);

        $it = $title if ($itb2 =~ m/^(img_|dscn)\d+$/si);  # Bah.

        if (uc($title)  eq uc($it) ||
            uc($titleb) eq uc($it)) {
          # no funny business

          if ($last_subheading) {
            push @cmd, ("--heading0", '');
            $last_subheading = '';
          }

        } elsif (uc($title)  eq uc($itb) ||
                 uc($titleb) eq uc($itb) ||
                 uc($titlec) eq uc($itb)) {

          push @cmd, ("--heading0", $itb2)
            unless (uc($itb2) eq uc($last_subheading));
          $last_subheading = $itb2;

        } else {
          print STDERR "$progname: WARNING: " .
            "$img.html and index.html titles don't match:" .
            " \"$titleb\" vs \"$itb\"\n";

          push @cmd, ("--heading0", $itb)
            unless (uc($itb) eq uc($last_subheading));
          $last_subheading = $itb;
        }

        push @cmd, $img2;

      } elsif ($line =~ m@^<A NAME=\"[^\"<>]*\">\s*(<B>)(.*?)</B>@si) {
        $last_subheading = $2;
        $last_subheading = html_quote (uc (html_unquote ($last_subheading)));
        push @cmd, ("--heading", $last_subheading);

      } elsif ($line =~ m@^<A NAME=\"bottom@si) {
        $last_subheading = '';
        push @cmd, ("--heading", '');

      } elsif ($line =~ m@^(?:<(?:P|BR)\b[^<>]*>\s*)*Photos by\s+(.*)@si) {
        my $p = $1;
        my ($url) = ($p =~ m@HREF=\"([^<>\"]+)\"@si);
        $p =~ s/<[^<>]+>/ /gsi;
        $p =~ s/^\s+|\s+$//gs;
        $p =~ s/\s+/ /gs;
        $p .= " $url" if $url;
        push @cmd, ("--byline", $p);

        $max_width = $width if ($width > $max_width);
        $width = 0;

      } elsif ($line =~ m@^<IFRAME@si) {
        my ($url)   = ($line =~ m@SRC=\"([^<>\"]+)\"@si);
        my ($title) = ($line =~ m@TITLE=\"([^<>\"]+)\"@si);
        $url =~ s/[?&].*$//si;
        $url =~ s@/(v|embed)/@/watch?v=@si;
        $url = "http:$url" if ($url =~ m@^//@s);
        push @cmd, ("--youtube", "$title $url");

      } elsif ($line =~ m@^<BR\b@si) {
        $max_width = $width if ($width > $max_width);
        $width = 0;

      } elsif ($line =~ m@^--xref (.*)@si) {
        my $n = $1;
        $n =~ s/^\s+|\s+$//gs;
        push @cmd, ("--xref", $n);

      } elsif ($line =~ m@^<P>\s*$@si) {
        $last_subheading = '';
        push @cmd, ("--heading", '');

      } elsif ($line =~ m@^\s*$@si) {
      } elsif ($line =~ m@</BODY>@si) {
      } elsif ($line =~ m@<A[^<>]*>&lt;&lt;@si) {
      } elsif ($line =~ m@^(<P>\s*)?<DIV CLASS=\"videogroup@si) {

      } else {
        print STDERR "MISS: $line\n";#### if ($verbose);
      }
    }

    push @cmd, ("--thumb", $galthumb) if defined($galthumb);

    print STDOUT $progname;

    if ($max_width > 0 && $max_width < 1000) {
      print STDOUT " --width $max_width";
    } elsif ($body =~ m@<DIV STYLE=\"max-width:\s*(\d+.?\d*(px|em|%))@si) {
      print STDOUT " --width $1";
    }

    foreach (@cmd) {
      if (m/[^-_.a-zA-Z\d]/ || m/^$/s) {
        if (m/\'/) {
          print STDOUT " \"$_\"";
        } else {
          print STDOUT " '$_'";
        }
      } else {
        print STDOUT " $_";
      }
    }
    print STDOUT "\n";

  } else {
    error ("index.html unparsable");
  }
}


# Returns a list of the EXIF (really, IPTC) keywords in the given file.
#
sub image_exif_keywords($) {
  my ($file) = @_;
  my $v = `identify -format '%[IPTC:2:25:Keywords]' "$file"`;
  print STDERR "$progname: $file: $v\n" if ($verbose > 2);
  my @result = ();
  foreach (split (m/\s*;\s*/, $v)) {
    push @result, $_ unless m/$excluded_exif_keywords/so;
  }
  return @result;
}


sub scan_exif(@) {
  my (@files) = @_;

  my @result = ();

  my %kwds;
  my %kwd_count;

  # Gather keywords of each image, and count number of occurences of each.
  #
  print STDERR "$progname: scanning EXIF data...\n" if ($verbose > 1);
  foreach my $file (@files) {
    error ("can't use $file with --exif-keywords") if ($file =~ m/^-/s);
    my @kwds = image_exif_keywords ($file);
    $kwds{$file} = \@kwds;
    foreach my $k (@kwds) {
      $kwd_count{$k} = ($kwd_count{$k} || 0) + 1;
    }
  }

  if ($verbose > 1) {
    my @keys = keys %kwds;
    print STDERR "$progname: " . ($#keys+1) . " keywords in " .
                 ($#files+1) . " files\n";
  }

  my $last_heading = '';
  my $section_count = 0;

  foreach my $file (@files) {
    my @okwds = @{$kwds{$file}};
    my @kwds = ();
    foreach my $k (@okwds) {
      push @kwds, $k if ($kwd_count{$k} <= $#files);
    }
    my $heading = uc(join (' + ', @kwds));
    if (uc($heading) ne uc($last_heading)) {
      push @result, "--heading $heading";
      $last_heading = $heading;
      $section_count++;
    }
    push @result, $file;
  }

  print STDERR "$progname: chose $section_count headings\n" 
    if ($verbose > 1);

  return @result;
}


my %image_size_cache = ();

# In the general case, we get image sizes by running ImageMagick, but
# it's a whole lot faster to do it by hand for the common formats.

# Given the raw body of a GIF document, returns the dimensions of the image.
#
sub gif_size($) {
  my ($body) = @_;
  my $type = substr($body, 0, 6);
  my $s;
  return () unless ($type =~ /GIF8[7,9]a/);
  $s = substr ($body, 6, 10);
  my ($a,$b,$c,$d) = unpack ("C"x4, $s);
  return (($b<<8|$a), ($d<<8|$c));
}


# Given the raw body of a JPEG document, returns the dimensions of the image.
#
sub jpeg_size($) {
  my ($body) = @_;
  my $i = 0;
  my $L = length($body);

  my $c1 = substr($body, $i, 1); $i++;
  my $c2 = substr($body, $i, 1); $i++;
  return () unless (ord($c1) == 0xFF && ord($c2) == 0xD8);

  my $ch = "0";
  while (ord($ch) != 0xDA && $i < $L) {
    # Find next marker, beginning with 0xFF.
    while (ord($ch) != 0xFF) {
      return () if (length($body) <= $i);
      $ch = substr($body, $i, 1); $i++;
    }
    # markers can be padded with any number of 0xFF.
    while (ord($ch) == 0xFF) {
      return () if (length($body) <= $i);
      $ch = substr($body, $i, 1); $i++;
    }

    # $ch contains the value of the marker.
    my $marker = ord($ch);

    if (($marker >= 0xC0) &&
        ($marker <= 0xCF) &&
        ($marker != 0xC4) &&
        ($marker != 0xCC)) {  # it's a SOFn marker
      $i += 3;
      return () if (length($body) <= $i);
      my $s = substr($body, $i, 4); $i += 4;
      my ($a,$b,$c,$d) = unpack("C"x4, $s);
      return (($c<<8|$d), ($a<<8|$b));

    } else {
      # We must skip variables, since FFs in variable names aren't
      # valid JPEG markers.
      return () if (length($body) <= $i);
      my $s = substr($body, $i, 2); $i += 2;
      my ($c1, $c2) = unpack ("C"x2, $s);
      my $length = ($c1 << 8) | ($c2 || 0);
      return () if ($length < 2);
      $i += $length-2;
    }
  }
  return ();
}


# Given the raw body of a PNG document, returns the dimensions of the image.
#
sub png_size($) {
  my ($body) = @_;
  return () unless ($body =~ m/^\211PNG\r/s);
  my ($bits) = ($body =~ m/^.{12}(.{12})/s);
  return () unless defined ($bits);
  return () unless ($bits =~ /^IHDR/);
  my ($ign, $w, $h) = unpack("a4N2", $bits);
  return ($w, $h);
}


# Returns the width and height of an image file by running "convert".
#
sub imagemagick_size($) {
  my ($file) = @_;

  my @cmd = ('identify',
           # '-define', 'pdf:use-trimbox=true',   # sometimes StackUnderflow
             '-density', '300x300',
             '-format', '%wx%h\n',
             $file . '[0]');
  print STDERR "$progname: executing: " . join(" ", @cmd) . "\n"
    if ($verbose > 2);

  my ($in, $out);
  my $pid = open2 ($out, $in, @cmd);
  close ($in);
  local $/ = undef;  # read entire file
  my $result = <$out>;
  waitpid ($pid, 0);

  print STDERR "$progname:   ==> $result\n" if ($verbose > 2);

  my ($w, $h) = ($result =~ m/^(\d+)x(\d+)\s*$/);

  return ($w, $h);
}


# Returns the width and height of the image, error if it doesn't exist.
#
sub image_size($) {
  my ($file) = @_;

  my $cache = $image_size_cache{$file};
  return @{$cache} if $cache;

  error ("$file does not exist") unless -f $file;
  my ($w, $h);

  my $body = '';
  open (my $in, '<:raw', $file) || error ("$file: $!");
  my $size = 4 * 1024;  # 4K isn't enough for all JPEGs, but is for most.
  my $n = sysread ($in, $body, $size);
  print STDERR "$progname: $file: read $n bytes\n" if ($verbose > 2);
  close ($in);

  ($w, $h) = jpeg_size ($body)        unless ($w && $h);
  ($w, $h) = gif_size ($body)         unless ($w && $h);
  ($w, $h) = png_size ($body)         unless ($w && $h);
  ($w, $h) = imagemagick_size ($file) unless ($w && $h);

  error ("no size: $file") unless ($w && $h);

  my @c = ($w, $h);
  $image_size_cache{$file} = \@c;

  return ($w, $h);
}


# Generates a bunch of HTML pages for a gallery of the given image files.
# These are the indexN pages that contain inline thumbnails.
#
sub generate_pages($@) {
  my ($galthumb, @images) = @_;

  my %thumbs  = ();
  my %sizes   = ();

  load_template ();

  # For each image: ensure there is a thumbnail, and find the sizes of both.
  #
  my $top_byline = undef;
  my $byline_count = 0;
  my $last_byline = '';
  my %byline_of;
  foreach my $img (@images) {

    $byline_count++ if ($img =~ m/^--?byline /);
    $last_byline = $1 if ($img =~ m/^--?byline (.*)/);

    next if ($img =~ m/^--?heading0? /);
    next if ($img =~ m/^--?byline /);
    next if ($img =~ m/^--?youtube /);
    next if ($img =~ m/^--?xref /);
    next if ($img =~ m/^--?keywords /);

    my ($w, $h) = image_size ($img);
    if (! $h) {
      print STDERR "$progname: unable to get dimensions: $img\n";
      next;
    }

    my @L0 = ($w, $h);
    $sizes{$img} = \@L0;
    my $hh = $img;
    $hh =~ s/\.[^.]+$/.html/s;
    $byline_of{$hh} = $last_byline;

    my $t;
    ($t, $w, $h) = thumb ($img, $w, $h, $last_byline);
    $thumbs{$img} = $t;
    my @L1 = ($w, $h);
    $sizes{$t} = \@L1;
  }

  return if ($re_thumb_p);

  my $toplevel_title = '';
  my $subtitle_subpages_p = 1;

  my $prev_galthumb = undef;


  # Extract the title from the existing index.html file, if any.
  # Also the existing thumb image.
  {
    my $file = "index.html";
    if (open (my $in, '<', $file)) {
      local $/ = undef;  # read entire file
      my $body = <$in>;
      if ($body =~ m@<TITLE\b[^<>]*>(.*?)</TITLE\b[^<>]*>@si) {
        $toplevel_title = $1;
      }
      if ($body =~ m@<A HREF=\"([^<>\"]+)\" REL=\"thumb\">@si) {
        $prev_galthumb = $1;
      }
      close $in;
    }
  }


  # Default to the galthumb in the index.html file if there is one
  # and it wasn't specified on the command line; else use the first image.

  if (!defined($galthumb)) {
    $galthumb = $prev_galthumb;
  }
  if (!defined($galthumb)) {
    foreach (@images) {
      next if m/^-/s;
      $galthumb = $_;
      last;
    }
  }

  if (defined($galthumb)) {
    $galthumb =~ s/(-thumb)?\.[^.]+$//si;
    $galthumb .= ".html";
  }

  my $ogalthumb = $galthumb;


  # Determine whether any subheading is already contained within the overall
  # title.  If it is, then strip the overall title from the title of sub-pages.
  # This is to handle these two cases:
  #
  #       "DNA Lounge: Cabaret Verdalet"               (thumbnail page title)
  #       "DNA Lounge: Cabaret Verdalet: Jill Tracy"   (image sub-page title)
  #       "DNA Lounge: Cabaret Verdalet: The Lollies"  (image sub-page title)
  # and
  #       "DNA Lounge: Android Lust + Equilibrium"     (thumbnail page title)
  #       "DNA Lounge: Android Lust"                   (image sub-page title)
  #       "DNA Lounge: Equilibrium"                    (image sub-page title)
  #
  # the goal here is to avoid redundant sub-page titles like:
  #
  #       "DNA Lounge: Android Lust + Equilibrium: Android Lust"
  #
  foreach my $img (@images) {
    next unless ($img =~ m/^--heading0? (.*)/);
    my $heading = $1;
    next if ($heading =~ m/^\s*$/s);
    my $heading_in_title_p = ($toplevel_title =~ m/\Q$heading\E/i);
    $subtitle_subpages_p = 0 if ($heading_in_title_p);
  }


  my $output = '';
  my $heading_count = 0;
  my $last_h = -1;
  foreach my $img (@images) {

    my $xref_p    = ($img =~ m/^--?xref /);
    my $byline_p  = ($img =~ m/^--?byline /);
    my $youtube_p = ($img =~ m/^--?youtube /);
    my $heading_p = ($img =~ m/^--?heading(0)? /);
    my $invisible_heading_p = $heading_p && defined($1);
    next if ($img =~ m/^--?keywords /);

    my $thumb = $thumbs{$img};
    my ($w, $h);
    ($w, $h) = @{$sizes{$thumb}} unless ($xref_p || $heading_p ||
                                         $byline_p || $youtube_p);

    # new line if:
    #
    #  - this is a heading
    #  - this thumbnail has a different height than the one to the left
    #
    my $thumb_height_change_p = (!$heading_p &&
                                 !$byline_p &&
                                 !$xref_p &&
                                 !$youtube_p &&
                                 $last_h > 0 &&
                                 $last_h != $h);

    $thumb_height_change_p = 0; ####

    $last_h = ($h || -1);
    if (($heading_p && !$invisible_heading_p) ||
        $thumb_height_change_p) {
      $output .= "\n\n<P>\n\n";
    }

    if ($invisible_heading_p) {
      next;
    } elsif ($heading_p) {
      my ($heading) = ($img =~ m/^[^\s]+\s+(.*)$/s);
      #error ("no heading? $img") unless $heading;

      my $anchor = make_anchor ($heading, $heading_count);
      print STDERR "$progname: anchor: $anchor\n" if ($verbose > 2);

      $heading =  #### KLUDGE
        '<SPAN STYLE="font-size: smaller">MY LIFE WITH THE<BR></SPAN>' .
        $heading
          if ($heading eq 'THRILL KILL KULT');

      if ($heading eq '') {
        $heading = '<P>';
      } else {
        $heading = "<B>$heading</B>";
      }

      $output .= "\n";
      if ($anchor eq '') {
        $output .= $heading;
      } else {
        my $h = $heading;
        $h =~ s/& /&amp; /gs;
        $output .= "<P><A NAME=\"$anchor\">$h</A><P>";
        $heading_count++;
      }
      $output .= "\n";

      next;
    } elsif ($byline_p) {
      my ($byline) = ($img =~ m/^[^\s]+\s+(.*)$/s);

      my $top_p = (!$output && $byline_count == 1);

      $byline =~ s/\bmailto://s;
      my $url = $1 if ($byline =~ s@\s*\b(https?:/[^\s]+)\s*@@gsi);
      $url = "mailto:$1" 
        if ($byline =~ s%\s+([-_.a-z\d]+@[-_.a-z\d]+)%%gsi ||
            $byline =~ s%([-_.a-z\d]+@[-_.a-z\d]+)\s+%%gsi);
      $byline =~ s/^\s+|\s+$//gsi;

      print STDERR "$progname: " . ($top_p ? "top " : "") .
                   "byline: $byline\n"
        if ($verbose > 2);
      error ("no byline? $img") unless $byline;

      $byline = "<A HREF=\"$url\">$byline</A>" if $url;
      $byline = "Photos by $byline<P>\n";

      if ($top_p) {
        error ("botched byline") if $top_byline;
        $top_byline = $byline;
      } else {
        $output .= "\n\n<P>$byline";
      }
      next;

    } elsif ($xref_p) {
      my ($n) = ($img =~ m/^[^\s]+\s+(.*)$/s);
      $output .= "<!-- #### cross-reference kludge: <B>$n</B> -->\n";
      next;

    } elsif ($youtube_p) {
      my ($ytitle) = ($img =~ m/^[^\s]+\s+(.*)$/s);

      my $url = $1 if ($ytitle =~ s@\s*\b(https?:/[^\s]+)\s*@@si);
      error ("no youtube url: $img") unless $url;

      my ($id) = ($url =~ m@v=([^?&<>]+)@si);
      error ("$url: no id") unless $id;

      $ytitle =~ s/^\s+|\s+$//gsi;

      # Only need to hit Youtube if the command line didn't title the video.
      if (! $ytitle) {
        my ($id2, $wh, $ss, $otitle);
        for (my $i = 0; $i < 10; $i++) {
          # Retry in case it fails
          ($id2, $wh, $ss, $otitle) = split(/\t/, `youtubedown --size '$url'`);
          utf8::decode ($otitle);  # Pack multi-byte UTF-8 to wide chars.
          last if $wh;
          sleep 1;
        }
        error ("youtubedown woes: $url") unless $wh;
        my ($w, $h) = ($wh =~ m/^(\d+)\s*x\s*(\d+)$/si);
        $otitle =~ s/^\s+|\s+$//s;
        $otitle =~ s/\"//gs;

        $ytitle = $otitle;
        print STDERR "$progname: youtube: $ytitle $url\n" if ($verbose > 2);
        error ("no youtube title? $img") unless $ytitle;
      }

      $ytitle = html_quote (html_unquote ($ytitle));

      $url  = "//www.youtube.com/embed/$id";
      $url .= '?version=3';		# new hotness
      $url .= '&theme=dark';		# darker controls
      $url .= '&modestbranding=1';	# lose Youtube logo in controls
      $url .= '&fs=1';			# enable full screen button
      $url .= '&rel=0';			# turn off "related" mouseovers
      $url .= '&showsearch=0';		# turn off search field
      $url .= '&showinfo=0';		# turn off title overlay
      $url .= '&iv_load_policy=3';	# turn off annotations
      $url =~ s/\&/&amp;/gsi;		# URL-entity-quotify

      my $url2 = "//img.youtube.com/vi/$id/0.jpg";

      my $em  = ("<DIV CLASS=\"video_floater\">" .
                 "<DIV CLASS=\"video_frame\">" .
                  "<IFRAME" .
                    " CLASS=\"video_embed\"\n" .
                    ($ytitle ? " TITLE=\"$ytitle\"\n" : "") .
                    " SRC=\"$url\"\n" .
                  " ALLOWFULLSCREEN></IFRAME>" .
                 "</DIV>\n" .
                 $ytitle . "\n" .
                "</DIV>");

      $output .= "\n$em\n";

      $ogalthumb = $url2 if (! defined($ogalthumb));

      next;
    }

    $output .= "\n ";

    my $img_html = $img;
    $img_html =~ s/\.[^.]+$/.html/;

    my $rel = '';
    if (defined($galthumb) && $img_html eq $galthumb) {
      $rel =' REL="thumb"';
      $galthumb = undef;
    }

    $output .= ("<A HREF=\"$img_html\"$rel>" .
                "<IMG SRC=\"$thumb\"".
                 " CLASS=\"thumb\"" .
                 " STYLE=\"max-width:${w}px; max-height:${h}px\">" .
                "</A>");
  }

  $output =~ s/^\s*<P> *//s;

  # No blank lines between headings and bylines.
  $output =~ s@(<A NAME=[^\n]*?</A>)(?:\s*<P>)+\s*(Photos by)@$1<BR>\n$2@gsi;

  # Extra blank line above adjacent heading and byline.
  $output =~ s@(<P>)\s*(<A NAME=[^\n]*?</A>\s*<BR>\s*Photos by)@$1<BR>$2@gsi;

  # No extra blank line at the top.
  $output =~ s@^(\s*)<P>(<BR>)?(<A NAME=)@$3@gsi;

  # Wrap consecutive videos in videogroup.
  $output =~ s@( (<DIV \s+ CLASS="video_floater" .*? </DIV> [^<>]* </DIV> \s* )+ )
              @\n\n<P>\n<DIV CLASS="videogroup">\n\n$1\n</DIV>@gsxi;

  $output = ("   <DIV STYLE=\"max-width:${page_width}px\">\n" .
             "$output\n" .
             "   </DIV>")
    if ($page_width && $page_width =~ m/^\d+$/s);

  my $h = $thumb_page_header;
  my $t = $toplevel_title;
  $t =~ s/& /&amp; /gs;
  $h =~ s@%%TITLE%%@$t@gs;
  $h =~ s@%%LINKS%%@@gs;

  $output = ("$h\n" .
             "  <BR CLEAR=BOTH>\n" .
             "  <DIV ALIGN=CENTER>\n" .
             "\n" .
             "$output\n" .
             "  </DIV>\n" .
             $thumb_page_footer);

  my $file = "index.html";

  $output = splice_existing_header ($output, $top_byline, $file);

  $output =~ s/[ \t]+$//gm;
  $output =~ s/(\n\n)\n+/$1/gs;
  $output =~ s@(\s*<P>\s*)+@$1@gsi;  # consecutive P
  $output =~ s@><P@>\n\n <P@gsi;
  $output =~ s@</B></A>\n+ <P@</B></A><P@gsi;
  $output =~ s@\n+(\n[ \t]*</DIV>)@$1@gsi;

  # Give the image pages the same title as the top-level page.
  # #### I think this clause might be redundant now?
  #
  if ($toplevel_title eq '') {
    $output =~ m@<TITLE\b[^<>]*>(.*?)</TITLE\b[^<>]*>@ ||
      error ("$file: no <TITLE>");
    $toplevel_title = $1;
    $toplevel_title =~ s@\s*\bPage\s*\d+@@gsi;

    print STDERR "$progname: WARNING: no useful title in index.html: " .
                 "please use --title\n"
      if ($toplevel_title eq '');
  }

  if ($noindex_p) {
    print STDERR "$progname: $file skipped\n" if ($verbose);
  } else {
    write_file_if_changed ($file, $output);
  }


  # Generate the image pages.
  #
  my $last_anchor = undef;
  my $last_anchor_title = undef;
  my $last_anchor_invis = 0;
  my $last_keywords = undef;
  my @all_images = ();

  foreach my $img (@images) {

    my $xref_p    = ($img =~ m/^--?xref /);
    my $byline_p  = ($img =~ m/^--?byline /);
    my $youtube_p = ($img =~ m/^--?youtube /);
    my $heading_p = ($img =~ m/^--?heading(0)? /);
    my $invisible_heading_p = $heading_p && defined($1);
    my $keywords_p = ($img =~ m/^--?keywords /);

    my $thumb = $thumbs{$img};
    my ($w, $h);
    ($w, $h) = @{$sizes{$thumb}} unless ($heading_p || $xref_p ||
                                         $keywords_p ||
                                         $byline_p || $youtube_p);

    if ($img =~ m/^--heading (.*)/) {
      $last_anchor_title = $1;
      $last_anchor_invis = 0;
      $last_anchor = make_anchor ($last_anchor_title, $heading_count);
      $heading_count++ unless ($last_anchor eq '');
      next;
    } elsif ($img =~ m/^--heading0 (.*)/) {
      $last_anchor_title = $1;
      $last_anchor_invis = 1;
      $last_anchor = undef;
      next;
    } elsif ($img =~ m/^--keywords (.*)/) {
      $last_keywords = $1;
      next;
    } elsif ($byline_p || $youtube_p || $xref_p) {
      next;
    }

    # Kludge for numeric titles (don't put them in the page title)
    $last_anchor_title = undef
      if ($last_anchor_title && $last_anchor_title =~ m/^\d+$/s);

    my $ii = ($last_anchor
              ? "./\#$last_anchor"
              : "./");
    my @crud = ( $img, $ii, $last_anchor_title, $last_anchor_invis,
                 $last_keywords );
    my @crud_copy = ( @crud );
    push @all_images, \@crud_copy;
  }


  my ($first, $last);
  if ($#all_images >= 0) {
    $first = (@{$all_images[0]})[0];
    $last  = (@{$all_images[$#all_images]})[0];
  }

  for (my $i = 0; $i <= $#all_images; $i++) {
    my $crud0 = ($i == 0 ? undef : $all_images[$i-1]);
    my $crud1 = $all_images[$i];
    my $crud2 = $all_images[$i+1];
    my $prev = (defined($crud0) ? @{$crud0}[0] : undef);
    my $next = (defined($crud2) ? @{$crud2}[0] : undef);
    my $img    = @{$crud1}[0];
    my $index  = @{$crud1}[1];
    my $ptitle = @{$crud1}[2];
    my $invis  = @{$crud1}[3];
    my $kwd    = @{$crud1}[4] || '';

    # Strip off the last bit of the index file's title after the 2nd colon.
    # E.g., "DNA Lounge: Hubba Hubba: Caveman" => "DNA Lounge: Hubba Hubba".
    #
#    $toplevel_title =~ s@(: .+?): .+?$@$1@s;

    if (!$ptitle) {
      $ptitle = $toplevel_title;
    } else {
      my $tt = $toplevel_title;
      my $pt = $ptitle;

      # Sometimes we want "DNA: Event: Act" but sometimes we want "DNA: Act".
      $tt =~ s@: .+?$@@ unless ($subtitle_subpages_p);

      $pt =~ s@<(P|BR)\b[^<>]*>@ / @gi;
      $pt =~ s@<[^<>]*>@ @gi;
      $pt = capitalize($pt);
      $ptitle = "$tt: $pt";
      $kwd = "$tt: $kwd" if $kwd;
    }

    foreach ($ptitle, $kwd) {
      s/&apos;/'/gs;
      s/&quot;/"/gs;

      # WTF.  "DNA Lounge: Hubba Hubba Revue: Hubba Hubba Revue: The Fuxedos"
      s@:([^ ])@\001$1@gs;
      s@(: [^:]+)([:,])\b(.*?)\1@[$1][$2][$3]@gsi;
      s@\001@:@gs;

      # WTF: "DNA Lounge: DNA Lounge: The Frail"
      s@^([^:]+:\s+)(\1)+@$1@gsi;
    }

    my $file = $img;
    $file =~ s/\.[^.]+$/.html/;
    generate_page ($img, $ptitle, $kwd, $index, $prev, $next, $first, $last);
  }

  generate_galthumb ($ogalthumb, $prev_galthumb,
                     ($ogalthumb ? $byline_of{$ogalthumb} : undef));
}


my $cwd_cache = undef;

# Generates an HTML page for wrapping the single given image.
#
sub generate_page($$$$$$$$) {
  my ($img, $title, $keywords, $index_page,
      $prev_img, $next_img, $first_img, $last_img) = @_;

  my $file = $img;
  $file =~ s/\.[^.]+$/.html/;

  my $output = $image_page_header;

  $output =~ s@<H1[^<>]*>[^<>]*</H1[^<>]*>\s*@@gi;  # delete <H1>
  $output =~ s/[ \t]+$//s;

  my $id = $img;
  $id =~ s@\.[^.\s/]+$@@;  # lose ".jpg"

  # If the current directory or filename seems to have a date in it, use that.
  # Unless the title already has a date in it.
  #
  $cwd_cache = getcwd() unless $cwd_cache;
  if ($title =~ m@\b\d\d?[- ][a-z][a-z][a-z][- ]\d\d\d\d[a-z]?\b@si) {
  } elsif ($cwd_cache =~ m@/(\d{4})[-_./](\d\d)[-_./](\d\d)[a-z]?\b@si) {
    my $tt = mktime (0,0,0, $3, $2-1, $1-1900, 0, 0, -1);
    $id = strftime ("%d %b %Y", localtime ($tt));
  } elsif ($img =~ m@\b(\d{4})[-_./](\d\d)[-_./](\d\d)[a-z]?\b@si) {
    my $tt = mktime (0,0,0, $3, $2-1, $1-1900, 0, 0, -1);
    $id = strftime ("%d %b %Y", localtime ($tt));
  }

  foreach ($title, $keywords) {
    next unless $_;
    s/&apos;/\'/gs;
    s/&quot;/\"/gs;
    $_ .= ", $id";
    s/& /&amp; /gs;
  }

  $output =~ s/%%TITLE%%/$title/g;

  # Lose any existing versions of the tags we generate.
  $output =~ s/^\s*< (?: LINK | META) \s+
                     (?: REL | PROPERTY | NAME ) = 
                     \" ( image_src | og:image | twitter:image\d* |
                          twitter:card | medium | description |
                          top | up | prev | next | first | last )
                     \" [^<>]* > \n
              //gmix;

  my ($img_width, $img_height) = image_size ($img);
  error ("unable to get dimensions: $img") unless $img_width;

  my $links = '';

  my $first_file = $first_img;
  my $last_file  = $last_img;
  $first_file =~ s/\.[^.]+$/.html/;
  $last_file  =~ s/\.[^.]+$/.html/;

  my $prev = $prev_img || '';
  my $next = $next_img || '';
  $prev =~ s/\.[^.]+$/.html/s;
  $next =~ s/\.[^.]+$/.html/s;


  my $u = $next || $index_page; # $first_file;
  my $hprev = ($prev
               ? "<A HREF=\"$prev\" CLASS=\"navL\">&lt;&lt;</A>" 
               : "<SPAN CLASS=\"navL\">&lt;&lt;</SPAN>");
  my $hnext = ($next
               ? "<A HREF=\"$next\" CLASS=\"navR\">&gt;&gt;</A>" 
               : "<SPAN CLASS=\"navR\">&gt;&gt;</SPAN>");

  my $index = $title;
  $index =~ s/^.*?: //s;  # Lose "DNA Lounge: "
  $index =~ s/, .*?$//s;  # Lose ", DD MMM YYYY"
  $index =~ s/^Flyer Archive: 1985-1999: //s;  # #### Kludge
  $index =~ s/^Flyer Archive: 1988-2014: //s;  # #### Kludge

  $output .= ("  <DIV ALIGN=CENTER>\n" .
              "   <DIV CLASS=\"top\">\n" .
              "    <DIV CLASS=\"gwbox\">\n" .
              "     $hprev\n" .
              "     <A HREF=\"$index_page\">$index</A>\n" .
              "     $hnext\n" .
              "    </DIV>\n" .
              "   </DIV>\n" .
              "   <A HREF=\"$u\">" .
                  "<IMG SRC=\"$img\" CLASS=\"photo\"" .
                      " STYLE=\"max-width:${img_width}px;" .
                             " max-height:${img_height}px\">" .
                 "</A>\n" .
              "  </DIV>\n");

  $title =~ s/\"/&quot;/gs;  # for "description" meta tag.
  $title =~ s/& /&amp; /gs;

  # Hints for Facebook and iPhone.
  #
  $img_width += 4;
  my $img_url = "";

  if (! $url_base) {
    if (open (my $in, '<', $file)) {
      local $/ = undef;  # read entire file
      my $body = <$in>;
      ($url_base) = ($body =~ m@<(?: LINK | META ) \s+
                                 (?: REL | PROPERTY | NAME ) \s* = \s*
                                 " (?: image_src | twitter:image0 ) " \s*
                                 (?: HREF | CONTENT ) \s* = \s*
                                 " ( [^\"<>]+ ) "
                               @six);

      $url_base =~ s@[^/]+$@@si if ($url_base);
      print STDERR "$progname: guessed URL base $url_base\n" if ($verbose > 1);
      if (! $js_hack) {
        ($js_hack) = ($body =~
                      m@(([ \t]*<SCRIPT[^<>]*?SRC=.*?</SCRIPT>\n)+)@si);
        print STDERR "$progname: guessed JS $js_hack\n" if ($verbose > 1);
      }
    }
  }

  if ($url_base) {
    $img_url = $url_base;
    $img_url .= "/" unless ($img_url =~ m@/$@s);
  }
  $img_url .= $img;

  # Meta tags are case-sensitive-lower on Facebook!

  $links .= "  <link rel=\"top\"   href=\"$index_page\" />\n";
  $links .= "  <link rel=\"up\"    href=\"$index_page\" />\n";

  $links .= "  <meta name=\"twitter:card\" content=\"photo\" />\n";

  $keywords = ($keywords ? html_quote ($keywords) : $title);
  $links .= "  <meta name=\"description\" content=\"$keywords\" />\n";

  $links .= "  <meta name=\"medium\" content=\"image\" />\n";
  $links .= "  <meta property=\"og:image\" content=\"$img_url\" />\n";
  $links .= "  <link rel=\"image_src\" href=\"$img_url\" />\n";

  $links .= "  <link rel=\"first\" href=\"$first_file\" />\n"
    unless ($first_file eq $file);
  $links .= "  <link rel=\"prev\"  href=\"$prev\" />\n" if ($prev);
  $links .= "  <link rel=\"next\"  href=\"$next\" />\n" if ($next);
  $links .= "  <link rel=\"last\"  href=\"$last_file\" />\n" 
    if ($do_last_link_p && $last_file ne $file);

  $output =~ s/%%LINKS%%\n*/$links/g;

  $output .= $image_page_footer;

  # It used to be that scrollTo(0,1) would hide the nav bar in iOS.
  # This no longer works as of iOS 7.0.1.
  # Now you have to add "minimal-ui" to the "viewport" meta tag,
  # and changing that tag from Javascript does not work.  Awesome.
  # So we put this on the image pages, but not on the thumbnails page.
  #
  $output =~ s@( <meta \s+ name= [\"'] viewport [\"'] \s+
                         content = [\"'] ) ( [^<>\"']+ ) ( [^<>]* > )
              @{ my ($a, $b, $c) = ( $1, $2, $3 );
                 $b .= ", minimal-ui" unless ($b =~ m/minimal-ui/s);
                 "$a$b$c";
               }@gsexi;

  write_file_if_changed ($file, $output,
                         "for $img (${img_width}x${img_height})");

  return ($file, $img_width, $img_height);
}


# Many of our photographers include gigantic fucking watermarks on their 
# images.  This is horrible.  But, even though we don't have much of a
# choice about including them in the full-sized images, including them
# in the thumbnail images it just stupid, so when cropping the thumbnails,
# we have these custom, per-photographer rules for how many pixels need
# to be nuked to lose the watermark.  This tends to result in the thumbs
# being much more "cinemascope" than the full-sized images.  Whatever.
#
# As I said in "Nightclub photography: you're doing it wrong:"
# http://jwz.org/b/ygbd
# 
#   Lose the giant watermark.
#
#   If you feel you must caption your photos, just put your name or
#   URL at the bottom in a relatively small font. Especially do not
#   use a huge transparent logo. It looks terrible and amateurish and
#   it is distracting.
#
#   In my experience, the size of the watermark is inversely
#   proportional to the quality of the photo.
#
#   Personally, I never watermark any of my photos, because it's not
#   like anyone's going to go and get rich off of some candid shot I
#   took of them in a club. I know other people are much more hung up
#   on getting credit about such things, but try to be a little
#   understated about it so that your desire for credit doesn't take a
#   big steaming dump on the composition of the photograph itself!
#
sub crop_for_byline($) {
  my ($byline) = @_;
  return 0 unless defined($byline);
  return (
          $byline =~ m/ShutterSlut/si     ? 138 :
#         $byline =~ m/ShutterSlut/si     ? 225 :
#         $byline =~ m/Attic Floc/si      ? 130 : # Attic Blow Up
#         $byline =~ m/Attic Floc/si      ? 280 : # Attic Bootie
          $byline =~ m/Attic Floc/si      ? 170 : # Attic Bootie
          $byline =~ m/Alex Stover/si     ? 145 :
          $byline =~ m/Geoffrey Smith/si  ?  40 :
          $byline =~ m/Benjamin Wallen/si ? 125 :
          $byline =~ m/Alexander Vaos/si  ?  40 :
          $byline =~ m/Rockin' Ryan/si    ? 164 :
          $byline =~ m/Holy Mountain/si   ?  40 :
          $byline =~ m/Bill Weaver/si     ? 100 :
          $byline =~ m/Pat McCarthy/si    ?  80 :
          $byline =~ m/Shameless/si       ?  50 :
#         $byline =~ m/Jody Lyon/si       ? 138 :
          0);
}


# Create a thumbnail jpeg for the given image, unless it already exists.
#
sub thumb($$$$) {
  my ($img, $img_width, $img_height, $last_byline) = @_;

  my $thumb_file = $img;
  $thumb_file =~ s/(\.[^.]+)$/-thumb.jpg/;
  die if ($thumb_file eq $img);

  my $this_height = $thumb_height;
  my $this_width = int (($thumb_height * $img_width / $img_height) + 0.5);

  my $generate_p = 0;

  if ($debug_p) {
    my ($w2, $h2) = image_size ($thumb_file);
    if ($w2) {
      ($this_width, $this_height) = ($w2, $h2);
    }
  } elsif (! -s $thumb_file) {
    $generate_p = 1;
  } else {
    print STDERR "$progname: $thumb_file already exists\n" if ($verbose > 1);

    ($this_width, $this_height) = image_size ($thumb_file);
    error ("unable to get dimensions: $thumb_file") unless $this_width;

    if ($re_thumb_p) {

      my $id = (stat($img))[9];
      my $td = (stat($thumb_file))[9];

      if ($id <= $td) {
        print STDERR "$progname: $thumb_file ($this_width x $this_height)" .
                     " is up to date\n"
          if ($verbose > 1);
      } else {
        print STDERR "$progname: $thumb_file was $this_width x $this_height\n"
          if ($verbose > 1);

        my $ir = $img_width / $img_height;
        my $tr = $this_width / $this_height;
        my $d = $ir - $tr;
        if ($d > 0.01 || $d < -0.01) {
          print STDERR "$progname: $thumb_file: ratios differ!" .
            "  $img_width x $img_height vs $this_width x $this_height\n";
        } else {
          $generate_p = 1;
        }
      }
    }
  }

  if ($generate_p) {
    my $crop = crop_for_byline ($last_byline);
    my @cmd = ("convert", $img . '[0]',
               "-quality", "95",
#	       "-fuzz", "1%", "-trim", "+repage",
               "-crop", "-0-${crop}",	# Lose watermark
#              "-resize", "1000x$thumb_height>",
               "-resize", "${thumb_height}x${thumb_height}>",
               "-strip",
               $thumb_file);
    print STDERR "$progname: " . join(' ', @cmd) . "\n" if ($verbose > 1);
    if (system (@cmd) != 0) {
      my $status = $? >> 8;
      my $signal = $? & 127;
      my $core   = $? & 128;
      if ($core) {
        print STDERR "$progname: $cmd[0] dumped core\n";
      } elsif ($signal) {
        $signal = "SIG" . $signames[$signal];
        print STDERR "$progname: $cmd[0] died with signal $signal\n";
      } else {
        print STDERR "$progname: $cmd[0] exited with status $status\n";
      }
      exit ($status == 0 ? -1 : $status);
    }

    ($this_width, $this_height) = image_size ($thumb_file);
    print STDERR "$progname: wrote $thumb_file for $img " .
      "(${img_width}x${img_height} => ${this_width}x${this_height})\n";
  }

  return ($thumb_file, $this_width, $this_height);
}


sub generate_galthumb($$$) {
  my ($f, $of, $byline) = @_;
  return unless $f;
  $of = '' unless $of;

  foreach ($f, $of) {
    s@^(//)@http:$1@s;
    s/\.html$/.jpg/s;
  }

  my ($w, $h) = ($thumb_height, $thumb_height);
  my $fuzz = 10; ####
  my $crop = crop_for_byline ($byline);

  my $out = "thumb.jpg";
  my @cmd = ("convert", $f,
             "-fuzz", "${fuzz}%",
             "-trim",			# Lose borders and dark areas
             "-crop", "-0-${crop}",	# Lose watermark
             "+repage",
             "-gravity", "north",
             "-resize", "^${w}x${h}",
             "-extent",  "${w}x${h}",
             "-strip",
             $out);

  if ($f && $f ne $of) {
    print STDERR "$progname: replacing $out ($f vs $of)\n" if ($verbose > 1);
    unlink $out unless $debug_p;

  } elsif (-f $out) {
    print STDERR "$progname: $out already exists\n" if ($verbose > 1);
    return;
  }

  if ($debug_p) {
    print STDERR "$progname: not executing \"" .
      join(" ", @cmd) . "\"\n";
  } else {
    print STDERR "$progname: executing \"" .
      join(" ", @cmd) . "\"\n" if ($verbose > 1);
    system (@cmd);
    print STDERR "$progname: wrote $out for $f\n";
  }
}


# If the given file exists, extract the HTML header from it, and return
# new HTML with that header.  This is so we can re-run this script on a
# directory after the HTML at the top of the file has been edited without
# overwriting that (but changing the thumbnail HTML.)  Kludge!
#
sub splice_existing_header($$$) {
  my ($html, $top_byline, $file) = @_;
  open (my $in, '<', $file) || return $html;
  local $/ = undef;  # read entire file
  my $old = <$in>;
  close $in;

  if ($old =~ m@^(.*?\s*)<BR CLEAR=BOTH>\n\s*<DIV ALIGN=CENTER>\n@si ||
      $old =~ m@^(.*?\s*)<DIV ALIGN=CENTER>\s*<(NOBR|TABLE)\b@si) {
    my $oh = $1;

  $top_byline = '' unless defined($top_byline);

#   if ($top_byline) {
      ($oh =~ s@^( .*? <P> \s* )				# 1
		 (?: <BR> \s* )?
                 ( \b Photos \s+ by \s+				# 2
		   (?: <A\b [^<>]* > .*? </A> \s* |
		       [^<>]+
                   )
                   (?: <P> \s* )?
                 )
                 ( .* )$					# 3
              @$1$top_byline$3@six) ||
      ($oh =~ s@^( .*? ) ( ( </DIV> \s* )* ) $
              @$1<P>$top_byline$2@six) ||
      error ("unable to splice top byline");
      error ("botched top byline")
        if ($oh =~ m/Photos by.*Photos by/si);
      $oh =~ s@([^\s])(</DIV>\s*)$@$1\n$2@si;
#   }

    ($html =~ s@^.*?\s*(<BR CLEAR=BOTH>\n\s*<DIV ALIGN=CENTER>\n)@$oh$1@si) ||
    ($html =~ s@^.*?\s*(<DIV ALIGN=CENTER>\s*<(NOBR|TABLE))\b@$oh$1@si) ||
      error ("$file: couldn't splice pre-existing header");
    print STDERR "$progname: $file: kept pre-existing header\n"
      if ($verbose > 1);

    # Another DNA-specific kludge, for the nav at the bottom of index.html.
    my ($nav) = ($oh =~ m@<DIV CLASS="navR">\s*(.*?)(<P>|</DIV>)@si);
    if ($nav) {
      $nav =~ s/^\s+|\s+$//gsi;
      $nav = ("<DIV ALIGN=CENTER>\n" .
              " <BR CLEAR=BOTH>\n" .
              " <DIV CLASS=\"navC2\">\n" .
              "  $nav\n" .
              " </DIV>\n" .
              "</DIV>\n");
      $html =~ s@(<!-- %%BOTTOM_END%% -->)@\n$nav$1@si;

      $html =~ s@<P>\s*(</DIV>)@\n$1@gsi;

      print STDERR "$progname: $file: kept pre-existing footer\n"
        if ($verbose > 1);
    }

  } else {
    print STDERR "$progname: $file: no pre-existing header\n"
      if ($verbose > 1);
  }

  $html =~ s@(<P>)([ \t]*<P>)+@$1@gs;

  return $html;
}


# returns the full path of the named program, or undef.
#
sub which($) {
  my ($prog) = @_;
  return $prog if ($prog =~ m@^/@s && -x $prog);
  foreach (split (/:/, $ENV{PATH})) {
    return $prog if (-x "$_/$prog");
  }
  return undef;
}


sub error($) {
  my ($err) = @_;
  print STDERR "$progname: $err\n";
  exit 1;
}

sub usage() {
  print STDERR "usage: $progname [--verbose] [--width pixels]\n" .
             "       [--thumb-height pixels] [--exif-keywords]\n" .
             "       [--title string] [--heading string]\n" .
             "       [--byline name [URL]] \n" .
             "       [--re-thumbnail] [--guess]\n" .
             "       [--base URL] [--thumb IMG]\n" .
             "       image-files ...\n";
  exit 1;
}

sub main() {

  my @images;
  my $tc = 0;
  my $guess_p = 0;
  my $exif_p = 0;
  my $galthumb = undef;

  while ($_ = $ARGV[0]) {
    shift @ARGV;
    if    (m/^--?verbose$/) { $verbose++; }
    elsif (m/^-v+$/) { $verbose += length($_)-1; }
    elsif (m/^--?debug$/) { $debug_p++; }
    elsif (m/^--?width$/) { $page_width = shift @ARGV; }
    elsif (m/^--?thumb-height$/) { $thumb_height = shift @ARGV; }
    elsif (m/^--?re-?thumb(nail)?$/) { $re_thumb_p = 1; }
    elsif (m/^--?no-last$/) { $do_last_link_p = 0; }
    elsif (m/^--?title$/) { $title = shift @ARGV;
      error ("multiple titles: did you mean --heading?") if ($tc++ > 0); }
    elsif (m/^--?heading0?$/) { push @images, "$_ " . shift @ARGV; }
    elsif (m/^--?byline$/)    { push @images, "$_ " . shift @ARGV; }
    elsif (m/^--?xref$/)      { push @images, "$_ " . shift @ARGV; }
    elsif (m/^--?keywords$/)  { push @images, "$_ " . shift @ARGV; }
    elsif (m/^--?youtube$/)   { push @images, "$_ " . shift @ARGV; }
    elsif (m/^--?guess$/) { $guess_p = 1; }
    elsif (m/^--?exif(-keywords)?$/) { $exif_p = 1; }
    elsif (m/^--?no-?index$/) { $noindex_p = 1; }
    elsif (m/^--?base$/) { $url_base = shift @ARGV; }
    elsif (m/^--?thumb$/) { $galthumb = shift @ARGV; }
    elsif (m/^-./) { print STDERR "$progname: unknown: $_\n"; usage; }
    else { push @images, $_; }
  }

  return guess() if ($guess_p);

  if ($#images < 0) {
    print STDERR "$progname: no images\n";
    exit 0;
    #usage;
  }

  my @pruned = ();
  foreach (@images) {
    next if (m/-thumb\.jpg$/);
    next if (m/^thumb\.jpg$/);
    next if (m/\.html$/);
    next if (m/[~%\#]$/);
    next if (m/\bCVS$/);
    s@^(https?://)?youtu\.be/@http://www.youtube.com/watch?v=@si;
    s@^(https?://[a-z\d.]*youtube.com)@--youtube $1@si;
    push @pruned, $_;
  }

  error ("no images specified?") if ($#pruned < 0);

  @pruned = scan_exif (@pruned) if ($exif_p);

  generate_pages ($galthumb, @pruned);
}

main();
exit 0;
